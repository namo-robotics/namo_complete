#!/usr/bin/env python3
"""Exercise workspace panes, agent context, and approval using real shell PTYs."""
import fcntl
import http.server
import json
import os
from pathlib import Path
import pty
import re
import select
import shlex
import shutil
import signal
import struct
import tempfile
import termios
import threading
import time

ROOT = Path(__file__).resolve().parent
ANSI = re.compile(rb'\x1b\[[0-?]*[ -/]*[@-~]')
REQUESTS = []
PROPOSAL = ''


class Handler(http.server.BaseHTTPRequestHandler):
    """Serve deterministic model replies without contacting an external provider."""

    def log_message(self, *args):
        """Keep the test output limited to assertions."""

    def do_POST(self):
        """Record context and return a validated or intentionally malformed reply."""
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        REQUESTS.append(request)
        text = request['messages'][0]['content']
        question = text.rsplit('User request:\n', 1)[-1]
        if 'SLOW' in question:
            time.sleep(1)
        envelope = {'answer': 'CONTEXT_ANSWER', 'command': PROPOSAL, 'explanation': 'Create the approved marker'}
        if 'typing hint' in question:
            envelope['alternatives'] = ['printf ALTERNATIVE_OK']
        if 'MALFORMED' in question:
            envelope['command'] = 'echo bad\nexit'
        if 'Summarize' in question:
            envelope = {'answer': 'SESSION_SUMMARY', 'command': '', 'explanation': ''}
        body = json.dumps({'content': [{'type': 'text', 'text': json.dumps(envelope)}], 'stop_reason': 'end_turn'}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


class Session:
    """Own a terminal child and collect its rendered frames."""

    def __init__(self, shell, home, endpoint, automatic=False, **settings):
        self.output = b''
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            env = dict(os.environ, HOME=str(home), NAMO_BIN=str(ROOT / 'bin/namo_complete'),
                       NAMO_WORKSPACE_SHELL=shell, NAMO_WORKSPACE_HOOK=str(ROOT / 'shell' / ('workspace.zsh' if 'zsh' in shell else 'workspace.bash')),
                       ANTHROPIC_API_KEY='local-test-token', NAMO_ENDPOINT=endpoint,
                       NAMO_HINT_MIN='1000', NAMO_TIMEOUT='3', NAMO_NO_LS='1', TERM='xterm-256color')
            for name in ('NAMO_WORKSPACE_ACTIVE', 'NAMO_WORKSPACE_DIR', 'NAMO_DISABLE', 'ZDOTDIR'):
                env.pop(name, None)
            env.update(settings)
            os.chdir(home)
            if automatic:
                argv = [shell, '-i'] if 'zsh' in shell else [shell, '--rcfile', str(home / '.bashrc'), '-i']
                os.execve(shell, argv, env)
            os.execve(str(ROOT / 'bin/namo_complete'), ['namo_complete'], env)
        self.resize(24, 120)
        try:
            self.wait_text('PROMPT>')
            self.read(.1)
        except BaseException:
            self.close()
            raise

    def resize(self, rows, cols):
        """Resize the physical terminal used by the workspace."""
        self.rows, self.cols = rows, cols
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))

    def read(self, seconds=.15):
        """Drain output without allowing a test to hang."""
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if select.select([self.fd], [], [], min(.03, max(0, end-time.monotonic())))[0]:
                try:
                    chunk = os.read(self.fd, 262144)
                except OSError:
                    break
                if not chunk:
                    break
                self.output += chunk
        return ANSI.sub(b'', self.output).decode('utf-8', 'replace')

    def send(self, data):
        """Write a key sequence without losing partial writes."""
        if isinstance(data, str):
            data = data.encode()
        while data:
            data = data[os.write(self.fd, data):]

    def wait_text(self, text, seconds=5):
        """Require text to appear before the deadline."""
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if text in self.read(.05):
                return
        raise AssertionError(f'Missing {text!r}: {self.read(0)[-3500:]}')

    def command(self, command):
        """Run a manually entered shell command."""
        self.send(command + '\r')
        self.read(.2)

    def focus_chat(self):
        """Click inside the agent pane in either split orientation."""
        x, y = self.cols - 2, self.rows - 2
        self.send(f'\x1b[<0;{x};{y}M\x1b[<0;{x};{y}m')
        self.read(.05)

    def ask(self, question):
        """Click the visible agent prompt and submit a question."""
        self.focus_chat()
        self.send(question + '\r')
        self.read(.2)

    def suggestion_button(self, cancel=False):
        """Click the current suggestion controls directly above the chat prompt."""
        self.read(.1)
        row, column = chat_prompt_position(self)
        x, y = column + (15 if cancel else 3), row - 1
        self.send(f'\x1b[<0;{x};{y}M\x1b[<0;{x};{y}m')
        self.read(.1)

    def terminal(self):
        """Switch from chat to the terminal pane."""
        self.send('\x1d')
        self.read(.05)

    def close(self):
        """Kill and reap an unfinished test session."""
        if self.pid:
            try:
                os.kill(self.pid, signal.SIGTERM)
                self.read(.2)
                waited, _ = os.waitpid(self.pid, os.WNOHANG)
                if not waited:
                    os.kill(self.pid, signal.SIGKILL)
                    os.waitpid(self.pid, 0)
            except (ProcessLookupError, ChildProcessError):
                pass
            self.pid = 0
        os.close(self.fd)


