# namo_complete

LLM-powered autocomplete for Bash terminal commands, written in the
[Sun](https://namo-robotics.github.io/sun/) programming language.

Suggestions appear **as you type**, and two keys put one in your prompt:

| Key | What it does |
|---|---|
| *(just type)* | A hint appears on the bottom line once you pause |
| **Alt-O** | Complete the partial command you are typing |
| **Alt-G** | Describe what you want in plain English, get a command |

Type part of a command, press **Alt-O**, and Claude completes it in place:

```
$ git com<Alt-O>
  1) git commit -m "..."
  2) git commit --amend
  3) git commit -a
  select [1-3] (any other key cancels): 1
$ git commit -m "..."
```

Or press **Alt-G** and just say what you mean:

```
$ <Alt-G>
ask> undo my last commit but keep the changes staged
  1) git reset --soft HEAD~1
  2) git reset HEAD~1
  select [1-2] (any other key cancels): 1
$ git reset --soft HEAD~1
```

The suggestion is placed in your readline buffer. **Nothing is ever executed** —
you still press Enter.

### Why Alt and not Ctrl

Both bindings use Alt so they are consistent, and because Ctrl-G is unusable in
editor terminals: VS Code binds it to *Go to Line/Column* and lists it in
`terminal.integrated.commandsToSkipShell`, so the keystroke is consumed by the
editor and never reaches bash. Alt-O and Alt-G are not claimed by anything and
work in VS Code, plain terminals, and over SSH alike.

Both are overridable with `NAMO_KEY` and `NAMO_ASK_KEY`, in `bind` keyseq
syntax. On macOS, Option-O and Option-G type `ø` and `©` rather than sending
Meta, so set something else there, e.g. `NAMO_KEY='\C-x\C-o'`.

## Live hints as you type

Off by default, because it is invasive. Turn it on before sourcing:

```bash
NAMO_LIVE=1
source ~/.local/share/namo_complete/namo_complete.bash
```

A dimmed suggestion then appears on the terminal's bottom line ~400ms after you
stop typing; press Alt-O to accept it. Toggle at runtime with
`namo-live on|off|status`.

**What this costs.** Bash's readline has no "line changed" hook, so live hints
work by rebinding every printable key to a function that inserts the character
and then does the extra work. That means bracketed paste is slower, undo
granularity changes, multi-byte UTF-8 is inserted byte-by-byte, and vi command
mode is not instrumented. If any of that bothers you, run `namo-live off` — the
Alt-O and Alt-G bindings keep working.

Rendering is a bottom-line status hint rather than inline grey ghost text.
True inline ghost text needs a full line editor; if you want that, install
[ble.sh](https://github.com/akinomyoga/ble.sh).

**Latency.** A live call takes ~700ms, far too slow to run per keystroke, so
the render path only ever reads the local cache (~2ms) and never blocks. A
debounced background job makes the actual request and repaints when it lands.

---

## What gets sent to Anthropic

Read this before installing. On each request, the following is sent to the
Claude API:

| Sent | Default | Turn it off |
|---|---|---|
| The partial command line you typed | always | — |
| Your current directory path | always | — |
| A listing of filenames in that directory | up to 40 names | `NAMO_NO_LS=1` |
| Your recent shell history | last 10 commands | `NAMO_HISTORY_LINES=0` |
| Everything | | `NAMO_DISABLE=1` |

History lines that look like they carry a credential are dropped before the
request is built — anything containing `password`, `secret`, `token`, `key=`,
`credential`, `authorization`, or a recognizable prefix (`sk-`, `ghp_`,
`github_pat_`, `AKIA`, `xoxb-`, `xoxp-`), plus every `export ...` line. This is
best-effort pattern matching, not a guarantee. If you work with sensitive
material in your shell, set `NAMO_HISTORY_LINES=0`.

Prompts are subject to Anthropic's data retention policy.

## Try it without installing

```bash
./run.sh
```

Opens an interactive bash shell **in your current directory**, set up exactly
the way an installed user's `.bashrc` would set it up — same throttling, same
cache, same timeouts. The only differences are that the binary comes from
`./bin` instead of `~/.local/bin`, and the prompt gets a blue `namo` prefix so
you can tell the shell apart from your normal one.

Start typing and a hint appears; Alt-O completes; Alt-G takes plain English.
Nothing is installed, your `.bashrc` is untouched, and Ctrl-D exits.

It needs a real API key. Copy the example env file — `.env` is gitignored:

```bash
cp .env.example .env && chmod 600 .env
$EDITOR .env          # set ANTHROPIC_API_KEY
```

`run.sh` and `test.sh` load `.env` automatically.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/namo-robotics/namo_complete/main/install.sh | bash
```

The installer sets up the Sun toolchain if it is missing, builds the binary
into `~/.local/bin`, and installs the shell integration. It does **not** edit
your `.bashrc`; it prints the line for you to add:

```bash
source ~/.local/share/namo_complete/namo_complete.bash
```

Then set your API key and open a new shell:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
```

Requirements: Linux, `bash`, and `curl`. (`curl` is not optional — Sun's stdlib
has no TLS, so `namo_complete` performs HTTPS by invoking it.)

## Configuration

All settings are environment variables.

| Variable | Default | Meaning |
|---|---|---|
| `ANTHROPIC_API_KEY` | — | Required. |
| `NAMO_KEY` | `\eo` | Completion binding (Alt-O), in `bind` syntax. |
| `NAMO_ASK_KEY` | `\eg` | Plain-English binding (Alt-G). |
| `NAMO_LIVE` | `0` | `1` enables as-you-type hints. |
| `NAMO_DEBOUNCE` | `0.4` | Idle seconds before a live request fires. |
| `NAMO_LIVE_MIN` | `3` | Minimum characters before hinting. |
| `NAMO_MODEL` | `claude-haiku-4-5` | Chosen for latency; any Claude model works. |
| `NAMO_TIMEOUT` | `10` | Seconds before the call is abandoned. |
| `NAMO_HISTORY_LINES` | `10` | History commands to send. `0` disables. |
| `NAMO_LS_LIMIT` | `40` | Filenames to send. |
| `NAMO_NO_LS` | `0` | `1` sends no directory listing. |
| `NAMO_MAX_SUGGESTIONS` | `3` | Candidates to request. |
| `NAMO_CACHE` | `1` | `0` disables the local cache. |
| `NAMO_CACHE_TTL` | `900` | Cache lifetime in seconds. |
| `NAMO_CONFIRM_DANGEROUS` | `1` | Confirm before inserting destructive-looking commands. |
| `NAMO_DISABLE` | `0` | `1` turns the feature off entirely. |
| `NAMO_ENDPOINT` | Anthropic Messages API | Override for testing against a mock. |

Responses are cached under `$XDG_CACHE_HOME/namo_complete`, keyed on the
normalized prefix plus directory plus model, so repeated Alt-O on the same
input costs nothing.

## How it works

```
bash readline ──Alt-O───> _namo_complete()          shell/namo_complete.bash
                             │ env: NAMO_LINE / NAMO_CWD
                             │ stdin: history, %%NAMO_LS%%, directory listing
                             ▼
                          namo_complete                    (Sun binary)
                             │ redact secrets -> cache lookup -> build JSON
                             │ chdir(runtime dir); write body.json + req.conf
                             │ system("curl -sS -K ./req.conf ...")
                             │ parse response
                             ▼
                          stdout: up to 3 lines ──> READLINE_LINE
```

Two properties are deliberate:

- **No user data reaches the shell.** The binary `chdir`s into its runtime
  directory first, so the `system()` string is a compile-time constant made
  only of relative literal paths. Nothing you type is ever interpolated into a
  command.
- **The API key never appears in `ps`.** It lives in a mode-0600 `curl -K`
  config file, created with `O_EXCL|O_NOFOLLOW`, and unlinked as soon as the
  request completes.

The binary is statically linked and depends on nothing at runtime but `curl`.

## Building from source

```bash
./build.sh                 # -> bin/namo_complete
```

Requires the Sun compiler on `PATH`. There is an Ubuntu 26.04 dev container in
[`.devcontainer/`](.devcontainer/) with the whole toolchain preinstalled;
`.devcontainer/verify.sh` checks it end to end.

Run it directly to debug:

```bash
echo 'git status' | NAMO_LINE='git com' NAMO_CWD="$PWD" ./bin/namo_complete
```

Every failure mode is silent on stdout — a missing key, a timeout, or a
network error leaves your prompt untouched and explains itself on stderr.

## Tests

```bash
./test.sh           # offline + end-to-end against a local mock; no API key needed
./test.sh --live    # additionally makes one real call and times it
```

Covers graceful degradation, credential redaction, API-key handling (header
present, nothing left on disk), request shape, cache behaviour, and the
readline rewrite. The `--live` run asserts that a real completion comes back in
under 1.5s — worth running after any change to `src/prompt.sun`, since a mock
will happily accept a request the real API rejects.

## Notes on Sun

This project is also a road test of a young language. The compiler and stdlib
gaps it ran into, the two miscompiles it hit, and what would have made it
easier are written up in [SUN_FEEDBACK.md](SUN_FEEDBACK.md).

## License

See [LICENSE](LICENSE).
