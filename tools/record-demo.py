#!/usr/bin/env python3
"""Record the real workspace with a local API fixture and render it as a GIF.

Requires Pillow, pyte, a built binary, and a monospace TrueType font.
Example: python3 tools/record-demo.py --font /path/to/monospace.ttf
"""
import argparse
import fcntl
import http.server
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import struct
import tempfile
import termios
import threading
import time

import pyte
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
COLS, ROWS = 112, 26
CELL_W, CELL_H = 11, 23
PAD, TOP = 24, 56
BACKGROUND = '#10151f'
FOREGROUND = '#dae2ef'
COLORS = dict(default=FOREGROUND, black=BACKGROUND, red='#f07886',
              green='#82d6a1', brown='#f3cb7b', blue='#85b9f6',
              magenta='#c9a3f5', cyan='#77d5df', white=FOREGROUND,
              brightblack='#778397', brightred='#f799a4',
              brightgreen='#a2e8b9', brightyellow='#ffe09b',
              brightblue='#a8ceff', brightmagenta='#ddbefa',
              brightcyan='#a2e9ed', brightwhite='#ffffff')


class DemoAPI(http.server.BaseHTTPRequestHandler):
    """Supply a deterministic response grounded in the fixture log."""

    def log_message(self, *args):
        """Keep recording output quiet."""

    def do_POST(self):
        """Return the fixture explanation and an editable command proposal."""
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        assert 'database connection timed out' in request['messages'][0]['content']
        time.sleep(.9)
        response = dict(answer='The database connection timed out.\nThe health check then returned 503.',
                        command="rg 'ERROR' logs/web.log",
                        explanation='Show just the error lines in the log.')
        body = json.dumps({'content': [{'type': 'text', 'text': json.dumps(response)}]}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class Recording:
    """Capture PTY output and render its actual terminal cells."""

    def __init__(self, home, endpoint, font):
        self.screen = pyte.Screen(COLS, ROWS)
        self.stream = pyte.ByteStream(self.screen)
        self.font = ImageFont.truetype(str(font), 17)
        self.frames, self.durations = [], []
        self.glyphs = {}
        self.caption = 'Your shell, with a contextual assistant alongside it'
        self.pointer = None
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            env = dict(os.environ, HOME=str(home), TERM='xterm-256color',
                       NAMO_BIN=str(ROOT / 'bin/namo_complete'),
                       NAMO_WORKSPACE_SHELL=shutil.which('bash'),
                       NAMO_WORKSPACE_HOOK=str(ROOT / 'shell/workspace.bash'),
                       ANTHROPIC_API_KEY='local-demo-fixture', NAMO_ENDPOINT=endpoint,
                       NAMO_HINT_MIN='1000', NAMO_NO_LS='1', NAMO_HISTORY_LINES='0',
                       NAMO_LAYOUT='vertical', NAMO_AGENT_WINDOW='1', NAMO_DISABLE='0')
            for key in ('NAMO_WORKSPACE_ACTIVE', 'NAMO_WORKSPACE_DIR', 'NAMO_WORKSPACE_STARTED_FILE'):
                env.pop(key, None)
            os.chdir(home)
            os.execve(str(ROOT / 'bin/namo_complete'), ['namo_complete'], env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))

    def color(self, value, background=False):
        """Resolve terminal palette values to visible RGB colors."""
        if value == 'default' and background:
            return BACKGROUND
        return COLORS.get(value, '#' + value if len(value) == 6 else FOREGROUND)

    def frame(self):
        """Draw a terminal frame with a title and a clearly labeled demo caption."""
        image = Image.new('RGB', (COLS * CELL_W + PAD * 2, ROWS * CELL_H + TOP + 76), BACKGROUND)
        draw = ImageDraw.Draw(image)
        draw.text((PAD, 17), 'namo_complete', font=self.font, fill=FOREGROUND)
        draw.text((image.width - 290, 17), 'terminal + agent workspace', font=self.font, fill='#778397')
        for row in range(ROWS):
            for col in range(COLS):
                cell = self.screen.buffer[row][col]
                fg, bg = self.color(cell.fg), self.color(cell.bg, True)
                if cell.reverse:
                    fg, bg = bg, fg
                key = (cell.data, fg, bg)
                if key not in self.glyphs:
                    tile = Image.new('RGB', (CELL_W, CELL_H), bg)
                    ImageDraw.Draw(tile).text((0, 1), cell.data, font=self.font, fill=fg)
                    self.glyphs[key] = tile
                image.paste(self.glyphs[key], (PAD + col * CELL_W, TOP + row * CELL_H))
        if not self.screen.cursor.hidden:
            x, y = PAD + self.screen.cursor.x * CELL_W, TOP + self.screen.cursor.y * CELL_H
            draw.rectangle((x, y, x + CELL_W - 1, y + CELL_H - 1), outline='#e3eaf4')
        if self.pointer:
            x, y = self.pointer
            draw.ellipse((x-12, y-12, x+12, y+12), outline='#ffffff', width=3)
        draw.line((PAD, image.height - 66, image.width - PAD, image.height - 66), fill='#303a4b')
        draw.text((PAD, image.height - 54), self.caption, font=self.font, fill=FOREGROUND)
        draw.text((PAD, image.height - 28), 'Live application capture · local API fixture', font=self.font, fill='#778397')
        self.frames.append(image)
        self.durations.append(125)

    def pause(self, seconds):
        """Drain the real terminal while recording at a fixed frame rate."""
        for _ in range(max(1, round(seconds * 8))):
            end = time.monotonic() + .125
            while time.monotonic() < end:
                if select.select([self.fd], [], [], max(0, end - time.monotonic()))[0]:
                    try:
                        data = os.read(self.fd, 262144)
                    except OSError:
                        break
                    if not data:
                        break
                    self.stream.feed(data)
            self.frame()

    def send(self, text):
        """Send input to the workspace through its physical PTY."""
        os.write(self.fd, text.encode())

    def type(self, text):
        """Type a command or question at a readable pace."""
        for offset in range(0, len(text), 3):
            self.send(text[offset:offset+3])
            self.pause(.125)

    def click(self, col, row):
        """Show a click and send the same mouse event to the workspace."""
        self.pointer = (PAD + (col - .5) * CELL_W, TOP + (row - .5) * CELL_H)
        self.pause(.375)
        self.send(f'\x1b[<0;{col};{row}M\x1b[<0;{col};{row}m')
        self.pause(.375)
        self.pointer = None

    def close(self):
        """Stop the recorded process and release its PTY."""
        os.kill(self.pid, signal.SIGTERM)
        os.waitpid(self.pid, 0)
        os.close(self.fd)