def wait_file(session, path, seconds=4):
    """Wait for a command's observable filesystem result."""
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if path.exists():
            return
        session.read(.05)
    raise AssertionError(f'Command did not create {path}; {session.read(0)[-2000:]}')


def check_shell(shell, endpoint):
    """Check normal terminal behavior and the explicit command approval boundary."""
    global PROPOSAL
    with tempfile.TemporaryDirectory(prefix='namo-workspace-test-') as directory:
        home = Path(directory)
        (home / '.bashrc').write_text("PS1='PROMPT> '\n")
        zsh_setup = "PS1='PROMPT> '\n"
        if os.environ.get('NAMO_TEST_ZSH_MODULE_PATH'):
            zsh_setup = 'module_path=("$NAMO_TEST_ZSH_MODULE_PATH" $module_path)\nfpath=("$NAMO_TEST_ZSH_FPATH_ROOT"/*(N) $fpath)\n' + zsh_setup
            (home / '.zshenv').write_text(zsh_setup)
        (home / '.zshrc').write_text(zsh_setup)
        marker = home / 'approved'
        PROPOSAL = 'printf approved > ' + shlex.quote(str(marker))
        session = Session(shell, home, endpoint)
        try:
            session.output = b''
            session.send('\x1d')
            session.wait_text('agent |')
            assert b'Click a pane to type' not in session.output
            assert b'Click here and type' not in session.output
            session.wait_text('chat>')
            session.send('draft stays here')
            for sequence in ('\x1d',) * 3:
                session.output = b''
                session.send(sequence)
                session.wait_text('terminal |')
                session.output = b''
                session.send(sequence)
                session.wait_text('agent |')
                session.wait_text('chat> draft stays here')
            session.send('\x1d')
            session.read(.1)
            session.command("printf 'TERMINAL_CONTEXT_123\\n'")
            session.wait_text('TERMINAL_CONTEXT_123')
            session.command('stty size > dimensions')
            assert (home / 'dimensions').read_text().strip() == '22 71'
            session.output = b''
            session.send('\x1b[<0;100;3M\x1b[<0;100;3m')
            session.wait_text('agent |')
            session.wait_text('chat> draft stays here')
            session.output = b''
            session.send('\x1b[<0;4;3M\x1b[<0;4;3m')
            session.wait_text('terminal |')
            session.send('\x1b]s')
            session.read(.2)
            session.command('stty size > dimensions')
            assert (home / 'dimensions').read_text().strip() == '12 120'
            session.output = b''
            session.send('\x1b[<0;4;16M\x1b[<0;4;16m')
            session.wait_text('agent |')
            session.wait_text('chat> draft stays here')
            session.output = b''
            session.send('\x1b[<0;4;3M\x1b[<0;4;3m')
            session.wait_text('terminal |')
            session.send('\x1b]\x1b[B')
            session.read(.2)
            session.command('stty size > dimensions')
            assert (home / 'dimensions').read_text().strip() == '13 120'
            session.send('\x1b]\x1b[A')
            session.resize(8, 60)
            session.read(.2)
            session.command('stty size > dimensions')
            assert (home / 'dimensions').read_text().strip() == '6 60'
            session.resize(24, 120)
            session.send('\x1b]a')
            session.read(.2)
            session.command('stty size > dimensions')
            assert (home / 'dimensions').read_text().strip() == '22 120'
            session.send('\x1b]a\x1b]s')
            session.read(.2)
            mouse_program = home / 'mouse-program.py'
            mouse_program.write_text("""import os, termios, tty
from pathlib import Path
saved = termios.tcgetattr(0)
tty.setraw(0)
os.write(1, b'\\x1b[?1000h\\x1b[?1006h')
Path('mouse-ready').touch()
try:
    Path('mouse-event').write_bytes(os.read(0, 64))
finally:
    os.write(1, b'\\x1b[?1000l\\x1b[?1006l')
    termios.tcsetattr(0, termios.TCSANOW, saved)
""")
            for orientation in ('vertical', 'horizontal'):
                if orientation == 'horizontal':
                    session.send('\x1b]s')
                    session.read(.1)
                session.command(shlex.quote(shutil.which('python3')) + ' ' + shlex.quote(str(mouse_program)))
                wait_file(session, home / 'mouse-ready')
                x, y = (100, 3) if orientation == 'vertical' else (4, 16)
                session.send(f'\x1b[<0;{x};{y}M\x1b[<0;{x};{y}m')
                session.read(.1)
                session.send('\x1b[<0;4;3M\x1b[<0;4;3m')
                session.read(.1)
                assert not (home / 'mouse-event').exists(), 'focus click leaked into the application'
                session.send('\x1b[<0;4;3M')
                wait_file(session, home / 'mouse-event')
                assert (home / 'mouse-event').read_bytes() == b'\x1b[<0;4;3M'
                session.read(.2)
                (home / 'mouse-ready').unlink()
                (home / 'mouse-event').unlink()
            session.send('\x1b]s')
            session.read(.1)
            session.send('\x1b]a')
            session.read(.2)
            session.command('stty size > dimensions')
            assert (home / 'dimensions').read_text().strip() == '22 120'
            session.resize(26, 130)
            session.read(.2)
            session.command('stty size > dimensions')
            assert (home / 'dimensions').read_text().strip() == '24 130'
            session.send('\x1b]a')
            session.read(.2)
            session.command('stty size > dimensions')
            assert (home / 'dimensions').read_text().strip() == '24 77'
            session.resize(30, 140)
            session.read(.2)
            session.command('stty size > dimensions')
            assert (home / 'dimensions').read_text().strip() == '28 83'
            session.resize(12, 60)
            session.read(.2)
            session.command('stty size > dimensions')
            assert (home / 'dimensions').read_text().strip() == '10 60'
            session.resize(24, 120)
            session.read(.2)
            session.focus_chat()
            session.send('\x7f' * len('draft stays here'))
            session.ask('Explain the terminal context')
            session.wait_text('CONTEXT_ANSWER')
            assert b'--- Agent reply ---' in session.output
            assert b'--- Command proposal ---' in session.output
            for color in (3, 5, 6):
                assert f'\x1b[38;5;{color}m'.encode() in session.output
            assert not marker.exists(), 'a proposal ran without approval'
            context = REQUESTS[-1]['messages'][0]['content']
            assert 'TERMINAL_CONTEXT_123' in context
            session.send('preserved draft')
            session.suggestion_button(cancel=True)
            session.wait_text('Suggestion canceled.')
            session.wait_text('chat> preserved draft')
            assert not marker.exists(), 'cancel ran the proposal'
            session.send('\x15')
            session.ask('Propose the command again')
            session.wait_text('[ Accept ]')
            assert b'\x1b[0;1;30;42m[ Accept ]' in session.output
            assert b'\x1b[1;37;41m[ Cancel ]' in session.output
            session.suggestion_button()
            session.wait_text('terminal |')
            assert not marker.exists(), 'accept executed the suggestion'
            session.send('\r')
            wait_file(session, marker)
            marker.unlink()
            session.ask('Propose the command again')
            session.read(.3)
            session.send('/run\r')
            session.wait_text('Type /approve')
            assert not marker.exists(), 'review executed the command'
            session.suggestion_button()
            wait_file(session, marker)
            session.wait_text('Approved command finished')
            marker.unlink()
            session.send('/approve\r')
            session.read(.3)
            assert not marker.exists(), 'approval was replayed'
            session.ask('Propose the command again')
            session.read(.3)
            session.send('/run\r')
            session.read(.1)
            session.terminal()
            session.command('cd /')
            session.ask('/approve')
            session.read(.2)
            assert not marker.exists(), 'approval survived a working-directory change'
            session.terminal()
            session.command('cd ' + shlex.quote(str(home)))
            session.ask('MALFORMED')
            session.read(.3)
            session.send('/run\r/approve\r')
            session.read(.3)
            assert not marker.exists(), 'malformed command became executable'
            session.terminal()
            session.command('sleep 2')
            session.ask('Please create the marker')
            session.read(.3)
            session.send('/run\r/approve\r')
            session.read(.2)
            assert not marker.exists(), 'command injected into a busy shell'
            session.read(2)
            session.send('\x1b')
            session.read(.15)
            session.terminal()
            session.command("printf '\\033]52;c;FORBIDDEN_CLIPBOARD\\007'")
            assert b'\x1b]52;' not in session.output, 'application OSC leaked into the physical terminal'
            if shutil.which('vim'):
                session.command('vim -Nu NONE -n edited')
                session.send('iEDITED_IN_VIM\x1b:wq\r')
                wait_file(session, home / 'edited')
                assert (home / 'edited').read_text() == 'EDITED_IN_VIM\n'
            session.send('\x1b[200~printf unfinished')
            session.read(.1)
            session.send('\x03\x1b[201~')
            session.read(.1)
            session.command('printf paste_ok > paste-recovered')
            wait_file(session, home / 'paste-recovered')
            session.command('sleep 20')
            session.send('\x03')
            session.read(.2)
            session.command('printf interrupt_ok > interrupted')
            wait_file(session, home / 'interrupted')
            session.command('sleep 20')
            session.send('\x1a')
            session.read(.2)
            session.command('fg')
            session.send('\x03')
            session.read(.2)
            if shutil.which('less'):
                session.command("printf 'pager\n%.0s' {1..80} | less")
                session.send('q')
                session.read(.2)
            if shutil.which('top'):
                session.command('top')
                session.send('q')
                session.read(.2)
            session.ask('SLOW request')
            session.send('\x1d')
            session.command('printf responsive > responsive')
            wait_file(session, home / 'responsive', .7)
            session.read(1)
            session.command('exit 7')
            session.read(.3)
            pid, status = os.waitpid(session.pid, os.WNOHANG)
            assert pid == session.pid and os.waitstatus_to_exitcode(status) == 7
            session.pid = 0
            assert b'\x1b[?1049l' in session.output
            print(f'PASS {Path(shell).name}: panes, resize, context, approval, invalid replies, busy shell, vim, signals, responsive requests, exit')
        finally:
            session.close()


