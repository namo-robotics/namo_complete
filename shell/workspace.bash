# Report shell state and install guarded command insertion inside a workspace.
[[ $- == *i* && -n ${NAMO_WORKSPACE_DIR:-} ]] || return 0
[[ ${_NAMO_WORKSPACE_HOOKED:-0} == 1 ]] && return 0
_NAMO_WORKSPACE_HOOKED=1
exec {_NAMO_WS_FD}<>"$NAMO_WORKSPACE_DIR/events" || return 0
"${NAMO_BIN:-namo_complete}" --nonblocking-fifo "$_NAMO_WS_FD" 2>/dev/null || return 0

# Write a small atomic record; terminal output cannot impersonate this channel.
_namo_ws_event() {
  local LC_ALL=C
  local kind=$1 payload=${2:0:2048} directory=${PWD:0:1024}
  printf '%s\0%s\0%s\0%s\0' "$kind" "$$" "$directory" "$payload" >&"$_NAMO_WS_FD" 2>/dev/null || :
}

# Capture status before other prompt hooks change it.
_namo_ws_prompt() {
  local result=$?
  _NAMO_WS_STATUS=$result
  if [[ ${_NAMO_WS_SEEDED:-0} == 0 ]]; then
    _NAMO_WS_SEEDED=1
    if [[ ${NAMO_HISTORY_LINES:-50} =~ ^[0-9]+$ && ${NAMO_HISTORY_LINES:-50} -gt 0 ]]; then
      _namo_ws_event history "$(builtin fc -ln -"${NAMO_HISTORY_LINES:-50}" 2>/dev/null)"
    fi
  fi
  printf '\037'
  return "$result"
}

# Append the marker after user hooks finish rebuilding the prompt.
_namo_ws_sync() {
  [[ $PS1 == *$'\035'* ]] || PS1+='\['$'\035''\]'
  _namo_ws_event prompt "${_NAMO_WS_STATUS:-0}"
  return "${_NAMO_WS_STATUS:-0}"
}

# PS0 runs once before a command, including compound commands.
_namo_ws_start() {
  local command
  command=$(HISTTIMEFORMAT= builtin history 1)
  _namo_ws_event start "$command"
  printf '\036'
}
PS0='$(_namo_ws_start)'"${PS0:-}"
if [[ ${PROMPT_COMMAND@a} == *a* ]]; then
  PROMPT_COMMAND=(_namo_ws_prompt "${PROMPT_COMMAND[@]}" _namo_ws_sync)
else
  PROMPT_COMMAND="_namo_ws_prompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}; _namo_ws_sync"
fi

# Read a proposal as data and require an empty edit buffer before execution.
_namo_ws_load() {
  local execute=$1 directory command
  if [[ ! -f $NAMO_WORKSPACE_DIR/command ]]; then
    _namo_ws_event rejected ''
    return
  fi
  { IFS= read -r directory; IFS= read -r command; } < "$NAMO_WORKSPACE_DIR/command"
  rm -f -- "$NAMO_WORKSPACE_DIR/command"
  if [[ $directory != "$PWD" || ( $execute == 1 && -n $READLINE_LINE ) || -z $command ]]; then
    _namo_ws_event rejected ''
    return
  fi
  READLINE_LINE=$command
  READLINE_POINT=${#READLINE_LINE}
  if [[ $execute == 1 ]]; then _namo_ws_event loaded "$command"; fi
}
# Insert a suggestion without submitting the command line.
_namo_ws_insert() { _namo_ws_load 0; }
# Load an approved command and acknowledge it to the host.
_namo_ws_approve() { _namo_ws_load 1; }
bind -x '"\C-x\C-o":_namo_ws_insert'
bind -x '"\C-x\C-r":_namo_ws_approve'
