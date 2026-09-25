#!/usr/bin/env bash
# Install the latest complete Sun toolchain locally for this checkout.
set -euo pipefail
cd "$(dirname "$0")"
staging=$(mktemp -d "${TMPDIR:-/tmp}/namo-sun.XXXXXX")
trap 'rm -rf "$staging"' EXIT
release=https://github.com/namo-robotics/sun/releases/download/dev
case "$(uname -s):$(uname -m)" in
  Linux:x86_64|Linux:amd64)
    curl -fL "$release/sun_0.dev_amd64.deb" -o "$staging/sun.deb"
    dpkg-deb -x "$staging/sun.deb" "$staging/package"
    mv "$staging/package/usr" "$staging/toolchain"
    ;;
  Darwin:arm64)
    curl -fL "$release/sun-0.dev-arm64-apple-darwin.tar.gz" -o "$staging/sun.tar.gz"
    mkdir "$staging/toolchain"
    tar -xzf "$staging/sun.tar.gz" -C "$staging/toolchain"
    ;;
  *) echo 'Unsupported build host' >&2; exit 1 ;;
esac
"$staging/toolchain/bin/sun" --version
test -f "$staging/toolchain/lib/sun/stdlib.moon"
test -f "$staging/toolchain/lib/sun/tls.moon"
mkdir -p .sun
cp -a "$staging/toolchain/." .sun/
echo 'Installed matching compiler and libraries in .sun; run ./build.sh.'