def check_close_button(shell, endpoint):
    """Close direct and automatic workspaces with terminal settings restored."""
    with tempfile.TemporaryDirectory(prefix='namo-close-test-') as directory:
        home = Path(directory)
        integration = 'namo_complete.zsh' if 'zsh' in shell else 'namo_complete.bash'
        startup = "PS1='PROMPT> '\n. " + shlex.quote(str(ROOT / 'shell' / integration)) + '\n'
        (home / '.bashrc').write_text(startup)
        (home / '.zshrc').write_text(startup)
        if os.environ.get('NAMO_TEST_ZSH_MODULE_PATH'):
            (home / '.zshenv').write_text('module_path=("$NAMO_TEST_ZSH_MODULE_PATH" $module_path)\nfpath=("$NAMO_TEST_ZSH_FPATH_ROOT"/*(N) $fpath)\n')
        for orientation, automatic, narrow in (('vertical', False, False), ('horizontal', True, False), ('vertical', False, True)):
            session = Session(shell, home, endpoint, automatic=automatic, NAMO_LAYOUT=orientation)
            try:
                if narrow:
                    session.resize(12, 60)
                    session.send('\x1d')
                session.wait_text('[×]')
                assert '\x1b[0;1;37;41m[×]'.encode() in session.output
                session.read(.15)
                row = 1 if orientation == 'vertical' else 14
                session.send(f'\x1b[<0;{session.cols-1};{row}M\x1b[<0;{session.cols-1};{row}m')
                end = time.monotonic() + 3
                pid = 0
                while time.monotonic() < end:
                    session.read(.05)
                    pid, status = os.waitpid(session.pid, os.WNOHANG)
                    if pid:
                        break
                assert pid == session.pid, 'close button did not exit promptly'
                session.pid = 0
                assert os.waitstatus_to_exitcode(status) == 0
                assert b'\x1b[?1049l' in session.output
                flags = termios.tcgetattr(session.fd)[3]
                assert flags & termios.ICANON and flags & termios.ECHO
                assert b'stopped unexpectedly' not in session.output
            finally:
                session.close()
        print(f'PASS {Path(shell).name} close button: layouts, automatic exit, terminal restoration')


