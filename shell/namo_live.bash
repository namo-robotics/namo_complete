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
# nothing, execs nothing and waits for nothing: it answers out of a hint table
# held in shell memory and pushes the line down a FIFO. Debounce, the binary and
# the network all live in the watcher process on the other end.

case $- in *i*) ;; *) return 0 ;; esac

: "${NAMO_DEBOUNCE:=0.4}"
: "${NAMO_QUIET:=0.05}"
: "${NAMO_HINT_MIN:=3}"
: "${NAMO_HINT_PREFIX:=~ }"
: "${NAMO_HINT_SUFFIX:=  (Alt-O / Alt-A for more)}"

# The watcher's history snapshot lives here, so the directory must be private.
_NAMO_DIR="${XDG_RUNTIME_DIR:-/tmp/namo-$UID}/namo_complete"
mkdir -p "$_NAMO_DIR" 2>/dev/null && chmod 700 "$_NAMO_DIR" 2>/dev/null
_NAMO_FIFO="$_NAMO_DIR/live_fifo.$$"
_NAMO_HINTFILE="$_NAMO_DIR/live_hint.$$"
_NAMO_HISTFILE="$_NAMO_DIR/live_hist.$$"

_NAMO_WPID=""      # watcher process
_NAMO_WFD=""       # write end of the FIFO, held open by this shell
_NAMO_TTYFD=""     # /dev/tty, opened once
_NAMO_OFF=""       # set if the plumbing could not be built; hints go quiet
_NAMO_SCREEN=""    # what the hint row is showing right now
_NAMO_SEEN=""      # last record ingested from the hint file
_NAMO_LAST=""      # newest hint, kept while it still extends the typed line
declare -A _NAMO_HINTS=()

_namo_live_cleanup() {
  [ -n "$_NAMO_WPID" ] && kill "$_NAMO_WPID" 2>/dev/null
  rm -f "$_NAMO_FIFO" "$_NAMO_HINTFILE" "$_NAMO_HISTFILE" 2>/dev/null
  return 0
}
trap _namo_live_cleanup EXIT

# Opening /dev/tty is two syscalls the blanked prompt line would pay for, so the
# descriptor is kept for the life of the shell.
_namo_tty() {
  [ -n "$_NAMO_TTYFD" ] && return 0
  [ -w /dev/tty ] || return 1
  # The braces are load-bearing: `exec {fd}>... 2>/dev/null` applies the stderr
  # redirect to the *shell*, permanently, and bash writes its prompt to stderr.
  { exec {_NAMO_TTYFD}>/dev/tty; } 2>/dev/null || { _NAMO_TTYFD=""; return 1; }
  return 0
}

# Absolute positioning to the last row. A newline would scroll the screen when
# the prompt sits at the bottom, invalidating the saved cursor.
_namo_paint() {
  _namo_tty || return 1
  if [ -n "$1" ]; then
    printf '\e7\e[999;1H\e[2K\e[2m%s%s\e[0m\e8' "$NAMO_HINT_PREFIX" "$1" >&"$_NAMO_TTYFD"
  else
    printf '\e7\e[999;1H\e[2K\e8' >&"$_NAMO_TTYFD"
  fi
  return 0
}

