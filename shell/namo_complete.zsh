# namo_complete integration for interactive zsh.
#
# The shell owns line editing, history, prompt hooks, and key bindings. The Sun
# binary owns requests, caching, output capture, and hint rendering.
#
#   Alt-O   accept the top completion
#   Alt-A   choose from alternatives
#   Alt-G   describe a command in plain English

[[ -o interactive ]] || return 0
[[ "${_NAMO_ZSH_LOADED:-}" == 1 ]] && return 0
typeset -g _NAMO_ZSH_LOADED=1

autoload -Uz add-zsh-hook add-zle-hook-widget

[[ -n ${NAMO_BIN+x} ]] || NAMO_BIN=namo_complete
[[ -n ${NAMO_KEY+x} ]] || NAMO_KEY='\eo'
[[ -n ${NAMO_ALT_KEY+x} ]] || NAMO_ALT_KEY='\ea'
[[ -n ${NAMO_ASK_KEY+x} ]] || NAMO_ASK_KEY='\eg'
[[ -n ${NAMO_TIMEOUT+x} ]] || NAMO_TIMEOUT=10
[[ -n ${NAMO_DYM+x} ]] || NAMO_DYM=1
[[ -n ${NAMO_OUTPUT+x} ]] || NAMO_OUTPUT=10

export NAMO_HINT_MIN NAMO_HINT_PREFIX NAMO_HINT_SUFFIX NAMO_DYM_PREFIX \
       NAMO_DEBOUNCE NAMO_QUIET NAMO_HISTORY_LINES NAMO_LS_LIMIT