def check_automatic(shell, endpoint):
    """Check automatic startup, recursion guards, and an otherwise ambiguous exit status."""
    with tempfile.TemporaryDirectory(prefix='namo-startup-test-') as directory:
        home = Path(directory)
        (home / '.bashrc').write_text("PS1='PROMPT> '\n. " + shlex.quote(str(ROOT / 'shell/namo_complete.bash')) + '\n')
        session = Session(shell, home, endpoint, automatic=True)
        try:
            assert session.output.count(b'\x1b[?1049h') == 1
            session.command('exit 125')
            session.read(.3)
            pid, status = os.waitpid(session.pid, os.WNOHANG)
            assert pid == session.pid and os.waitstatus_to_exitcode(status) == 125
            session.pid = 0
        finally:
            session.close()
        print('PASS automatic startup: one workspace, managed-shell recursion guard, exact exit status')


def chat_prompt_position(session):
    """Find the prompt in the latest complete workspace frame."""
    frame = session.output.rsplit(b'\x1b[?25l', 1)[-1]
    positions = re.findall(rb'\x1b\[(\d+);(\d+)H\x1b\[0mchat> ', frame)
    return tuple(map(int, positions[-1])) if positions else None


def check_suggestion_buttons(shell, endpoint):
    """Review and dismiss suggestions in stacked and single-pane layouts."""
    global PROPOSAL
    with tempfile.TemporaryDirectory(prefix='namo-buttons-test-') as directory:
        home = Path(directory)
        (home / '.bashrc').write_text("PS1='PROMPT> '\n")
        marker = home / 'clicked'
        PROPOSAL = 'printf clicked > ' + shlex.quote(str(marker))
        for orientation, narrow in (('horizontal', False), ('vertical', True)):
            session = Session(shell, home, endpoint, NAMO_LAYOUT=orientation)
            try:
                if narrow:
                    session.resize(12, 60)
                    session.read(.2)
                    session.send('\x1d')
                    session.read(.1)
                session.ask('Propose a command')
                session.wait_text('[ Accept ]')
                session.suggestion_button()
                session.wait_text('terminal |')
                assert not marker.exists(), 'accept executed the suggestion'
                session.send('\r')
                wait_file(session, marker)
                marker.unlink()
                session.send('\x1d')
                session.ask('Propose another command')
                session.read(.3)
                session.send('/run\r')
                session.wait_text('[ Run    ]')
                assert not marker.exists(), 'review executed the command'
                session.suggestion_button(cancel=True)
                session.wait_text('Suggestion canceled.')
                assert not marker.exists(), 'cancel executed the command'
                session.send('/approve\r')
                session.read(.2)
                assert not marker.exists(), 'canceled proposal remained executable'
            finally:
                session.close()
        print('PASS suggestion buttons: stacked and single-pane review, cancellation, approval invalidation')


