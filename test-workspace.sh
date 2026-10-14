#!/usr/bin/env bash
# Compile deterministic screen tests and exercise the workspace with real PTYs.
set -euo pipefail
cd "$(dirname "$0")"
if [[ -x .sun/bin/sun ]]; then
  export PATH="$PWD/.sun/bin:$PATH"
  export SUN_PATH="$PWD/.sun/lib/sun"
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sun -c -o "$work/terminal-tests" tests/workspace/terminal.sun
"$work/terminal-tests"
python3 test-workspace.py
