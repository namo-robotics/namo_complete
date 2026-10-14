#!/usr/bin/env bash
# Install the matching Sun compiler, libraries, and link tools on GitHub runners.
set -euo pipefail
: "${GITHUB_PATH:?This setup script requires a GitHub Actions runner}"
release=https://github.com/namo-robotics/sun/releases/download/dev
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT

case "$(uname -s):$(uname -m)" in
  Linux:x86_64)
    # Sun needs musl-built C++ runtime archives as well as the C compiler.
    curl -fL --retry 3 -o "$staging/musl.tgz" https://musl.cc/x86_64-linux-musl-cross.tgz
    mkdir -p /opt/cross
    tar -xzf "$staging/musl.tgz" -C /opt/cross
    /opt/cross/x86_64-linux-musl-cross/bin/x86_64-linux-musl-gcc --version
    echo '/opt/cross/x86_64-linux-musl-cross/bin' >> "$GITHUB_PATH"

    curl -fL --retry 3 -o "$staging/sun.deb" "$release/sun_0.dev_amd64.deb"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$staging/sun.deb"
    sun --version | tee /tmp/sun-version.txt
    ;;
  Darwin:arm64)
    brew install llvm@20 libarchive bash
    xcodebuild -version
    xcrun ld -version_details
    curl -fL --retry 3 -o "$staging/sun.tgz" "$release/sun-0.dev-arm64-apple-darwin.tar.gz"
    toolchain="${RUNNER_TEMP:-/tmp}/namo-sun"
    mkdir -p "$toolchain"
    tar -xzf "$staging/sun.tgz" -C "$toolchain"
    printf '%s\n' "$toolchain/bin" "$(brew --prefix)/bin" >> "$GITHUB_PATH"
    "$toolchain/bin/sun" --version | tee /tmp/sun-version.txt
    ;;
  *) echo 'error: unsupported CI platform' >&2; exit 1 ;;
esac