def check_chat_editor(shell, endpoint):
    """Keep input after the conversation and scroll it within the agent rectangle."""
    with tempfile.TemporaryDirectory(prefix='namo-editor-test-') as directory:
        home = Path(directory)
        (home / '.bashrc').write_text("PS1='PROMPT> '\n")
        for orientation, column, top in (('vertical', 73, 1), ('horizontal', 1, 14)):
            session = Session(shell, home, endpoint, ANTHROPIC_API_KEY='', NAMO_LAYOUT=orientation)
            try:
                session.send('\x1d')
                session.focus_chat()
                session.send('draft ©')
                session.read(.2)
                row, prompt_column = chat_prompt_position(session)
                assert top <= row < 22 and prompt_column == column
                assert 'chat> draft ©' in session.read(0)
                session.send('x' * 200)
                session.read(.2)
                cursors = re.findall(rb'\x1b\[(\d+);(\d+)H\x1b\[\?25h', session.output)
                assert cursors and int(cursors[-1][0]) == row
                assert column <= int(cursors[-1][1]) <= 120
                session.send('\x7f' * 207)
                session.ask('A first question')
                session.read(.1)
                next_row, _ = chat_prompt_position(session)
                assert row < next_row <= 22, 'prompt did not follow the new conversation output'
                for _ in range(6):
                    session.ask('Fill the conversation with this question ' * 5)
                session.read(.1)
                assert chat_prompt_position(session) == (22, column)
                session.send('\x1b]\x1b[5~')
                session.read(.1)
                assert chat_prompt_position(session) is None, 'prompt should scroll out with the transcript'
                session.send('resume drafting')
                session.read(.1)
                assert chat_prompt_position(session) == (22, column), 'editing should return to the live prompt'
                session.send('\x15')
                session.terminal()
                session.command('printf editor_ok > editor-result')
                wait_file(session, home / 'editor-result')
                (home / 'editor-result').unlink()
            finally:
                session.close()
        print('PASS chat editor: prompt follows output, scrollback, direct typing, bounded cursor')


