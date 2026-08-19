#!/usr/bin/env bash
# The bash half of namo_complete. Your ~/.bashrc sources this file; it binds
# three keys and returns.
#
#   Alt-O   finish the line I am typing
#   Alt-A   the same, but let me pick from the alternatives
#   Alt-G   I describe the command in English, you write it
#
# All three do the same thing: send the line you are typing (or your question)
# to the daemon, wait for the commands it sends back, and put one of them into
# your prompt. It is left there for you to edit or run -- nothing in this file
# ever executes a command. If anything goes wrong, from a missing API key to no
# network, you get silence and your line untouched.
#
# The daemon is one copy of the namo binary, started once per shell by
# namo_live.bash, which is where the pipes to it live. Nothing here starts a
# process of its own: not the key handlers, not the question Alt-G asks you,
# not the mistyped-command path at the bottom. `printf` and `read` are builtins
# and the pipes are already open, so a key press is a write and a wait.
#
# This half has to be a shell function because the line you are typing belongs
# to bash and to nothing else: READLINE_LINE exists only while a `bind -x`
# handler is running, and assigning to it is the only way to put a command in
# someone's prompt without running it. The daemon does everything else --
# your history (from the snapshot the prompt hook leaves it), the directory
# listing, dropping credentials, the cache, the API call.
#
# The bottom of the file is where those two meet. When bash cannot find a
# command at all it calls command_not_found_handle, and by then the line is
# gone and you are waiting for your prompt back -- so that path starts nothing
# and waits for nothing. It writes the mistyped line down, and the daemon
# answers it in the row under your prompt a moment later.
#
# namo_live.bash, sourced at the end, is the other half of the shell side: the
# keystroke handlers and the daemon they feed.

case $- in *i*) ;; *) return 0 ;; esac

: "${NAMO_BIN:=namo_complete}"
: "${NAMO_KEY:=\eo}"
: "${NAMO_ALT_KEY:=\ea}"
: "${NAMO_ASK_KEY:=\eg}"
: "${NAMO_TIMEOUT:=10}"
: "${NAMO_HISTORY_LINES:=50}"
: "${NAMO_LS_LIMIT:=40}"
: "${NAMO_DYM:=1}"

