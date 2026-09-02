#!/bin/sh
# Install namo_complete from an unpacked release directory.
#
#   ./install.sh [--prefix DIR] [--no-rc]
#
# Installs the binary and shell integrations, then updates the platform default
# shell configuration. Adding the source line is idempotent.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
EDIT_RC=1
MARKER="# namo_complete"

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --prefix=*) PREFIX="${1#*=}"; shift ;;
    --no-rc|--no-bashrc) EDIT_RC=0; shift ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -x "$HERE/bin/namo_complete" ] || {
  echo "error: $HERE/bin/namo_complete missing - is this an unpacked release?" >&2
  exit 1
}

case "${NAMO_INSTALL_OS:-$(uname -s)}" in
  Darwin|macos)
    SHELL_KIND=zsh
    SHELL_FILE=namo_complete.zsh
    RC_FILE="${ZSHRC:-${ZDOTDIR:-$HOME}/.zshrc}"
    ;;
  *)
    SHELL_KIND=bash
    SHELL_FILE=namo_complete.bash
    RC_FILE="${BASHRC:-$HOME/.bashrc}"
    ;;
esac

BIN_DIR="$PREFIX/bin"
SHARE_DIR="$PREFIX/share/namo_complete"
mkdir -p "$BIN_DIR" "$SHARE_DIR"

install -m 0755 "$HERE/bin/namo_complete" "$BIN_DIR/namo_complete"
install -m 0644 "$HERE/share/namo_complete/namo_complete.bash" "$SHARE_DIR/"
install -m 0644 "$HERE/share/namo_complete/namo_complete.zsh" "$SHARE_DIR/"
[ -f "$HERE/VERSION" ] &&
  install -m 0644 "$HERE/VERSION" "$SHARE_DIR/VERSION"
[ -f "$HERE/BUILT-WITH" ] &&
  install -m 0644 "$HERE/BUILT-WITH" "$SHARE_DIR/BUILT-WITH"

printf 'installed:\n  %s\n  %s/%s\n' \
  "$BIN_DIR/namo_complete" "$SHARE_DIR" "$SHELL_FILE"

"$BIN_DIR/namo_complete" --version 2>/dev/null | sed 's/^/  /' || true

other=$(command -v namo_complete 2>/dev/null || true)
if [ -n "$other" ] && [ "$other" != "$BIN_DIR/namo_complete" ]; then
  printf '\nwarning: %s comes first on your PATH and will be used instead:\n  %s\n' \
    "namo_complete" "$($other --version 2>/dev/null | head -1 || echo "$other")" >&2
fi

SOURCE_LINE="[ -f \"$SHARE_DIR/$SHELL_FILE\" ] && . \"$SHARE_DIR/$SHELL_FILE\""

if [ "$EDIT_RC" = 1 ]; then
  if [ -f "$RC_FILE" ] && grep -qF "$MARKER" "$RC_FILE"; then
    printf '  %s already sourced in %s\n' "namo_complete" "$RC_FILE"
  else
    printf '\n%s\n%s\n' "$MARKER" "$SOURCE_LINE" >> "$RC_FILE"
    printf '  added %s integration to %s\n' "$SHELL_KIND" "$RC_FILE"
  fi
else
  printf '\nAdd to %s:\n\n    %s\n' "$RC_FILE" "$SOURCE_LINE"
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) printf '\n%s is not on your PATH:\n    export PATH="%s:$PATH"\n' \
       "$BIN_DIR" "$BIN_DIR" ;;
esac

cat <<EOF

Set your API key, then open a new $SHELL_KIND shell:

    export ANTHROPIC_API_KEY=sk-ant-...
EOF