def check_recovery(shell, endpoint):
    """Recover the launching shell after startup failure or a killed workspace host."""
    with tempfile.TemporaryDirectory(prefix='namo-recovery-test-') as directory:
        home = Path(directory)
        setup = "PS1='PROMPT> '\n"
        if 'zsh' in shell and os.environ.get('NAMO_TEST_ZSH_MODULE_PATH'):
            setup = 'module_path=("$NAMO_TEST_ZSH_MODULE_PATH" $module_path)\nfpath=("$NAMO_TEST_ZSH_FPATH_ROOT"/*(N) $fpath)\n' + setup
            (home / '.zshenv').write_text(setup)
        suffix = 'zsh' if 'zsh' in shell else 'bash'
        (home / ('.zshrc' if suffix == 'zsh' else '.bashrc')).write_text(
            setup + '. ' + shlex.quote(str(ROOT / ('shell/namo_complete.' + suffix))) + '\n')
        for failure in ('startup', 'crash', 'disabled'):
            settings = {'SHELL': shell}
            if failure == 'disabled':
                settings['NAMO_DISABLE'] = '1'
            if failure == 'crash':
                settings['NAMO_LAYOUT'] = 'horizontal'
            if failure == 'startup':
                settings['NAMO_WORKSPACE_HOOK'] = str(home / 'missing-hook')
            session = Session(shell, home, endpoint, automatic=True, **settings)
            try:
                if failure == 'crash':
                    session.command('stty size > initial-size')
                    assert (home / 'initial-size').read_text().strip() == '12 120'
                    session.command('printf "%s" "$PPID" > host-pid')
                    host = int((home / 'host-pid').read_text())
                    assert host != session.pid
                    os.kill(host, signal.SIGKILL)
                if failure != 'disabled':
                    session.wait_text('continuing with the regular shell')
                else:
                    assert b'\x1b[?1049h' not in session.output
                session.command('printf recovered > ' + failure)
                wait_file(session, home / failure)
                session.command("stty -a > terminal-settings")
                settings_text = (home / 'terminal-settings').read_text()
                assert '-icanon' not in settings_text and '-echo ' not in settings_text
                assert session.output.count(b'\x1b[?1049h') <= 1, 'workspace restarted after failure'
            finally:
                session.close()
        print(f'PASS {Path(shell).name} recovery: startup failure, host crash, restored terminal, no restart loop')


def check_worker_failures(shell, endpoint):
    """Keep manual commands responsive when workers stop reading, close output, or vanish."""
    with tempfile.TemporaryDirectory(prefix='namo-worker-test-') as directory:
        home = Path(directory)
        (home / '.bashrc').write_text("PS1='PROMPT> '\n")
        wrapper = home / 'worker-wrapper'
        for behavior in ('stalled', 'closed', 'missing'):
            script = '#!/bin/sh\nif [ "$1" = --workspace-worker ]; then\n'
            if behavior == 'closed':
                script += 'exec 1>&-\n'
            script += 'exec sleep 20\nfi\nexec ' + shlex.quote(str(ROOT / 'bin/namo_complete')) + ' "$@"\n'
            wrapper.write_text(script)
            wrapper.chmod(0o700)
            session = Session(shell, home, endpoint, NAMO_BIN=str(wrapper), NAMO_TIMEOUT='1')
            try:
                session.command("printf 'context for backpressure %s\\n' {1..3000}")
                session.read(1)
                if behavior == 'missing':
                    wrapper.unlink()
                session.ask('Explain the recorded terminal output')
                session.terminal()
                session.command('printf responsive > ' + behavior)
                wait_file(session, home / behavior, .7)
                session.wait_text('Agent request failed' if behavior == 'missing' else 'Agent request timed out', 3)
                session.command('printf after_failure > after-' + behavior)
                wait_file(session, home / ('after-' + behavior), .7)
                assert os.waitpid(session.pid, os.WNOHANG)[0] == 0
            finally:
                session.close()
        print('PASS worker isolation: pipe backpressure, early output closure, missing executable, timeout')