_namo_find_binary() {
  if [[ "$NAMO_BIN" == */* ]]; then
    [[ -x "$NAMO_BIN" ]] && { print -rn -- "$NAMO_BIN"; return 0; }
  else
    local found
    found=$(command -v -- "$NAMO_BIN" 2>/dev/null) &&
      { print -rn -- "$found"; return 0; }
  fi
  [[ -x "$HOME/.local/bin/namo_complete" ]] &&
    { print -rn -- "$HOME/.local/bin/namo_complete"; return 0; }
  return 1
}

typeset -g _NAMO_DIR="${XDG_RUNTIME_DIR:-/tmp/namo-$UID}/namo_complete"
mkdir -p "$_NAMO_DIR" 2>/dev/null && chmod 700 "$_NAMO_DIR" 2>/dev/null
typeset -g _NAMO_FIFO="$_NAMO_DIR/fifo.$$"
typeset -g _NAMO_REPLYFIFO="$_NAMO_DIR/reply.$$"
typeset -g _NAMO_HISTFILE="$_NAMO_DIR/hist.$$"
typeset -g _NAMO_PIDFILE="$_NAMO_DIR/daemon_pid.$$"
typeset -g _NAMO_DYMFILE="$_NAMO_DIR/dym.$$"
typeset -g _NAMO_PTSFILE="$_NAMO_DIR/pts.$$"
typeset -g _NAMO_OUTFILE="$_NAMO_DIR/out.$$"
typeset -g _NAMO_RELAY_PIDFILE="$_NAMO_DIR/relay_pid.$$"

typeset -g _NAMO_WFD=""
typeset -g _NAMO_RFD=""
typeset -gi _NAMO_REQ_ID=0
typeset -g _NAMO_OFF=""
typeset -g _NAMO_TTYFD=""
typeset -g _NAMO_CAPTURE=""
typeset -g _NAMO_REPLY_OUT=""
typeset -g _NAMO_REPLY_ERROR=""
typeset -g _NAMO_QUESTION=""
typeset -g _NAMO_BUFFER_SENT=""
typeset -g _NAMO_LAST_COMMAND=""
typeset -g _NAMO_PASTE=""

typeset -g _NAMO_BIN_PATH
_NAMO_BIN_PATH=$(_namo_find_binary) || _NAMO_OFF=1
typeset -g _NAMO_SHELL_FILE=${${(%):-%x}:A}

namo-version() {
  print -r -- "shell:  $_NAMO_SHELL_FILE"
  print -r -- "binary: ${_NAMO_BIN_PATH:-not found}"
  [[ -n "$_NAMO_BIN_PATH" ]] && "$_NAMO_BIN_PATH" --version
}

_namo_on_exit() {
  # ETX explicitly stops the daemon on platforms that do not report FIFO EOF.
  [[ -n "$_NAMO_WFD" ]] && printf '\t\003\n' >&$_NAMO_WFD 2>/dev/null
  rm -f "$_NAMO_FIFO" "$_NAMO_REPLYFIFO" "$_NAMO_HISTFILE" "$_NAMO_PIDFILE" \
        "$_NAMO_DYMFILE" "$_NAMO_PTSFILE" "$_NAMO_OUTFILE" \
        "$_NAMO_RELAY_PIDFILE" 2>/dev/null
  return 0
}

_namo_daemon_is_running() {
  local pid=""
  [[ -s "$_NAMO_PIDFILE" ]] || return 1
  read -r pid < "$_NAMO_PIDFILE" 2>/dev/null || return 1
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

_namo_daemon_ensure() {
  [[ -n "$_NAMO_OFF" ]] && return 1
  [[ -n "$_NAMO_WFD" && -n "$_NAMO_RFD" ]] &&
    _namo_daemon_is_running && return 0

  if [[ -z "$_NAMO_WFD" ]]; then
    [[ -p "$_NAMO_FIFO" ]] ||
      mkfifo -m 600 "$_NAMO_FIFO" 2>/dev/null || return 1
    { exec {_NAMO_WFD}<>"$_NAMO_FIFO"; } 2>/dev/null ||
      { _NAMO_WFD=""; return 1; }
  fi

  if [[ -z "$_NAMO_RFD" ]]; then
    [[ -p "$_NAMO_REPLYFIFO" ]] ||
      mkfifo -m 600 "$_NAMO_REPLYFIFO" 2>/dev/null || return 1
    { exec {_NAMO_RFD}<>"$_NAMO_REPLYFIFO"; } 2>/dev/null ||
      { _NAMO_RFD=""; return 1; }
  fi

  NAMO_SHELL=zsh NAMO_DAEMON=1 NAMO_FIFO="$_NAMO_FIFO" NAMO_REPLY="$_NAMO_REPLYFIFO" \
    NAMO_HISTFILE="$_NAMO_HISTFILE" NAMO_PIDFILE="$_NAMO_PIDFILE" \
    NAMO_DYMFILE="$_NAMO_DYMFILE" NAMO_OUTFILE="$_NAMO_OUTFILE" \
    "$_NAMO_BIN_PATH" </dev/null >/dev/null 2>&1
  _namo_daemon_is_running
}

_namo_relay_is_running() {
  local pid=""
  [[ -s "$_NAMO_RELAY_PIDFILE" ]] || return 1
  read -r pid < "$_NAMO_RELAY_PIDFILE" 2>/dev/null || return 1
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

_namo_capture_ensure() {
  _NAMO_CAPTURE=""
  [[ -t 1 ]] || return 0
  [[ -n "$_NAMO_OFF" ]] && return 1
  _namo_relay_is_running && { _NAMO_CAPTURE=1; return 0; }

  if [[ -z "$_NAMO_TTYFD" ]]; then
    { exec {_NAMO_TTYFD}>&1; } 2>/dev/null || return 1
  else
    exec >&$_NAMO_TTYFD 2>&1
  fi

  NAMO_RELAY=1 NAMO_OUTPUT="$NAMO_OUTPUT" NAMO_SHELL_PID=$$ \
    NAMO_PTSFILE="$_NAMO_PTSFILE" NAMO_OUTFILE="$_NAMO_OUTFILE" \
    NAMO_RELAY_PIDFILE="$_NAMO_RELAY_PIDFILE" NAMO_FIFO="$_NAMO_FIFO" \
    "$_NAMO_BIN_PATH" </dev/null >/dev/null 2>&1
  _namo_relay_is_running || return 1

  local pts=""
  read -r pts < "$_NAMO_PTSFILE" 2>/dev/null || return 1
  [[ -n "$pts" ]] || return 1
  exec > "$pts" 2>&1
  _NAMO_CAPTURE=1
}

_namo_send_line() {
  [[ -n "$_NAMO_WFD" ]] || return 0
  printf '%s\t%s\n' "$PWD" "$1" >&$_NAMO_WFD 2>/dev/null
  return 0
}

_namo_clear_hint_row() {
  _namo_send_line ""
}

_namo_ask_daemon() {
  _NAMO_REPLY_OUT=""
  _NAMO_REPLY_ERROR=""
  [[ -n "$_NAMO_WFD" && -n "$_NAMO_RFD" ]] || return 1
  _namo_daemon_is_running || return 1

  (( _NAMO_REQ_ID++ ))
  local id=$_NAMO_REQ_ID
  printf '%s\t\002%s\t%s\t%s\n' "$PWD" "$id" "$1" "$2" \
    >&$_NAMO_WFD 2>/dev/null || return 1

  local line="" n="" i=0 out=""
  while true; do
    IFS= read -r -t "$NAMO_TIMEOUT" -u $_NAMO_RFD line || return 1
    [[ "${line%%$'\t'*}" == "$id" ]] && break
  done
  n="${line#*$'\t'}"
  if [[ "$n" == E$'\t'* ]]; then
    _NAMO_REPLY_ERROR="${n#E$'\t'}"
    return 2
  fi
  [[ "$n" == <-> ]] || return 1
  for (( i = 0; i < n; i++ )); do
    IFS= read -r -t "$NAMO_TIMEOUT" -u $_NAMO_RFD line || return 1
    [[ "${line%%$'\t'*}" == "$id" ]] || continue
    out+="${line#*$'\t'}"$'\n'
  done
  _NAMO_REPLY_OUT="$out"
}

_namo_reserve_hint_row() {
  [[ -t 1 ]] || return 0
  local flat="${PROMPT//$'\n'/}" rows i out=""
  rows=$(( 1 + ${#PROMPT} - ${#flat} ))
  for (( i = 0; i < rows; i++ )); do
    out+=$'\n\033[2K'
  done
  printf '%s\033[%dA' "$out" "$rows"
}

_namo_history_snapshot() {
  local keep=${NAMO_HISTORY_LINES:-50}
  if (( keep > 0 )); then
    { fc -ln -$keep; } > "$_NAMO_HISTFILE" 2>/dev/null
  else
    : > "$_NAMO_HISTFILE"
  fi
}

_namo_on_prompt() {
  _namo_daemon_ensure || _NAMO_OFF=1
  _namo_capture_ensure
  [[ -n "$_NAMO_CAPTURE" ]] && printf '\037'
  _namo_send_line ""
  _NAMO_BUFFER_SENT=""
  _namo_history_snapshot
  _namo_post_correction
  _namo_reserve_hint_row
}

_namo_on_preexec() {
  _NAMO_LAST_COMMAND="$1"
  _NAMO_BUFFER_SENT=""
  _namo_send_line ""
  [[ -n "$_NAMO_CAPTURE" ]] && printf '\036'
  printf '\033[2K'
}

# zsh exposes the edit buffer during redraw. This hook runs inside ZLE and only
# writes to an already-open FIFO, so observing a key starts no process and does
# not force an extra repaint.
_namo_zle_line_changed() {
  [[ "$BUFFER" == "$_NAMO_BUFFER_SENT" ]] && return 0
  _NAMO_BUFFER_SENT="$BUFFER"
  _namo_send_line "$BUFFER"
}

_namo_pick_and_insert() {
  emulate -L zsh
  local out="$1" force="${2:-0}"
  [[ -z "${out//[[:space:]]/}" ]] && return 0

  local -a cands
  cands=("${(@f)${out%$'\n'}}")
  (( ${#cands[@]} > 0 )) || return 0

  local chosen="$cands[1]" flag="" cmd="" desc="" k="" i=0
  if [[ "$force" == 1 ]] && (( ${#cands[@]} > 1 )); then
    printf '\n\r\033[2K'
    for (( i = 1; i <= ${#cands[@]}; i++ )); do
      IFS=$'\t' read -r flag cmd desc <<< "$cands[$i]"
      printf '  %d) %s\033[K\n' "$i" "$cmd"
      [[ -n "$desc" ]] && printf '     \033[2m%s\033[0m\033[K\n' "$desc"
    done
    printf '  select [1-%d]: ' "${#cands[@]}"
    read -rsk 1 k
    printf '\n'
    [[ "$k" == <1-9> ]] && (( k <= ${#cands[@]} )) || {
      _namo_clear_hint_row
      return 0
    }
    chosen="$cands[$k]"
  fi

  IFS=$'\t' read -r flag cmd desc <<< "$chosen"
  [[ -n "$cmd" ]] || return 0

  if [[ "$flag" == '!' ]]; then
    local yn=""
    printf '\n\r\033[2K  \033[33mdestructive:\033[0m %s\033[K\n' "$cmd"
    printf '  insert anyway? [y/N] '
    read -rsk 1 yn
    printf '\n'
    [[ "$yn" == [yY] ]] || return 0
  fi

  BUFFER="$cmd"
  CURSOR=${#BUFFER}
  _NAMO_BUFFER_SENT="$BUFFER"
  _namo_clear_hint_row
}

# Read one bracketed paste after its leading Escape byte.
_namo_read_paste() {
  emulate -L zsh
  typeset ch="" opener="" pasted="" marker=$'\033[201~'
  integer i=0
  read -rsk 1 -u 0 -t 0.05 ch || return 1
  [[ "$ch" == '[' ]] || return 1
  for (( i = 0; i < 4; i++ )); do
    read -rsk 1 -u 0 ch || return 1
    opener+="$ch"
    [[ "$ch" == '~' ]] && break
  done
  [[ "$opener" == '200~' ]] || return 1
  while read -rsk 1 -u 0 ch; do
    pasted+="$ch"
    (( ${#pasted} <= 16384 )) || return 1
    if (( ${#pasted} >= 6 )) && [[ "${pasted[-6,-1]}" == "$marker" ]]; then
      if (( ${#pasted} == 6 )); then pasted=""; else pasted="${pasted[1,-7]}"; fi
      pasted="${pasted//$'\r'/ }"
      pasted="${pasted//$'\n'/ }"
      typeset -g _NAMO_PASTE="$pasted"
      return 0
    fi
  done
  return 1
}


_namo_read_question() {
  emulate -L zsh
  _NAMO_QUESTION=""
  local q="$BUFFER" ch=""
  printf '\n\r\033[2K\033[36mask>\033[0m %s' "$q"
  while read -rsk 1 -u 0 ch; do
    case "$ch" in
      '') break ;;
      $'\003') printf '\n'; return 1 ;;
      $'\033')
        _namo_read_paste || { printf '\n'; return 1; }
        q+="$_NAMO_PASTE"
        printf '%s' "$_NAMO_PASTE" ;;
      $'\177'|$'\010')
        [[ -n "$q" ]] && { q="${q[1,-2]}"; printf '\b \b'; } ;;
      $'\025')
        q=""
        printf '\r\033[K\033[36mask>\033[0m ' ;;
      *)
        q+="$ch"
        printf '%s' "$ch" ;;
    esac
  done
  printf '\n'
  _NAMO_QUESTION="$q"
}

# Show why an ask request left the editable line unchanged.
_namo_ask_notice() {
  printf '\r\033[2K\033[33mnamo:\033[0m %s\n' "$1"
}

_namo_key_request() {
  emulate -L zsh
  local mode="$1" force="$2"
  [[ -n "${WIDGET:-}" ]] && zle -I

  if [[ "$mode" == a ]]; then
    _namo_read_question || { [[ -n "${WIDGET:-}" ]] && zle reset-prompt; return 0; }
    [[ -z "${_NAMO_QUESTION//[[:space:]]/}" ]] &&
      { [[ -n "${WIDGET:-}" ]] && zle reset-prompt; return 0; }
    if ! _namo_ask_daemon a "$_NAMO_QUESTION"; then
      if [[ -n "$_NAMO_REPLY_ERROR" ]]; then
        _namo_ask_notice "request failed: $_NAMO_REPLY_ERROR"
      else
        _namo_ask_notice "request timed out or the helper is unavailable"
      fi
      [[ -n "${WIDGET:-}" ]] && zle reset-prompt
      return 0
    fi
    if [[ -z "${_NAMO_REPLY_OUT//[[:space:]]/}" ]]; then
      _namo_ask_notice "no command returned; add missing paths or constraints"
      [[ -n "${WIDGET:-}" ]] && zle reset-prompt
      return 0
    fi
  else
    [[ -z "${BUFFER//[[:space:]]/}" ]] && return 0
    _namo_ask_daemon c "$BUFFER" ||
      { [[ -n "${WIDGET:-}" ]] && zle reset-prompt; return 0; }
  fi

  _namo_pick_and_insert "$_NAMO_REPLY_OUT" "$force"
  [[ -n "${WIDGET:-}" ]] && zle reset-prompt
}

_namo_on_complete_key() {
  _namo_key_request c 0
}

_namo_on_alternatives_key() {
  _namo_key_request c 1
}

_namo_on_ask_key() {
  _namo_key_request a 1
}

zle -N namo-complete _namo_on_complete_key
zle -N namo-alternatives _namo_on_alternatives_key
zle -N namo-ask _namo_on_ask_key

typeset -g _NAMO_KEY_SEQ=$(printf '%b' "$NAMO_KEY")
typeset -g _NAMO_ALT_KEY_SEQ=$(printf '%b' "$NAMO_ALT_KEY")
typeset -g _NAMO_ASK_KEY_SEQ=$(printf '%b' "$NAMO_ASK_KEY")
for _namo_keymap in emacs viins; do
  bindkey -M "$_namo_keymap" "$_NAMO_KEY_SEQ" namo-complete 2>/dev/null
  bindkey -M "$_namo_keymap" "$_NAMO_ALT_KEY_SEQ" namo-alternatives 2>/dev/null
  bindkey -M "$_namo_keymap" "$_NAMO_ASK_KEY_SEQ" namo-ask 2>/dev/null
done
unset _namo_keymap

_namo_should_correct() {
  [[ "$NAMO_DYM" == 1 ]] || return 1
  [[ "${NAMO_DISABLE:-0}" == 1 ]] && return 1
  [[ -t 2 ]] || return 1
  [[ -n "$_NAMO_DYMFILE" && -n "$_NAMO_WFD" ]] || return 1
  return 0
}

_namo_queue_correction() {
  local exact="${_NAMO_LAST_COMMAND:-$2}"
  printf '%s\t%s\t0  %s\n' "$1" "$2" "$exact" \
    > "$_NAMO_DYMFILE" 2>/dev/null
  return 0
}

_namo_post_correction() {
  [[ -s "$_NAMO_DYMFILE" ]] || return 0
  _namo_send_line $'\001'
}

if (( ${+functions[command_not_found_handler]} )); then
  functions[_namo_previous_not_found_handler]="$functions[command_not_found_handler]"
fi

command_not_found_handler() {
  local rc=127
  if (( ${+functions[_namo_previous_not_found_handler]} )); then
    _namo_previous_not_found_handler "$@"
    rc=$?
  else
    printf '%s: command not found: %s\n' "${0:t}" "$1" >&2
  fi
  _namo_should_correct && _namo_queue_correction "$1" "$*"
  return $rc
}

add-zsh-hook -d precmd _namo_on_prompt 2>/dev/null
add-zsh-hook precmd _namo_on_prompt
add-zsh-hook -d preexec _namo_on_preexec 2>/dev/null
add-zsh-hook preexec _namo_on_preexec
add-zsh-hook -d zshexit _namo_on_exit 2>/dev/null
add-zsh-hook zshexit _namo_on_exit
add-zle-hook-widget -d line-pre-redraw _namo_zle_line_changed 2>/dev/null
add-zle-hook-widget line-pre-redraw _namo_zle_line_changed

_namo_on_prompt
