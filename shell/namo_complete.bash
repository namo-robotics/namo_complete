#!/usr/bin/env bash
# namo_complete - LLM-powered bash command completion.
#
# Enable by adding this line to ~/.bashrc:
#     source ~/.local/share/namo_complete/namo_complete.bash
#
#   Alt-O    complete the partial command you are typing
#   Alt-G    describe what you want in plain English, get a command
#
# For suggestions that update as you type, opt in before sourcing:
#     NAMO_LIVE=1
# (see namo_live.bash for what that costs -- it rebinds printable keys)
#
# The suggestion is only ever placed in the readline buffer. Nothing is
# executed; you still press Enter.

case $- in
  *i*) ;;
  *) return 0 ;;
esac

: "${NAMO_BIN:=namo_complete}"
: "${NAMO_KEY:=\eo}"    # Alt-O
: "${NAMO_ASK_KEY:=\eg}"   # Alt-G. Both bindings use Alt for consistency, and
                           # because Ctrl-G is unusable: VS Code binds it to
                           # "Go to Line" and never forwards it to the shell.
: "${NAMO_TIMEOUT:=10}"
: "${NAMO_HISTORY_LINES:=10}"
: "${NAMO_LS_LIMIT:=40}"
: "${NAMO_CONFIRM_DANGEROUS:=1}"

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

# History, a sentinel, then a directory listing. Sending the listing from bash
# keeps a user-controlled path out of every command string the binary builds.
_namo_gather() {
  fc -ln -"$NAMO_HISTORY_LINES" 2>/dev/null
  echo '%%NAMO_LS%%'
  ls -1A 2>/dev/null | head -n "$NAMO_LS_LIMIT"
}

_namo_is_dangerous() {
  local c="${1,,}"
  case "$c" in
    *"rm -rf"*|*"rm -fr"*|*mkfs*|*"dd if="*|*"> /dev/"*|*"| sh"*|*"| bash"*|sudo\ *)
      return 0 ;;
  esac
  return 1
}

# Turn the binary's output into a chosen command, then install it in the
# readline buffer. Shared by both keybindings.
_namo_choose() {
  local out=$1
  [[ -z "${out//[[:space:]]/}" ]] && return 0

  local -a cands=()
  local line
  while IFS= read -r line; do
    [[ -n "${line//[[:space:]]/}" ]] && cands+=("$line")
  done <<<"$out"
  (( ${#cands[@]} )) || return 0

  local pick="${cands[0]}"
  if (( ${#cands[@]} > 1 )); then
    printf '\n'
    local i
    for i in "${!cands[@]}"; do
      printf '  %d) %s\n' "$((i + 1))" "${cands[$i]}"
    done
    local k
    read -rsn1 -p "  select [1-${#cands[@]}] (any other key cancels): " k
    printf '\n'
    [[ "$k" =~ ^[1-9]$ ]] && (( k <= ${#cands[@]} )) || return 0
    pick="${cands[$((k - 1))]}"
  fi

  if [[ "$NAMO_CONFIRM_DANGEROUS" == 1 ]] && _namo_is_dangerous "$pick"; then
    local yn
    printf '\n  \033[33mthis looks destructive:\033[0m %s\n' "$pick"
    read -rsn1 -p "  insert it anyway? [y/N] " yn
    printf '\n'
    [[ "$yn" == [yY] ]] || return 0
  fi

  # SECURITY: a newline in READLINE_LINE submits the line immediately, so a
  # multi-line suggestion must never reach the buffer intact.
  pick="${pick%%$'\n'*}"
  pick="${pick//$'\r'/}"

  READLINE_LINE="$pick"
  READLINE_POINT=${#READLINE_LINE}
}

# --- Alt-O: complete what you have typed -----------------------------------
_namo_complete() {
  local bin
  bin=$(_namo_resolve_bin) || {
    printf '\n[namo] binary not found (set NAMO_BIN or run install.sh)\n' >&2
    return 0
  }
  [[ -z "${READLINE_LINE//[[:space:]]/}" ]] && return 0

  local out rc
  out=$(
    NAMO_LINE="$READLINE_LINE" NAMO_POINT="$READLINE_POINT" NAMO_CWD="$PWD" \
    timeout "$NAMO_TIMEOUT" "$bin" <<<"$(_namo_gather)" 2>/dev/null
  )
  rc=$?
  case $rc in
    0) ;;
    124) printf '\n[namo] timed out after %ss\n' "$NAMO_TIMEOUT" >&2; return 0 ;;
    *)   return 0 ;;
  esac

  _namo_choose "$out"
}

# --- Alt-G: describe it in English -----------------------------------------
_namo_ask() {
  local bin
  bin=$(_namo_resolve_bin) || {
    printf '\n[namo] binary not found (set NAMO_BIN or run install.sh)\n' >&2
    return 0
  }

  local q
  printf '\n'
  # -e gives readline editing inside the sub-prompt; seed it with whatever is
  # already on the line so a half-typed thought is not lost.
  IFS= read -e -r -p $'\033[36mask>\033[0m ' -i "$READLINE_LINE" q
  [[ -z "${q//[[:space:]]/}" ]] && return 0

  local out rc
  out=$(
    NAMO_MODE=ask NAMO_QUERY="$q" NAMO_CWD="$PWD" \
    timeout "$NAMO_TIMEOUT" "$bin" <<<"$(_namo_gather)" 2>/dev/null
  )
  rc=$?
  case $rc in
    0) ;;
    124) printf '[namo] timed out after %ss\n' "$NAMO_TIMEOUT" >&2; return 0 ;;
    *)   return 0 ;;
  esac

  _namo_choose "$out"
}

_namo_bind() {  # keyseq, function
  bind -x "\"$1\": $2" 2>/dev/null
  bind -m vi-insert -x "\"$1\": $2" 2>/dev/null
}

_namo_bind "$NAMO_KEY" _namo_complete
_namo_bind "$NAMO_ASK_KEY" _namo_ask

# Live as-you-type hints are opt-in: they rebind every printable key.
if [ -f "${BASH_SOURCE[0]%/*}/namo_live.bash" ]; then
  # shellcheck disable=SC1091
  source "${BASH_SOURCE[0]%/*}/namo_live.bash"
fi