def check_hidden_agent(shell, endpoint):
    """Check hidden startup, paused requests, and reopening without losing the shell."""
    with tempfile.TemporaryDirectory(prefix='namo-hidden-test-') as directory:
        home = Path(directory)
        (home / '.bashrc').write_text("PS1='PROMPT> '\n")
        before = len(REQUESTS)
        session = Session(shell, home, endpoint, NAMO_AGENT_WINDOW='0',
                          NAMO_HINT_MIN='3', NAMO_CONTEXT_BYTES='4096', NAMO_LAYOUT='horizontal')
        try:
            session.command('stty size > dimensions')
            assert (home / 'dimensions').read_text().strip() == '22 120'
            session.command('false')
            session.command("printf 'context line %s\\n' {1..400}")
            session.send('printf hidden')
            session.read(3)
            assert len(REQUESTS) == before, 'hidden agent made a request'
            session.send('\x03')
            session.send('\x1b]a')
            session.read(.1)
            session.ask('SLOW reopen agent')
            session.read(.1)
            assert len(REQUESTS) > before
            session.send('\x1b]a')
            session.read(1.2)
            session.command('stty size > dimensions')
            assert (home / 'dimensions').read_text().strip() == '22 120'
            before = len(REQUESTS)
            session.read(2.5)
            assert len(REQUESTS) == before, 'requests resumed while hidden'
            session.send('\x1b]a')
            session.read(.1)
            session.ask('Explain after reopening')
            session.wait_text('CONTEXT_ANSWER')
            session.send('/hide\r')
            session.read(.2)
            session.command('stty size > dimensions')
            assert (home / 'dimensions').read_text().strip() == '22 120'
        finally:
            session.close()
        print('PASS agent visibility: hidden startup, full-width shell, paused requests, cancellation, reopening')


def check_quiet_agent(shell, endpoint):
    """Keep empty hints, dismissed suggestions, and obsolete requests quiet."""
    global PROPOSAL
    with tempfile.TemporaryDirectory(prefix='namo-quiet-test-') as directory:
        home = Path(directory)
        (home / '.bashrc').write_text("PS1='PROMPT> '\n")
        for command in ('', 'printf quiet'):
            PROPOSAL = command
            session = Session(shell, home, endpoint, NAMO_HINT_MIN='3', NAMO_DEBOUNCE='0.1')
            try:
                before = len(REQUESTS)
                session.send('printf quiet')
                session.read(.8)
                assert len(REQUESTS) == before + 1, 'quiet hint retried without an edit'
                frame = session.output.rsplit(b'\x1b[?25l', 1)[-1]
                assert b'Suggestion:' not in frame and b'Thinking...' not in frame
                assert b'[ Accept ]' not in frame
            finally:
                session.close()
        PROPOSAL = 'printf useful'
        session = Session(shell, home, endpoint, NAMO_HINT_MIN='3', NAMO_DEBOUNCE='0.1')
        try:
            session.send('printf u')
            session.wait_text('Suggestion:')
            session.focus_chat()
            session.send('\x1b')
            session.read(.2)
            session.terminal()
            before = len(REQUESTS)
            session.read(.5)
            frame = session.output.rsplit(b'\x1b[?25l', 1)[-1]
            assert b'Suggestion:' not in frame and b'[ Accept ]' not in frame
            assert len(REQUESTS) == before, 'dismissed hint returned without an edit'
            session.output = b''
            session.send('\x15printf SLOW')
            session.wait_text('Thinking...')
            session.send('\x15')
            session.read(.2)
            frame = session.output.rsplit(b'\x1b[?25l', 1)[-1]
            assert b'Thinking...' not in frame, 'obsolete request kept thinking'
            session.read(1)
            frame = session.output.rsplit(b'\x1b[?25l', 1)[-1]
            assert b'Suggestion:' not in frame, 'canceled response returned'
            session.command('sleep 5')
            session.send('\x03')
            session.read(.3)
            before = len(REQUESTS)
            session.read(.5)
            assert len(REQUESTS) == before, 'intentional interruption triggered advice'
        finally:
            session.close()
        print('PASS quiet agent: abstention, duplicate hints, dismissal, obsolete requests, interrupted commands')


