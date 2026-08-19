#!/usr/bin/env bash
# As-you-type hints. Always on: they are the feature, not an add-on.
#
# Readline has no line-changed hook, so every printable key is rebound. Costs:
# slower paste, per-character undo, byte-wise UTF-8, no vi command mode.
#
# And one more, the expensive one: bash blanks the prompt line ("\r", erase to
# end of line) before it runs a `bind -x` command and repaints it afterwards, so
# however long the handler takes is a hole in the line being typed into. A single
# fork is enough to see it flicker. The keystroke path below therefore forks
# nothing, execs nothing and waits for nothing: it pushes the line down a FIFO
# and returns. Debounce, the cache, the API call and the hint row itself all
# live in the daemon on the other end -- see src/live.sun.
#
# What is left here is only what readline will not let go of: the key bindings,
# READLINE_LINE, and `fc` (a builtin, so the shell is the only thing that can
# read its own history).
#
# The same pipe carries the rest of the shell's traffic, for the same reason.
# Alt-O, Alt-A and Alt-G send a request and wait for the answer on a second
# FIFO (_namo_request), and a command bash could not find is posted after the
# prompt is back (_namo_dym_post). Nothing on any of those paths forks: the
# descriptors are open, and printf and read are builtins.

case $- in *i*) ;; *) return 0 ;; esac

# The daemon reads these settings from its environment, so a plain shell
# variable is no longer enough to carry them across.
for _namo_v in NAMO_HINT_MIN NAMO_HINT_PREFIX NAMO_HINT_SUFFIX \
               NAMO_DEBOUNCE NAMO_QUIET NAMO_HISTORY_LINES NAMO_LS_LIMIT; do
  # shellcheck disable=SC2163  # exporting the *named* variable is the point
  [ -n "${!_namo_v+set}" ] && export "$_namo_v"
done
unset _namo_v

# The daemon's history snapshot lives here, so the directory must be private.
_NAMO_DIR="${XDG_RUNTIME_DIR:-/tmp/namo-$UID}/namo_complete"
mkdir -p "$_NAMO_DIR" 2>/dev/null && chmod 700 "$_NAMO_DIR" 2>/dev/null
_NAMO_FIFO="$_NAMO_DIR/live_fifo.$$"
_NAMO_HISTFILE="$_NAMO_DIR/live_hist.$$"
_NAMO_PIDFILE="$_NAMO_DIR/live_pid.$$"
_NAMO_DYMFILE="$_NAMO_DIR/live_dym.$$"
_NAMO_REPLYFIFO="$_NAMO_DIR/live_reply.$$"

_NAMO_WFD=""   # write end of the FIFO, held open by this shell
_NAMO_RFD=""   # read end of the reply FIFO, likewise
_NAMO_REQ_ID=0
_NAMO_OFF=""   # set if the plumbing could not be built; hints go quiet

# Resolved once. Doing it per prompt would be a command substitution, and this
# is the only value the prompt hook needs from outside the shell.
_NAMO_BIN_PATH=$(_namo_resolve_bin) || _NAMO_OFF=1

_namo_live_cleanup() {
  rm -f "$_NAMO_FIFO" "$_NAMO_HISTFILE" "$_NAMO_PIDFILE" "$_NAMO_DYMFILE" \
        "$_NAMO_REPLYFIFO" 2>/dev/null
  return 0
}
trap _namo_live_cleanup EXIT