# Repainting the row with what it already shows is a visible blink of its own, so
# the shell tracks the contents and an unchanged hint costs nothing.
_namo_hint() {
  [ "$1" = "$_NAMO_SCREEN" ] && return 0
  _namo_paint "$1" || return 0
  _NAMO_SCREEN=$1
  return 0
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

# Between commands: drop the hint, cancel whatever the watcher was about to
# paint, and refresh its view of the history. `fc` is a builtin, so this is the
# one place the history is gathered -- a watcher that outlives the command would
# otherwise keep answering from the snapshot it was forked with.
_namo_live_prompt_hook() {
  _NAMO_LAST=""
  _namo_push ""
  _namo_hint ""
  { fc -ln -"${NAMO_HISTORY_LINES:-50}"; } > "$_NAMO_HISTFILE" 2>/dev/null
  _namo_eol_fix
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

# A bare `cmd &` in an interactive shell prints "[1] 12345" -- on every keystroke,
# back when this was spawned per key. Braces plus a stderr redirect suppress the
# notice while still yielding $!, and disown keeps the matching "Done" line from
# turning up at the next prompt.
_namo_watcher_up() {
  [ -n "$_NAMO_WPID" ] && kill -0 "$_NAMO_WPID" 2>/dev/null && return 0
  [ -p "$_NAMO_FIFO" ] || mkfifo -m 600 "$_NAMO_FIFO" 2>/dev/null || return 1
  if [ -z "$_NAMO_WFD" ]; then
    # Read-write: opening a FIFO for writing alone blocks until a reader shows
    # up, and this shell must never block on its own helper. Braces as in
    # _namo_tty: a bare `exec ... 2>/dev/null` would take the shell's stderr
    # with it and the prompt would stop being drawn.
    { exec {_NAMO_WFD}<>"$_NAMO_FIFO"; } 2>/dev/null || { _NAMO_WFD=""; return 1; }
  fi
  { _namo_watch & } 2>/dev/null
  _NAMO_WPID=$!
  disown "$_NAMO_WPID" 2>/dev/null
  return 0
}

# Hand the current line to the watcher. Nothing here forks: the FIFO is already
# open, so this is one write() into a pipe buffer.
_namo_push() {
  [ -n "$_NAMO_OFF" ] && return 0
  _namo_watcher_up || { _NAMO_OFF=1; return 0; }
  printf '%s\t%s\n' "$PWD" "$1" >&"$_NAMO_WFD" 2>/dev/null
  return 0
}

# Pick up whatever the watcher last painted. It writes a record only for a hint
# it actually put on screen, so one read gives both the hint and the state of the
# row. Builtin read from an open file: no subshell, no `cat`.
_namo_ingest() {
  local raw line hint
  # stderr first: the input redirect is what fails before the watcher has
  # written anything, and its complaint would land on the prompt line.
  { IFS= read -r raw; } 2>/dev/null < "$_NAMO_HINTFILE" || return 0
  [ "$raw" = "$_NAMO_SEEN" ] && return 0
  _NAMO_SEEN=$raw
  line=${raw%%$'\t'*}
  hint=${raw#*$'\t'}
  [ "$hint" = "$raw" ] && return 0
  (( ${#_NAMO_HINTS[@]} > 500 )) && _NAMO_HINTS=()
  _NAMO_HINTS[$line]=$hint
  _NAMO_LAST=$hint
  [ -n "$hint" ] && _NAMO_SCREEN="$hint$NAMO_HINT_SUFFIX"
  return 0
}

_namo_tick() {
  local line=$READLINE_LINE hint
  _namo_ingest
  _namo_push "$line"

  if [ "${#line}" -lt "$NAMO_HINT_MIN" ]; then
    _NAMO_LAST=""
    _namo_hint ""
    return 0
  fi

  hint=${_NAMO_HINTS[$line]-}
  # A hint the user is typing straight into stays up instead of blinking off and
  # back on with every character that confirms it.
  [ -z "$hint" ] && [[ $_NAMO_LAST == "$line"* ]] && hint=$_NAMO_LAST

  if [ -n "$hint" ] && [ "$hint" != "$line" ]; then
    _namo_hint "$hint$NAMO_HINT_SUFFIX"
  else
    _namo_hint ""
  fi
  return 0
}

# ---------------------------------------------------------------------------
# The watcher. Everything that forks, execs or waits happens on this side.
# ---------------------------------------------------------------------------

# History comes from the shell's own snapshot; the listing is taken from the
# directory the line was typed in, which may not be the one this process started
# in. Gathering it here keeps a user-controlled path out of the binary's argv.
_namo_watch_gather() {
  [ -s "$_NAMO_HISTFILE" ] && [ "${NAMO_HISTORY_LINES:-50}" != 0 ] && \
    cat -- "$_NAMO_HISTFILE" 2>/dev/null
  echo '%%NAMO_LS%%'
  ls -1A -- "${1:-.}" 2>/dev/null | head -n "${NAMO_LS_LIMIT:-40}"
}

# One line, one hint. cache=1 stays local; cache=0 may call the API first.
_namo_serve() {
  local rfd=$1 bin=$2 msg=$3 cache=$4 cwd line hint
  cwd=${msg%%$'\t'*}
  line=${msg#*$'\t'}
  [ "$line" = "$msg" ] && return 0
  [ "${#line}" -lt "$NAMO_HINT_MIN" ] && return 0

  if [ "$cache" = 0 ]; then
    _namo_watch_gather "$cwd" | NAMO_LINE="$line" NAMO_CWD="$cwd" "$bin" >/dev/null 2>&1
  fi
  hint=$(NAMO_CACHE_ONLY=1 NAMO_LINE="$line" NAMO_CWD="$cwd" "$bin" </dev/null 2>/dev/null | head -1)
  [ -n "$hint" ] && [ "$hint" != "$line" ] || return 0

  # Newer keystrokes are already queued: this answer is for a line the user has
  # moved past, and painting it would fight the round that is about to run.
  read -r -t 0 -u "$rfd" 2>/dev/null && return 0

  printf '%s\t%s\n' "$line" "$hint" > "$_NAMO_HINTFILE"
  _namo_paint "$hint$NAMO_HINT_SUFFIX"
  return 0
}

# Blocks on the FIFO, so an idle shell costs nothing at all. Reading a line means
# a keystroke; a short gap means a look at the cache; NAMO_DEBOUNCE of silence
# means the user has stopped and the request is worth paying for.
_namo_watch() {
  local rfd bin cur msg
  bin=$(_namo_resolve_bin) || return 0
  { exec {rfd}<"$_NAMO_FIFO"; } 2>/dev/null || return 0
  # Drop the inherited write end: with the shell holding the only one left, the
  # read below returns end-of-file when the shell exits and the watcher stops.
  exec {_NAMO_WFD}<&-
  trap 'exit 0' TERM INT HUP

  while IFS= read -r -u "$rfd" cur; do
    while IFS= read -r -t "$NAMO_QUIET" -u "$rfd" msg; do cur=$msg; done
    _namo_serve "$rfd" "$bin" "$cur" 1
    while IFS= read -r -t "$NAMO_DEBOUNCE" -u "$rfd" msg; do
      cur=$msg
      while IFS= read -r -t "$NAMO_QUIET" -u "$rfd" msg; do cur=$msg; done
      _namo_serve "$rfd" "$bin" "$cur" 1
    done
    _namo_serve "$rfd" "$bin" "$cur" 0
  done
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
