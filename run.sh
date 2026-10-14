#!/usr/bin/env bash
# Launch the workspace from this checkout, keeping the caller's working directory.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
if [ -f "$ROOT/.env" ]; then
  set -a
  . "$ROOT/.env"
  set +a
fi
if [ ! -x "$ROOT/bin/namo_complete" ]; then
  "$ROOT/build.sh" >/dev/null
fi
export NAMO_BIN="$ROOT/bin/namo_complete"
exec "$NAMO_BIN"
