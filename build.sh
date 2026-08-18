#!/usr/bin/env bash
# Build the namo_complete binary.
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
sun -c -o bin/namo_complete src/main.sun

echo
echo "built: bin/namo_complete"
file bin/namo_complete | sed 's/^/  /'
