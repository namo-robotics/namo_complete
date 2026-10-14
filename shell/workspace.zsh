# Report shell state and install guarded command insertion inside a workspace.
[[ -o interactive && -n ${NAMO_WORKSPACE_DIR:-} ]] || return 0
[[ ${_NAMO_WORKSPACE_HOOKED:-0} == 1 ]] && return 0
typeset -g _NAMO_WORKSPACE_HOOKED=1
autoload -Uz add-zsh-hook add-zle-hook-widget
exec {_NAMO_WS_FD}<>"$NAMO_WORKSPACE_DIR/events" || return 0
"${NAMO_BIN:-namo_complete}" --nonblocking-fifo "$_NAMO_WS_FD" 2>/dev/null || return 0

# Send bounded records separately from shell output.
_namo_ws_event() {
  local LC_ALL=C
  local kind=$1 payload=${2[1,2048]} directory=${PWD[1,1024]}
  printf '%s\0%s\0%s\0%s\0' "$kind" "$$" "$directory" "$payload" >&$_NAMO_WS_FD 2>/dev/null || :
}
# Report completion status before the next interactive prompt.
_namo_ws_prompt() {
  local result=$?
  if [[ ${_NAMO_WS_SEEDED:-0} == 0 ]]; then
    _NAMO_WS_SEEDED=1
    if [[ ${NAMO_HISTORY_LINES:-50} == <-> && ${NAMO_HISTORY_LINES:-50} -gt 0 ]]; then
      _namo_ws_event history "$(fc -ln -${NAMO_HISTORY_LINES:-50} 2>/dev/null)"
    fi
  fi
  _namo_ws_event prompt "$result"
  printf '\037'
  return "$result"
}
# Record the next command before it starts.
_namo_ws_start() { _namo_ws_event start "$1"; printf '\036'; }
# Report the editable buffer without starting a process.
_namo_ws_line() { _namo_ws_event line "$BUFFER"; }
add-zsh-hook precmd _namo_ws_prompt
add-zsh-hook preexec _namo_ws_start
add-zle-hook-widget line-pre-redraw _namo_ws_line

# Insert only a proposal matching this prompt's directory and edit state.
_namo_ws_load() {
  local execute=$1 directory command
  if [[ ! -f $NAMO_WORKSPACE_DIR/command ]]; then _namo_ws_event rejected ''; return; fi
  { IFS= read -r directory; IFS= read -r command; } < "$NAMO_WORKSPACE_DIR/command"
  rm -f -- "$NAMO_WORKSPACE_DIR/command"
  if [[ $directory != "$PWD" || ( $execute == 1 && -n $BUFFER ) || -z $command ]]; then
    _namo_ws_event rejected ''
    return
  fi
  BUFFER=$command
  CURSOR=${#BUFFER}
  if [[ $execute == 1 ]]; then _namo_ws_event loaded "$command"; fi
}
# Insert a suggestion without submitting the command line.
_namo_ws_insert() { _namo_ws_load 0; }
# Load an approved command and acknowledge it to the host.
_namo_ws_approve() { _namo_ws_load 1; }
zle -N _namo_ws_insert
zle -N _namo_ws_approve
for keymap in emacs viins vicmd; do
  bindkey -M "$keymap" '^X^O' _namo_ws_insert
  bindkey -M "$keymap" '^X^R' _namo_ws_approve
done
