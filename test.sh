#!/usr/bin/env bash
# namo_complete test suite.
#
#   ./test.sh          offline tests + end-to-end against a local mock API
#   ./test.sh --live   also make one real call (needs ANTHROPIC_API_KEY)
#
# No API key is required for the default run.
set -uo pipefail
cd "$(dirname "$0")"

# Load .env if present (gitignored; see .env.example).
if [ -f "$PWD/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$PWD/.env"
  set +a
fi

BIN=./bin/namo_complete
PORT=${NAMO_TEST_PORT:-8731}
MOCK_PID=""
pass=0; fail=0

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }
cleanup() { [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null; rm -f /tmp/namo_req.json; }
trap cleanup EXIT

# Keep the developer's real cache out of the way.
export XDG_CACHE_HOME=$(mktemp -d)
export XDG_RUNTIME_DIR=$(mktemp -d); chmod 700 "$XDG_RUNTIME_DIR"

# Stash the real key before section 2 replaces it with a fake one.
: "${ANTHROPIC_API_KEY_REAL:=${ANTHROPIC_API_KEY:-}}"
export ANTHROPIC_API_KEY_REAL

[ -x "$BIN" ] || { echo "building first..."; ./build.sh >/dev/null || exit 1; }

# --------------------------------------------------------------------------
head_ "1. graceful degradation (no API key, no network)"
# --------------------------------------------------------------------------
run_bare() { env -u ANTHROPIC_API_KEY "$@" "$BIN" </dev/null 2>/tmp/namo_err; }

out=$(run_bare NAMO_LINE='gi' NAMO_CWD="$PWD"); rc=$?
[ -z "$out" ] && [ "$rc" = 0 ] && ok "short prefix: no call, empty stdout" \
                              || bad "short prefix (rc=$rc out=$out)"

out=$(run_bare NAMO_LINE='git commit' NAMO_CWD="$PWD" NAMO_DISABLE=1); rc=$?
[ -z "$out" ] && [ "$rc" = 0 ] && ok "NAMO_DISABLE=1 is a no-op" || bad "NAMO_DISABLE"

out=$(run_bare NAMO_LINE='git commit' NAMO_CWD="$PWD"); rc=$?
[ -z "$out" ] && [ "$rc" = 1 ] && grep -q 'API_KEY' /tmp/namo_err \
  && ok "missing key: stdout clean, message on stderr" || bad "missing key (rc=$rc)"

out=$(env ANTHROPIC_API_KEY=x NAMO_ENDPOINT='http://127.0.0.1:9/v1' \
        NAMO_LINE='git commit' NAMO_CWD="$PWD" "$BIN" </dev/null 2>/dev/null); rc=$?
[ -z "$out" ] && ok "unreachable endpoint: stdout stays clean" || bad "unreachable endpoint"

# --------------------------------------------------------------------------
head_ "2. end-to-end against a mock API"
# --------------------------------------------------------------------------
command -v python3 >/dev/null 2>&1 || { echo "  (skipped: python3 not found)"; exit 0; }

cat > /tmp/namo_mock.py <<PY
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('content-length', 0)))
        open('/tmp/namo_req.json','wb').write(body)
        open('/tmp/namo_hdr.txt','w').write(str(self.headers))
        r = {"id":"m","type":"message","role":"assistant","model":"claude-haiku-4-5",
             "content":[{"type":"text","text":"git commit -m \\"msg\\"\\ngit commit --amend\\ngit commit -a"}],
             "stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
        o = json.dumps(r).encode()
        self.send_response(200); self.send_header('content-type','application/json')
        self.send_header('content-length', str(len(o))); self.end_headers(); self.wfile.write(o)
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', $PORT), H).serve_forever()
PY
python3 /tmp/namo_mock.py & MOCK_PID=$!
sleep 1.2

export ANTHROPIC_API_KEY='sk-ant-TESTKEY-must-not-leak'
export NAMO_ENDPOINT="http://127.0.0.1:$PORT/v1/messages"
export NAMO_MIN_GAP=0   # the 1s throttle would otherwise starve these tests

payload() {
  echo 'git status'
  echo 'export GITHUB_TOKEN=ghp_SECRETVALUE'
  echo 'git commit -m "fix the password reset flow"'
  echo 'ls -la'
  echo '%%NAMO_LS%%'
  echo 'README.md'
  echo 'src'
}

out=$(payload | env NAMO_LINE='git com' NAMO_CWD="$PWD" NAMO_CACHE=0 "$BIN" 2>/dev/null)
n=$(printf '%s\n' "$out" | grep -c .)
[ "$n" = 3 ] && ok "returns 3 suggestions" || bad "expected 3 suggestions, got $n"

grep -q 'ghp_SECRETVALUE' /tmp/namo_req.json \
  && bad "SECRET LEAKED into the prompt" || ok "credential line redacted from history"
grep -q 'git status' /tmp/namo_req.json \
  && ok "benign history retained" || bad "benign history dropped"
grep -q 'fix the password reset flow' /tmp/namo_req.json \
  && ok "keyword-only line kept; prefixes are the whole filter" \
  || bad "keyword-only line dropped"
grep -q '<ls>' /tmp/namo_req.json \
  && ok "directory listing sent in its own tag" || bad "listing tag missing"
grep -qi "x-api-key: sk-ant-TESTKEY" /tmp/namo_hdr.txt \
  && ok "api key sent as a header" || bad "api key header missing"
grep -rl 'sk-ant-TESTKEY' "$XDG_RUNTIME_DIR" >/dev/null 2>&1 \
  && bad "api key left behind on disk" || ok "no key left on disk after the call"

# effort/thinking must be absent: both are errors on Haiku 4.5.
python3 - <<'PY' && ok "request shape valid for Haiku 4.5" || bad "bad request shape"
import json,sys
d=json.load(open('/tmp/namo_req.json'))
assert d['model']=='claude-haiku-4-5', d['model']
assert d['max_tokens']==150 and d['temperature']==0
assert 'output_config' not in d and 'thinking' not in d
assert all(x.strip() for x in d['stop_sequences']), 'whitespace-only stop sequence'
PY

# cache: second identical call must not reach the mock
rm -f /tmp/namo_req.json
payload | env NAMO_LINE='cached probe xyz' NAMO_CWD="$PWD" "$BIN" >/dev/null 2>&1
rm -f /tmp/namo_req.json
payload | env NAMO_LINE='cached probe xyz' NAMO_CWD="$PWD" "$BIN" >/dev/null 2>&1
[ -f /tmp/namo_req.json ] && bad "cache miss: second call hit the API" \
                          || ok "second identical call served from cache"

# --------------------------------------------------------------------------
head_ "2b. prose is dropped, commands survive"
# --------------------------------------------------------------------------
# A second mock whose reply text is whatever is in /tmp/namo_text.txt: the
# model sometimes explains itself instead of staying silent, and an
# explanation must never reach the hint row.
PORT2=$((PORT + 1))
cat > /tmp/namo_mock2.py <<PY
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('content-length', 0)))
        r = {"id":"m","type":"message","role":"assistant","model":"claude-haiku-4-5",
             "content":[{"type":"text","text":open('/tmp/namo_text.txt').read()}],
             "stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
        o = json.dumps(r).encode()
        self.send_response(200); self.send_header('content-type','application/json')
        self.send_header('content-length', str(len(o))); self.end_headers(); self.wfile.write(o)
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', $PORT2), H).serve_forever()
PY
python3 /tmp/namo_mock2.py & MOCK2_PID=$!
sleep 1.2
trap 'cleanup; kill "$MOCK2_PID" 2>/dev/null' EXIT

say() { NAMO_ENDPOINT="http://127.0.0.1:$PORT2/v1/messages" NAMO_CACHE=0 \
        NAMO_MAX_SUGGESTIONS=10 NAMO_LINE="${2:-git com}" NAMO_CWD="$PWD" "$BIN" </dev/null 2>/dev/null; }

printf 'I cannot produce a useful completion for this input. The line "dfdfff" does not appear to be a valid bash command.\n' > /tmp/namo_text.txt
out=$(say); rc=$?
[ -z "$out" ] && [ "$rc" = 0 ] && ok "refusal prose produces no suggestion" \
                              || bad "refusal prose leaked: $out"

printf 'The line you typed does not look like a bash command\n' > /tmp/namo_text.txt
out=$(say)
[ -z "$out" ] && ok "plain sentence produces no suggestion" || bad "sentence leaked: $out"

printf -- '- git push\n# a comment\n```\n1) ls -la\n' > /tmp/namo_text.txt
out=$(say)
[ -z "$out" ] && ok "markdown and comments dropped" || bad "markup leaked: $out"

printf 'git commit -m "msg"\ncd ..\ngit add .\necho hello world\nSorry, I have nothing for you\n' > /tmp/namo_text.txt
n=$(say | grep -c .)
[ "$n" = 4 ] && ok "real commands survive the filter (dots, echo)" \
             || bad "expected 4 commands through the filter, got $n"

printf 'du -sh *\tshow directory sizes\nI cannot help with that request\n' > /tmp/namo_text.txt
out=$(NAMO_MODE=ask NAMO_QUERY='how big are these dirs' say)
[ "$out" = "$(printf 'du -sh *\tshow directory sizes')" ] \
  && ok "ask mode keeps COMMAND<TAB>DESCRIPTION, drops the apology" \
  || bad "ask mode filter: $out"

# --------------------------------------------------------------------------
head_ "3. bash integration"
# --------------------------------------------------------------------------
res=$(bash -i -c '
  source shell/namo_complete.bash
  NAMO_BIN=./bin/namo_complete
  READLINE_LINE="git com"; READLINE_POINT=7
  NAMO_MAX_SUGGESTIONS=1 NAMO_CACHE=0 _namo_complete </dev/null
  echo "LINE=$READLINE_LINE POINT=$READLINE_POINT"
' 2>/dev/null | grep '^LINE=')
case "$res" in
  "LINE=git commit"*"POINT="*) ok "readline buffer rewritten ($res)" ;;
  *) bad "readline not rewritten (got: $res)" ;;
