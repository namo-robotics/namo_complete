#!/usr/bin/env bash
# Reject runtime dependencies outside the supported platform's system libraries.
set -euo pipefail
binary=${1:-bin/namo_complete}
case "$(uname -s)" in
  Linux)
    description=$(file -L "$binary")
    printf '%s\n' "$description"
    if [[ $description != *'static-pie linked'* && $description != *'statically linked'* ]]; then
      echo 'error: Linux release binary must be statically linked' >&2
      exit 1
    fi
    headers=$(readelf -lW "$binary")
    if [[ $headers == *INTERP* ]]; then
      echo 'error: Linux release binary must not require a dynamic loader' >&2
      exit 1
    fi
    dynamic=$(readelf -dW "$binary")
    if [[ $dynamic == *'(NEEDED)'* ]]; then
      echo 'error: Linux release binary must not require shared libraries' >&2
      exit 1
    fi
    ;;
  Darwin)
    dependencies=$(otool -L "$binary")
    printf '%s\n' "$dependencies"
    external=$(printf '%s\n' "$dependencies" | awk 'NR > 1 && $1 !~ /^\/usr\/lib\// && $1 !~ /^\/System\/Library\// { print $1 }')
    if [[ -n $external ]]; then
      printf 'error: macOS release binary requires non-system libraries:\n%s\n' "$external" >&2
      exit 1
    fi
    ;;
  *) echo 'error: unsupported linkage-check platform' >&2; exit 1 ;;
esac
