#!/usr/bin/env bash
# namo_complete installer. Downloads a prebuilt release; no compiler needed.
#
#   curl -fsSL https://raw.githubusercontent.com/namo-robotics/namo_complete/main/install.sh | bash
#
#   --version vX.Y.Z   install a specific release      (NAMO_VERSION)
#                      default: latest stable, or `dev` if there is none
#   --prefix DIR       install root, default ~/.local  (NAMO_PREFIX)
#   --no-bashrc        do not add the source line to ~/.bashrc
set -euo pipefail

REPO="${NAMO_REPO:-namo-robotics/namo_complete}"
PREFIX="${NAMO_PREFIX:-$HOME/.local}"
VERSION="${NAMO_VERSION:-}"
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
    --no-bashrc) NO_BASHRC=1; shift ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
  *) die "no prebuilt binary for $(uname -m); only linux-x86_64 is published." ;;
esac

if [ -z "$VERSION" ]; then
  # Follow the /releases/latest redirect: no token, no rate limit, no jq.
  loc=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
        "https://github.com/$REPO/releases/latest" 2>/dev/null || true)
  VERSION="${loc##*/}"
  case "$VERSION" in
    v*) ;;
    *) VERSION=dev
       warn "no stable release of $REPO; falling back to the rolling dev build." ;;
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