def main():
    """Record a short workflow and write the README animation."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--font', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'assets/demo.gif')
    parser.add_argument('--preview', type=Path)
    args = parser.parse_args()
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), DemoAPI)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='namo-demo-') as directory:
            home = Path(directory)
            (home / '.bashrc').write_text("PS1='demo $ '\nHISTFILE=/dev/null\n")
            (home / 'logs').mkdir()
            (home / 'logs/web.log').write_text('09:41:02 INFO  server started on :3000\n09:41:07 ERROR database connection timed out\n09:41:07 ERROR health check returned 503\n09:41:12 INFO  retry scheduled\n')
            rec = Recording(home, f'http://127.0.0.1:{server.server_port}/v1/messages', args.font)
            try:
                rec.pause(.75)
                rec.type('cat logs/web.log'); rec.send('\r'); rec.pause(1.5)
                rec.caption = 'Ask about the output without copying it into chat'
                rec.click(88, 23)
                rec.type('What failed? Show me only the errors.'); rec.send('\r'); rec.pause(2.5)
                assert any('database connection' in line for line in rec.screen.display)
                rec.caption = 'Accept copies the command into your shell; it does not run it'
                for row, line in enumerate(rec.screen.display):
                    if '[ Accept ]' in line:
                        rec.click(line.index('[ Accept ]') + 4, row + 1)
                        break
                else:
                    raise RuntimeError('The agent did not render an Accept button')
                rec.pause(1.5)
                rec.caption = 'Review or edit the command, then press Enter yourself'
                rec.send('\r'); rec.pause(2)
                rec.caption = 'Switch between side-by-side and stacked layouts'
                rec.send('\x1b]s'); rec.pause(2)
                rec.send('\x1b]s'); rec.pause(1)
                rec.caption = 'Keep working in your terminal. Ask the agent when you need it.'
                rec.pause(2)
                if args.preview:
                    rec.frames[-1].save(args.preview)
                args.output.parent.mkdir(parents=True, exist_ok=True)
                rec.frames[0].save(args.output, save_all=True, append_images=rec.frames[1:],
                                   duration=rec.durations, loop=0, optimize=True)
                print(f'{args.output}: {len(rec.frames)} frames, {sum(rec.durations)/1000:.1f}s')
            finally:
                rec.close()
    finally:
        server.shutdown()
        thread.join()


if __name__ == '__main__':
    main()
