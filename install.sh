#!/bin/sh
# namo_complete installer. Downloads a prebuilt release; no compiler needed.
#
#   curl -fsSL https://raw.githubusercontent.com/namo-robotics/namo_complete/main/install.sh | sh
#
#   --version vX.Y.Z   install a specific release      (NAMO_VERSION)
#                      default: latest stable, or `dev` if there is none
#   --prefix DIR       install root, default ~/.local  (NAMO_PREFIX)
#   --no-rc            do not edit the shell startup file
set -eu

REPO="${NAMO_REPO:-namo-robotics/namo_complete}"
PREFIX="${NAMO_PREFIX:-$HOME/.local}"
VERSION="${NAMO_VERSION:-}"
NO_RC=0

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --version=*) VERSION="${1#*=}"; shift ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --prefix=*) PREFIX="${1#*=}"; shift ;;
    --no-rc|--no-bashrc) NO_RC=1; shift ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

case "$(uname -s):$(uname -m)" in
  Linux:x86_64|Linux:amd64) PLATFORM=linux; ARCH=x86_64 ;;
  Darwin:arm64) PLATFORM=macos; ARCH=arm64 ;;
  *) die "no prebuilt binary for $(uname -s)/$(uname -m); supported: Linux x86_64 and macOS arm64." ;;
esac
command -v curl >/dev/null 2>&1 || die "curl is required to download the release."


if [ -z "$VERSION" ]; then
  loc=$(curl -fsSLI -o /dev/null -w '%{url_effective}' -H 'Cache-Control: no-cache' \
        "https://github.com/$REPO/releases/latest" 2>/dev/null || true)
  VERSION="${loc##*/}"
  case "$VERSION" in
    v*) ;;
    *) VERSION=dev
       warn "no stable release of $REPO; falling back to the rolling dev build." ;;
  esac
fi

NAME="namo_complete-${VERSION}-${PLATFORM}-${ARCH}"
BASE="https://github.com/$REPO/releases/download/$VERSION"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' 0

# Rolling dev assets need cache-bypass headers because their URLs do not change.
fetch() { curl -fsSL -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' "$@"; }

say "downloading $NAME"
fetch -o "$TMP/$NAME.tar.gz" "$BASE/$NAME.tar.gz" || die "download failed: $BASE/$NAME.tar.gz"

if fetch -o "$TMP/SHA256SUMS" "$BASE/SHA256SUMS" 2>/dev/null; then
  expected=$(awk -v file="$NAME.tar.gz" '$2 == file { print $1 }' "$TMP/SHA256SUMS")
  if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$TMP/$NAME.tar.gz" | awk '{print $1}')
  else
    actual=$(shasum -a 256 "$TMP/$NAME.tar.gz" | awk '{print $1}')
  fi
  [ -n "$expected" ] && [ "$actual" = "$expected" ] \
    || die "checksum mismatch -- refusing to install."
  say "checksum verified: $(printf '%s' "$actual" | cut -c1-16)..."
else
  warn "skipping checksum verification."
fi

tar -C "$TMP" -xzf "$TMP/$NAME.tar.gz"
[ "$NO_RC" = 1 ] && set -- --no-rc || set --
"$TMP/$NAME/install.sh" --prefix "$PREFIX" "$@"

[ -n "${ANTHROPIC_API_KEY:-}" ] || warn "ANTHROPIC_API_KEY is not set."