esac


# keybindings must survive hosts that steal Ctrl-G (VS Code = "Go to Line")
binds=$(bash -i -c 'source shell/namo_complete.bash 2>/dev/null; bind -X 2>/dev/null' 2>/dev/null)
for seq in '\\eo' '\\ea' '\\eg'; do
  printf '%s' "$binds" | grep -q "\"$seq\"" \
    && ok "keyseq $seq bound" || bad "keyseq $seq not bound"
done

# default: no picker -- the top suggestion is accepted with no extra keystroke
res=$(bash -i -c '
  source shell/namo_complete.bash 2>/dev/null
  READLINE_LINE="git com"; READLINE_POINT=7
  _namo_choose "$(printf "git commit\ngit commit --amend\ngit commit -a")" </dev/null
  echo "R=[$READLINE_LINE]"
' 2>/dev/null | grep '^R=')
[ "$res" = 'R=[git commit]' ] && ok "top suggestion accepted without a picker" \
                              || bad "expected top suggestion, got $res"

# Alt-A forces the list for one invocation without changing config
res=$(bash -i -c '
  source shell/namo_complete.bash 2>/dev/null
  READLINE_LINE="git com"; READLINE_POINT=7
  _namo_choose "$(printf "git commit\ngit commit --amend\ngit commit -a")" 1 <<<"3"
  echo "R=[$READLINE_LINE]"
' 2>/dev/null | grep '^R=')
[ "$res" = 'R=[git commit -a]' ] && ok "Alt-A path lists alternatives and selects #3" \
                                 || bad "forced picker failed (got $res)"

# the picker cancels cleanly on a non-numeric key, leaving the line alone
res=$(bash -i -c '
  source shell/namo_complete.bash 2>/dev/null
  READLINE_LINE="git com"; READLINE_POINT=7
  # here-string, not a pipe: a pipe would run _namo_choose in a subshell and
  # its READLINE_LINE assignment would be discarded.
  _namo_choose "$(printf "git commit\ngit commit --amend\ngit commit -a")" 1 <<<"q"
  echo "R=[$READLINE_LINE]"
' 2>/dev/null | grep '^R=')
[ "$res" = 'R=[git com]' ] && ok "picker cancels on a non-numeric key" \
                           || bad "cancel did not leave the line alone (got $res)"

# Ask mode returns COMMAND<TAB>DESCRIPTION: the list shows both, the buffer
# gets the command only.
res=$(bash -i -c '
  source shell/namo_complete.bash 2>/dev/null
  READLINE_LINE="x"; READLINE_POINT=1
  _namo_choose "$(printf "du -sh *\tShow sizes\nls -lhS\tSort by size")" 1 <<<"2"
  echo "R=[$READLINE_LINE]"
' 2>/dev/null)
printf '%s' "$res" | grep -q 'Sort by size' \
  && ok "descriptions shown next to each alternative" || bad "descriptions not displayed"
printf '%s' "$res" | grep -q '^R=\[ls -lhS\]$' \
  && ok "only the command half reaches the buffer" \
  || bad "description leaked into the buffer ($(printf '%s' "$res" | grep '^R='))"

# The destructive-command confirmation is unconditional; declining inserts nothing.
res=$(bash -i -c '
  source shell/namo_complete.bash 2>/dev/null
  READLINE_LINE="clean up"; READLINE_POINT=8
  _namo_choose "rm -rf build" <<<"n"
  echo "R=[$READLINE_LINE]"
' 2>/dev/null | grep '^R=')
[ "$res" = 'R=[clean up]' ] && ok "destructive suggestion held for confirmation" \
                            || bad "destructive suggestion inserted anyway (got $res)"

# --------------------------------------------------------------------------
head_ "4. ask mode (plain English -> command)"
# --------------------------------------------------------------------------
rm -f /tmp/namo_req.json
out=$(payload | env NAMO_MODE=ask NAMO_QUERY='delete every log file' \
        NAMO_CWD="$PWD" NAMO_CACHE=0 "$BIN" 2>/dev/null)
[ -n "$out" ] && ok "ask mode returns a command" || bad "ask mode returned nothing"
grep -q '<request>delete every log file</request>' /tmp/namo_req.json \
  && ok "query sent in a <request> tag" || bad "<request> tag missing or empty"
grep -q '<line>' /tmp/namo_req.json \
  && bad "ask mode wrongly sent a <line> tag" || ok "ask mode omits the <line> tag"
python3 - <<'PYX' && ok "ask mode uses the ask system prompt" || bad "wrong system prompt"
import json
d=json.load(open('/tmp/namo_req.json'))
assert 'plain-English' in d['system'], d['system'][:80]
assert 'COMMAND<TAB>DESCRIPTION' in d['system'], "ask prompt does not request descriptions"
assert d['max_tokens'] == 300, d['max_tokens']
PYX

# ask-mode cache must not collide with completion cache
rm -f /tmp/namo_req.json
payload | env NAMO_MODE=ask NAMO_QUERY='cache probe one' NAMO_CWD="$PWD" "$BIN" >/dev/null 2>&1
rm -f /tmp/namo_req.json
payload | env NAMO_LINE='cache probe one' NAMO_CWD="$PWD" "$BIN" >/dev/null 2>&1
[ -f /tmp/namo_req.json ] \
  && ok "ask and complete keys do not collide" \
  || bad "completion wrongly reused the ask-mode cache entry"

# --------------------------------------------------------------------------
head_ "5. live hints"
# --------------------------------------------------------------------------
# cache-only must never make a network call
pkill -f namo_mock.py >/dev/null 2>&1; sleep 0.3
out=$(env NAMO_CACHE_ONLY=1 NAMO_LINE='git com' NAMO_CWD="$PWD" \
        NAMO_ENDPOINT='http://127.0.0.1:9/v1' "$BIN" </dev/null 2>&1); rc=$?
[ "$rc" = 0 ] && ok "cache-only exits cleanly with the network down" \
              || bad "cache-only failed with the network down (rc=$rc)"
python3 /tmp/namo_mock.py & MOCK_PID=$!; sleep 1

# cache-only latency budget: this runs on every keystroke
start=$(date +%s%N)
for _ in 1 2 3 4 5 6 7 8 9 10; do
  env NAMO_CACHE_ONLY=1 NAMO_LINE='git com' NAMO_CWD="$PWD" "$BIN" </dev/null >/dev/null 2>&1
done
per=$(( ($(date +%s%N) - start) / 10000000 ))
[ "$per" -le 15 ] && ok "cache-only lookup ${per}ms per keystroke" \
                  || bad "cache-only too slow for live use: ${per}ms"

# key handlers edit the buffer correctly
res=$(bash -i -c '
  source shell/namo_complete.bash 2>/dev/null
  READLINE_LINE=""; READLINE_POINT=0
  for c in g i t " " c o; do _namo_key "$c"; done
  _namo_backspace
  READLINE_POINT=3; _namo_key "X"
  echo "R=[$READLINE_LINE|$READLINE_POINT]"
' 2>/dev/null | grep '^R=')
[ "$res" = 'R=[gitX c|4]' ] && ok "live key handlers edit the buffer correctly" \
                            || bad "live key handlers wrong (got $res)"

# Live hints are the point of the tool: they must be on with no opt-in.
printf '%s' "$binds" | grep -q '"a" "_namo_key a"' \
  && ok "live hints active on source, no opt-in" || bad "live hints not enabled by default"
printf '%s' "$binds" | grep -q '"\\C-?" "_namo_backspace"' \
  && ok "backspace routed through the live handler" || bad "backspace not rebound"
res=$(bash -i -c '
  source shell/namo_complete.bash 2>/dev/null
  type -t namo-live' 2>/dev/null | tail -1)
[ -z "$res" ] && ok "no switch to turn live hints off" \
              || bad "namo-live still defined ($res)"

# Regression: a bare `cmd &` in an interactive shell prints "[1] 12345" to the
# terminal on every keystroke. Needs a real pty to reproduce.
if command -v script >/dev/null 2>&1; then
  cat > /tmp/namo_rc_test.sh <<RCEOF
export NAMO_BIN="$PWD/$BIN"
export NAMO_MIN_GAP=0 NAMO_DEBOUNCE=0.3
export NAMO_ENDPOINT="$NAMO_ENDPOINT"
export ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
source "$PWD/shell/namo_complete.bash"
PS1='T\$ '
RCEOF
  jobnoise=$(printf 'READLINE_LINE=""; READLINE_POINT=0; for c in g i t " " c o; do _namo_key "$c"; done\nsleep 1\nexit\n' \
    | script -qec "bash --rcfile /tmp/namo_rc_test.sh -i" /dev/null 2>&1 \
    | tr -d '\r' | grep -acE '^\[[0-9]+\][[:space:]]+[0-9]+')
  [ "$jobnoise" = 0 ] && ok "no job-control noise while typing" \
                      || bad "$jobnoise job notifications leaked to the terminal"

  # Output with no trailing newline must not swallow the next prompt: the hook
  # pads to the end of the row so the wrap happens before the prompt is drawn.
  eolcap=$(printf 'printf hi\nexit\n' \
    | script -qec "bash --rcfile /tmp/namo_rc_test.sh -i" /dev/null 2>&1)
  printf '%s' "$eolcap" | grep -q "hi  *$(printf '\r')" \
    && ok "prompt starts on a fresh line after unterminated output" \
    || bad "no end-of-line padding emitted after unterminated output"
  rm -f /tmp/namo_rc_test.sh
  # Ctrl-G must NOT be bound: VS Code steals it, so it would look broken.
  for stolen in '\\C-g' '\\C-o'; do
    printf '%s' "$binds" | grep -q "\"$stolen\"" \
      && bad "$stolen is still bound (should be Alt-only)" \
      || ok "$stolen intentionally unbound"
  done
else
  echo "  (skipped pty test: 'script' not available)"
fi

# --------------------------------------------------------------------------
head_ "6. packaging"
# --------------------------------------------------------------------------
# Build the release tarball the same way .github/workflows/release.yml does,
# then install from it into a temp prefix -- so a packaging break is caught
# here rather than at tag time.
PKGTMP=$(mktemp -d)
PNAME=$(./packaging/package.sh v0.0.0-test "$PKGTMP" 2>/dev/null)

[ -s "$PKGTMP/$PNAME.tar.gz" ] && ok "release tarball builds" || bad "tarball missing"
( cd "$PKGTMP" && sha256sum -c --status SHA256SUMS ) \
  && ok "checksum verifies" || bad "checksum failed"

mkdir -p "$PKGTMP/x"
tar -C "$PKGTMP/x" -xzf "$PKGTMP/$PNAME.tar.gz"
"$PKGTMP/x/$PNAME/install.sh" --prefix "$PKGTMP/prefix" --no-bashrc >/dev/null 2>&1
[ -x "$PKGTMP/prefix/bin/namo_complete" ] \
  && ok "installs a runnable binary into the prefix" || bad "binary not installed"
[ -f "$PKGTMP/prefix/share/namo_complete/namo_complete.bash" ] && \
[ -f "$PKGTMP/prefix/share/namo_complete/namo_live.bash" ] \
  && ok "installs both shell files" || bad "shell integration not installed"

out=$(env -u ANTHROPIC_API_KEY NAMO_LINE='gi' NAMO_CWD="$PWD" \
        "$PKGTMP/prefix/bin/namo_complete" </dev/null 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] \
  && ok "installed binary runs" || bad "installed binary misbehaved (rc=$rc out=$out)"

# .bashrc handling: adds once, never duplicates, and honours --no-bashrc.
: > "$PKGTMP/bashrc"
BASHRC="$PKGTMP/bashrc" "$PKGTMP/x/$PNAME/install.sh" --prefix "$PKGTMP/p2" >/dev/null 2>&1
BASHRC="$PKGTMP/bashrc" "$PKGTMP/x/$PNAME/install.sh" --prefix "$PKGTMP/p2" >/dev/null 2>&1
n=$(grep -c 'namo_complete.bash' "$PKGTMP/bashrc" 2>/dev/null || echo 0)
[ "$n" = 1 ] && ok "adds the source line to .bashrc exactly once" \
             || bad "expected 1 source line in .bashrc, found $n"

: > "$PKGTMP/bashrc2"
BASHRC="$PKGTMP/bashrc2" "$PKGTMP/x/$PNAME/install.sh" --prefix "$PKGTMP/p3" --no-bashrc >/dev/null 2>&1
[ ! -s "$PKGTMP/bashrc2" ] && ok "--no-bashrc leaves .bashrc untouched" \
                           || bad "--no-bashrc modified .bashrc"

res=$(NAMO_BIN="$PKGTMP/prefix/bin/namo_complete" bash -i -c '
  source '"$PKGTMP"'/prefix/share/namo_complete/namo_complete.bash 2>/dev/null
  _namo_resolve_bin' 2>/dev/null)
[ "$res" = "$PKGTMP/prefix/bin/namo_complete" ] \
  && ok "integration resolves the installed binary" || bad "bin resolution failed ($res)"
rm -rf "$PKGTMP"

# --------------------------------------------------------------------------
if [ "${1:-}" = "--live" ]; then
  head_ "7. live Anthropic API call"
  unset NAMO_ENDPOINT
  if [ -z "${ANTHROPIC_API_KEY_REAL:-}" ]; then
    bad "no real key: put ANTHROPIC_API_KEY in .env for --live"
  else
    export ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY_REAL"
    start=$(date +%s%N)
    out=$(payload | env NAMO_LINE='git com' NAMO_CWD="$PWD" NAMO_CACHE=0 "$BIN" 2>/tmp/namo_live_err)
    ms=$(( ($(date +%s%N) - start) / 1000000 ))
    if [ -s /tmp/namo_live_err ]; then
      bad "live call reported an error: $(head -1 /tmp/namo_live_err)"
    elif printf '%s' "$out" | grep -q '^git '; then
      ok "live call returned real completions in ${ms}ms"
      printf '%s\n' "$out" | sed 's/^/        /'
      [ "$ms" -lt 1500 ] && ok "latency under 1.5s target" \
                         || bad "latency ${ms}ms exceeds the 1.5s comfort target"
    else
      bad "live call returned no usable completion (got: ${out:-<empty>})"
    fi
  fi
fi

# --------------------------------------------------------------------------
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
