#!/usr/bin/env bash
# As-you-type hints. Always on: they are the feature, not an add-on.
#
# Readline has no line-changed hook, so every printable key is rebound. Costs:
# slower paste, per-character undo, byte-wise UTF-8, no vi command mode.
# Rendering reads only the local cache; a debounced job does the API call.

case $- in *i*) ;; *) return 0 ;; esac

: "${NAMO_DEBOUNCE:=0.4}"
: "${NAMO_HINT_MIN:=3}"
: "${NAMO_HINT_PREFIX:=~ }"
: "${NAMO_HINT_SUFFIX:=  (Alt-O / Alt-A for more)}"

_NAMO_DIR="${XDG_RUNTIME_DIR:-/tmp}/namo_complete"
mkdir -p "$_NAMO_DIR" 2>/dev/null
_NAMO_STATE="$_NAMO_DIR/live_line.$$"
_NAMO_PIDFILE="$_NAMO_DIR/live_pid.$$"
_NAMO_SHOWN=0

_namo_live_cleanup() {
  local p; p=$(cat "$_NAMO_PIDFILE" 2>/dev/null)
  [ -n "$p" ] && kill "$p" 2>/dev/null
  rm -f "$_NAMO_STATE" "$_NAMO_PIDFILE" 2>/dev/null
  return 0
}
trap _namo_live_cleanup EXIT

# Absolute positioning to the last row. A newline would scroll the screen when
# the prompt sits at the bottom, invalidating the saved cursor.
_namo_hint() {
  [ -w /dev/tty ] || return 0
  if [ -n "$1" ]; then
    printf '\e7\e[999;1H\e[2K\e[2m%s%s\e[0m\e8' "$NAMO_HINT_PREFIX" "$1" > /dev/tty
    _NAMO_SHOWN=1
  elif [ "$_NAMO_SHOWN" = 1 ]; then
    printf '\e7\e[999;1H\e[2K\e8' > /dev/tty
    _NAMO_SHOWN=0
  fi
}

_namo_live_prompt_hook() { _namo_hint ""; }
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

# The ( ... & ) wrapper is load-bearing: a bare `cmd &` in an interactive shell
# prints "[1] 12345" on every keystroke. disown does not help -- the notice is
# printed when the job starts.
_namo_prefetch() {
  local line=$1 bin=$2 old
  old=$(cat "$_NAMO_PIDFILE" 2>/dev/null)
  [ -n "$old" ] && kill "$old" 2>/dev/null

  ( {
      echo "$BASHPID" > "$_NAMO_PIDFILE"
      sleep "$NAMO_DEBOUNCE"
      [ "$(cat "$_NAMO_STATE" 2>/dev/null)" = "$line" ] || exit 0

      { fc -ln -"${NAMO_HISTORY_LINES:-50}" 2>/dev/null
        echo '%%NAMO_LS%%'
        ls -1A 2>/dev/null | head -n "${NAMO_LS_LIMIT:-40}"
      } | NAMO_LINE="$line" NAMO_CWD="$PWD" "$bin" >/dev/null 2>&1

      [ "$(cat "$_NAMO_STATE" 2>/dev/null)" = "$line" ] || exit 0
      h=$(NAMO_CACHE_ONLY=1 NAMO_LINE="$line" NAMO_CWD="$PWD" "$bin" </dev/null 2>/dev/null | head -1)
      [ -n "$h" ] && [ "$h" != "$line" ] && [ -w /dev/tty ] && \
        printf '\e7\e[999;1H\e[2K\e[2m%s%s%s\e[0m\e8' \
               "$NAMO_HINT_PREFIX" "$h" "$NAMO_HINT_SUFFIX" > /dev/tty
    } & ) 2>/dev/null
}

_namo_tick() {
  local bin h
  bin=$(_namo_resolve_bin) || return 0
  printf '%s' "$READLINE_LINE" > "$_NAMO_STATE"

  if [ "${#READLINE_LINE}" -lt "$NAMO_HINT_MIN" ]; then _namo_hint ""; return 0; fi

  # Cache only: never block on the network here.
  h=$(NAMO_CACHE_ONLY=1 NAMO_LINE="$READLINE_LINE" NAMO_CWD="$PWD" "$bin" </dev/null 2>/dev/null | head -1)
  if [ -n "$h" ] && [ "$h" != "$READLINE_LINE" ]; then
    _namo_hint "${h}${NAMO_HINT_SUFFIX}"
  else
    _namo_hint ""
  fi
  _namo_prefetch "$READLINE_LINE" "$bin"
}

_namo_key() {
  READLINE_LINE="${READLINE_LINE:0:$READLINE_POINT}${1}${READLINE_LINE:$READLINE_POINT}"
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

_NAMO_PUNCT=(' ' '-' '_' '.' '/' '=' ',' ':' '+' '@' '%' '~')

# Every printable key routes through _namo_key so the hint can follow the line.
for _namo_c in {a..z} {A..Z} {0..9}; do
  bind -x "\"$_namo_c\": _namo_key $_namo_c" 2>/dev/null
done
for _namo_c in "${_NAMO_PUNCT[@]}"; do
  bind -x "\"$_namo_c\": _namo_key \"$_namo_c\"" 2>/dev/null
done
unset _namo_c
bind -x '"\C-?": _namo_backspace' 2>/dev/null