_namo_resolve_bin() {
  if [[ "$NAMO_BIN" == */* ]]; then
    [[ -x "$NAMO_BIN" ]] && { printf '%s' "$NAMO_BIN"; return 0; }
  else
    local p
    p=$(command -v "$NAMO_BIN" 2>/dev/null) && { printf '%s' "$p"; return 0; }
  fi
  [[ -x "$HOME/.local/bin/namo_complete" ]] && { printf '%s' "$HOME/.local/bin/namo_complete"; return 0; }
  return 1
}

_namo_is_dangerous() {
  case "${1,,}" in
    *"rm -rf"*|*"rm -fr"*|*mkfs*|*"dd if="*|*"> /dev/"*|*"| sh"*|*"| bash"*|sudo\ *) return 0 ;;
  esac
  return 1
}

# Ask mode returns "COMMAND<TAB>DESCRIPTION"; completion returns bare commands.
# Sets cmd and desc in the caller's scope.
_namo_split() {
  cmd="${1%%$'\t'*}"
  desc=""
  [[ "$1" == *$'\t'* ]] && desc="${1#*$'\t'}"
  cmd="${cmd%"${cmd##*[![:space:]]}"}"
  desc="${desc#"${desc%%[![:space:]]*}"}"
}

_namo_choose() {
  local out=$1 force=${2:-0}
  [[ -z "${out//[[:space:]]/}" ]] && return 0

  local -a cands=(); local line
  while IFS= read -r line; do
    [[ -n "${line//[[:space:]]/}" ]] && cands+=("$line")
  done <<<"$out"
  (( ${#cands[@]} )) || return 0

  # Alt-O takes the top candidate; Alt-A and ask mode (force) open the list.
  local pick="${cands[0]}"
  if [[ "$force" == 1 ]] && (( ${#cands[@]} > 1 )); then
    printf '\n'
    local i cmd desc
    for i in "${!cands[@]}"; do
      _namo_split "${cands[$i]}"
      printf '  %d) %s\n' "$((i + 1))" "$cmd"
      [[ -n "$desc" ]] && printf '     \033[2m%s\033[0m\n' "$desc"
    done
    local k
    read -rsn1 -p "  select [1-${#cands[@]}]: " k
    printf '\n'
    # Anything that is not one of the offered numbers cancels: no insertion,
    # straight back to the regular prompt with the line as it was.
    if ! [[ "$k" =~ ^[1-9]$ ]] || (( k > ${#cands[@]} )); then
      declare -F _namo_hint >/dev/null && _namo_hint ""
      return 0
    fi
    pick="${cands[$((k - 1))]}"
  fi

  # Only the command half ever reaches the buffer.
  pick="${pick%%$'\t'*}"

  if _namo_is_dangerous "$pick"; then
    local yn
    printf '\n  \033[33mdestructive:\033[0m %s\n' "$pick"
    read -rsn1 -p "  insert anyway? [y/N] " yn
    printf '\n'
    [[ "$yn" == [yY] ]] || return 0
  fi

  # A newline in READLINE_LINE submits immediately -- never let one through.
  pick="${pick%%$'\n'*}"; pick="${pick//$'\r'/}"

  READLINE_LINE="$pick"
  READLINE_POINT=${#READLINE_LINE}
  declare -F _namo_hint >/dev/null && _namo_hint ""
}

# Alt-G reads a question here rather than handing the terminal back to its own
# line discipline. `stty sane` (and the `stty -g` needed to undo it) are two
# more processes, and this path is meant to start none -- and a handler that
# died between the two would leave the terminal in cooked mode. Readline has
# the terminal in raw mode while this runs, so a byte at a time arrives here
# the moment it is typed; the echo and the erasing are ours to do.
#
# Leaves the question in _NAMO_QUESTION. Returns 1 if it was abandoned.
_namo_read_question() {
  _NAMO_QUESTION=""
  local q="$READLINE_LINE" ch
  printf '\n\033[36mask>\033[0m %s' "$q" >/dev/tty
  while IFS= read -rsn1 ch; do
    case "$ch" in
      '')                 break ;;                      # Enter
      $'\003'|$'\033')    printf '\n' >/dev/tty; return 1 ;;   # Ctrl-C, Esc
      $'\177'|$'\010')                                   # Backspace
        [[ -n "$q" ]] && { q="${q%?}"; printf '\b \b' >/dev/tty; } ;;
      $'\025')                                           # Ctrl-U
        q=""; printf '\r\033[K\033[36mask>\033[0m ' >/dev/tty ;;
      $'\027')                                           # Ctrl-W
        # No extglob: trailing spaces off, then the last run of non-spaces.
        local trimmed="${q%"${q##*[! ]}"}"
        case "$trimmed" in
          *' '*) q="${trimmed% *} " ;;
          *)     q="" ;;
        esac
        printf '\r\033[K\033[36mask>\033[0m %s' "$q" >/dev/tty ;;
      *)                  q+="$ch"; printf '%s' "$ch" >/dev/tty ;;
    esac
  done
  printf '\n' >/dev/tty
  _NAMO_QUESTION="$q"
}

_namo_run() {  # mode, force_picker
  local mode=$1 force=$2
  # Everything below goes through the daemon, which namo_live.bash owns.
  if ! declare -F _namo_request >/dev/null; then
    printf '\n[namo] live hints are not running\n' >&2
    return 0
  fi

  if [[ "$mode" == ask ]]; then
    _namo_read_question || return 0
    [[ -z "${_NAMO_QUESTION//[[:space:]]/}" ]] && return 0
    _namo_request a "$_NAMO_QUESTION" || return 0
  else
    [[ -z "${READLINE_LINE//[[:space:]]/}" ]] && return 0
    _namo_request c "$READLINE_LINE" || return 0
  fi

  _namo_choose "$_NAMO_REPLY_OUT" "$force"
}

_namo_complete()     { _namo_run complete 0; }
_namo_alternatives() { _namo_run complete 1; }
_namo_ask()          { _namo_run ask 1; }

_namo_bind() { bind -x "\"$1\": $2" 2>/dev/null; bind -m vi-insert -x "\"$1\": $2" 2>/dev/null; }
_namo_bind "$NAMO_KEY" _namo_complete
_namo_bind "$NAMO_ALT_KEY" _namo_alternatives
_namo_bind "$NAMO_ASK_KEY" _namo_ask

# ---------------------------------------------------------------------------
# "did you mean". command_not_found_handle is the one hook bash offers for a
# line that was not a command, and by the time it runs the line has already
# been accepted -- there is no readline buffer left to write to and nothing
# this function sets would survive the fork bash does around it.
#
# It also must not make anyone wait. The prompt comes back the moment bash's
# own message is printed; the line is handed to the live daemon, which is
# already running, already knows how to call the API without blocking the
# shell, and already owns a row to draw the answer in. See namo_live.bash.
# ---------------------------------------------------------------------------

_namo_dym_wanted() {
  [[ "$NAMO_DYM" == 1 ]] || return 1
  [[ "${NAMO_DISABLE:-0}" == 1 ]] && return 1
  # A pipeline or $(...) is a script failing, not someone at a prompt.
  [ -t 2 ] || return 1
  # The daemon draws the answer; without it there is nowhere to put one.
  declare -F _namo_dym_queue >/dev/null || return 1
  return 0
}

# Whatever was handling this before (Ubuntu's apt hint, say) still prints its
# own message; ours is a row under the prompt, drawn later, not a line here.
if declare -F command_not_found_handle >/dev/null; then
  eval "_namo_dym_prev() $(declare -f command_not_found_handle | tail -n +2)"
fi

command_not_found_handle() {
  local rc=127
  if declare -F _namo_dym_prev >/dev/null; then
    _namo_dym_prev "$@"
    rc=$?
  else
    printf '%s: %s: command not found\n' "${0##*/}" "$1" >&2
  fi

  if _namo_dym_wanted; then
    # "$@" has been through word splitting and globbing, so `grpe *.log` no
    # longer says what was typed. The history list still does: bash adds the
    # line before running it. (`history 1`, not `fc -ln -1` -- fc skips the
    # entry it considers current. HISTTIMEFORMAT would prefix a timestamp; we
    # are in a forked child, so clearing it here changes nothing upstream.)
    local q raw
    HISTTIMEFORMAT=''
    raw=$(history 1 2>/dev/null)
    q="${raw#"${raw%%[![:space:]]*}"}"   # drop the indent
    q="${q#*[[:space:]]}"                # drop the history number
    q="${q#"${q%%[![:space:]]*}"}"
    # HISTCONTROL=ignorespace, HISTIGNORE, `set +o history`: the line may never
    # have been recorded, in which case entry 1 is somebody else's. The first
    # word is what bash failed to find, so it has to match.
    [[ "${q%%[[:space:]]*}" == "$1" ]] || q="$*"
    # A file, not the FIFO: this runs in a child, and the write end of the
    # FIFO belongs to the shell. The prompt hook posts it a moment later.
    _namo_dym_queue "$q"
  fi
  return $rc
}

# Live hints rebind every printable key. See namo_live.bash for the cost.
[ -f "${BASH_SOURCE[0]%/*}/namo_live.bash" ] && source "${BASH_SOURCE[0]%/*}/namo_live.bash"
