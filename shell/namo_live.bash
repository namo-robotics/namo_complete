#!/usr/bin/env bash
# namo_complete live hints -- suggestions that update as you type.
#
# Opt in with NAMO_LIVE=1 before sourcing namo_complete.bash.
#
# HOW IT WORKS, AND WHY IT IS LIKE THIS
#
# Bash's readline has no "the line changed" hook. The only way to react to
# typing is to rebind each printable character to a function that inserts the
# character itself and then does the extra work. That is what this file does,
# and it has real costs:
#
#   * Bracketed paste is slower (every pasted character runs the function).
#   * Undo granularity changes (each character is its own edit).
#   * Multi-byte UTF-8 input is inserted byte-by-byte.
#   * vi command mode is not instrumented (insert mode is).
#
# Turn it off at any time with `namo-live off`.
#
# Suggestions are rendered on the terminal's bottom line rather than inline:
# real ghost text needs a full line editor (see ble.sh). The render path only
# ever reads the local cache, so it never blocks on the network. A debounced
# background job does the actual API call and repaints when it lands.

case $- in *i*) ;; *) return 0 ;; esac

: "${NAMO_DEBOUNCE:=0.4}"        # seconds of idle typing before an API call
: "${NAMO_LIVE_MIN:=3}"          # don't suggest below this many characters
: "${NAMO_HINT_PREFIX:=~ }"

_NAMO_STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/namo_complete"
mkdir -p "$_NAMO_STATE_DIR" 2>/dev/null
_NAMO_STATE="$_NAMO_STATE_DIR/live_line.$$"
_NAMO_PIDFILE="$_NAMO_STATE_DIR/live_pid.$$"
_NAMO_HINT_SHOWN=0

_namo_live_cleanup() {
  local p; p=$(cat "$_NAMO_PIDFILE" 2>/dev/null)
  [ -n "$p" ] && kill "$p" 2>/dev/null
  rm -f "$_NAMO_STATE" "$_NAMO_PIDFILE" 2>/dev/null
  return 0
}
trap _namo_live_cleanup EXIT

# --- rendering --------------------------------------------------------------
# Draw on the terminal's last row using absolute positioning. Emitting a
# newline instead would scroll the screen whenever the prompt sits at the
# bottom, and the saved cursor position would then be wrong.
_namo_hint() {
  local text=$1
  [ -w /dev/tty ] || return 0
  if [ -n "$text" ]; then
    printf '\e7\e[999;1H\e[2K\e[2m%s%s\e[0m\e8' "$NAMO_HINT_PREFIX" "$text" > /dev/tty
    _NAMO_HINT_SHOWN=1
  elif [ "$_NAMO_HINT_SHOWN" = 1 ]; then
    printf '\e7\e[999;1H\e[2K\e8' > /dev/tty
    _NAMO_HINT_SHOWN=0
  fi
}

# Clear the hint before each new prompt (i.e. after a command runs).
_namo_live_prompt_hook() { _namo_hint ""; }
# PROMPT_COMMAND is an array in bash 5.1+ and a string before that.
if [[ ${PROMPT_COMMAND@a} == *a* ]]; then
  [[ " ${PROMPT_COMMAND[*]} " == *" _namo_live_prompt_hook "* ]] || \
    PROMPT_COMMAND=(_namo_live_prompt_hook "${PROMPT_COMMAND[@]}")
else
  case "${PROMPT_COMMAND:-}" in
    *_namo_live_prompt_hook*) ;;
    "") PROMPT_COMMAND=_namo_live_prompt_hook ;;
    *)  PROMPT_COMMAND="_namo_live_prompt_hook; ${PROMPT_COMMAND}" ;;
  esac
fi

# --- the debounced fetch ----------------------------------------------------
# The `( ... & )` subshell wrapper is load-bearing, not style. A bare `cmd &`
# in an interactive shell prints a job notification -- "[1] 610874" -- to the
# terminal, and with one prefetch per keystroke that floods the screen and
# scrolls the hint away. Backgrounding *inside* a subshell keeps job control
# quiet. `disown` does not help: the notice is printed when the job starts.
_namo_prefetch() {
  local line=$1 bin=$2

  # Cancel an in-flight prefetch for an older prefix.
  local old
  old=$(cat "$_NAMO_PIDFILE" 2>/dev/null)
  [ -n "$old" ] && kill "$old" 2>/dev/null

  ( {
      echo "$BASHPID" > "$_NAMO_PIDFILE"
      sleep "$NAMO_DEBOUNCE"
      # Still typing the same thing? If not, this request is stale.
      [ "$(cat "$_NAMO_STATE" 2>/dev/null)" = "$line" ] || exit 0

      { fc -ln -"${NAMO_HISTORY_LINES:-10}" 2>/dev/null
        echo '%%NAMO_LS%%'
        ls -1A 2>/dev/null | head -n "${NAMO_LS_LIMIT:-40}"
      } | NAMO_LINE="$line" NAMO_CWD="$PWD" "$bin" >/dev/null 2>&1

      # Re-check: the user may have typed on while the request was in flight.
      [ "$(cat "$_NAMO_STATE" 2>/dev/null)" = "$line" ] || exit 0
      h=$(NAMO_CACHE_ONLY=1 NAMO_LINE="$line" NAMO_CWD="$PWD" "$bin" </dev/null 2>/dev/null | head -1)
      [ -n "$h" ] && [ "$h" != "$line" ] && [ -w /dev/tty ] && \
        printf '\e7\e[999;1H\e[2K\e[2m%s%s  (Alt-O)\e[0m\e8' "$NAMO_HINT_PREFIX" "$h" > /dev/tty
    } & ) 2>/dev/null
}

