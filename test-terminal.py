#!/usr/bin/env python3
"""Check that full helper pipes and incomplete pastes cannot trap the editor."""

import fcntl
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent


def check_shell(shell, integration):
    """Exercise shell hooks with an undrained FIFO and an open input stream."""
    with tempfile.TemporaryDirectory(prefix="namo-terminal-") as temp:
        fifo = Path(temp) / "fifo"
        os.mkfifo(fifo)
        helper = Path(temp) / "helper"
        helper.write_text('#!/bin/sh\nif [ "$1" = --nonblocking-fifo ]; then\n'
                          '  exec "$NAMO_TEST_BINARY" "$@"\nfi\nexit 0\n')
        helper.chmod(0o700)
        fd = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
        try:
            while True:
                try:
                    os.write(fd, b"x" * 512)
                except BlockingIOError:
                    break
            setup = '''
NAMO_BIN=/does/not/exist
source "$NAMO_TEST_INTEGRATION"
_NAMO_OFF=""
_NAMO_BIN_PATH="$NAMO_TEST_HELPER"
_NAMO_FIFO="$NAMO_TEST_FIFO"
_namo_daemon_is_running() { return 0; }
_namo_daemon_ensure || exit 10
_namo_send_line 'git status'
if _namo_ask_daemon c 'git status'; then exit 11; fi
_namo_on_exit
printf 'PIPE_OK\\n'
'''
            env = dict(os.environ, NAMO_TEST_FIFO=str(fifo),
                       XDG_RUNTIME_DIR=temp, NAMO_TEST_HELPER=str(helper),
                       NAMO_TEST_BINARY=str(ROOT / "bin/namo_complete"),
                       NAMO_TEST_INTEGRATION=str(ROOT / "shell" / integration))
            extra = integration.endswith(".zsh") and os.environ.get("NAMO_TEST_ZSH_MODULE_PATH")
            if extra:
                setup = 'module_path=("$NAMO_TEST_ZSH_MODULE_PATH" $module_path)\nfpath=("$NAMO_TEST_ZSH_FPATH_ROOT"/*(N) $fpath)\n' + setup
            result = subprocess.run([shell, "-fic", setup], env=env,
                                    capture_output=True, timeout=5)
            assert result.returncode == 0 and b"PIPE_OK" in result.stdout, result.stderr
            print(f"PASS {integration}: full request pipe leaves hooks responsive")
            # The helper must change the shared open description, not its own copy.
            flags = fcntl.fcntl(fd, fcntl.F_GETFL)
            fcntl.fcntl(fd, fcntl.F_SETFL, flags & ~os.O_NONBLOCK)
            subprocess.run([str(ROOT / 'bin/namo_complete'), '--nonblocking-fifo', str(fd)],
                           pass_fds=(fd,), check=True)
            assert fcntl.fcntl(fd, fcntl.F_GETFL) & os.O_NONBLOCK
        finally:
            os.close(fd)

        for payload in (b'[', b'[200~unfinished', b'[200~cancel\x03'):
            script = '''
NAMO_BIN=/does/not/exist
source "$NAMO_TEST_INTEGRATION"
if _namo_read_paste; then exit 12; fi
printf 'PASTE_OK\\n'
'''
            if extra:
                script = 'module_path=("$NAMO_TEST_ZSH_MODULE_PATH" $module_path)\nfpath=("$NAMO_TEST_ZSH_FPATH_ROOT"/*(N) $fpath)\n' + script
            proc = subprocess.Popen([shell, '-fic', script], env=env,
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE)
            try:
                proc.stdin.write(payload)
                proc.stdin.flush()
                # Keep stdin open: EOF would hide an unbounded read.
                proc.wait(timeout=0.75 if payload.endswith(b"\x03") else 4)
                assert proc.returncode == 0 and b'PASTE_OK' in proc.stdout.read()
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.communicate()
        print(f"PASS {integration}: incomplete and cancelled pastes return to editing")


if __name__ == '__main__':
    check_shell(shutil.which('bash'), 'namo_complete.bash')
    zsh = os.environ.get('ZSH_BIN') or shutil.which('zsh')
    if zsh:
        check_shell(zsh, 'namo_complete.zsh')
    else:
        print('SKIP zsh: not installed')
