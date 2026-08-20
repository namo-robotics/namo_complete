#!/usr/bin/env bash
# Install namo_complete from an unpacked release directory.
#
#   ./install.sh [--prefix DIR] [--no-bashrc]
#
# Copies into <prefix> (default ~/.local) and adds the source line to
# ~/.bashrc unless --no-bashrc is given. Adding the line is idempotent.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
BASHRC="${BASHRC:-$HOME/.bashrc}"
EDIT_BASHRC=1
MARKER="# namo_complete"

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --prefix=*) PREFIX="${1#*=}"; shift ;;
    --no-bashrc) EDIT_BASHRC=0; shift ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

install -m 0755 "$HERE/bin/namo_complete"                      "$BIN_DIR/namo_complete"
install -m 0644 "$HERE/share/namo_complete/namo_complete.bash" "$SHARE_DIR/"
[ -f "$HERE/VERSION" ]    && install -m 0644 "$HERE/VERSION"    "$SHARE_DIR/VERSION"
[ -f "$HERE/BUILT-WITH" ] && install -m 0644 "$HERE/BUILT-WITH" "$SHARE_DIR/BUILT-WITH"

printf 'installed:\n  %s\n  %s/namo_complete.bash\n' "$BIN_DIR/namo_complete" "$SHARE_DIR"

# Say which build this is, from the binary itself: `dev` is a rolling tag, so
# the version alone does not identify one. Same string `namo_complete --version`
# prints later, which is how a shell that is misbehaving gets identified.
"$BIN_DIR/namo_complete" --version 2>/dev/null | sed 's/^/  /' || true

# An older copy earlier on PATH is the quiet failure this catches: the install
# succeeds, and the shell goes on running the other one.
other=$(command -v namo_complete 2>/dev/null || true)
if [ -n "$other" ] && [ "$other" != "$BIN_DIR/namo_complete" ]; then
  printf '\nwarning: %s comes first on your PATH and will be used instead:\n  %s\n' \
    "namo_complete" "$($other --version 2>/dev/null | head -1 || echo "$other")" >&2
fi

SOURCE_LINE="[ -f \"$SHARE_DIR/namo_complete.bash\" ] && . \"$SHARE_DIR/namo_complete.bash\""

if [ "$EDIT_BASHRC" = 1 ]; then
  if [ -f "$BASHRC" ] && grep -qF "$MARKER" "$BASHRC"; then
    printf '  %s already sourced in %s\n' "namo_complete" "$BASHRC"
  else
    printf '\n%s\n%s\n' "$MARKER" "$SOURCE_LINE" >> "$BASHRC"
    printf '  added to %s\n' "$BASHRC"
  fi
else
  printf '\nAdd to your ~/.bashrc:\n\n    %s\n' "$SOURCE_LINE"
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) printf '\n%s is not on your PATH:\n    export PATH="%s:$PATH"\n' "$BIN_DIR" "$BIN_DIR" ;;
esac

cat <<EOF

Set your API key, then open a new shell:

    export ANTHROPIC_API_KEY=sk-ant-...
EOF
