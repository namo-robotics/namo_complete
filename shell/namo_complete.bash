#!/usr/bin/env bash
# The bash half of namo_complete. Your ~/.bashrc sources this file; it binds
# some keys, hooks the prompt, and returns.
#
#   Alt-O   finish the line I am typing
#   Alt-A   the same, but let me pick from the alternatives
#   Alt-G   I describe the command in English, you write it
#
# A dim hint also appears under your line as you type, and a command bash
# cannot find gets a "did you mean" in the same row.
#
# None of the thinking happens here. One long-running copy of the namo binary
# -- the daemon -- starts at the first prompt, and this file talks to it down
# two FIFOs: a key press goes one way, the answer comes back the other. What
# you are *typing* takes a different route entirely: readline echoes it onto
# this shell's stdout, which is a pty a second helper holds, and that helper
# reads the line off it. No printable key is bound, and nothing here runs on a
# keystroke -- which is what keeps bash from erasing and repainting the prompt
# row on every character you type.
#
# What is left is the things only bash can do:
#
#   * READLINE_LINE, the line you are typing, exists only inside a `bind -x`
#     handler, and assigning to it is the only way to put a command in your
#     prompt without running it. That is what Alt-O does.
#   * `fc` is a builtin, so this is the only process that can read the shell's
#     own history. It leaves the daemon a snapshot at every prompt.
#   * `bind`, PROMPT_COMMAND, PS0 and command_not_found_handle are bash's.
#   * PS1 ends with a marker, so the helper watching the pty knows where the
#     prompt stops and the line starts.
#   * `exec` points this shell's stdout at that pty. It is also where the last
#     few lines your commands printed are kept; NAMO_OUTPUT=0 stops the
#     keeping, not the pty.
#
# Everything else -- what to send, what to keep out of it, which suggestions
# are worth stopping on, what the hint says and where it goes -- belongs to the
# binary. See src/daemon.sun and src/cmd_output_relay.sun.
#
# Nothing here ever executes a command. The only thing that reaches your line
# is a candidate you picked, and it sits there until you press Enter.

case $- in *i*) ;; *) return 0 ;; esac

# What the shell itself needs. Every other setting is the daemon's, and it
# reads them from its own environment -- where the defaults are, in
# src/config.sun -- so they are exported below rather than defaulted here.
: "${NAMO_BIN:=namo_complete}"
: "${NAMO_KEY:=\eo}"
: "${NAMO_ALT_KEY:=\ea}"
: "${NAMO_ASK_KEY:=\eg}"
: "${NAMO_TIMEOUT:=10}"
: "${NAMO_DYM:=1}"
: "${NAMO_OUTPUT:=10}"

# Exporting one that is unset puts nothing in the daemon's environment, so
# these carry the user's value or nothing at all.
export NAMO_HINT_MIN NAMO_HINT_PREFIX NAMO_HINT_SUFFIX NAMO_DYM_PREFIX \
       NAMO_DEBOUNCE NAMO_QUIET NAMO_HISTORY_LINES NAMO_LS_LIMIT

