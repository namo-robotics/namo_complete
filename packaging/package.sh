#!/usr/bin/env bash
# Build a platform-named release tarball from the current binary.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:-${NAMO_VERSION:-v0.0.0-dev}}
OUT=${2:-dist}

case "${NAMO_OS:-$(uname -s)}:${NAMO_ARCH:-$(uname -m)}" in
  Linux:x86_64|Linux:amd64|linux:x86_64|linux:amd64) PLATFORM=linux; ARCH=x86_64 ;;
  Darwin:arm64|macos:arm64) PLATFORM=macos; ARCH=arm64 ;;
  *) echo "unsupported packaging target: ${NAMO_OS:-$(uname -s)}/${NAMO_ARCH:-$(uname -m)}" >&2; exit 1 ;;
esac
NAME="namo_complete-${VERSION}-${PLATFORM}-${ARCH}"

log() { printf "%s\n" "$*" >&2; }
checksum() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

[ -x bin/namo_complete ] || { log "building..."; ./build.sh >&2; }

PACKAGE_DIR="$OUT/$NAME"
rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR/bin" "$PACKAGE_DIR/share/namo_complete"

install -m 0755 bin/namo_complete          "$PACKAGE_DIR/bin/"
install -m 0644 shell/namo_complete.bash   "$PACKAGE_DIR/share/namo_complete/"
install -m 0644 shell/namo_complete.zsh    "$PACKAGE_DIR/share/namo_complete/"
install -m 0644 README.md LICENSE          "$PACKAGE_DIR/"
install -m 0755 packaging/install-local.sh "$PACKAGE_DIR/install.sh"
printf "%s\n" "$VERSION" > "$PACKAGE_DIR/VERSION"
[ -n "${NAMO_BUILT_WITH:-}" ] && printf "%s\n" "$NAMO_BUILT_WITH" > "$PACKAGE_DIR/BUILT-WITH"

mkdir -p "$OUT"
tar -C "$OUT" -czf "$OUT/$NAME.tar.gz" "$NAME"
DIGEST=$(checksum "$OUT/$NAME.tar.gz")
printf "%s  %s.tar.gz\n" "$DIGEST" "$NAME" > "$OUT/SHA256SUMS"

log "$(wc -c < "$OUT/$NAME.tar.gz" | tr -d " ") $OUT/$NAME.tar.gz"
log "$(cat "$OUT/SHA256SUMS")"
printf "%s\n" "$NAME"
