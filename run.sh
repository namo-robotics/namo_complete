#!/usr/bin/env bash
# Run namo_complete as an installed user would, without installing it.
# Uses zsh on macOS and Bash elsewhere.
set -uo pipefail
INVOKED_FROM=$PWD
cd "$(dirname "$0")"
ROOT=$PWD

[ -f .env ] && { set -a; . ./.env; set +a; }

[ -n "${ANTHROPIC_API_KEY:-}" ] || {
  echo "error: ANTHROPIC_API_KEY not set (put it in .env or export it)" >&2
  exit 1
}
[ -x bin/namo_complete ] || ./build.sh >/dev/null || exit 1

if [ "$(uname -s)" = Darwin ]; then
  RC_DIR=$(mktemp -d)
  RC="$RC_DIR/.zshrc"
  {
    printf 'if [ -f "$HOME/.zshrc" ]; then . "$HOME/.zshrc"; fi\n'
    printf 'export NAMO_BIN=%q\n' "$ROOT/bin/namo_complete"
    printf 'source %q\n' "$ROOT/shell/namo_complete.zsh"
    printf 'PROMPT=%%F{blue}namo%%f\ %%~\ %%#\ \n'
    printf 'cd %q\n' "$INVOKED_FROM"
    cat <<'EOF'
printf '\n  type for hints   \033[1mAlt-O\033[0m accept   \033[1mAlt-A\033[0m alternatives   \033[1mAlt-G\033[0m ask\n'
printf '  nothing is executed; Ctrl-D exits\n\n'
EOF
  } > "$RC"
  ZDOTDIR="$RC_DIR" zsh -d -i
  rm -rf "$RC_DIR"
  exit
fi

RC=$(mktemp)
{
  printf 'if [ -f "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi\n'
  printf 'export NAMO_BIN=%q\n' "$ROOT/bin/namo_complete"
  printf 'source %q\n' "$ROOT/shell/namo_complete.bash"
  cat <<'EOF'
_NAMO_PS1_PREFIX='\[\e[1;34m\]namo\[\e[0m\] '
_namo_prompt_prefix() {
  case $PS1 in "$_NAMO_PS1_PREFIX"*) ;; *) PS1="$_NAMO_PS1_PREFIX$PS1" ;; esac
}
if [[ ${PROMPT_COMMAND@a} == *a* ]]; then
  PROMPT_COMMAND+=(_namo_prompt_prefix)
else
  PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }_namo_prompt_prefix"
fi
EOF
  printf 'cd %q\n' "$INVOKED_FROM"
  cat <<'EOF'
printf '\n  type for hints   \033[1mAlt-O\033[0m accept   \033[1mAlt-A\033[0m alternatives   \033[1mAlt-G\033[0m ask\n'
printf '  nothing is executed; Ctrl-D exits\n\n'
EOF
} > "$RC"

bash --rcfile "$RC" -i
rm -f "$RC"