def check_context_controls(shell, endpoint):
    """Verify context opt-outs, redaction, typing hints, cancellation, and summaries."""
    global PROPOSAL
    with tempfile.TemporaryDirectory(prefix='namo-context-test-') as directory:
        home = Path(directory)
        (home / '.bashrc').write_text("PS1='PROMPT> '\n")
        PROPOSAL = 'printf HINT_OK'
        session = Session(shell, home, endpoint, NAMO_OUTPUT='0', NAMO_HISTORY_LINES='0')
        try:
            session.command('printf PRIVATE_OUTPUT_777')
            before = len(REQUESTS)
            session.ask('Question with sk-private-secret')
            session.wait_text('CONTEXT_ANSWER')
            assert len(REQUESTS) > before
            text = REQUESTS[-1]['messages'][0]['content']
            assert 'PRIVATE_OUTPUT_777' not in text and 'sk-private-secret' not in text
            session.ask('SLOW cancelled request')
            session.send('\x1b')
            session.read(.2)
            session.terminal()
            session.command('printf cancel_ok > cancelled')
            wait_file(session, home / 'cancelled')
        finally:
            session.close()
        session = Session(shell, home, endpoint, NAMO_OUTPUT='10', NAMO_HISTORY_LINES='0')
        try:
            session.command('true SECRET_COMMAND_999')
            session.command('printf PUBLIC_OUTPUT_888')
            session.ask('Explain output without command history')
            session.wait_text('CONTEXT_ANSWER')
            text = REQUESTS[-1]['messages'][0]['content']
            assert 'SECRET_COMMAND_999' not in text and 'PUBLIC_OUTPUT_888' in text
        finally:
            session.close()
        session = Session(shell, home, endpoint, NAMO_HINT_MIN='3', NAMO_DEBOUNCE='0.2', NAMO_CONTEXT_BYTES='4096')
        try:
            session.send('printf HI')
            session.wait_text('Suggestion:')
            session.send('\x1ba')
            session.wait_text('ALTERNATIVE_OK')
            session.send('/pick 2\r')
            session.read(.1)
            session.send('\x1bo')
            session.terminal()
            session.read(.2)
            session.send('\r')
            session.wait_text('ALTERNATIVE_OK')
            session.command("printf 'context line %s\\n' {1..400}")
            session.read(3)
            assert any('Summarize the session' in request['messages'][0]['content'] for request in REQUESTS)
            session.wait_text('Context: older output summarized or omitted')
        finally:
            session.close()
        print('PASS context: output/history opt-outs, credential redaction, cancellation, typing hints, asynchronous summaries')


if __name__ == '__main__':
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        endpoint = f'http://127.0.0.1:{server.server_port}/v1/messages'
        check_shell(shutil.which('bash'), endpoint)
        check_chat_editor(shutil.which('bash'), endpoint)
        check_suggestion_buttons(shutil.which('bash'), endpoint)
        check_recovery(shutil.which('bash'), endpoint)
        check_worker_failures(shutil.which('bash'), endpoint)
        check_hidden_agent(shutil.which('bash'), endpoint)
        check_context_controls(shutil.which('bash'), endpoint)
        check_quiet_agent(shutil.which('bash'), endpoint)
        check_automatic(shutil.which('bash'), endpoint)
        check_close_button(shutil.which('bash'), endpoint)
        zsh = os.environ.get('ZSH_BIN') or shutil.which('zsh')
        if zsh:
            check_shell(zsh, endpoint)
            check_recovery(zsh, endpoint)
            check_close_button(zsh, endpoint)
        else:
            print('SKIP zsh workspace: zsh is not installed')
    finally:
        server.shutdown()
        thread.join()
