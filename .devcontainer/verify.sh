#!/usr/bin/env bash
# Confirm the container has everything namo_complete needs, and that it is
# actually isolated from the host. Run automatically by postCreateCommand.
set -uo pipefail

fail=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=1; }

echo "namo_complete dev container check"
echo

echo "toolchain:"
for t in sun curl jq git bash node; do
  if command -v "$t" >/dev/null 2>&1; then
    ok "$t ($("$t" --version 2>&1 | head -1 | cut -c1-58))"
  else
    bad "$t missing"
  fi
done

echo
echo "sun:"
if [ -f /usr/lib/sun/stdlib.moon ]; then
  ok "stdlib.moon present (SUN_PATH=${SUN_PATH:-unset})"
else
  bad "/usr/lib/sun/stdlib.moon missing"
fi

# The compiler is only useful if it can actually produce a binary.
tmp=$(mktemp -d)
cat > "$tmp/t.sun" <<'EOF'
using sun;
function main() i32 { println("sun-ok"); return 0; }
manifest { moons: ["stdlib.moon"] }
EOF
if (cd "$tmp" && sun -c -o t t.sun >/dev/null 2>&1) && [ "$("$tmp/t" 2>/dev/null)" = "sun-ok" ]; then
  ok "compiles and runs a static binary"
else
  bad "cannot compile a trivial program"
fi
rm -rf "$tmp"

echo
echo "isolation:"
if [ -S /var/run/docker.sock ]; then
  bad "docker.sock is mounted - container can control the host daemon"
else
  ok "no docker.sock (host daemon unreachable)"
fi
if [ "$(id -u)" -ne 0 ]; then
  ok "running as non-root ($(id -un), uid $(id -u))"
else
  bad "running as root"
fi
if [ -d /workspace ]; then
  ok "workspace mounted at /workspace"
else
  bad "/workspace missing"
fi

echo
echo "credentials:"
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  ok "ANTHROPIC_API_KEY present (${#ANTHROPIC_API_KEY} chars)"
else
  printf '  \033[33mwarn\033[0m  ANTHROPIC_API_KEY not set - export it on the host before reopening\n'
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "container ready."
else
  echo "container has problems (see FAIL above)." >&2
fi
exit "$fail"
