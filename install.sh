#!/usr/bin/env bash
# namo_complete installer. Downloads a prebuilt release; no compiler needed.
#
#   curl -fsSL https://raw.githubusercontent.com/namo-robotics/namo_complete/main/install.sh | bash
#
#   --version vX.Y.Z   install a specific release      (NAMO_VERSION)
#                      use `--version dev` for the rolling build of main
#   --prefix DIR       install root, default ~/.local  (NAMO_PREFIX)
#   --from-source      build locally; needs the Sun compiler
#   --no-bashrc        do not add the source line to ~/.bashrc
set -euo pipefail

REPO="${NAMO_REPO:-namo-robotics/namo_complete}"
PREFIX="${NAMO_PREFIX:-$HOME/.local}"
VERSION="${NAMO_VERSION:-}"
FROM_SOURCE=0
NO_BASHRC=0

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --version=*) VERSION="${1#*=}"; shift ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --prefix=*) PREFIX="${1#*=}"; shift ;;
    --from-source) FROM_SOURCE=1; shift ;;
    --no-bashrc) NO_BASHRC=1; shift ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

# curl is also the runtime HTTPS transport: Sun's stdlib has no TLS.
command -v curl >/dev/null 2>&1 || die "curl is required."
# Sun's C FFI is ELF-only and this program is entirely FFI, so there is no
# macOS build to ship. See SUN_FEEDBACK.md.
[ "$(uname -s)" = Linux ] || die "only Linux is supported (got $(uname -s)); Sun's FFI is ELF-only."
case "$(uname -m)" in
  x86_64|amd64) ARCH=x86_64 ;;
  *) die "no prebuilt binary for $(uname -m); try --from-source" ;;
esac

if [ "$FROM_SOURCE" = 1 ]; then
  command -v sun >/dev/null 2>&1 || die "--from-source needs the Sun compiler on PATH."
  SRC="$(cd "$(dirname "$0")" && pwd)"
  [ -f "$SRC/src/main.sun" ] || die "--from-source must run from a source checkout."
  ( cd "$SRC" && ./build.sh >/dev/null ) || die "build failed."
  mkdir -p "$PREFIX/bin" "$PREFIX/share/namo_complete"
  install -m 0755 "$SRC/bin/namo_complete" "$PREFIX/bin/namo_complete"
  install -m 0644 "$SRC/shell/namo_complete.bash" "$SRC/shell/namo_live.bash" \
                  "$PREFIX/share/namo_complete/"
  say "installed to $PREFIX"
  SHARE="$PREFIX/share/namo_complete"
  LINE="[ -f \"$SHARE/namo_complete.bash\" ] && . \"$SHARE/namo_complete.bash\""
  if [ "$NO_BASHRC" = 0 ] && ! { [ -f "$HOME/.bashrc" ] && grep -qF '# namo_complete' "$HOME/.bashrc"; }; then
    printf '\n# namo_complete\n%s\n' "$LINE" >> "$HOME/.bashrc"
    say "added to $HOME/.bashrc"
  else
    printf '\nAdd to ~/.bashrc:\n\n    %s\n' "$LINE"
  fi
  exit 0
fi

if [ -z "$VERSION" ]; then
  # Follow the /releases/latest redirect: no token, no rate limit, no jq.
  loc=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
        "https://github.com/$REPO/releases/latest" 2>/dev/null || true)
  VERSION="${loc##*/}"
  case "$VERSION" in
    v*) ;;
    *) die "could not find the latest release of $REPO; pass --version vX.Y.Z" ;;
  esac
fi

NAME="namo_complete-${VERSION}-linux-${ARCH}"
BASE="https://github.com/$REPO/releases/download/$VERSION"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

say "downloading $NAME"
curl -fsSL -o "$TMP/$NAME.tar.gz" "$BASE/$NAME.tar.gz" || die "download failed: $BASE/$NAME.tar.gz"

if curl -fsSL -o "$TMP/SHA256SUMS" "$BASE/SHA256SUMS" 2>/dev/null \
   && command -v sha256sum >/dev/null 2>&1; then
  ( cd "$TMP" && grep " $NAME.tar.gz\$" SHA256SUMS | sha256sum -c --status - ) \
    || die "checksum mismatch -- refusing to install."
  say "checksum verified"
else
  warn "skipping checksum verification."
fi

tar -C "$TMP" -xzf "$TMP/$NAME.tar.gz"
[ "$NO_BASHRC" = 1 ] && set -- --no-bashrc || set --
"$TMP/$NAME/install.sh" --prefix "$PREFIX" "$@"

[ -n "${ANTHROPIC_API_KEY:-}" ] || warn "ANTHROPIC_API_KEY is not set."
