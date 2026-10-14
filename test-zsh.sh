#!/usr/bin/env bash
# Exercise the zsh integration and the macOS package installer.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$PWD
ZSH_BIN="${ZSH_BIN:-$(command -v zsh 2>/dev/null || true)}"

[ -n "$ZSH_BIN" ] || {
  echo "error: zsh is required for test-zsh.sh" >&2
  exit 1
}

pass=0
fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

# Shell interaction is covered by test-workspace.sh; keep installer checks here.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pkg="$work/package"
name=$(NAMO_OS=macos NAMO_ARCH=arm64 ./packaging/package.sh v0.0.0-zsh "$pkg" 2>/dev/null)
mkdir -p "$work/unpacked"
tar -C "$work/unpacked" -xzf "$pkg/$name.tar.gz"
ZSHRC="$work/zshrc" NAMO_INSTALL_OS=Darwin \
  "$ZSH_BIN" "$work/unpacked/$name/install.sh" --prefix "$work/prefix" >/dev/null

ZSHRC="$work/zshrc" NAMO_INSTALL_OS=Darwin \
  "$ZSH_BIN" "$work/unpacked/$name/install.sh" --prefix "$work/prefix" >/dev/null
n=$(grep -c 'namo_complete.zsh' "$work/zshrc" 2>/dev/null || echo 0)
[[ "$n" == 1 ]] &&
  ok "macOS installer updates .zshrc once" ||
  bad "macOS installer duplicated its .zshrc entry"

: > "$work/zshrc-no-edit"
ZSHRC="$work/zshrc-no-edit" NAMO_INSTALL_OS=Darwin \
  "$ZSH_BIN" "$work/unpacked/$name/install.sh" --prefix "$work/prefix-no-edit" --no-rc >/dev/null
[[ ! -s "$work/zshrc-no-edit" ]] &&
  ok "macOS installer honours --no-rc" ||
  bad "macOS installer edited .zshrc with --no-rc"

[ -f "$work/prefix/share/namo_complete/namo_complete.zsh" ] &&
[ -f "$work/prefix/share/namo_complete/namo_complete.bash" ] &&
  ok "macOS package ships zsh and optional Bash integrations" ||
  bad "macOS package omitted a shell integration"
grep -q 'namo_complete.zsh' "$work/zshrc" &&
  ! grep -q 'namo_complete.bash' "$work/zshrc" &&
  ok "macOS installer updates .zshrc with zsh integration" ||
  bad "macOS installer did not select zsh"
[[ "$name" == *-macos-arm64 ]] &&
  ok "macOS artifact name identifies arm64" ||
  bad "unexpected macOS artifact name: $name"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
