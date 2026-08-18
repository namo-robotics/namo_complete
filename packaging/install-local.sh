#!/usr/bin/env bash
# Install namo_complete from an unpacked release directory.
#
# This script ships *inside* the release tarball, so it only ever copies files
# that are already next to it. The network-facing installer is install.sh in
# the repository root, which downloads a release and then calls this.
#
#   ./install.sh [--prefix DIR] [--no-bashrc-hint]
#
# Default prefix is ~/.local, giving:
#   <prefix>/bin/namo_complete
#   <prefix>/share/namo_complete/namo_complete.bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
SHOW_HINT=1

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --prefix=*) PREFIX="${1#*=}"; shift ;;
    --no-bashrc-hint) SHOW_HINT=0; shift ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -x "$HERE/bin/namo_complete" ] || {
  echo "error: $HERE/bin/namo_complete missing - is this an unpacked release?" >&2
  exit 1
}

BIN_DIR="$PREFIX/bin"
SHARE_DIR="$PREFIX/share/namo_complete"
mkdir -p "$BIN_DIR" "$SHARE_DIR"

install -m 0755 "$HERE/bin/namo_complete"                    "$BIN_DIR/namo_complete"
install -m 0644 "$HERE/share/namo_complete/namo_complete.bash" "$SHARE_DIR/"
install -m 0644 "$HERE/share/namo_complete/namo_live.bash"     "$SHARE_DIR/"
[ -f "$HERE/VERSION" ] && install -m 0644 "$HERE/VERSION" "$SHARE_DIR/VERSION"

printf 'installed:\n  %s\n  %s/namo_complete.bash\n' "$BIN_DIR/namo_complete" "$SHARE_DIR"

[ "$SHOW_HINT" = 1 ] || exit 0

cat <<EOF

Add to your ~/.bashrc:

    NAMO_LIVE=1
    source $SHARE_DIR/namo_complete.bash

Then set your API key:

    export ANTHROPIC_API_KEY=sk-ant-...

Open a new shell, start typing, and press Alt-O to accept a suggestion.
EOF

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) printf '\nNote: %s is not on your PATH. Add:\n    export PATH="%s:$PATH"\n' "$BIN_DIR" "$BIN_DIR" ;;
esac
