#!/usr/bin/env bash
# Run namo_complete exactly as an installed user would, without installing it.
#
#   ./run.sh
#
# Opens an interactive bash shell in your current directory with the same
# setup a real user gets from their .bashrc:
#
#     NAMO_LIVE=1
#     source ~/.local/share/namo_complete/namo_complete.bash
#
# The only differences from a real install are that the binary is taken from
# ./bin instead of ~/.local/bin, and the prompt is prefixed with a blue "namo"
# so you can tell this shell apart from your normal one. Every runtime default
# (throttling, cache, timeouts) is exactly what a user would get.
#
# Nothing is installed and your .bashrc is untouched. Ctrl-D exits.
set -uo pipefail
INVOKED_FROM=$PWD            # capture before we cd to the script directory
cd "$(dirname "$0")"
ROOT=$PWD

case "${1:-}" in
  "") ;;
  -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
esac

# Load .env if present (gitignored; see .env.example).
if [ -f "$PWD/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$PWD/.env"
  set +a
fi

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  cat >&2 <<'MSG'
error: ANTHROPIC_API_KEY is not set.

  Put it in a .env file next to this script (it is gitignored):

      cp .env.example .env && chmod 600 .env
      $EDITOR .env

  or export it:

      export ANTHROPIC_API_KEY=sk-ant-...
MSG
  exit 1
fi

command -v curl >/dev/null 2>&1 || {
  echo "error: curl is required (namo_complete uses it for HTTPS)." >&2
  exit 1
}

[ -x ./bin/namo_complete ] || { echo "building..."; ./build.sh >/dev/null || exit 1; }

# The binary location is the one thing that differs from an install.
export NAMO_BIN="$ROOT/bin/namo_complete"
# What a user who wants as-you-type hints puts in their .bashrc.
export NAMO_LIVE=1

RC=$(mktemp)
{
  # --rcfile replaces ~/.bashrc, so source it explicitly; otherwise this would
  # not be the user's real shell.
  printf 'if [ -f "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi\n'
  printf 'export NAMO_BIN=%q\n' "$ROOT/bin/namo_complete"
  printf 'export NAMO_LIVE=1\n'
  printf 'source %q\n' "$ROOT/shell/namo_complete.bash"

  cat <<'RCEOF'
# Keep whatever prompt they already have; just put a blue "namo" in front so
# this shell is distinguishable. Done from PROMPT_COMMAND rather than assigned
# once, because many prompts (starship, powerline, VTE helpers) rebuild PS1 on
# every command.
_NAMO_PS1_PREFIX='\[\e[1;34m\]namo\[\e[0m\] '
_namo_prompt_prefix() {
  case $PS1 in
    "$_NAMO_PS1_PREFIX"*) ;;                       # already prefixed
    *) PS1="$_NAMO_PS1_PREFIX$PS1" ;;
  esac
}
# PROMPT_COMMAND is an array in bash 5.1+ and a string before that.
if [[ ${PROMPT_COMMAND@a} == *a* ]]; then
  PROMPT_COMMAND+=(_namo_prompt_prefix)
else
  PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }_namo_prompt_prefix"
fi
RCEOF

  printf 'cd %q\n' "$INVOKED_FROM"
  cat <<'RCEOF2'
printf '\n  \033[1mnamo_complete\033[0m\n\n'
printf '  \033[1mtype\033[0m        a hint appears on the bottom line when you pause\n'
printf '  \033[1mAlt-O\033[0m       complete what you have typed\n'
printf '  \033[1mAlt-G\033[0m       describe it in English, e.g. \033[1mundo my last commit\033[0m\n\n'
printf '  Suggestions land in your prompt - nothing is \033[1mever\033[0m executed.\n'
printf '  \033[1mnamo-live off\033[0m stops the hints. Ctrl-D exits.\n\n'
RCEOF2
} > "$RC"

bash --rcfile "$RC" -i
rm -f "$RC"