# --- called after every instrumented keystroke ------------------------------
_namo_tick() {
  local bin
  bin=$(_namo_resolve_bin) || return 0
  printf '%s' "$READLINE_LINE" > "$_NAMO_STATE"

  if [ "${#READLINE_LINE}" -lt "$NAMO_LIVE_MIN" ]; then
    _namo_hint ""
    return 0
  fi

  # Instant path: cache only, never the network.
  local h
  h=$(NAMO_CACHE_ONLY=1 NAMO_LINE="$READLINE_LINE" NAMO_CWD="$PWD" "$bin" </dev/null 2>/dev/null | head -1)
  if [ -n "$h" ] && [ "$h" != "$READLINE_LINE" ]; then
    _namo_hint "$h  (Alt-O)"
  else
    _namo_hint ""
  fi

  _namo_prefetch "$READLINE_LINE" "$bin"
}

# --- key handlers -----------------------------------------------------------
_namo_key() {
  local c=$1
  READLINE_LINE="${READLINE_LINE:0:$READLINE_POINT}${c}${READLINE_LINE:$READLINE_POINT}"
  READLINE_POINT=$((READLINE_POINT + 1))
  _namo_tick
}

_namo_backspace() {
  if (( READLINE_POINT > 0 )); then
    READLINE_LINE="${READLINE_LINE:0:$((READLINE_POINT - 1))}${READLINE_LINE:$READLINE_POINT}"
    READLINE_POINT=$((READLINE_POINT - 1))
  fi
  _namo_tick
}

# --- binding ----------------------------------------------------------------
_namo_live_on() {
  local c
  for c in {a..z} {A..Z} {0..9}; do
    bind -x "\"$c\": _namo_key $c" 2>/dev/null
  done
  # Punctuation that shows up in commands. Quoted individually because bind
  # takes a double-quoted keyseq and several of these are shell-special.
  bind -x '" ": _namo_key " "'    2>/dev/null
  bind -x '"-": _namo_key "-"'    2>/dev/null
  bind -x '"_": _namo_key "_"'    2>/dev/null
  bind -x '".": _namo_key "."'    2>/dev/null
  bind -x '"/": _namo_key "/"'    2>/dev/null
  bind -x '"=": _namo_key "="'    2>/dev/null
  bind -x '",": _namo_key ","'    2>/dev/null
  bind -x '":": _namo_key ":"'    2>/dev/null
  bind -x '"+": _namo_key "+"'    2>/dev/null
  bind -x '"@": _namo_key "@"'    2>/dev/null
  bind -x '"%": _namo_key "%"'    2>/dev/null
  bind -x '"~": _namo_key "~"'    2>/dev/null
  bind -x '"\C-?": _namo_backspace' 2>/dev/null
  NAMO_LIVE=1
  printf 'namo: live hints ON (debounce %ss). Turn off with: namo-live off\n' "$NAMO_DEBOUNCE"
}

_namo_live_off() {
  local c
  for c in {a..z} {A..Z} {0..9}; do
    bind "\"$c\": self-insert" 2>/dev/null
  done
  for c in ' ' '-' '_' '.' '/' '=' ',' ':' '+' '@' '%' '~'; do
    bind "\"$c\": self-insert" 2>/dev/null
  done
  bind '"\C-?": backward-delete-char' 2>/dev/null
  _namo_hint ""
  NAMO_LIVE=0
  echo "namo: live hints OFF (Alt-O still works)"
}

namo-live() {
  case "${1:-status}" in
    on)     _namo_live_on ;;
    off)    _namo_live_off ;;
    status) echo "namo live hints: ${NAMO_LIVE:-0} (debounce ${NAMO_DEBOUNCE}s)" ;;
    *)      echo "usage: namo-live [on|off|status]" >&2; return 2 ;;
  esac
}

[ "${NAMO_LIVE:-0}" = 1 ] && _namo_live_on