_namo_find_binary() {
  if [[ "$NAMO_BIN" == */* ]]; then
    [[ -x "$NAMO_BIN" ]] && { printf '%s' "$NAMO_BIN"; return 0; }
  else
    local p
    p=$(command -v "$NAMO_BIN" 2>/dev/null) && { printf '%s' "$p"; return 0; }
  fi
  [[ -x "$HOME/.local/bin/namo_complete" ]] && { printf '%s' "$HOME/.local/bin/namo_complete"; return 0; }
  return 1
}

# ---------------------------------------------------------------------------
# The daemon, and the two pipes to it
# ---------------------------------------------------------------------------

# The history snapshot lives here, so the directory must be private.
_NAMO_DIR="${XDG_RUNTIME_DIR:-/tmp/namo-$UID}/namo_complete"
mkdir -p "$_NAMO_DIR" 2>/dev/null && chmod 700 "$_NAMO_DIR" 2>/dev/null
_NAMO_FIFO="$_NAMO_DIR/fifo.$$"
_NAMO_REPLYFIFO="$_NAMO_DIR/reply.$$"
_NAMO_HISTFILE="$_NAMO_DIR/hist.$$"
_NAMO_PIDFILE="$_NAMO_DIR/daemon_pid.$$"
_NAMO_DYMFILE="$_NAMO_DIR/dym.$$"
_NAMO_PTSFILE="$_NAMO_DIR/pts.$$"
_NAMO_OUTFILE="$_NAMO_DIR/out.$$"
_NAMO_RELAY_PIDFILE="$_NAMO_DIR/relay_pid.$$"

_NAMO_WFD=""   # write end of the request FIFO, held open by this shell
_NAMO_RFD=""   # read end of the reply FIFO, likewise
_NAMO_REQ_ID=0
_NAMO_OFF=""   # set if the plumbing could not be built; everything goes quiet
_NAMO_TTYFD="" # dup of the real terminal, to fall back on if the relay dies
_NAMO_CAPTURE="" # set while this shell's output really is going through a relay

# Resolved once. Doing it per prompt would be a command substitution, and this
# is the only value the prompt hook needs from outside the shell.
_NAMO_BIN_PATH=$(_namo_find_binary) || _NAMO_OFF=1

# Which pair is this shell actually running? The two halves are installed
# together but sourced and resolved separately, so a shell can end up with a new
# binary and an old bash file, or the other way round -- and either explains
# behaviour the current source does not. Typed by hand, so a fork is free here.
_NAMO_SHELL_FILE="${BASH_SOURCE[0]}"
namo-version() {
  printf 'shell:  %s\n' "$_NAMO_SHELL_FILE"
  printf 'binary: %s\n' "${_NAMO_BIN_PATH:-not found}"
  [ -n "$_NAMO_BIN_PATH" ] && "$_NAMO_BIN_PATH" --version
}

_namo_on_exit() {
  rm -f "$_NAMO_FIFO" "$_NAMO_REPLYFIFO" "$_NAMO_HISTFILE" "$_NAMO_PIDFILE" \
        "$_NAMO_DYMFILE" "$_NAMO_PTSFILE" "$_NAMO_OUTFILE" \
        "$_NAMO_RELAY_PIDFILE" 2>/dev/null
  return 0
}
trap _namo_on_exit EXIT

# The daemon writes its pid before it hands the prompt back, so this never
# races with a start-up we just asked for. Both `read` and `kill` are builtins.
_namo_daemon_is_running() {
  local pid=""
  [ -s "$_NAMO_PIDFILE" ] || return 1
  { read -r pid; } < "$_NAMO_PIDFILE" 2>/dev/null || return 1
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

_namo_daemon_ensure() {
  [ -n "$_NAMO_OFF" ] && return 1
  [ -n "$_NAMO_WFD" ] && [ -n "$_NAMO_RFD" ] && _namo_daemon_is_running && return 0

  if [ -z "$_NAMO_WFD" ]; then
    [ -p "$_NAMO_FIFO" ] || mkfifo -m 600 "$_NAMO_FIFO" 2>/dev/null || return 1
    # Read-write: opening a FIFO for writing alone blocks until a reader shows
    # up, and this shell must never block on its own helper. The braces are
    # load-bearing: `exec {fd}>... 2>/dev/null` applies the stderr redirect to
    # the *shell*, permanently, and bash writes its prompt to stderr.
    { exec {_NAMO_WFD}<>"$_NAMO_FIFO"; } 2>/dev/null || { _NAMO_WFD=""; return 1; }
  fi

  # The way back. Read-write again, so that a daemon that died does not deliver
  # an end-of-file to a `read` that is waiting for an answer.
  if [ -z "$_NAMO_RFD" ]; then
    [ -p "$_NAMO_REPLYFIFO" ] || mkfifo -m 600 "$_NAMO_REPLYFIFO" 2>/dev/null || return 1
    { exec {_NAMO_RFD}<>"$_NAMO_REPLYFIFO"; } 2>/dev/null || { _NAMO_RFD=""; return 1; }
  fi

  # The binary forks and detaches itself, so this returns immediately -- no
  # background job, no "[1] 12345" notice, nothing to disown.
  NAMO_DAEMON=1 NAMO_FIFO="$_NAMO_FIFO" NAMO_REPLY="$_NAMO_REPLYFIFO" \
    NAMO_HISTFILE="$_NAMO_HISTFILE" NAMO_PIDFILE="$_NAMO_PIDFILE" \
    NAMO_DYMFILE="$_NAMO_DYMFILE" NAMO_OUTFILE="$_NAMO_OUTFILE" \
    "$_NAMO_BIN_PATH" </dev/null >/dev/null 2>&1
  _namo_daemon_is_running
}

# ---------------------------------------------------------------------------
# Output capture (on unless NAMO_OUTPUT=0)
#
# Bash never sees what a command prints: the child inherits the terminal and
# writes to it directly. To record it, something has to be on the other end of
# this shell's stdout -- and if that something is a pipe, every command loses
# isatty(1) and with it colour and pagers. So it is a pty: `exec > "$pts"`
# below leaves the shell writing to a terminal, which the relay copies through
# to the real one while keeping the last NAMO_OUTPUT lines. See src/cmd_output_relay.sun.
# ---------------------------------------------------------------------------

_namo_relay_is_running() {
  local pid=""
  [ -s "$_NAMO_RELAY_PIDFILE" ] || return 1
  { read -r pid; } < "$_NAMO_RELAY_PIDFILE" 2>/dev/null || return 1
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

_namo_capture_ensure() {
  # Nothing below prints a marker unless this ends up back at 1: a shell with no
  # relay behind it must not put control bytes in its own output.
  _NAMO_CAPTURE=""
  # Note what is *not* here: a check on NAMO_OUTPUT. The pty is how the line
  # being typed is seen at all now, so it goes up even when nothing is being
  # recorded; NAMO_OUTPUT=0 means the relay keeps no output, not that there is
  # no relay. NAMO_DISABLE=1 is what turns the whole thing off.
  # Only when stdout is already a terminal. A shell whose output is a pipe or a
  # file is being read by something -- a script, a harness -- and putting a pty
  # in front of it would send that output to the terminal instead.
  [ -t 1 ] || return 0
  [ -n "$_NAMO_OFF" ] && return 1
  _namo_relay_is_running && { _NAMO_CAPTURE=1; return 0; }

  if [ -z "$_NAMO_TTYFD" ]; then
    # Kept for the life of the shell: if the relay ever dies, this is the only
    # way back to a terminal that still exists.
    { exec {_NAMO_TTYFD}>&1; } 2>/dev/null || return 1
  else
    exec >&"$_NAMO_TTYFD" 2>&1
  fi

  NAMO_RELAY=1 NAMO_OUTPUT="$NAMO_OUTPUT" NAMO_SHELL_PID=$$ \
    NAMO_PTSFILE="$_NAMO_PTSFILE" NAMO_OUTFILE="$_NAMO_OUTFILE" \
    NAMO_RELAY_PIDFILE="$_NAMO_RELAY_PIDFILE" NAMO_FIFO="$_NAMO_FIFO" \
    "$_NAMO_BIN_PATH" </dev/null >/dev/null 2>&1
  _namo_relay_is_running || return 1

  local pts=""
  { read -r pts; } < "$_NAMO_PTSFILE" 2>/dev/null || return 1
  [ -n "$pts" ] || return 1
  exec > "$pts" 2>&1
  _NAMO_CAPTURE=1
}

# Hand the current line to the daemon and return. One write() into a pipe
# buffer: this is the keystroke path, and it must do nothing else.
_namo_send_line() {
  [ -n "$_NAMO_WFD" ] || return 0
  printf '%s\t%s\n' "$PWD" "$1" >&"$_NAMO_WFD" 2>/dev/null
  return 0
}

# The hint row is the daemon's, so clearing it after an accepted or cancelled
# suggestion is a message like any other.
_namo_clear_hint_row() {
  _namo_send_line ""
}

# Ask the daemon something and wait for the answer: Alt-O, Alt-A, Alt-G. STX
# marks the record as a question rather than a line being typed.
#
#   <cwd> TAB STX <id> TAB <mode> TAB <subject>     out
#   <id> TAB <count>                                back
#   <id> TAB <flag> TAB <command> TAB <description> ...that many times
#
# The id is on every line, so an answer this shell has already given up waiting
# for is dropped here instead of being handed back as if it belonged to the
# next request. Leaves the candidates in _NAMO_REPLY_OUT.
_namo_ask_daemon() {  # mode ("c" to complete, "a" to answer), subject
  _NAMO_REPLY_OUT=""
  [ -n "$_NAMO_WFD" ] && [ -n "$_NAMO_RFD" ] || return 1
  # Starting one here would fork, which is the thing being avoided; the prompt
  # hook keeps one running, or there is nothing to ask.
  _namo_daemon_is_running || return 1

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

# ---------------------------------------------------------------------------
# The prompt
# ---------------------------------------------------------------------------

# Output without a trailing newline (`curl -s`, `printf`, ...) leaves the next
# prompt glued to it. Writing one full terminal width of spaces wraps to a fresh
# line only when the cursor is not already at column 1: at column 1 the terminal
# defers the wrap, so \r lands back on the same row and the prompt overwrites the
# spaces. Costs nothing and needs no cursor-position query. Same trick as zsh's
# PROMPT_EOL_MARK.
_namo_start_on_fresh_line() {
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
_namo_reserve_hint_row() {
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
#
# It is also where the recording of a command's output starts, when there is
# one: everything before this point was the prompt and the line being typed.
# The marker rides in front of the clear, and only while a relay is actually
# there to take it back out again, so PS0 is rebuilt whenever that changes.
if [[ "${PS0:-}" != *$'\033[2K'* ]]; then
  _NAMO_PS0_BASE="${PS0:-}"
  _NAMO_PS0=$'\033[2K'
  PS0="$_NAMO_PS0_BASE$_NAMO_PS0"
elif [ -z "${_NAMO_PS0:-}" ]; then
  # A clear is already in PS0 and it is not ours: leave PS0 alone entirely.
  _NAMO_PS0_BASE=""
  _NAMO_PS0=""
fi

# The tracker in the relay needs to know where the prompt stops and the line
# being typed starts, and only PS1 can say: everything before its last byte is
# the prompt. So PS1 ends with a marker, wrapped in \[ \] so readline does not
# count it as width, and the relay takes it back out before the bytes reach the
# screen. It is added only while a relay is actually there to do that.
#
# Re-checked at every prompt, and from the *end* of PROMPT_COMMAND: a prompt
# that is rebuilt from scratch each command -- starship, git-prompt -- drops
# whatever we appended last time.
_NAMO_PS1_MARK=$'\\['$'\035'$'\\]'
_namo_ps1_sync() {
  case "$PS1" in
    *"$_NAMO_PS1_MARK")
      [ -n "$_NAMO_CAPTURE" ] && return 0
      PS1=${PS1%"$_NAMO_PS1_MARK"} ;;
    *)
      [ -n "$_NAMO_CAPTURE" ] && PS1="$PS1$_NAMO_PS1_MARK" ;;
  esac
  return 0
}

_namo_ps0_sync() {
  [ -n "${_NAMO_PS0:-}" ] || return 0
  local want=$'\033[2K'
  [ -n "$_NAMO_CAPTURE" ] && want=$'\036'"$want"
  [ "$want" = "$_NAMO_PS0" ] && return 0
  _NAMO_PS0=$want
  PS0="$_NAMO_PS0_BASE$_NAMO_PS0"
}

# Between commands: make sure the daemon is still there, drop the hint, refresh
# its view of the history, and post anything command_not_found_handle left for
# it. Doing all of it here rather than on the keystroke path is what keeps the
# start-up fork out of the line being typed into -- and a daemon that died
# would otherwise leave this shell writing into a pipe with nobody draining it.
_namo_on_prompt() {
  _namo_daemon_ensure || _NAMO_OFF=1
  _namo_capture_ensure
  # The command is done: this is what it printed. The relay writes those lines
  # down and takes the marker back out again, so the screen never sees it.
  [ -n "$_NAMO_CAPTURE" ] && printf '\037'
  _namo_ps0_sync
  _namo_send_line ""
  { fc -ln -"${NAMO_HISTORY_LINES:-50}"; } > "$_NAMO_HISTFILE" 2>/dev/null
  # After the snapshot, so the line is corrected against a history that already
  # contains it, and after the clear, so the answer is not wiped by it.
  _namo_post_correction
  _namo_start_on_fresh_line
  _namo_reserve_hint_row
}
if [[ ${PROMPT_COMMAND@a} == *a* ]]; then
  [[ " ${PROMPT_COMMAND[*]} " == *" _namo_on_prompt "* ]] || \
    PROMPT_COMMAND=(_namo_on_prompt "${PROMPT_COMMAND[@]}")
  [[ " ${PROMPT_COMMAND[*]} " == *" _namo_ps1_sync "* ]] || \
    PROMPT_COMMAND+=(_namo_ps1_sync)
else
  case "${PROMPT_COMMAND:-}" in
    *_namo_on_prompt*) ;;
    "") PROMPT_COMMAND=_namo_on_prompt ;;
    *)  PROMPT_COMMAND="_namo_on_prompt; ${PROMPT_COMMAND}" ;;
  esac
  case "${PROMPT_COMMAND:-}" in
    *_namo_ps1_sync*) ;;
    *) PROMPT_COMMAND="${PROMPT_COMMAND}; _namo_ps1_sync" ;;
  esac
fi

# ---------------------------------------------------------------------------
# Typing
#
# Not a single key is rebound here, and that is the point. Readline echoes what
# you type onto this shell's stdout, which is the relay's pty, and the relay
# follows the line from there (src/cmd_output_relay.sun). Rebinding every printable key
# was the other way to see it, and it made bash erase and repaint the prompt
# row once per character -- flicker on any terminal that draws as the bytes
# arrive, plus slower paste, per-character undo, byte-wise UTF-8 and no vi
# command mode. All of that is gone with the bindings.
#
# What the tracker needs from this side is one marker at the end of the prompt,
# so it knows where the prompt stops and the line starts. See _namo_ps1_sync.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# The keys
# ---------------------------------------------------------------------------

# Candidates arrive as "<flag> TAB <command> TAB <description>". The daemon has
# already pulled ask mode's two halves apart and decided whether a command is
# one to stop on ("!"), so there is nothing to parse here: pick one, insert it.
_namo_pick_and_insert() {
  local out=$1 force=${2:-0}
  [[ -z "${out//[[:space:]]/}" ]] && return 0

  local -a cands
  mapfile -t cands <<<"${out%$'\n'}"
  (( ${#cands[@]} )) || return 0

  # Alt-O takes the top candidate; Alt-A and ask mode (force) open the list.
  local chosen="${cands[0]}" flag cmd desc i k
  if [[ "$force" == 1 ]] && (( ${#cands[@]} > 1 )); then
    printf '\n'
    for i in "${!cands[@]}"; do
      IFS=$'\t' read -r flag cmd desc <<<"${cands[$i]}"
      printf '  %d) %s\n' "$((i + 1))" "$cmd"
      [[ -n "$desc" ]] && printf '     \033[2m%s\033[0m\n' "$desc"
    done
    read -rsn1 -p "  select [1-${#cands[@]}]: " k
    printf '\n'
    # Anything that is not one of the offered numbers cancels: no insertion,
    # straight back to the regular prompt with the line as it was.
    if ! [[ "$k" =~ ^[1-9]$ ]] || (( k > ${#cands[@]} )); then
      _namo_clear_hint_row
      return 0
    fi
    chosen="${cands[$((k - 1))]}"
  fi

  IFS=$'\t' read -r flag cmd desc <<<"$chosen"
  [[ -n "$cmd" ]] || return 0

  if [[ "$flag" == '!' ]]; then
    local yn
    printf '\n  \033[33mdestructive:\033[0m %s\n' "$cmd"
    read -rsn1 -p "  insert anyway? [y/N] " yn
    printf '\n'
    [[ "$yn" == [yY] ]] || return 0
  fi

  READLINE_LINE="$cmd"
  READLINE_POINT=${#READLINE_LINE}
  _namo_clear_hint_row
}

# Alt-G reads its question here rather than handing the terminal back to its
# own line discipline. `stty sane` (and the `stty -g` needed to undo it) are
# two more processes, and a handler that died between them would leave the
# terminal in cooked mode. Readline has it in raw mode while this runs, so a
# byte arrives the moment it is typed; the echo and the erasing are ours.
#
# Leaves the question in _NAMO_QUESTION. Returns 1 if it was abandoned.
#
# It draws on stdout, like every other row this file prints. That matters with
# the output capture on: stdout is then a pty the relay copies through, and a
# write straight to /dev/tty would overtake the rows the shell itself printed
# -- the prompt would land on top of a hint instead of under it. The wrapper
# keeps /dev/tty for the one case stdout is not a terminal.
_namo_read_question() {
  if [ -t 1 ]; then _namo_read_question_on_tty
  elif { : >/dev/tty; } 2>/dev/null; then _namo_read_question_on_tty >/dev/tty
  else _namo_read_question_on_tty >/dev/null   # no terminal at all: still read
  fi
}

_namo_read_question_on_tty() {
  _NAMO_QUESTION=""
  local q="$READLINE_LINE" ch
  # The row below the line is the reserved hint row, and a hint may still be
  # sitting in it: clear it before the prompt goes there.
  printf '\n\r\033[2K\033[36mask>\033[0m %s' "$q"
  while IFS= read -rsn1 ch; do
    case "$ch" in
      '')                 break ;;                  # Enter
      $'\003'|$'\033')    printf '\n'; return 1 ;;   # Ctrl-C, Esc
      $'\177'|$'\010')                               # Backspace
        [[ -n "$q" ]] && { q="${q%?}"; printf '\b \b'; } ;;
      $'\025')                                       # Ctrl-U
        q=""; printf '\r\033[K\033[36mask>\033[0m ' ;;
      *)                  q+="$ch"; printf '%s' "$ch" ;;
    esac
  done
  printf '\n'
  _NAMO_QUESTION="$q"
}

_namo_key_request() {  # mode ("c" or "a"), show_picker
  local mode=$1 force=$2

  if [[ "$mode" == a ]]; then
    _namo_read_question || return 0
    [[ -z "${_NAMO_QUESTION//[[:space:]]/}" ]] && return 0
    _namo_ask_daemon a "$_NAMO_QUESTION" || return 0
  else
    [[ -z "${READLINE_LINE//[[:space:]]/}" ]] && return 0
    _namo_ask_daemon c "$READLINE_LINE" || return 0
  fi

  _namo_pick_and_insert "$_NAMO_REPLY_OUT" "$force"
}

_namo_on_complete_key()     { _namo_key_request c 0; }
_namo_on_alternatives_key() { _namo_key_request c 1; }
_namo_on_ask_key()          { _namo_key_request a 1; }

_namo_bind_key() { bind -x "\"$1\": $2" 2>/dev/null; bind -m vi-insert -x "\"$1\": $2" 2>/dev/null; }
_namo_bind_key "$NAMO_KEY" _namo_on_complete_key
_namo_bind_key "$NAMO_ALT_KEY" _namo_on_alternatives_key
_namo_bind_key "$NAMO_ASK_KEY" _namo_on_ask_key

# ---------------------------------------------------------------------------
# "did you mean"
#
# command_not_found_handle is the one hook bash offers for a line that was not
# a command, and by the time it runs the line has already been accepted: there
# is no readline buffer left to write to, nothing this function sets survives
# the fork bash does around it, and you are waiting for your prompt back. So it
# prints bash's message, writes the line down, and returns. The prompt hook
# posts it, and the daemon answers it in the row under your prompt.
# ---------------------------------------------------------------------------

_namo_should_correct() {
  [[ "$NAMO_DYM" == 1 ]] || return 1
  [[ "${NAMO_DISABLE:-0}" == 1 ]] && return 1
  # A pipeline or $(...) is a script failing, not someone at a prompt.
  [ -t 2 ] || return 1
  # The daemon draws the answer; without one there is nowhere to put it.
  [ -n "$_NAMO_DYMFILE" ] && [ -n "$_NAMO_WFD" ] || return 1
  return 0
}

# The word bash could not find, then the words it would have run (already
# through globbing and word splitting), then the line as `history 1` prints it.
# The daemon picks that apart -- history_line in util.sun -- and prefers the
# history, which still has the quotes and globs as they were typed, unless the
# line was never recorded at all. HISTTIMEFORMAT would put a timestamp in front
# of it; the assignment is temporary, and this runs in a child of the shell.
_namo_queue_correction() {
  [ -n "$_NAMO_DYMFILE" ] || return 0
  { printf '%s\t%s\t' "$1" "$2"; HISTTIMEFORMAT='' history 1; } \
    > "$_NAMO_DYMFILE" 2>/dev/null
  return 0
}

# SOH is the knock on the door: the one record the daemon does not treat as a
# line being typed. Readline cannot put a 0x01 at the start of a buffer, so
# nothing typed collides with it. The daemon reads the file and removes it.
_namo_post_correction() {
  [ -s "$_NAMO_DYMFILE" ] || return 0
  _namo_send_line $'\001'
}

# Whatever was handling this before (Ubuntu's apt hint, say) still prints its
# own message; ours is a row under the prompt, drawn later, not a line here.
if declare -F command_not_found_handle >/dev/null; then
  eval "_namo_previous_not_found_handler() $(declare -f command_not_found_handle | tail -n +2)"
fi

command_not_found_handle() {
  local rc=127
  if declare -F _namo_previous_not_found_handler >/dev/null; then
    _namo_previous_not_found_handler "$@"
    rc=$?
  else
    printf '%s: %s: command not found\n' "${0##*/}" "$1" >&2
  fi
  _namo_should_correct && _namo_queue_correction "$1" "$*"
  return $rc
}
