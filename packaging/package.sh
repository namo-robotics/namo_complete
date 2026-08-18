#!/usr/bin/env bash
# Build the release tarball. Used by CI and runnable locally.
#
#   ./packaging/package.sh [version] [outdir]
#
# Defaults: version v0.0.0-dev, outdir dist. Prints the artifact base name on
# stdout; progress goes to stderr.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-${NAMO_VERSION:-v0.0.0-dev}}"
OUT="${2:-dist}"
ARCH="${NAMO_ARCH:-$(uname -m)}"
NAME="namo_complete-${VERSION}-linux-${ARCH}"

log() { printf '%s\n' "$*" >&2; }

[ -x bin/namo_complete ] || { log "building..."; ./build.sh >&2; }

rm -rf "${OUT:?}/$NAME"
mkdir -p "$OUT/$NAME/bin" "$OUT/$NAME/share/namo_complete"

install -m 0755 bin/namo_complete          "$OUT/$NAME/bin/"
install -m 0644 shell/namo_complete.bash \
                shell/namo_live.bash       "$OUT/$NAME/share/namo_complete/"
install -m 0644 README.md LICENSE          "$OUT/$NAME/"
install -m 0755 packaging/install-local.sh "$OUT/$NAME/install.sh"
printf '%s\n' "$VERSION" > "$OUT/$NAME/VERSION"
[ -n "${NAMO_BUILT_WITH:-}" ] && printf '%s\n' "$NAMO_BUILT_WITH" > "$OUT/$NAME/BUILT-WITH"

tar -C "$OUT" -czf "$OUT/$NAME.tar.gz" "$NAME"
( cd "$OUT" && sha256sum "$NAME.tar.gz" > SHA256SUMS )

log "$(ls -l "$OUT/$NAME.tar.gz" | awk '{print $5, $NF}')"
log "$(cat "$OUT/SHA256SUMS")"
printf '%s\n' "$NAME"
