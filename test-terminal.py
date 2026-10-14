#!/usr/bin/env python3
"""Check that undrained workspace metadata cannot block shell editing."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent


def check_shell(shell, suffix):
    """Fill the metadata FIFO and ensure native shell hooks return promptly."""
    with tempfile.TemporaryDirectory(prefix='namo-terminal-') as directory:
        path = Path(directory)
        fifo = path / 'events'
        os.mkfifo(fifo)
        fd = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
        try:
            while True:
                try:
                    os.write(fd, b'x' * 512)
                except BlockingIOError:
                    break
            env = dict(os.environ, NAMO_WORKSPACE_DIR=str(path),
                       NAMO_BIN=str(ROOT / 'bin/namo_complete'),
                       NAMO_TEST_HOOK=str(ROOT / 'shell' / ('workspace.' + suffix)))
            setup = ''
            if suffix == 'zsh' and env.get('NAMO_TEST_ZSH_MODULE_PATH'):
                setup = 'module_path=("$NAMO_TEST_ZSH_MODULE_PATH" $module_path)\nfpath=("$NAMO_TEST_ZSH_FPATH_ROOT"/*(N) $fpath)\n'
            script = setup + '''
source "$NAMO_TEST_HOOK"
_namo_ws_event line 'echo still editing'
printf 'NONBLOCKING_OK\\n'
'''
            result = subprocess.run([shell, '-fic', script], env=env, capture_output=True, timeout=3)
            assert result.returncode == 0 and b'NONBLOCKING_OK' in result.stdout, result.stderr
        finally:
            os.close(fd)
        print(f'PASS {suffix}: full metadata pipe does not block the shell')


if __name__ == '__main__':
    check_shell(shutil.which('bash'), 'bash')
    zsh = os.environ.get('ZSH_BIN') or shutil.which('zsh')
    if zsh:
        check_shell(zsh, 'zsh')
