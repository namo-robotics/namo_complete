<div align="center">

# namo_complete

[![ci](https://github.com/namo-robotics/namo_complete/actions/workflows/ci.yml/badge.svg)](https://github.com/namo-robotics/namo_complete/actions/workflows/ci.yml) [![release](https://github.com/namo-robotics/namo_complete/actions/workflows/release.yml/badge.svg)](https://github.com/namo-robotics/namo_complete/actions/workflows/release.yml)

### LLM-powered autocomplete for your Bash terminal, written in [Sun](https://namo-robotics.github.io/sun/)

(**Linux-only** until Sun can target MacOS)

</div>

![namo_complete: a hint appears as you type, Alt-O accepts it; Alt-G asks for a
command in plain English](assets/demo.gif)

Type as usual. A moment after you pause, a dim hint appears on the row below
your line with the command you are most likely looking for. Press **Alt-O** to accept the hint, which puts it in your line where
you can edit it before pressing Enter. If you mistype a command, the *command not found* line comes with a **did you mean** hint.
Press **Alt-G** to enter **ask>** mode where you can describe the command that you want in plain english.

| Key       | Action                                                               |
| --------- | -------------------------------------------------------------------- |
| **Alt-O** | Accept the hint                                                      |
| **Alt-A** | List the other candidates, pick one by number                        |
| **Alt-G** | Describe what you want in plain English, pick from described options |


## Install

```bash
curl -fsSL https://raw.githubusercontent.com/namo-robotics/namo_complete/main/install.sh | bash
```

Then open a new terminall. You will also need to set the `ANTHROPIC_API_KEY` env var.
```bash
export ANTHROPIC_API_KEY=sk-ant-...
```

The install script downloads a release artifact and 
unpacks two files to `~/.local/bin/namo_complete` and `~/.local/share/namo_complete.bash`. It then adds a line to your `~/.bashrc` so new shells source the `namo_complete.bash` script.

Options:

| Option             | Env var        | Effect                                                                                                                  |
| ------------------ | -------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `--version vX.Y.Z` | `NAMO_VERSION` | Install a particular release; `dev` takes the latest build of `main`. Default: latest stable, or `dev` if there is none |
| `--prefix DIR`     | `NAMO_PREFIX`  | Install root. Default `~/.local`                                                                                        |
| `--no-bashrc`      | —              | Skip the `~/.bashrc` edit; add the source line yourself                                                                 |


## Uninstall

```bash
rm -f  ~/.local/bin/namo_complete
rm -rf ~/.local/share/namo_complete ~/.cache/namo_complete
sed -i '/# namo_complete/,+1d' ~/.bashrc     # drops the marker and the source line
```
## What gets sent to Anthropic

| Sent                          | Default       | Disable                |
| ----------------------------- | ------------- | ---------------------- |
| The partial command line      | always        | —                      |
| A command bash could not find | always        | `NAMO_DYM=0`           |
| What the last command printed | last 10 lines | `NAMO_OUTPUT=0`        |
| Current directory path        | always        | —                      |
| Filenames in that directory   | 40            | `NAMO_NO_LS=1`         |
| Recent shell history          | 50 commands   | `NAMO_HISTORY_LINES=0` |
| Everything                    |               | `NAMO_DISABLE=1`       |

Any history line or captured output line that contains something shaped like an
API key (`sk-`, `ghp_`, `github_pat_`, `AKIA`, `xoxb-`, `xoxp-`) is thrown away
before the request is built. That is the whole check: it catches a key you
pasted at a prompt, not a secret that looks like anything else. If you handle
sensitive material in this shell, set `NAMO_HISTORY_LINES=0` and it sends no
history at all.

## Configuration

| Variable                                     | Default                | Meaning                                                                              |
| -------------------------------------------- | ---------------------- | ------------------------------------------------------------------------------------ |
| `ANTHROPIC_API_KEY`                          | —                      | Required                                                                             |
| `NAMO_MODEL`                                 | `claude-haiku-4-5`     | Any Claude model                                                                     |
| `NAMO_BIN`                                   | `namo_complete`        | Binary path, if not on `PATH`                                                        |
| `NAMO_KEY` / `NAMO_ALT_KEY` / `NAMO_ASK_KEY` | `\eo` / `\ea` / `\eg`  | The three keys, written the way bash's `bind` writes them                            |
| `NAMO_DEBOUNCE` / `NAMO_QUIET`               | `0.2` / `0.05`         | Seconds of not typing before a request; how long a burst of typing is left to settle |
| `NAMO_HINT_MIN`                              | `3`                    | Minimum characters before hinting                                                    |
| `NAMO_HINT_PREFIX`                           | `hint: `               | Text in front of the hint row                                                        |
| `NAMO_TIMEOUT`                               | `10`                   | Seconds before giving up                                                             |
| `NAMO_DYM` / `NAMO_DYM_PREFIX`               | `1` / `did you mean: ` | "did you mean" after *command not found*, and the text in front of it                |
| `NAMO_OUTPUT`                                | `10`                   | Lines of the last command's output to send; `0` keeps none (hints still work)        |
| `NAMO_HISTORY_LINES`                         | `50`                   | History commands sent; `0` disables                                                  |
| `NAMO_LS_LIMIT` / `NAMO_NO_LS`               | `40` / `0`             | Directory listing                                                                    |
| `NAMO_MAX_SUGGESTIONS`                       | `3`                    | Candidates requested                                                                 |
| `NAMO_CACHE` / `NAMO_CACHE_TTL`              | `1` / `900`            | Local cache                                                                          |
| `NAMO_DISABLE`                               | `0`                    | `1` turns everything off                                                             |
| `NAMO_ENDPOINT`                              | Messages API           | Override, for testing                                                                |

Answers are cached in `~/.cache/namo_complete`, looked up by what you had typed,
which directory you were in, and which model answered. Deleting that directory
is safe at any time.

## Architecture

Three processes and one program file. Bash owns the line you are typing, because
its own line editor is the only thing that can; the rest belongs to two
background helpers, both of them the same binary started in a different mode:

- **the daemon** — lives as long as your shell, and does all the thinking:
  waiting for you to pause, looking in the cache, calling the API, drawing the
  hint row.
- **the output relay** — holds a *stand-in terminal* (a pseudo-terminal, or pty:
  a pair of endpoints that looks exactly like a real terminal to anything
  writing into it). The shell's output goes there instead of straight to your
  screen, and the relay passes every byte through to the real terminal. On the
  way past it keeps the last few lines your commands printed — that is what it
  is named for — and reads the line you are typing.

The two helpers and the shell talk over *named pipes* — files you write bytes
into at one end and read at the other.

```mermaid
flowchart LR
    BASH["bash<br>your prompt, your keys"]
    REL["the output relay"]
    DAE["the daemon"]
    TTY["your terminal"]
    CACHE[("answers already given")]
    API(["Claude"])

    BASH -->|"everything it prints,<br>including your line as you type it"| REL
    REL -->|"all of it, unchanged"| TTY
    REL -->|"your line, and what the last command printed"| DAE
    BASH -->|"Alt-O, Alt-A, Alt-G"| DAE
    DAE -->|"the commands it suggests"| BASH
    DAE -->|"the hint row"| TTY
    DAE <-->|"looked in first, written back after"| CACHE
    DAE -->|"only when the cache has no answer"| API
```

**The shell half** is one file, [`shell/namo_complete.bash`](shell/namo_complete.bash),
and deliberately thin: it does only the things that are impossible outside bash.

- The line you are typing is readable and writable, as `READLINE_LINE`, only
  inside a key handler bash runs for you. Assigning to it is the one way to put
  a command into someone's prompt without running it, and that is what Alt-O
  does — those three keys are the only ones this binds.
- Your shell's history can only be read by the shell itself, so it drops the
  daemon a copy at every prompt.
- The prompt hooks bash offers (`PROMPT_COMMAND`, `PS0`, `PS1`) and its
  "command not found" hook belong to it as well.

**The other half** is [`src/`](src/): a single program that behaves differently
depending on how it is started — as the daemon, as the output relay, or as a
plain one-shot run that reads its input, prints candidates and exits. That last
shape is what `run.sh`, the test suite and any script use, and it is the only
one that existed first. Everything else in there is what the daemon calls out
to: settings read from the environment, the prompt and the context that goes
with it, the redaction pass that drops lines looking like keys, the curl client,
and the cache.

Two deliberate properties:

- **No shell is ever involved.** `curl` is started directly, with its arguments
  passed one by one, so there is never a command string for a filename or a URL
  to be quoted into. Directories are listed by asking the operating system, not
  by running `ls`.
- **Your API key never shows up in the process list or on disk.** It is fed to
  `curl` on its standard input; only the harmless parts — the URL, the fixed
  headers, the path of the request body — are passed as arguments.

Everything the binary needs is inside the one file — it links nothing at run
time and depends on nothing but `curl`. One source file reaches outside Sun's
standard library: [`cmd_output_relay.sun`](src/cmd_output_relay.sun) calls a handful of C functions
directly (`posix_openpt`, `grantpt`, `unlockpt`, `ptsname`, `ioctl`, `read`,
`open`), because creating a stand-in terminal is the one thing the standard
library cannot yet do. No other file in [`src/`](src/) calls C or uses an
`unsafe` block.

## Development

```bash
./run.sh            # try it here, without installing anything
./build.sh          # -> bin/namo_complete (needs the Sun compiler)
./test.sh           # no API key needed: it answers itself with a local stub
./test.sh --live    # adds one real call, and times it
```

`run.sh` and `test.sh` read `.env`, which is never committed:

```bash
cp .env.example .env && chmod 600 .env
```

[`.devcontainer/`](.devcontainer/) has an Ubuntu 26.04 image with the compiler
already installed. Nothing ever fails loudly into your prompt: a missing key, a
timeout or a network error leaves your line exactly as it was and explains
itself separately.

## Notes on Sun

Sun is young, and the gaps this project ran into — in the compiler and in its
standard library — are written up in [SUN_FEEDBACK.md](SUN_FEEDBACK.md) as
ready-to-file issues.

## License

See [LICENSE](LICENSE).
