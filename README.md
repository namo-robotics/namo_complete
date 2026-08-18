# namo_complete

LLM-powered autocomplete for Bash terminal commands, written in the
[Sun](https://namo-robotics.github.io/sun/) programming language.

Suggestions appear **as you type**, and two keys put one in your prompt:

| Key | What it does |
|---|---|
| *(just type)* | A hint appears on the bottom line once you pause |
| **Alt-O** | Accept the suggestion shown on the bottom line |
| **Alt-A** | Same, but list the alternatives and pick one |
| **Alt-G** | Describe what you want in plain English, get a command |

Type part of a command, press **Alt-O**, and the suggestion on the bottom line
is accepted in place:

```
$ git com
  ~ git commit -m "..."  (Alt-O)          <- hint, appears while you type

$ git commit -m "..."                     <- after Alt-O
```

Press **Alt-A** instead when you want to see the other candidates:

```
$ git com<Alt-A>
  1) git commit -m "..."
  2) git commit --amend
  3) git commit -a
  select [1-3] (any other key cancels): 1
```

Or press **Alt-G** and just say what you mean:

```
$ <Alt-G>
ask> undo my last commit but keep the changes staged
$ git reset --soft HEAD~1
```

The suggestion is placed in your readline buffer. **Nothing is ever executed** —
you still press Enter.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/namo-robotics/namo_complete/main/install.sh | bash
```

Downloads a prebuilt release binary, verifies its SHA-256, installs to
`~/.local`, and adds the source line to your `~/.bashrc` — **no Sun toolchain,
no compiler, no root**. Pass `--no-bashrc` to skip the `.bashrc` edit. Pin a version with
`--version v0.1.0`, change the location with `--prefix`, or build from a
checkout with `--from-source`. For the latest build of `main`:

```bash
curl -fsSL https://raw.githubusercontent.com/namo-robotics/namo_complete/main/install.sh | bash -s -- --version dev
```

Then set your API key and open a new shell:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
```

**Requires Linux x86_64**, `bash` 4.4+, and `curl` — not optional, since Sun's
stdlib has no TLS and `namo_complete` performs HTTPS by invoking it. macOS is
not supported: Sun's C FFI targets ELF only, and every syscall this program
makes goes through it (see [SUN_FEEDBACK.md](SUN_FEEDBACK.md)).

Before installing, see [what gets sent to Anthropic](#what-gets-sent-to-anthropic).

## Try it without installing

```bash
./run.sh
```

Opens an interactive bash shell **in your current directory**, set up exactly
the way an installed user's `.bashrc` would set it up — same throttling, same
cache, same timeouts. The only differences are that the binary comes from
`./bin` instead of `~/.local/bin`, and the prompt gets a blue `namo` prefix so
you can tell the shell apart from your normal one.

Start typing and a hint appears; Alt-O accepts it, Alt-A shows alternatives,
Alt-G takes plain English.
Nothing is installed, your `.bashrc` is untouched, and Ctrl-D exits.

It needs a real API key. Copy the example env file — `.env` is gitignored:

```bash
cp .env.example .env && chmod 600 .env
$EDITOR .env          # set ANTHROPIC_API_KEY
```

`run.sh` and `test.sh` load `.env` automatically.

## Live hints as you type

A dimmed suggestion appears on the terminal's bottom line ~400ms after you stop
typing; press Alt-O to accept it. This is on by default — it is the point of
the tool. Turn it off for a session with `namo-live off`.

**What this costs.** Bash's readline has no "line changed" hook, so live hints
work by rebinding every printable key to a function that inserts the character
and then does the extra work. That means bracketed paste is slower, undo
granularity changes, multi-byte UTF-8 is inserted byte-by-byte, and vi command
mode is not instrumented. If any of that bothers you, run `namo-live off` — the
Alt-O, Alt-A and Alt-G bindings keep working.

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

## Configuration

All settings are environment variables.

| Variable | Default | Meaning |
|---|---|---|
| `ANTHROPIC_API_KEY` | — | Required. |
| `NAMO_KEY` | `\eo` | Completion binding (Alt-O), in `bind` syntax. |
| `NAMO_ASK_KEY` | `\eg` | Plain-English binding (Alt-G). |
| `NAMO_DEBOUNCE` | `0.4` | Idle seconds before a live request fires. |
| `NAMO_HINT_MIN` | `3` | Minimum characters before hinting. |
| `NAMO_MODEL` | `claude-haiku-4-5` | Chosen for latency; any Claude model works. |
| `NAMO_TIMEOUT` | `10` | Seconds before the call is abandoned. |
| `NAMO_HISTORY_LINES` | `10` | History commands to send. `0` disables. |
| `NAMO_LS_LIMIT` | `40` | Filenames to send. |
| `NAMO_NO_LS` | `0` | `1` sends no directory listing. |
| `NAMO_ALT_KEY` | `\ea` | Alternatives binding (Alt-A). |
| `NAMO_PICKER` | `0` | `1` makes Alt-O always list alternatives too. |
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

## Releases

[`release.yml`](.github/workflows/release.yml) builds in an `ubuntu:26.04`
container, runs the test suite, checks the binary really is statically linked,
installs from the packaged tarball as a smoke test, then publishes
`namo_complete-<version>-linux-x86_64.tar.gz` plus `SHA256SUMS`.

| Trigger | Release |
|---|---|
| merge to `main` | `dev` — a rolling prerelease, tag force-moved and assets overwritten every time |
| tag `v*` | immutable versioned release with generated notes |

`install.sh` resolves the newest *stable* release by default, so the `dev`
prerelease is opt-in via `--version dev`. Pull requests run
[`ci.yml`](.github/workflows/ci.yml), which is the same build and tests without
publishing or touching the API.

`./test.sh` builds and installs the tarball locally too, so packaging breaks
surface before tag time rather than during a release.

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
