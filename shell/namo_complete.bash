# Launch the terminal and agent workspace once, preserving a regular-shell fallback.
case $- in *i*) ;; *) return 0 ;; esac
[[ ${NAMO_WORKSPACE_ACTIVE:-0} == 1 || ${NAMO_DISABLE:-0} == 1 ]] && return 0
[[ ${_NAMO_WORKSPACE_INTEGRATION:-0} == 1 ]] && return 0
_NAMO_WORKSPACE_INTEGRATION=1
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'namo_complete requires Bash 4.4 or newer.\n' >&2
  return 0
fi

# Start one workspace after user startup configuration has finished.
_namo_workspace_launch() {
  [[ ${_NAMO_WORKSPACE_ATTEMPTED:-0} == 1 ]] && return 0
  _NAMO_WORKSPACE_ATTEMPTED=1
  [[ -t 0 && -t 1 ]] || return 0
  local binary result started terminal_state completed
  binary=$(command -v -- "${NAMO_BIN:-namo_complete}") || return 0
  started=$(mktemp "${TMPDIR:-/tmp}/namo-workspace-started.XXXXXX") || return 0
  terminal_state=$(stty -g 2>/dev/null) || return 0
  if NAMO_WORKSPACE_STARTED_FILE="$started" NAMO_WORKSPACE_SHELL="${BASH:-/bin/bash}" "$binary"; then
    result=0
  else
    result=$?
  fi
  completed=$(cat -- "$started" 2>/dev/null)
  rm -f -- "$started"
  if [[ $completed == exited ]]; then exit "$result"; fi
  # Restore the outer shell even if the host died without running cleanup.
  stty "$terminal_state" 2>/dev/null || stty sane 2>/dev/null || :
  printf '\033[0m\033[?7h\033[?25h\033[?2004l\033[?1000l\033[?1002l\033[?1003l\033[?1006l\033[?1049l'
  printf 'namo workspace stopped unexpectedly; continuing with the regular shell.\n' >&2
  return 0
}
if [[ ${PROMPT_COMMAND@a} == *a* ]]; then
  PROMPT_COMMAND+=(_namo_workspace_launch)
else
  PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }_namo_workspace_launch"
fi
