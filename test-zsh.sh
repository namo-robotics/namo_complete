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
  _namo_read_question() { _NAMO_QUESTION='missing details' }
  _namo_ask_daemon() { _NAMO_REPLY_OUT='' }
  BUFFER=''
  _namo_key_request a 1
  _namo_ask_daemon() { _NAMO_REPLY_ERROR='model rejected request'; return 2 }
  _namo_key_request a 1
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

printf '%s\n' "$out" | grep -q 'no command returned' &&
  ok "zsh ask mode explains an empty model answer" ||
  bad "zsh ask mode silently discarded an empty answer: $out"

printf '%s\n' "$out" | grep -q 'request failed: model rejected request' &&
  ok "zsh ask mode prints the daemon error" ||
  bad "zsh ask mode hid the daemon error: $out"

paste_out=$(printf '\033[200~change CLAUDE.md\ninto a symbolic link\033[201~\n' |
  "$ZSH_BIN" -dfi -c "$setup
    NAMO_BIN=/does/not/exist
    source \"$ROOT/shell/namo_complete.zsh\"
    BUFFER=''
    _namo_read_question
    print -r -- \"Q=[\$_NAMO_QUESTION]\"
  " 2>/dev/null)
printf '%s\n' "$paste_out" | grep -qF 'Q=[change CLAUDE.md into a symbolic link]' &&
  ok "bracketed paste stays inside zsh ask mode" ||
  bad "bracketed paste escaped zsh ask mode: $paste_out"

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
import signal
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
scan_from = 0

def read_until(needle, timeout=8):
    """Read through the next occurrence of a PTY byte sequence."""
    global data, scan_from
    end = time.time() + timeout
    while data.find(needle, scan_from) < 0 and time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if ready:
            try:
                data += os.read(fd, 65536)
            except OSError:
                break
    found = data.find(needle, scan_from)
    if found < 0:
        raise AssertionError(data[-2000:])
    scan_from = found + len(needle)

def wait_for_exit(timeout=8):
    """Reap zsh or fail without leaving the CI job blocked."""
    end = time.time() + timeout
    while time.time() < end:
        waited, status = os.waitpid(pid, os.WNOHANG)
        if waited == pid:
            if status != 0:
                raise AssertionError(f"zsh exited with status {status}: {data[-2000:]!r}")
            return
        time.sleep(0.1)
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    os.waitpid(pid, 0)
    raise AssertionError(f"zsh did not exit: {data[-2000:]!r}")

read_until(b"ZTEST> ")
os.write(fd, b"git st")
time.sleep(0.3)
os.write(fd, b"\x1bo")
time.sleep(0.3)
os.write(fd, b"\r")
read_until(b"42\r\n")
read_until(b"ZTEST> ")
os.write(fd, b"\x04")
wait_for_exit()
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
