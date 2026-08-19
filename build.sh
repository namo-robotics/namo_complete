#!/usr/bin/env bash
# Build the namo_complete binary.
#
# Needs a Sun whose stdlib carries sun.process / sun.env / sun.time (the
# 2026-08-19 dev build or newer); an older one fails on the first `using`.
set -euo pipefail

cd "$(dirname "$0")"

: "${SUN_PATH:=/usr/lib/sun}"
export SUN_PATH

if ! command -v sun >/dev/null 2>&1; then
  echo "error: the 'sun' compiler is not on PATH." >&2
  echo "       install it with ./install.sh, or see https://namo-robotics.github.io/sun/" >&2
  exit 1
fi

mkdir -p bin
echo "building bin/namo_complete ..."
if ! sun -c -o bin/namo_complete src/main.sun; then
  echo >&2
  echo "error: build failed. If the errors mention 'sun.process', 'sun.env' or" >&2
  echo "       an unknown member on a stdlib type, the installed Sun predates" >&2
  echo "       the stdlib modules this project needs. Update it:" >&2
  echo "         curl -LO https://github.com/namo-robotics/sun/releases/download/dev/sun_0.dev_amd64.deb" >&2
  echo "         sudo apt install ./sun_0.dev_amd64.deb" >&2
  exit 1
fi

echo
echo "built: bin/namo_complete"
file bin/namo_complete | sed 's/^/  /'
