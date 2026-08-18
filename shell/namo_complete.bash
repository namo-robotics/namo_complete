#!/usr/bin/env bash
# namo_complete: Alt-O accept suggestion, Alt-A alternatives, Alt-G plain English.
# Suggestions only ever reach the readline buffer; nothing is executed.

case $- in *i*) ;; *) return 0 ;; esac

: "${NAMO_BIN:=namo_complete}"
: "${NAMO_KEY:=\eo}"
: "${NAMO_ALT_KEY:=\ea}"
: "${NAMO_ASK_KEY:=\eg}"
: "${NAMO_TIMEOUT:=10}"
: "${NAMO_HISTORY_LINES:=50}"
: "${NAMO_LS_LIMIT:=40}"

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

# History, sentinel, listing. Gathering the listing here keeps a user-controlled
# path out of every command string the binary builds.
_namo_gather() {
  fc -ln -"$NAMO_HISTORY_LINES" 2>/dev/null
  echo '%%NAMO_LS%%'
  ls -1A 2>/dev/null | head -n "$NAMO_LS_LIMIT"
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
    [[ "$k" =~ ^[1-9]$ ]] && (( k <= ${#cands[@]} )) || return 0
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

_namo_run() {  # mode, force_picker
  local mode=$1 force=$2 bin out rc
  bin=$(_namo_resolve_bin) || { printf '\n[namo] binary not found\n' >&2; return 0; }

  if [[ "$mode" == ask ]]; then
    local q
    printf '\n'
    IFS= read -e -r -p $'\033[36mask>\033[0m ' -i "$READLINE_LINE" q
    [[ -z "${q//[[:space:]]/}" ]] && return 0
    out=$(NAMO_MODE=ask NAMO_QUERY="$q" NAMO_CWD="$PWD" \
          timeout "$NAMO_TIMEOUT" "$bin" <<<"$(_namo_gather)" 2>/dev/null)
  else
    [[ -z "${READLINE_LINE//[[:space:]]/}" ]] && return 0
    out=$(NAMO_LINE="$READLINE_LINE" NAMO_POINT="$READLINE_POINT" NAMO_CWD="$PWD" \
          timeout "$NAMO_TIMEOUT" "$bin" <<<"$(_namo_gather)" 2>/dev/null)
  fi
  rc=$?

  [[ $rc == 124 ]] && { printf '\n[namo] timed out\n' >&2; return 0; }
  [[ $rc == 0 ]] || return 0
  _namo_choose "$out" "$force"
}

_namo_complete()     { _namo_run complete 0; }
_namo_alternatives() { _namo_run complete 1; }
_namo_ask()          { _namo_run ask 1; }

_namo_bind() { bind -x "\"$1\": $2" 2>/dev/null; bind -m vi-insert -x "\"$1\": $2" 2>/dev/null; }
_namo_bind "$NAMO_KEY" _namo_complete
_namo_bind "$NAMO_ALT_KEY" _namo_alternatives
_namo_bind "$NAMO_ASK_KEY" _namo_ask

# Live hints rebind every printable key. See namo_live.bash for the cost.
[ -f "${BASH_SOURCE[0]%/*}/namo_live.bash" ] && source "${BASH_SOURCE[0]%/*}/namo_live.bash"
