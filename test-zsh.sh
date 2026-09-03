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

export NAMO_TEST_ROOT="$ROOT"
setup='
if [[ -n "${NAMO_TEST_ZSH_MODULE_PATH:-}" ]]; then
  module_path=("$NAMO_TEST_ZSH_MODULE_PATH" $module_path)
fi
if [[ -n "${NAMO_TEST_ZSH_FPATH_ROOT:-}" ]]; then
  fpath=("$NAMO_TEST_ZSH_FPATH_ROOT"/*(N) $fpath)
fi
'

out=$("$ZSH_BIN" -dfi -c "$setup
  NAMO_BIN=/does/not/exist
  source \"$ROOT/shell/namo_complete.zsh\"
  _namo_ask_daemon() { _NAMO_REPLY_OUT=\$'-\\tgit status\\tworking tree\\n' }
  BUFFER='git st'
  CURSOR=6
  _namo_key_request c 0
  print -r -- \"BUFFER=\$BUFFER CURSOR=\$CURSOR\"
  bindkey -M emacs \"^[o\"
  add-zle-hook-widget -L line-pre-redraw
" 2>&1)

printf '%s\n' "$out" | grep -q 'BUFFER=git status CURSOR=10' &&
  ok "Alt-O replaces the zsh edit buffer" ||
  bad "Alt-O did not replace BUFFER: $out"
printf '%s\n' "$out" | grep -q '"\^\[o" namo-complete' &&
  ok "Alt-O is bound in the zsh emacs keymap" ||
  bad "Alt-O binding missing: $out"
printf '%s\n' "$out" | grep -q '_namo_zle_line_changed' &&
  ok "ZLE redraw hook is registered" ||
  bad "ZLE redraw hook missing: $out"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/.zshrc" <<'ZRC'
if [[ -n "${NAMO_TEST_ZSH_MODULE_PATH:-}" ]]; then
  module_path=("$NAMO_TEST_ZSH_MODULE_PATH" $module_path)
fi
if [[ -n "${NAMO_TEST_ZSH_FPATH_ROOT:-}" ]]; then
  fpath=("$NAMO_TEST_ZSH_FPATH_ROOT"/*(N) $fpath)
fi
PROMPT='ZTEST> '
NAMO_BIN=/does/not/exist
source "$NAMO_TEST_ROOT/shell/namo_complete.zsh"
exec {_NAMO_WFD}> "$ZDOTDIR/lines"
_namo_ask_daemon() { _NAMO_REPLY_OUT=$'-\techo $((40+2))\ttest\n' }
ZRC

python3 - "$work" "$ZSH_BIN" <<'PY'
import os
import pty
import select
import sys
import time

root, zsh = sys.argv[1:]
env = os.environ.copy()
env["ZDOTDIR"] = root
pid, fd = pty.fork()
if pid == 0:
    os.execve(zsh, [zsh, "-d", "-i"], env)

data = b""

def read_until(needle, timeout=8):
    global data
    end = time.time() + timeout
    while needle not in data and time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if ready:
            try:
                data += os.read(fd, 65536)
            except OSError:
                break
    if needle not in data:
        raise AssertionError(data[-2000:])

read_until(b"ZTEST> ")
os.write(fd, b"git st")
time.sleep(0.3)
os.write(fd, b"\x1bo")
time.sleep(0.3)
os.write(fd, b"\r")
read_until(b"42\r\n")
os.write(fd, b"exit\r")
os.waitpid(pid, 0)
PY
ok "Alt-O works in a live ZLE session"

grep -q $'\tgit st$' "$work/lines" &&
  ok "typed zsh buffers reach the FIFO without a process" ||
  bad "the final typed buffer was not reported"

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