# The daemon writes its pid before it hands the prompt back, so this never
# races with a start-up we just asked for. Both `read` and `kill` are builtins.
_namo_daemon_live() {
  local pid=""
  { read -r pid; } < "$_NAMO_PIDFILE" 2>/dev/null || return 1
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

_namo_daemon_up() {
  [ -n "$_NAMO_OFF" ] && return 1
  [ -n "$_NAMO_WFD" ] && _namo_daemon_live && return 0

  if [ -z "$_NAMO_WFD" ]; then
    [ -p "$_NAMO_FIFO" ] || mkfifo -m 600 "$_NAMO_FIFO" 2>/dev/null || return 1
    # Read-write: opening a FIFO for writing alone blocks until a reader shows
    # up, and this shell must never block on its own helper. The braces are
    # load-bearing: `exec {fd}>... 2>/dev/null` applies the stderr redirect to
    # the *shell*, permanently, and bash writes its prompt to stderr.
    { exec {_NAMO_WFD}<>"$_NAMO_FIFO"; } 2>/dev/null || { _NAMO_WFD=""; return 1; }
  fi

  # The way back. Read-write again, so that the daemon restarting does not
  # deliver an end-of-file to a `read` that is waiting for an answer.
  if [ -z "$_NAMO_RFD" ]; then
    [ -p "$_NAMO_REPLYFIFO" ] || mkfifo -m 600 "$_NAMO_REPLYFIFO" 2>/dev/null || return 1
    { exec {_NAMO_RFD}<>"$_NAMO_REPLYFIFO"; } 2>/dev/null || { _NAMO_RFD=""; return 1; }
  fi

  # The binary forks and detaches itself, so this returns immediately -- no
  # background job, no "[1] 12345" notice, nothing to disown.
  NAMO_DAEMON=1 NAMO_FIFO="$_NAMO_FIFO" NAMO_REPLY="$_NAMO_REPLYFIFO" \
    NAMO_HISTFILE="$_NAMO_HISTFILE" NAMO_PIDFILE="$_NAMO_PIDFILE" \
    "$_NAMO_BIN_PATH" </dev/null >/dev/null 2>&1
  _namo_daemon_live
}

# Hand the current line to the daemon. Nothing here forks: the FIFO is already
# open, so this is one write() into a pipe buffer.
_namo_push() {
  [ -n "$_NAMO_WFD" ] || return 0
  printf '%s\t%s\n' "$PWD" "$1" >&"$_NAMO_WFD" 2>/dev/null
  return 0
}

# Ask the daemon something and wait for the answer: Alt-O, Alt-A, Alt-G. The
# key handlers used to start a copy of the binary per key press; going through
# the daemon instead means the whole interactive path -- keystrokes, keys,
# mistyped commands -- forks nothing at all. `printf` and `read` are builtins,
# the two descriptors are already open, so this is a write and a wait.
#
# Answers are labelled with the request id, so an answer to a request this
# shell has already given up on is dropped here rather than handed back as if
# it belonged to the next one. Leaves the candidates in _NAMO_REPLY_OUT.
_namo_request() {  # mode ("c" or "a"), subject
  _NAMO_REPLY_OUT=""
  [ -n "$_NAMO_WFD" ] && [ -n "$_NAMO_RFD" ] || return 1
  # Starting it here would fork, which is the thing we are avoiding; the
  # prompt hook has one running, or there is nothing to ask.
  _namo_daemon_live || return 1

  _NAMO_REQ_ID=$(( _NAMO_REQ_ID + 1 ))
  local id=$_NAMO_REQ_ID
  printf '%s\t\002%s\t%s\t%s\n' "$PWD" "$id" "$1" "$2" >&"$_NAMO_WFD" 2>/dev/null || return 1

  local line n i out=""
  while :; do
    IFS= read -r -t "$NAMO_TIMEOUT" -u "$_NAMO_RFD" line || return 1
    [[ "${line%%$'\t'*}" == "$id" ]] && break
  done
  n="${line#*$'\t'}"
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  for (( i = 0; i < n; i++ )); do
    IFS= read -r -t "$NAMO_TIMEOUT" -u "$_NAMO_RFD" line || return 1
    [[ "${line%%$'\t'*}" == "$id" ]] || continue
    out+="${line#*$'\t'}"$'\n'
  done
  _NAMO_REPLY_OUT="$out"
}

# The hint row belongs to the daemon, so namo_complete.bash clearing it after
# an accepted or cancelled suggestion is a message too.
_namo_hint() {
  _namo_push ""
}

# A line bash could not find, left here by command_not_found_handle. That runs
# in a child of this shell, which cannot reach the FIFO -- the write end is
# ours -- so it drops the line in a file and the prompt hook posts it.
_namo_dym_queue() {
  [ -n "$_NAMO_DYMFILE" ] || return 0
  printf '%s\n' "$1" > "$_NAMO_DYMFILE" 2>/dev/null
  return 0
}

# SOH in front of the line marks the record as "correct this", the one record
# the daemon does not treat as something being typed. Readline cannot put a
# 0x01 at the start of a buffer, so no line the user types collides with it.
_namo_dym_post() {
  [ -s "$_NAMO_DYMFILE" ] || return 0
  local line=""
  IFS= read -r line < "$_NAMO_DYMFILE"
  rm -f "$_NAMO_DYMFILE" 2>/dev/null
  [ -n "$line" ] || return 0
  _namo_push $'\001'"$line"
}

# Output without a trailing newline (`curl -s`, `printf`, ...) leaves the next
# prompt glued to it. Writing one full terminal width of spaces wraps to a fresh
# line only when the cursor is not already at column 1: at column 1 the terminal
# defers the wrap, so \r lands back on the same row and the prompt overwrites the
# spaces. Costs nothing and needs no cursor-position query. Same trick as zsh's
# PROMPT_EOL_MARK.
_namo_eol_fix() {
  [ -t 1 ] || return 0
  printf '%*s\r' "${COLUMNS:-80}" ''
}

# The hint is drawn one row below the cursor, so that row has to exist and be
# empty before the prompt is printed -- otherwise it is either off the bottom
# of the screen or on top of whatever is there. Bash prints the prompt after
# this hook returns, so a prompt that spans rows needs one reserved row per
# extra row it prints; the \n in PS1 are what say how many.
#
# Pressing Enter then moves the cursor into that row and the command's output
# starts there, so the reservation costs no scrollback: it is a row of headroom
# while you type, and the next thing printed takes it back.
_namo_reserve_row() {
  [ -t 1 ] || return 0
  local flat=${PS1//\\n/} rows i out=''
  rows=$(( 1 + (${#PS1} - ${#flat}) / 2 ))
  for (( i = 0; i < rows; i++ )); do out+=$'\n\033[2K'; done
  printf '%s\033[%dA' "$out" "$rows"
}

# PS0 is printed after Enter and before the command runs, with the cursor at
# the start of the very row the hint is in: erasing it here is what keeps a
# stale hint out of the command's output. (PROMPT_COMMAND is too late -- by
# then the output has been written over it.)
case "${PS0:-}" in
  *$'\033[2K'*) ;;
  *) PS0="${PS0:-}"$'\033[2K' ;;
esac

# Between commands: make sure the daemon is still there, drop the hint, and
# refresh its view of the history. Doing it here rather than on the keystroke
# path is what keeps the start-up fork out of the blanked prompt line -- and a
# daemon that died would otherwise leave this shell writing into a pipe with
# nobody draining it.
_namo_live_prompt_hook() {
  _namo_daemon_up || _NAMO_OFF=1
  _namo_push ""
  { fc -ln -"${NAMO_HISTORY_LINES:-50}"; } > "$_NAMO_HISTFILE" 2>/dev/null
  # After the snapshot, so the daemon corrects the line against a history that
  # already contains it, and after the clear above, so the answer is not wiped
  # by it. Both are writes into a pipe: the prompt is not held up by either.
  _namo_dym_post
  _namo_eol_fix
  _namo_reserve_row
}
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

_namo_key() {
  READLINE_LINE="${READLINE_LINE:0:$READLINE_POINT}${1}${READLINE_LINE:$READLINE_POINT}"
  READLINE_POINT=$((READLINE_POINT + 1))
  _namo_push "$READLINE_LINE"
}

_namo_backspace() {
  if (( READLINE_POINT > 0 )); then
    READLINE_LINE="${READLINE_LINE:0:$((READLINE_POINT - 1))}${READLINE_LINE:$READLINE_POINT}"
    READLINE_POINT=$((READLINE_POINT - 1))
  fi
  _namo_push "$READLINE_LINE"
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
