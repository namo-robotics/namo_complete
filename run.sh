#!/usr/bin/env bash
# Run namo_complete as an installed user would, without installing it.
# Opens a bash shell in the current directory with the integration loaded.
set -uo pipefail
INVOKED_FROM=$PWD
cd "$(dirname "$0")"
ROOT=$PWD

[ -f .env ] && { set -a; . ./.env; set +a; }

[ -n "${ANTHROPIC_API_KEY:-}" ] || {
  echo "error: ANTHROPIC_API_KEY not set (put it in .env or export it)" >&2; exit 1; }
command -v curl >/dev/null || { echo "error: curl is required" >&2; exit 1; }
[ -x bin/namo_complete ] || ./build.sh >/dev/null || exit 1

RC=$(mktemp)
{
  # --rcfile replaces ~/.bashrc, so source it explicitly.
  printf 'if [ -f "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi\n'
  printf 'export NAMO_BIN=%q\n' "$ROOT/bin/namo_complete"
  printf 'source %q\n' "$ROOT/shell/namo_complete.bash"
  cat <<'EOF'
# Prefix the existing prompt; from PROMPT_COMMAND because prompts like starship
# rebuild PS1 every command. PROMPT_COMMAND is an array in bash 5.1+.
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
