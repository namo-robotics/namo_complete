#!/usr/bin/env bash
# namo_complete installer.
#
#   curl -fsSL https://raw.githubusercontent.com/<you>/namo_complete/main/install.sh | bash
#
# Installs the Sun toolchain (if missing), builds the binary into
# ~/.local/bin, drops the shell integration into
# ~/.local/share/namo_complete, and prints the line to add to .bashrc.
#
# This script never edits your .bashrc for you.
set -euo pipefail

REPO_URL="${NAMO_REPO_URL:-https://github.com/namo-robotics/namo_complete}"
SUN_DEB_URL="${SUN_DEB_URL:-https://github.com/namo-robotics/sun/releases/download/dev/sun_0.dev_amd64.deb}"
PREFIX="${NAMO_PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
SHARE_DIR="$PREFIX/share/namo_complete"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- prerequisites ----------------------------------------------------------

# curl is not optional: Sun's stdlib has no TLS, so namo_complete performs
# HTTPS by invoking curl.
command -v curl >/dev/null 2>&1 || die "curl is required (namo_complete uses it for HTTPS)."
command -v bash >/dev/null 2>&1 || die "bash is required."

case "$(uname -s)" in
  Linux) ;;
  *) die "only Linux is supported today (Sun ships an amd64 .deb)." ;;
esac

# --- sun toolchain ----------------------------------------------------------

if command -v sun >/dev/null 2>&1; then
  say "sun already installed: $(sun --version 2>&1 | head -1)"
else
  say "installing the Sun toolchain"
  if ! command -v dpkg >/dev/null 2>&1; then
    die "sun is not installed and this is not a Debian/Ubuntu system.
       Build Sun from source (https://github.com/namo-robotics/sun), then re-run."
  fi
  tmp_deb=$(mktemp -d)/sun.deb
  curl -fsSL -o "$tmp_deb" "$SUN_DEB_URL" || die "could not download the Sun package."
  if [ "$(id -u)" -eq 0 ]; then
    dpkg -i "$tmp_deb" || { apt-get update && apt-get install -y -f; }
  else
    command -v sudo >/dev/null 2>&1 || die "need root (or sudo) to install the Sun package."
    sudo dpkg -i "$tmp_deb" || { sudo apt-get update && sudo apt-get install -y -f; }
  fi
  rm -f "$tmp_deb"
  command -v sun >/dev/null 2>&1 || die "sun still not on PATH after install."
fi

export SUN_PATH="${SUN_PATH:-/usr/lib/sun}"

# --- source -----------------------------------------------------------------

if [ -f "$(dirname "$0")/src/main.sun" ]; then
  SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
  say "building from $SRC_DIR"
else
  command -v git >/dev/null 2>&1 || die "git is required to fetch the source."
  SRC_DIR="$(mktemp -d)/namo_complete"
  say "cloning $REPO_URL"
  git clone --depth 1 "$REPO_URL" "$SRC_DIR" >/dev/null 2>&1 || die "clone failed."
fi

# --- build & install --------------------------------------------------------

say "compiling"
( cd "$SRC_DIR" && mkdir -p bin && sun -c -o bin/namo_complete src/main.sun ) \
  || die "compilation failed."

mkdir -p "$BIN_DIR" "$SHARE_DIR"
install -m 0755 "$SRC_DIR/bin/namo_complete" "$BIN_DIR/namo_complete"
install -m 0644 "$SRC_DIR/shell/namo_complete.bash" "$SHARE_DIR/namo_complete.bash"

say "installed:"
printf '    %s\n    %s\n' "$BIN_DIR/namo_complete" "$SHARE_DIR/namo_complete.bash"

# --- next steps -------------------------------------------------------------

echo
say "add this line to your ~/.bashrc:"
printf '\n    source %s/namo_complete.bash\n\n' "$SHARE_DIR"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR is not on your PATH; add it too:
           export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  warn "ANTHROPIC_API_KEY is not set. namo_complete needs it:
           export ANTHROPIC_API_KEY=sk-ant-..."
fi

echo "Then open a new shell, type part of a command, and press Ctrl-O."
