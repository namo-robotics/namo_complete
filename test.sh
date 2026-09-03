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
TEST_OS=$(uname -s)
# Taken now, because `set -- $wsz` in section 5 rewrites the positional args
# -- gating on "$1" further down silently skipped the live section.
LIVE="${1:-}"
MOCK_PID=""
pass=0; fail=0
DIAGNOSED_PIDS=""

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ns_now() { python3 -c 'import time; print(time.time_ns())'; }
script_shell() {
  if [ "$(uname -s)" = Darwin ]; then
    script -q /dev/null bash --rcfile "$1" -i
  else
    script -qec "bash --rcfile $1 -i" /dev/null
  fi
}

# Both `kill -0` and `pgrep` answer for a process that has exited but has not
# been reaped yet. Whether such a zombie lingers is a property of the init of
# the environment -- CI runs in a container whose PID 1 is not a reaper -- and
# not of the helper under test, which is gone either way. So ask for a process
# that is still *running*, and read the state straight out of /proc: the field
# after the last ')' in stat, 'Z' for a corpse.
alive() {
  if [ "$(uname -s)" = Darwin ]; then
    case $(ps -o stat= -p "${1:-none}" 2>/dev/null) in
      '' | *Z*) return 1 ;;
      *) return 0 ;;
    esac
  fi
  case $(sed -n 's/.*) \(.\) .*/\1/p' "/proc/${1:-none}/stat" 2>/dev/null) in
    '' | Z) return 1 ;;
    *) return 0 ;;
  esac
}
running_helpers() {
  local p out=""
  for p in $(pgrep -x namo_complete 2>/dev/null | sort -n); do
    alive "$p" && out="$out$p "
  done
  printf '%s' "$out"
}
wait_for_helpers() {
  local expected=$1
  for _ in {1..50}; do
    [ "$(running_helpers)" = "$expected" ] && return 0
    sleep 0.1
  done
  return 1
}
wait_for_exit() {
  local pid=$1
  for _ in {1..50}; do
    alive "$pid" || return 0
    sleep 0.1
  done
  return 1
}
diag_text() {
  printf '        diagnostic %s: ' "$1"
  printf '%q\n' "$2"
}
diag_file() {
  local label=$1 path=$2 size
  if [ ! -e "$path" ]; then
    printf '        diagnostic %s: <missing>\n' "$label"
    return
  fi
  if [ -p "$path" ]; then
    printf '        diagnostic %s: present, named pipe\n' "$label"
    return
  fi
  size=$(wc -c < "$path" | tr -d '[:space:]')
  printf '        diagnostic %s: present, %s bytes\n' "$label" "$size"
}
diag_process() {
  local pid=$1
  printf '        diagnostic process %s:\n' "${pid:-<missing>}"
  [ -n "$pid" ] || return
  case " $DIAGNOSED_PIDS " in
    *" $pid "*)
      printf '          already reported\n'
      return
      ;;
  esac
  DIAGNOSED_PIDS="$DIAGNOSED_PIDS$pid "
  ps -o pid=,ppid=,pgid=,stat=,etime=,command= -p "$pid" 2>&1 | sed 's/^/          /'
  if command -v lsof >/dev/null 2>&1; then
    lsof -p "$pid" 2>/dev/null | grep -E 'FIFO|namo|tty' | sed 's/^/          /'
  fi
  if [ "$TEST_OS" = Darwin ] && command -v sample >/dev/null 2>&1 && alive "$pid"; then
    sample "$pid" 1 1 2>&1 | sed -n '1,100p' | sed 's/^/          /'
  fi
}
diag_requests() {
  local path=$1 size records typed glob ignored
  if [ ! -s "$path" ]; then
    printf '        diagnostic requests: <missing or empty>\n'
    return
  fi
  size=$(wc -c < "$path" | tr -d '[:space:]')
  records=$(wc -l < "$path" | tr -d '[:space:]')
  typed=$(grep -c '<typed>' "$path" 2>/dev/null || true)
  glob=$(grep -cF '<typed>grpe -r TODO *.md</typed>' "$path" 2>/dev/null || true)
  ignored=$(grep -cF '<typed>grpe -r TODO src</typed>' "$path" 2>/dev/null || true)
  printf '        diagnostic requests: bytes=%s records=%s typed=%s expected_glob=%s expected_ignorespace=%s\n' \
    "$size" "$records" "$typed" "$glob" "$ignored"
}
stop_mock() {
  if [ -n "${MOCK_PID:-}" ]; then
    kill "$MOCK_PID" 2>/dev/null
    wait "$MOCK_PID" 2>/dev/null
  fi
  MOCK_PID=""
}
cleanup() { stop_mock; rm -f /tmp/namo_req.json /tmp/namo_reqs.log; }
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

out=$(env ANTHROPIC_API_KEY=x NAMO_MIN_GAP=0 NAMO_CACHE=0 NAMO_ENDPOINT='http://127.0.0.1:9/v1' \
        NAMO_LINE='git commit' NAMO_CWD="$PWD" "$BIN" </dev/null 2>/dev/null); rc=$?
[ -z "$out" ] && [ "$rc" = 1 ] \
  && ok "unreachable endpoint: stdout stays clean" || bad "unreachable endpoint"

out=$(env ANTHROPIC_API_KEY=x NAMO_MIN_GAP=0 NAMO_CACHE=0 NAMO_ENDPOINT='https://127.0.0.1:9/v1' \
        NAMO_LINE='git commit' NAMO_CWD="$PWD" "$BIN" </dev/null 2>/dev/null); rc=$?
[ -z "$out" ] && [ "$rc" = 1 ] \
  && ok "TLS connection failure: stdout stays clean" || bad "TLS connection failure"

for endpoint in 'ftp://example.com/v1' 'http://example.com/v1' 'https:///v1' 'https://example.com:bad/v1' \
                'https://user@example.com/v1' 'https://example.com:443:2/v1' \
                'https://example.com:4294967739/v1' 'https://example.com/a b' \
                'https://example.com/v1#fragment'; do
  out=$(env ANTHROPIC_API_KEY=x NAMO_MIN_GAP=0 NAMO_CACHE=0 NAMO_ENDPOINT="$endpoint" NAMO_LINE='git commit' \
          NAMO_CWD="$PWD" "$BIN" </dev/null 2>/dev/null); rc=$?
  [ -z "$out" ] && [ "$rc" = 1 ] \
    && ok "malformed endpoint rejected: $endpoint" || bad "malformed endpoint accepted: $endpoint"
done

out=$(env ANTHROPIC_API_KEY="bad
header" NAMO_MIN_GAP=0 NAMO_CACHE=0 NAMO_ENDPOINT='http://127.0.0.1:9/v1' \
        NAMO_LINE='git commit' NAMO_CWD="$PWD" "$BIN" </dev/null 2>/dev/null); rc=$?
[ -z "$out" ] && [ "$rc" = 1 ] \
  && ok "invalid API-key header rejected" || bad "invalid API-key header accepted"

# Which build is this? `dev` is a rolling tag, so the commit is the only thing
# that identifies a binary -- and the question has to be answerable on a machine
# where the tool is switched off and misbehaving.
for flag in --version -V; do
  # NAMO_DISABLE and a missing key are both deliberate: the answer must not
  # depend on the tool being configured or turned on.
  out=$(env -u ANTHROPIC_API_KEY NAMO_DISABLE=1 "$BIN" "$flag" </dev/null 2>/dev/null); rc=$?
  { [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -qE '^namo_complete .+ \(commit .+, built .+\)$'; } \
    && ok "$flag names the version, the commit and the build time" \
    || bad "$flag printed (rc=$rc): $out"
done

ver=$("$BIN" --version 2>/dev/null)
printf '%s\n' "$ver" | grep -q '^built with sun ' \
  && ok "--version names the compiler it was built with" || bad "no built-with line"
printf '%s\n' "$ver" | grep -q 'commit unknown' \
  && bad "the binary does not know its own commit" \
  || ok "the commit is stamped, not a placeholder"

# --------------------------------------------------------------------------
head_ "2. end-to-end against a mock API"
# --------------------------------------------------------------------------
command -v python3 >/dev/null 2>&1 || { echo "  (skipped: python3 not found)"; exit 0; }

cat > /tmp/namo_mock.py <<PY
import http.server, json, time
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('content-length', 0)))
        open('/tmp/namo_req.json','wb').write(body)
        # Every request, appended: a pty test cannot rely on being the last
        # caller, since the daemon is asking for its own hints throughout.
        open('/tmp/namo_reqs.log','ab').write(body + b'\\n')
        open('/tmp/namo_hdr.txt','w').write(str(self.headers))
        open('/tmp/namo_path.txt','w').write(self.path)
        if self.path == '/status':
            o = b'service unavailable'
            self.send_response(503); self.send_header('content-length', str(len(o)))
            self.end_headers(); self.wfile.write(o); return
        # Correction mode gets its own answer, so a "did you mean" test cannot
        # pass on a completion that happened to be in flight.
        if b'<typed>' in body:
            # Slow on purpose: the shell must not be waiting for this.
            time.sleep(1.0)
            txt = "git status"
        else:
            txt = "git commit -m \\"msg\\"\\ngit commit --amend\\ngit commit -a"
        r = {"id":"m","type":"message","role":"assistant","model":"claude-haiku-4-5",
             "content":[{"type":"text","text":txt}],
             "stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
        o = json.dumps(r).encode()
        self.send_response(200); self.send_header('content-type','application/json')
        if self.path == '/chunked':
            self.send_header('transfer-encoding', 'chunked'); self.end_headers()
            self.wfile.write((format(len(o), 'x') + '\r\n').encode() + o + b'\r\n0\r\n\r\n')
        else:
            self.send_header('content-length', str(len(o))); self.end_headers(); self.wfile.write(o)
    def log_message(self, *a): pass
class S(http.server.ThreadingHTTPServer):
    allow_reuse_address = True
S(('127.0.0.1', $PORT), H).serve_forever()
PY
python3 /tmp/namo_mock.py & MOCK_PID=$!
sleep 1.2

export ANTHROPIC_API_KEY='sk-ant-TESTKEY-must-not-leak'
export NAMO_ENDPOINT="http://127.0.0.1:$PORT/v1/messages"
export NAMO_MIN_GAP=0   # the 1s throttle would otherwise starve these tests

# Only history now: the binary lists the working directory itself.
payload() {
  echo 'git status'
  echo 'export GITHUB_TOKEN=ghp_SECRETVALUE'
  echo 'git commit -m "fix the password reset flow"'
  echo 'ls -la'
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
python3 - <<'PY' && ok "listing gathered by the binary on the one-shot path" \
                || bad "one-shot listing wrong"
import json
c = json.load(open('/tmp/namo_req.json'))['messages'][0]['content']
assert '<ls>' in c, c
names = c.split('<ls>')[1].split('</ls>')[0].split()
assert 'README.md' in names and 'src' in names, names
assert '.' not in names and '..' not in names, names
assert names == sorted(names), names
PY
grep -qi "x-api-key: sk-ant-TESTKEY" /tmp/namo_hdr.txt \
  && ok "api key sent as a header" || bad "api key header missing"
[ "$(cat /tmp/namo_path.txt)" = /v1/messages ] \
  && ok "custom endpoint path sent unchanged" || bad "custom endpoint path missing"
grep -qi "^Host: 127.0.0.1:$PORT" /tmp/namo_hdr.txt \
  && ok "custom endpoint port included in Host" || bad "custom port missing from Host"

out=$(payload | env NAMO_LINE='git com' NAMO_CWD="$PWD" NAMO_CACHE=0 \
      NAMO_ENDPOINT="http://127.0.0.1:$PORT/chunked" "$BIN" 2>/dev/null)
printf '%s\n' "$out" | grep -q '^git commit -m' \
  && ok "chunked HTTP response decoded" || bad "chunked response failed"

err=$(payload | env NAMO_LINE='git com' NAMO_CWD="$PWD" NAMO_CACHE=0 \
      NAMO_ENDPOINT="http://127.0.0.1:$PORT/status" "$BIN" 2>&1 >/dev/null); rc=$?
printf '%s' "$err" | grep -q 'HTTP status 503' && [ "$rc" = 1 ] \
  && ok "non-2xx status reported" || bad "non-2xx status hidden (rc=$rc err=$err)"

grep -rl 'sk-ant-TESTKEY' "$XDG_RUNTIME_DIR" >/dev/null 2>&1 \
  && bad "api key left behind on disk" || ok "no key left on disk after the call"

# Opus is the default, and its current API rejects temperature.
python3 - <<'PY' && ok "request shape valid for default Opus 5" || bad "bad default request shape"
import json,sys
d=json.load(open('/tmp/namo_req.json'))
assert d['model']=='claude-opus-5', d['model']
assert d['max_tokens'] > 150
assert 'temperature' not in d
assert 'output_config' not in d and 'thinking' not in d
assert all(x.strip() for x in d['stop_sequences']), 'whitespace-only stop sequence'
PY

# The older low-latency model remains an opt-in and keeps its smaller budget
# and deterministic temperature setting.
rm -f /tmp/namo_req.json
payload | env NAMO_LINE='git com' NAMO_CWD="$PWD" NAMO_CACHE=0 \
  NAMO_MODEL=claude-haiku-4-5 "$BIN" >/dev/null 2>&1
python3 - <<'PY' && ok "request shape valid for explicit Haiku 4.5" || bad "bad Haiku request shape"
import json
d=json.load(open('/tmp/namo_req.json'))
assert d['model']=='claude-haiku-4-5', d['model']
assert d['temperature']==0
assert d['max_tokens']==150
PY

# An unknown name is far more likely to be newer than this list than older.
rm -f /tmp/namo_req.json
payload | env NAMO_LINE='git com' NAMO_CWD="$PWD" NAMO_CACHE=0 \
  NAMO_MODEL=claude-model-from-the-future "$BIN" >/dev/null 2>&1
python3 - <<'PY' && ok "temperature omitted for an unrecognised model" || bad "temperature sent to an unrecognised model"
import json
d=json.load(open('/tmp/namo_req.json'))
assert 'temperature' not in d, 'an unknown model must be treated as new, not old'
assert d['max_tokens'] > 150, 'an unknown model gets the thinking-model budget too'
PY

# cache: second identical call must not reach the mock
rm -f /tmp/namo_req.json
payload | env NAMO_LINE='cached probe xyz' NAMO_CWD="$PWD" "$BIN" >/dev/null 2>&1
rm -f /tmp/namo_req.json
payload | env NAMO_LINE='cached probe xyz' NAMO_CWD="$PWD" "$BIN" >/dev/null 2>&1
[ -f /tmp/namo_req.json ] && bad "cache miss: second call hit the API" \
                          || ok "second identical call served from cache"

# --------------------------------------------------------------------------
head_ "2c. the api key never reaches the process table"
# --------------------------------------------------------------------------
# The native client keeps the key in this process and never creates a child.
# A listener that accepts and then says nothing holds the request open long
# enough to inspect both the process table and the client's child list.
PORT3=$((PORT + 2))
python3 - <<PY3 & STALL_PID=$!
import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $PORT3)); s.listen(8)
held = []
while True:
    c, _ = s.accept()
    held.append(c)
PY3
sleep 1
NAMO_ENDPOINT="http://127.0.0.1:$PORT3/v1/messages" NAMO_CACHE=0 \
  NAMO_LINE='process table probe' NAMO_CWD="$PWD" "$BIN" </dev/null >/dev/null 2>&1 &
probe=$!
sleep 1
# The bracket keeps the pattern from matching this grep's own command line.
seen=$(ps -ww -eo args 2>/dev/null | grep -c '[s]k-ant-TESTKEY')
children=$(pgrep -P "$probe" 2>/dev/null || true)
[ -z "$children" ] && ok "native client starts no transport subprocess" \
                    || bad "native client spawned children: $children"
kill "$probe" "$STALL_PID" 2>/dev/null
wait "$probe" 2>/dev/null
[ "${seen:-1}" = 0 ] && ok "api key absent from every command line" \
                     || bad "api key visible in the process table ($seen matches)"

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
# Alt-O goes through the daemon: the shell writes a request into the FIFO and
# reads the answer back, so a key press starts no process at all. The second
# call proves it -- by then the path to the binary is a lie, and the answer
# still comes.
res=$(bash -i -c '
  export NAMO_TTY=/tmp/namo_t3_tty NAMO_MAX_SUGGESTIONS=1 NAMO_CACHE=0
  export NAMO_BIN='"$PWD/$BIN"'   # resolved when the file is sourced now
  source shell/namo_complete.bash
  _namo_on_prompt                      # what a prompt would do
  READLINE_LINE="git com"; READLINE_POINT=7
  _namo_on_complete_key </dev/null
  echo "LINE=$READLINE_LINE POINT=$READLINE_POINT"
  _NAMO_BIN_PATH=/nonexistent/namo_complete
  READLINE_LINE="git com"; READLINE_POINT=7
  _namo_on_complete_key </dev/null
  echo "AGAIN=$READLINE_LINE"
' 2>/dev/null | grep -E '^LINE=|^AGAIN=')
rm -f /tmp/namo_t3_tty
printf '%s' "$res" | grep -q '^AGAIN=git commit' \
  && ok "a key press starts no process: answered with no binary to run" \
  || bad "the key path still needs the binary ($(printf '%s' "$res" | grep '^AGAIN='))"
res=$(printf '%s' "$res" | grep '^LINE=')
case "$res" in
  "LINE=git commit"*"POINT="*) ok "readline buffer rewritten ($res)" ;;
  *) bad "readline not rewritten (got: $res)" ;;
esac

# An answer this shell gave up waiting for must not be handed back as if it
# were the next one: every line of a reply carries the request id.
res=$(bash -i -c '
  export NAMO_TTY=/tmp/namo_t3_tty NAMO_MAX_SUGGESTIONS=1 NAMO_CACHE=0
  export NAMO_BIN='"$PWD/$BIN"'
  source shell/namo_complete.bash
  _namo_on_prompt
  printf "%s\t%s\n%s\t%s\n" 99 1 99 "stale answer" >&"$_NAMO_RFD"
  READLINE_LINE="git com"; READLINE_POINT=7
  _namo_on_complete_key </dev/null
  echo "LINE=$READLINE_LINE"
' 2>/dev/null | grep '^LINE=')
rm -f /tmp/namo_t3_tty
printf '%s' "$res" | grep -q 'stale answer' \
  && bad "a stale reply was taken for the answer" \
  || ok "replies are matched to the request that asked ($res)"

# Alt-G reads its question with builtins only -- no stty, no line discipline.
res=$(bash -i -c '
  source shell/namo_complete.bash 2>/dev/null
  READLINE_LINE=""
  typed=$(printf "how big\010\010\010big are these")
  _namo_read_question <<< "$typed"
  echo "Q=[$_NAMO_QUESTION]"' 2>/dev/null | grep '^Q=')
[ "$res" = 'Q=[how big are these]' ] \
  && ok "the question reader handles typing and backspace" \
  || bad "question reader wrong (got $res)"

res=$(bash -i -c '
  source shell/namo_complete.bash 2>/dev/null
  READLINE_LINE=""
  typed=$(printf "\033[200~change CLAUDE.md\ninto a symbolic link\033[201~")
  _namo_read_question <<< "$typed"
  echo "Q=[$_NAMO_QUESTION]"' 2>/dev/null | grep '^Q=')
[ "$res" = 'Q=[change CLAUDE.md into a symbolic link]' ] \
  && ok "bracketed paste stays inside ask mode" \
  || bad "bracketed paste escaped into the shell (got $res)"

res=$(bash -i -c '
  NAMO_BIN=/does/not/exist
  source shell/namo_complete.bash 2>/dev/null
  _namo_read_question() { _NAMO_QUESTION="missing details"; }
  _namo_ask_daemon() { _NAMO_REPLY_OUT=""; return 0; }
  _namo_line_repaint() { :; }
  _namo_line_settle() { :; }
  READLINE_LINE=""
  _namo_key_request a 1' 2>/dev/null)
printf '%s' "$res" | grep -q 'no command returned' \
  && ok "ask mode explains an empty model answer" \
  || bad "ask mode silently discarded an empty answer"

res=$(bash -i -c '
  NAMO_BIN=/does/not/exist
  source shell/namo_complete.bash 2>/dev/null
  _namo_read_question() { _NAMO_QUESTION="valid request"; }
  _namo_ask_daemon() { _NAMO_REPLY_ERROR="model rejected request"; return 2; }
  _namo_line_repaint() { :; }
  _namo_line_settle() { :; }
  READLINE_LINE=""
  _namo_key_request a 1' 2>/dev/null)
printf '%s' "$res" | grep -q 'request failed: model rejected request' \
  && ok "ask mode prints the daemon error" \
  || bad "ask mode hid the daemon error"

res=$(bash -i -c '
  NAMO_BIN=/does/not/exist
  source shell/namo_complete.bash 2>/dev/null
  _namo_daemon_is_running() { return 0; }
  exec {_NAMO_WFD}>/dev/null
  exec {_NAMO_RFD}<<<$'"'"'84\tE\tmodel rejected request'"'"'
  _NAMO_REQ_ID=83
  _namo_ask_daemon a "valid request"
  rc=$?
  printf "rc=%s error=%s\n" "$rc" "$_NAMO_REPLY_ERROR"
' 2>/dev/null)
[ "$res" = 'rc=2 error=model rejected request' ] \
  && ok "Bash parses the daemon error frame" \
  || bad "Bash failed to parse the daemon error frame ($res)"


# keybindings must survive hosts that steal Ctrl-G (VS Code = "Go to Line")
binds=$(bash -i -c 'source shell/namo_complete.bash 2>/dev/null; bind -X 2>/dev/null' 2>/dev/null)
for seq in '\\eo' '\\ea' '\\eg'; do
  printf '%s' "$binds" | grep -q "\"$seq\"" \
    && ok "keyseq $seq bound" || bad "keyseq $seq not bound"
done

# The pair a shell is really running, for when the two halves disagree.
res=$(NAMO_BIN="$PWD/$BIN" bash -i -c '
  source shell/namo_complete.bash 2>/dev/null
  namo-version' 2>/dev/null)
{ printf '%s\n' "$res" | grep -q "^binary: .*$BIN\$" \
  && printf '%s\n' "$res" | grep -q 'namo_complete .*commit ' \
  && printf '%s\n' "$res" | grep -q '^shell: '; } \
  && ok "namo-version names the shell file, the binary and its commit" \
  || bad "namo-version printed: $(printf '%s' "$res" | tr '\n' '|')"

# default: no picker -- the top suggestion is accepted with no extra keystroke
res=$(bash -i -c '
  source shell/namo_complete.bash 2>/dev/null
  READLINE_LINE="git com"; READLINE_POINT=7
  _namo_pick_and_insert "$(printf -- "-\tgit commit\t\n-\tgit commit --amend\t\n-\tgit commit -a\t")" </dev/null
  echo "R=[$READLINE_LINE]"
' 2>/dev/null | grep '^R=')
[ "$res" = 'R=[git commit]' ] && ok "top suggestion accepted without a picker" \
                              || bad "expected top suggestion, got $res"

# Alt-A forces the list for one invocation without changing config
res=$(bash -i -c '
  source shell/namo_complete.bash 2>/dev/null
  READLINE_LINE="git com"; READLINE_POINT=7
  _namo_pick_and_insert "$(printf -- "-\tgit commit\t\n-\tgit commit --amend\t\n-\tgit commit -a\t")" 1 <<<"3"
  echo "R=[$READLINE_LINE]"
' 2>/dev/null | grep '^R=')
[ "$res" = 'R=[git commit -a]' ] && ok "Alt-A path lists alternatives and selects #3" \
                                 || bad "forced picker failed (got $res)"

# the picker cancels cleanly on a non-numeric key, leaving the line alone
res=$(bash -i -c '
  source shell/namo_complete.bash 2>/dev/null
  READLINE_LINE="git com"; READLINE_POINT=7
  # here-string, not a pipe: a pipe would run _namo_pick_and_insert in a subshell and
  # its READLINE_LINE assignment would be discarded.
  _namo_pick_and_insert "$(printf -- "-\tgit commit\t\n-\tgit commit --amend\t\n-\tgit commit -a\t")" 1 <<<"q"
  echo "R=[$READLINE_LINE]"
' 2>/dev/null | grep '^R=')
[ "$res" = 'R=[git com]' ] && ok "picker cancels on a non-numeric key" \
                           || bad "cancel did not leave the line alone (got $res)"

# Ask mode returns COMMAND<TAB>DESCRIPTION: the list shows both, the buffer
# gets the command only.
res=$(bash -i -c '
  source shell/namo_complete.bash 2>/dev/null
  READLINE_LINE="x"; READLINE_POINT=1
  _namo_pick_and_insert "$(printf -- "-\tdu -sh *\tShow sizes\n-\tls -lhS\tSort by size")" 1 <<<"2"
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
  _namo_pick_and_insert "$(printf -- "!\trm -rf build\t")" <<<"n"
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
assert d['max_tokens'] == 1200, d['max_tokens']
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
head_ "4b. did you mean (command not found)"
# --------------------------------------------------------------------------
# A third mode: bash could not find the command, so the line is corrected
# rather than completed. The shell prints bash's message and hands the prompt
# straight back; the answer is drawn by the daemon whenever it arrives.
rm -f /tmp/namo_req.json
out=$(payload | env NAMO_MODE=dym NAMO_QUERY='gti status' \
        NAMO_CWD="$PWD" NAMO_CACHE=0 "$BIN" 2>/dev/null)
[ "$out" = 'git status' ] && ok "correction mode returns the fixed line" \
                          || bad "correction mode returned '$out'"
grep -q '<typed>gti status</typed>' /tmp/namo_req.json \
  && ok "the typed line is sent in a <typed> tag" || bad "<typed> tag missing"
grep -q '<line>\|<request>' /tmp/namo_req.json \
  && bad "correction mode sent a completion or ask tag too" \
  || ok "correction mode omits the <line> and <request> tags"
python3 - <<'PYX' && ok "correction mode uses the correction prompt" || bad "wrong system prompt"
import json
d=json.load(open('/tmp/namo_req.json'))
assert 'correct shell command lines' in d['system'], d['system'][:80]
assert 'output nothing at all' in d['system'], "the model is not allowed to stay silent"
assert d['max_tokens'] == 600, d['max_tokens']
PYX

# Three modes, three cache namespaces.
rm -f /tmp/namo_req.json
payload | env NAMO_MODE=dym NAMO_QUERY='cache probe two' NAMO_CWD="$PWD" "$BIN" >/dev/null 2>&1
rm -f /tmp/namo_req.json
payload | env NAMO_MODE=ask NAMO_QUERY='cache probe two' NAMO_CWD="$PWD" "$BIN" >/dev/null 2>&1
[ -f /tmp/namo_req.json ] && ok "correction and ask keys do not collide" \
                          || bad "ask wrongly reused the correction cache entry"

# An existing handler keeps its message and its exit status.
res=$(bash -i -c '
  command_not_found_handle(){ echo "PREV:[$*]"; return 42; }
  source shell/namo_complete.bash 2>/dev/null
  nosuchcmd_zz; echo "rc=$?"' 2>&1)
printf '%s' "$res" | grep -q 'PREV:\[nosuchcmd_zz\]' \
  && ok "an existing command-not-found handler still runs" \
  || bad "pre-existing handler lost"
printf '%s' "$res" | grep -q 'rc=42' && ok "its exit status is passed through" \
                                     || bad "handler exit status swallowed"
res=$(bash -i -c '
  source shell/namo_complete.bash 2>/dev/null
  nosuchcmd_zz; echo "rc=$?"' 2>&1)
printf '%s' "$res" | grep -q 'nosuchcmd_zz: command not found' \
  && ok "bash's own message still comes first" || bad "command-not-found message lost"
printf '%s' "$res" | grep -q 'rc=127' && ok "status 127 preserved" || bad "status not 127"

# ---- the daemon side of it, driven directly ----
# A correction rides the same FIFO as every keystroke, marked with a leading
# SOH, and must never be mistaken for a line being typed.
CT=$(mktemp -d)
mkfifo -m 600 "$CT/fifo"
printf 'git status\nls -la\n' > "$CT/hist"
exec {CFD}<>"$CT/fifo"
rm -f /tmp/namo_reqs.log
NAMO_DAEMON=1 NAMO_FIFO="$CT/fifo" NAMO_HISTFILE="$CT/hist" NAMO_PIDFILE="$CT/pid" \
  NAMO_DYMFILE="$CT/dym" NAMO_TTY="$CT/tty" NAMO_DEBOUNCE=0.2 NAMO_QUIET=0.05 \
  NAMO_CACHE=0 "$BIN" </dev/null >/dev/null 2>&1
sleep 0.3

# What command_not_found_handle leaves behind: the word bash could not find,
# the words it would have run, and the line as `history 1` prints it. Picking
# that apart is the daemon's job (history_line, util.sun).
dym_file() { printf '%s\t%s\t  512  %s\n' "$1" "$2" "$3" > "$CT/dym"; }
dym_file gti "gti bisect" "gti bisect"
printf '%s\t\001\n' "$PWD" >&$CFD
sleep 1.6
grep -q 'did you mean: git status' "$CT/tty" \
  && ok "the correction is drawn in the hint row" \
  || bad "no correction row drawn"
grep -q 'Alt-O' "$CT/tty" \
  && bad "the correction row offers Alt-O, which would run a completion" \
  || ok "the correction row carries no Alt-O suffix"
grep -q '<typed>gti bisect</typed>' /tmp/namo_reqs.log \
  && ok "the daemon asks in correction mode" || bad "daemon did not ask for a correction"
grep -q '<line>.\?gti bisect' /tmp/namo_reqs.log \
  && bad "the correction record was also completed as a typed line" \
  || ok "a correction is never treated as something being typed"

# Regression: the correction is posted by the prompt hook, so it can land in
# any of the daemon's waits -- coalesce, debounce -- not just the idle one.
# The row belongs to the failed command and to nothing else: a correction that
# arrives while a hint for a line being typed is up is dropped, not painted
# over it. The daemon holds this file open, so it is counted, not truncated.
dym_rows() { grep -o 'did you mean' "$CT/tty" 2>/dev/null | grep -c . ; }
printf '%s\t%s\n' "$PWD" "git co" >&$CFD
sleep 1.2                      # long enough for the hint itself to be painted
grep -q 'hint: ' "$CT/tty" && ok "a typed line still gets its hint" \
                           || bad "no hint painted for a typed line"
before=$(dym_rows)
dym_file gti "gti rebase" "gti rebase"
printf '%s\t\001\n' "$PWD" >&$CFD
sleep 1.8
[ "$(dym_rows)" = "$before" ] \
  && ok "a correction never lands on top of a hint for a line being typed" \
  || bad "correction painted over the hint row mid-typing"

# The real sequence: Enter clears the row (the prompt hook pushes an empty
# line) and the correction follows it, both inside the daemon's debounce
# window rather than at the top of its loop.
before=$(dym_rows)
dym_file gti "gti rebase" "gti rebase"
printf '%s\t%s\n' "$PWD" "git co" >&$CFD
printf '%s\t%s\n' "$PWD" "" >&$CFD
printf '%s\t\001\n' "$PWD" >&$CFD
sleep 1.8
[ "$(dym_rows)" -gt "$before" ] \
  && ok "a correction arriving mid-debounce is still served" \
  || bad "correction swallowed by the debounce window"
unset -f dym_rows

# The history entry belongs to some earlier command (HISTCONTROL=ignorespace
# and friends): the first word does not match, so the words bash passed the
# handler are used instead.
rm -f /tmp/namo_reqs.log
dym_file grpe "grpe -r FIXME lib" "  17  cd /workspace"
printf '%s\t\001\n' "$PWD" >&$CFD
sleep 1.8
grep -q '<typed>grpe -r FIXME lib</typed>' /tmp/namo_reqs.log 2>/dev/null \
  && ok "an unrecorded line falls back to the words bash passed in" \
  || bad "wrong line corrected when the history entry was somebody else's"

exec {CFD}>&-
sleep 0.4
rm -rf "$CT"
unset -f dym_file

# ---- and through a real shell ----
if command -v script >/dev/null 2>&1; then
  cat > /tmp/namo_rc_dym.sh <<RCEOF
export NAMO_BIN="$PWD/$BIN"
export NAMO_MIN_GAP=0 NAMO_DEBOUNCE=0.3
export NAMO_ENDPOINT="$NAMO_ENDPOINT"
export ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
source "$PWD/shell/namo_complete.bash"
PS1='T\$ '
RCEOF
  runpty() { script_shell /tmp/namo_rc_dym.sh 2>&1 | tr -d '\r'; }
  ms_now() { echo $(( $(ns_now) / 1000000 )); }

  # The mock holds a correction for a full second. A session that types one and
  # leaves must not have waited for it: nothing in the shell is watching.
  rm -f /tmp/namo_reqs.log
  t0=$(ms_now); { printf 'NAMO_DYM=0\nnosuchcmd_zz\n'; sleep 0.2; printf 'exit\n'; } \
    | runpty >/dev/null
  base=$(( $(ms_now) - t0 ))
  t0=$(ms_now); res=$( { printf 'gti diff\n'; sleep 0.2; printf 'exit\n'; } | runpty)
  dym=$(( $(ms_now) - t0 ))
  [ $(( dym - base )) -lt 500 ] \
    && ok "prompt returns immediately: ${dym}ms vs ${base}ms baseline, 1000ms call" \
    || bad "the shell waited for the correction (${dym}ms vs ${base}ms baseline)"
  printf '%s' "$res" | grep -q 'gti: command not found' \
    && ok "bash's message is printed at once" || bad "error message missing"
  # The shell left before the answer did; the daemon is still in the call.
  sleep 1.5
  grep -q '<typed>gti diff</typed>' /tmp/namo_reqs.log 2>/dev/null \
    && ok "the correction is still asked for after the shell has moved on" \
    || bad "typed line not sent"

  # The words bash hands the handler have been globbed; the history list has
  # what was actually typed.
  rm -f /tmp/namo_reqs.log
  globcap=$(printf 'grpe -r TODO *.md\nsleep 1.4\nexit\n' | runpty)
  if grep -q '<typed>grpe -r TODO \*.md</typed>' /tmp/namo_reqs.log 2>/dev/null; then
    ok "globs are sent unexpanded, as typed"
  else
    bad "the glob was expanded before it reached the model"
    diag_text "glob shell transcript bytes" "${#globcap}"
    diag_requests /tmp/namo_reqs.log
  fi

  # A line the history list never recorded still has to reach the model.
  rm -f /tmp/namo_reqs.log
  ignorecap=$(printf 'HISTCONTROL=ignorespace\n grpe -r TODO src\nsleep 1.4\nexit\n' | runpty)
  if grep -q '<typed>grpe -r TODO src</typed>' /tmp/namo_reqs.log 2>/dev/null; then
    ok "unrecorded line (HISTCONTROL=ignorespace) still corrected"
  else
    bad "wrong line sent when it was kept out of the history list"
    diag_text "ignorespace shell transcript bytes" "${#ignorecap}"
    diag_requests /tmp/namo_reqs.log
  fi

  rm -f /tmp/namo_reqs.log
  printf 'NAMO_DYM=0\nnosuchcmd_zz\nsleep 1.4\nexit\n' | runpty >/dev/null
  grep -q '<typed>' /tmp/namo_reqs.log 2>/dev/null \
    && bad "NAMO_DYM=0 still asked" || ok "NAMO_DYM=0 turns it off"

  rm -f /tmp/namo_rc_dym.sh
  unset -f runpty ms_now
  # A daemon still holding a slow correction would show up as a leak in the
  # next section, which counts the helpers that outlive their shell.
  sleep 1.5
else
  echo "  (skipped pty tests: 'script' not available)"
fi

# --------------------------------------------------------------------------
head_ "5. live hints"
# --------------------------------------------------------------------------
# A dead, dedicated endpoint proves cache-only never makes a network call.
# Keep the main mock alive: rebinding one port can stall connect() on macOS
# and turn every later daemon assertion into a cascading failure.
out=$(env NAMO_CACHE_ONLY=1 NAMO_LINE='git com' NAMO_CWD="$PWD" \
        NAMO_ENDPOINT='http://127.0.0.1:9/v1' "$BIN" </dev/null 2>&1); rc=$?
[ "$rc" = 0 ] && ok "cache-only exits cleanly with the network down" \
              || bad "cache-only failed with the network down (rc=$rc)"

# Keep the one-shot cache path cheap without treating process startup jitter as
# a functional failure on shared CI runners.
start=$(ns_now)
for _ in 1 2 3 4 5 6 7 8 9 10; do
  env NAMO_CACHE_ONLY=1 NAMO_LINE='git com' NAMO_CWD="$PWD" "$BIN" </dev/null >/dev/null 2>&1
done
per=$(( ($(ns_now) - start) / 10000000 ))
[ "$per" -le 50 ] && ok "cache-only lookup ${per}ms per call" \
                  || bad "cache-only too slow for live use: ${per}ms"

# No printable key is rebound any more: bash erases and repaints the prompt row
# around every `bind -x` handler, which is a visible flicker on a terminal that
# draws as the bytes arrive. The line is read off the pty instead (5d).
printf '%s' "$binds" | grep -qE '^"[a-zA-Z0-9]": ' \
  && bad "a printable key is still rebound: bash will repaint the row per keystroke" \
  || ok "no printable key is rebound"
printf '%s' "$binds" | grep -q '"\\C-?"' \
  && bad "backspace is still rebound" || ok "backspace left to readline"
res=$(bash -i -c '
  source shell/namo_complete.bash 2>/dev/null
  type -t _namo_on_printable_key' 2>/dev/null | tail -1)
[ -z "$res" ] && ok "the per-keystroke handler is gone, not just unbound" \
              || bad "_namo_on_printable_key still defined ($res)"

# Live hints are still the point of the tool, so the one thing the shell has to
# do for them -- mark the end of the prompt -- happens with no opt-in.
res=$(bash -i -c '
  source shell/namo_complete.bash 2>/dev/null
  PS1="T\$ "; _NAMO_CAPTURE=1; _namo_ps1_sync; _namo_ps1_sync
  printf "%q\n" "$PS1"' 2>/dev/null | tail -1)
[ "$res" = "\$'T\$ \\\\[\\035\\\\]'" ] \
  && ok "prompt marker appended once, inside \\[ \\]" \
  || bad "PS1 marker wrong (got $res)"
res=$(bash -i -c '
  source shell/namo_complete.bash 2>/dev/null
  PS1="T\$ "; _NAMO_CAPTURE=1; _namo_ps1_sync; _NAMO_CAPTURE=""; _namo_ps1_sync
  printf "%q\n" "$PS1"' 2>/dev/null | tail -1)
[ "$res" = "T\\\$\\ " ] \
  && ok "marker taken back out when no relay is there to strip it" \
  || bad "PS1 marker not removed (got $res)"
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
  daemons_before=$(running_helpers)
  jobcap=$(printf 'git com\nsleep 1\nexit\n' \
    | script_shell /tmp/namo_rc_test.sh 2>&1 \
    | tr -d '\r')
  jobnoise=$(printf '%s' "$jobcap" | grep -acE '^\[[0-9]+\][[:space:]]+[0-9]+')
  [ "$jobnoise" = 0 ] && ok "no job-control noise while typing" \
                      || bad "$jobnoise job notifications leaked to the terminal"

  # The daemon holds the read end of the FIFO; when the shell that owns the
  # write end goes away it must see end-of-file and stop, not linger.
  wait_for_helpers "$daemons_before"
  daemons_after=$(running_helpers)
  if [ "$daemons_before" = "$daemons_after" ]; then
    ok "no daemon left behind by an exited shell"
  else
    bad "the daemon outlived its shell"
    diag_text "helpers before shell" "$daemons_before"
    diag_text "helpers after shell" "$daemons_after"
    diag_text "shell transcript bytes" "${#jobcap}"
    for helper in $daemons_after; do
      case " $daemons_before " in
        *" $helper "*) ;; *) diag_process "$helper" ;;
      esac
    done
  fi

  # Output with no trailing newline must not swallow the next prompt: the hook
  # pads to the end of the row so the wrap happens before the prompt is drawn.
  eolcap=$( { printf 'printf hi\n'; sleep 0.2; printf 'exit\n'; } \
    | script_shell /tmp/namo_rc_test.sh 2>&1)
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
head_ "5b. the daemon"
# --------------------------------------------------------------------------
# The FIFO read loop, the debounce, the cache lookup, the API call and the hint
# row all sit inside the binary (src/daemon.sun); the shell only writes
# "<cwd><tab><line>" into a pipe. These drive that side of it directly.
DT=$(mktemp -d)
mkfifo -m 600 "$DT/fifo" "$DT/reply"
printf 'git status\nexport TOK=ghp_LIVELEAK\n' > "$DT/hist"
exec {DFD}<>"$DT/fifo"
rm -f /tmp/namo_req.json

NAMO_DAEMON=1 NAMO_FIFO="$DT/fifo" NAMO_REPLY="$DT/reply" NAMO_HISTFILE="$DT/hist" \
  NAMO_PIDFILE="$DT/pid" NAMO_TTY="$DT/tty" NAMO_DEBOUNCE=0.2 NAMO_QUIET=0.05 \
  "$BIN" </dev/null >"$DT/stdout" 2>"$DT/stderr"
dpid=$(cat "$DT/pid" 2>/dev/null)
{ [ -n "$dpid" ] && alive "$dpid"; } \
  && ok "daemon detaches and records its pid before returning" \
  || bad "daemon did not start"

printf '%s\t%s\n' "$PWD" "daemon probe" >&"$DFD"
sleep 1.2
if grep -q 'hint: ' "$DT/tty"; then
  ok "hint painted after the debounce"
else
  bad "no hint painted"
  diag_file "daemon tty" "$DT/tty"
  diag_file "daemon stderr" "$DT/stderr"
  diag_requests /tmp/namo_reqs.log
  diag_process "$dpid"
fi
# One row below the cursor, never on it: the row the prompt hook reserves.
# Absolute positioning would put it at the bottom of the screen, which is the
# line being typed as soon as the prompt gets there.
grep -q "$(printf '\033')\[1B" "$DT/tty" \
  && ok "hint row placed one row below the cursor" || bad "hint row not positioned"
grep -q "$(printf '\033')\[999;1H" "$DT/tty" \
  && bad "hint row still addressed absolutely" || ok "no absolute jump to the last row"
[ "$(tr -dc '\n' < "$DT/tty" | wc -c | tr -d '[:space:]')" = 0 ] \
  && ok "no newline emitted while drawing" \
  || bad "the hint row emitted a newline, which scrolls the screen"

# The other direction: a request the shell waits for. STX marks it, the answer
# comes back down the reply FIFO labelled with the id that asked.
exec {RFD}<>"$DT/reply"
# A line of its own, so nothing another test cached can answer this one.
printf '%s\t\002%s\t%s\t%s\n' "$PWD" 42 c "zzprobe com" >&"$DFD"
hdr=""; IFS= read -r -t 5 -u "$RFD" hdr
n=${hdr#*$'\t'}
if [ "${hdr%%$'\t'*}" = 42 ] && [ "$n" -ge 1 ] 2>/dev/null; then
  ok "reply header names the request and the number of answers ($n)"
else
  bad "bad reply header: $(printf '%s' "$hdr" | cat -v)"
  diag_file "reply fifo" "$DT/reply"
  diag_file "daemon stderr" "$DT/stderr"
  diag_requests /tmp/namo_reqs.log
  diag_process "$dpid"
fi
first=""; IFS= read -r -t 5 -u "$RFD" first
[ "$first" = "$(printf '42\t-\tgit commit -m "msg"\t')" ] \
  && ok "candidates come back split, with the verdict in front" \
  || bad "bad reply line: $(printf '%s' "$first" | cat -v)"
for (( i = 1; i < n; i++ )); do IFS= read -r -t 5 -u "$RFD" _; done

# A line too short to be worth a round trip is still answered, with nothing.
printf '%s\t\002%s\t%s\t%s\n' "$PWD" 43 c "gi" >&"$DFD"
hdr=""; IFS= read -r -t 5 -u "$RFD" hdr
[ "$hdr" = "$(printf '43\t0')" ] \
  && ok "a request too short to serve gets an empty answer, not silence" \
  || bad "short request answered with: $(printf '%s' "$hdr" | cat -v)"
exec {RFD}>&-

grep -q 'ghp_LIVELEAK' /tmp/namo_req.json \
  && bad "SECRET LEAKED from the daemon path" \
  || ok "history snapshot redacted on the daemon path too"

python3 - <<'PYCHK' && ok "listing gathered by the binary, sorted, no . or .." \
                    || bad "directory listing wrong on the daemon path"
import json
c = json.load(open('/tmp/namo_req.json'))['messages'][0]['content']
assert '<ls>' in c, c
names = c.split('<ls>')[1].split('</ls>')[0].split()
assert 'README.md' in names and 'src' in names, names
assert '.' not in names and '..' not in names, names
assert names == sorted(names), names
PYCHK

# A line under NAMO_HINT_MIN clears the row instead of leaving a stale hint.
: > "$DT/tty"
printf '%s\t%s\n' "$PWD" "hi" >&"$DFD"
sleep 0.5
grep -q '2K' "$DT/tty" && ok "short line clears the hint row" || bad "row not cleared"

rm -f /tmp/namo_req.json
printf '%s\t%s\n' "$PWD" "daemon probe" >&"$DFD"
sleep 1.2
[ -f /tmp/namo_req.json ] && bad "the daemon re-called the API for a cached line" \
                          || ok "repeat line served from cache, no call"

exec {DFD}>&-
wait_for_exit "$dpid"
if alive "$dpid"; then
  bad "daemon outlived the shell that owned the FIFO"
  diag_process "$dpid"
else
  ok "daemon stops when the FIFO reaches end-of-file"
fi
if [ -f "$DT/pid" ]; then
  bad "pid file left behind"
  diag_file "daemon pid file" "$DT/pid"
else
  ok "pid file removed on exit"
fi
rm -rf "$DT"

# --------------------------------------------------------------------------
head_ "5c. output capture (on by default)"
# --------------------------------------------------------------------------
# The shell's stdout on the far side of a pty, so that what a command printed
# can be sent as context without every command losing isatty(1).
RT=$(mktemp -d)
NAMO_RELAY=1 NAMO_OUTPUT=3 NAMO_PTSFILE="$RT/pts" NAMO_OUTFILE="$RT/out" \
  NAMO_RELAY_PIDFILE="$RT/pid" NAMO_TTY="$RT/tty" NAMO_SHELL_PID=$$ \
  "$BIN" </dev/null >/dev/null 2>&1
sleep 0.4
pts=$(cat "$RT/pts" 2>/dev/null)
[ -n "$pts" ] && [ -c "$pts" ] && ok "relay allocates a pty and names it ($pts)" \
                              || bad "no pty allocated"
relaypid=$(cat "$RT/pid" 2>/dev/null)
{ [ -n "$relaypid" ] && alive "$relaypid"; } \
  && ok "relay detaches and records its pid" || bad "relay did not start"

# What a command run under it would print: a start marker, output, a flush.
{ printf '\036'
  printf 'one\ntwo\n\033[32mthree\033[0m\nexport TOK=ghp_LEAKED\nfour\n'
  printf '\037'; } > "$pts"
sleep 0.6

grep -q 'three' "$RT/tty" && ok "output reaches the real terminal" \
                          || bad "output never reached the terminal"
grep -q "$(printf '\033')\[32m" "$RT/tty" \
  && ok "colour passes through untouched" || bad "colour was stripped on the way out"
LC_ALL=C grep -q "$(printf '\036')\|$(printf '\037')" "$RT/tty" \
  && bad "a marker reached the screen" || ok "markers never reach the screen"

recorded=$(cat "$RT/out" 2>/dev/null)
[ "$recorded" = "$(printf 'two\nthree\nfour')" ] \
  && ok "only the last NAMO_OUTPUT lines are kept, escapes stripped" \
  || bad "recorded wrong: $(printf '%s' "$recorded" | tr '\n' '|')"
printf '%s' "$recorded" | grep -q 'ghp_LEAKED' \
  && bad "SECRET LEAKED from captured output" \
  || ok "credential line dropped from output too"

# The line before the start marker belongs to the prompt, not the command.
: > "$RT/out"
{ printf 'stale typing echo\n\036'; printf 'fresh output\n\037'; } > "$pts"
sleep 0.6
[ "$(cat "$RT/out")" = "fresh output" ] \
  && ok "recording starts where the command does" \
  || bad "the prompt line was recorded as output: $(cat "$RT/out")"

kill "$relaypid" 2>/dev/null

# The window size. There is no SIGWINCH handler in the relay -- the real
# terminal is asked on a timer -- so the case that matters is a resize in the
# middle of output that never pauses: the poll is ready every time round, and
# a check that only ran when the loop was idle would never run at all.
wsz=$(python3 - "$BIN" <<'PYW' 2>/dev/null
import fcntl, os, pty, struct, subprocess, sys, tempfile, termios, threading, time

def get(fd): return struct.unpack("HHHH", fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0" * 8))[:2]
def put(fd, r, c): fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", r, c, 0, 0))

def settles(fd, want, limit=4.0):
    t0 = time.time()
    while time.time() - t0 < limit:
        if get(fd) == want: return int((time.time() - t0) * 1000)
        time.sleep(0.02)
    return -1

d = tempfile.mkdtemp()
master, slave = pty.openpty()          # standing in for the real terminal
put(master, 40, 100)
draining = True
def drain():
    while draining:
        try:
            if not os.read(master, 65536): return
        except OSError: return
threading.Thread(target=drain, daemon=True).start()

subprocess.run([sys.argv[1]], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
               stderr=subprocess.DEVNULL,
               env=dict(os.environ, NAMO_RELAY="1", NAMO_OUTPUT="3",
                        NAMO_PTSFILE=d + "/pts", NAMO_OUTFILE=d + "/out",
                        NAMO_RELAY_PIDFILE=d + "/pid", NAMO_TTY=os.ttyname(slave),
                        NAMO_SHELL_PID=str(os.getpid())))
pts = ""
for _ in range(60):
    try: pts = open(d + "/pts").read().strip()
    except OSError: pass
    if pts: break
    time.sleep(0.05)
inner = os.open(pts, os.O_RDWR | os.O_NOCTTY)
relay = int(open(d + "/pid").read().strip())

start = settles(inner, (40, 100))      # what the shell's stdout is born with
put(master, 50, 120)
idle = settles(inner, (50, 120))       # nothing running: the loop is waiting

flooding = True
def flood():
    while flooding:
        try: os.write(inner, b"x" * 2048)
        except OSError: return
th = threading.Thread(target=flood, daemon=True); th.start()
time.sleep(0.4)
put(master, 24, 80)
busy = settles(inner, (24, 80))        # a build printing without a pause
flooding = False; th.join(timeout=2)

try:  # running, not merely unreaped: a crashed relay is a zombie here
    if sys.platform == "darwin":
        stat = subprocess.check_output(["ps", "-o", "stat=", "-p", str(relay)], text=True).strip()
        alive = 0 if not stat or "Z" in stat else 1
    else:
        alive = 0 if open("/proc/%d/stat" % relay).read().rsplit(") ", 1)[1][0] == "Z" else 1
except (OSError, subprocess.CalledProcessError):
    alive = 0
draining = False
os.kill(relay, 9)
print(start, idle, busy, alive)
PYW
)
set -- $wsz
[ "${1:--1}" != "-1" ] && ok "the terminal's size reaches the pty at startup" \
                       || bad "pty never took the terminal's size"
[ "${2:--1}" != "-1" ] && ok "a resize on an idle terminal reaches the pty (${2}ms)" \
                       || bad "idle resize never reached the pty"
[ "${3:--1}" != "-1" ] && ok "a resize during unbroken output reaches the pty (${3}ms)" \
                       || bad "resize ignored while output was flowing"
[ "${4:-0}" = 1 ] && ok "the relay survives all of it" || bad "relay died during resizes"

# The context the model gets, from the one-shot path.
printf 'on branch main\nnothing to commit\n' > "$RT/ctx"
rm -f /tmp/namo_req.json
payload | env NAMO_OUTFILE="$RT/ctx" NAMO_LINE='git ad' NAMO_CWD="$PWD" \
              NAMO_CACHE=0 "$BIN" >/dev/null 2>&1
grep -q '<output>' /tmp/namo_req.json \
  && ok "recorded output is sent as its own block" || bad "<output> block missing"
python3 - <<'PYO' && ok "the block holds what the command printed" || bad "wrong output block"
import json
c = json.load(open('/tmp/namo_req.json'))['messages'][0]['content']
body = c.split('<output>')[1].split('</output>')[0]
assert 'on branch main' in body and 'nothing to commit' in body, body
PYO
rm -f /tmp/namo_req.json
payload | env NAMO_LINE='git ad' NAMO_CWD="$PWD" NAMO_CACHE=0 "$BIN" >/dev/null 2>&1
grep -q '<output>' /tmp/namo_req.json \
  && bad "an <output> block was sent with capture off" \
  || ok "nothing sent when capture is off"
rm -rf "$RT"

# ...and through a real shell, where the point is that nothing about the
# terminal changes.
if command -v script >/dev/null 2>&1; then
  cat > /tmp/namo_rc_out.sh <<RCEOF
export NAMO_BIN="$PWD/$BIN"
export NAMO_MIN_GAP=0 NAMO_DEBOUNCE=0.3 NAMO_CACHE=0
export NAMO_ENDPOINT="$NAMO_ENDPOINT"
export ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
export NAMO_OUTPUT=5
source "$PWD/shell/namo_complete.bash"
PS1='T\$ '
RCEOF
  rm -f /tmp/namo_reqs.log
  daemons_before=$(running_helpers)
  cap=$( { printf '[ -t 1 ] && echo ISATTY_OK\nprintf "zzprobe output\\n"\nzzq com\n'; \
      sleep 1; printf 'exit\n'; } \
    | script_shell /tmp/namo_rc_out.sh 2>&1 | tr -d '\r')
  printf '%s' "$cap" | grep -q 'ISATTY_OK' \
    && ok "commands still see a terminal on stdout" \
    || bad "isatty(1) is false with capture on -- the pty is not working"
  printf '%s' "$cap" | grep -q 'zzprobe output' \
    && ok "their output still reaches the screen" || bad "output lost on the way out"
  sleep 0.5
  grep -q 'zzprobe output' /tmp/namo_reqs.log 2>/dev/null \
    && ok "and is sent to the model with the next line" \
    || bad "captured output never reached a request"
  wait_for_helpers "$daemons_before"
  daemons_after=$(running_helpers)
  if [ "$daemons_before" = "$daemons_after" ]; then
    ok "no relay or daemon left behind by an exited shell"
  else
    bad "a helper outlived its shell"
    diag_text "helpers before shell" "$daemons_before"
    diag_text "helpers after shell" "$daemons_after"
    diag_text "shell transcript bytes" "${#cap}"
    for helper in $daemons_after; do
      case " $daemons_before " in
        *" $helper "*) ;; *) diag_process "$helper" ;;
      esac
    done
  fi
  rm -f /tmp/namo_rc_out.sh
fi

# --------------------------------------------------------------------------
head_ "5d. the line tracker"
# --------------------------------------------------------------------------
# No key is rebound any more: readline echoes the line onto the shell's stdout,
# which is the relay's pty, and the relay follows it from there. These drive
# that pty directly with the bytes readline actually writes -- the marker at
# the end of the prompt, the characters, BS, ESC[K, ESC[n@, ESC[nP, ESC[nD.
TT=$(mktemp -d)
mkfifo -m 600 "$TT/fifo"
exec {TFD}<>"$TT/fifo"
NAMO_RELAY=1 NAMO_OUTPUT=3 NAMO_PTSFILE="$TT/pts" NAMO_OUTFILE="$TT/out" \
  NAMO_RELAY_PIDFILE="$TT/pid" NAMO_TTY="$TT/tty" NAMO_FIFO="$TT/fifo" \
  NAMO_SHELL_PID=$$ "$BIN" </dev/null >/dev/null 2>&1
sleep 0.4
tpts=$(cat "$TT/pts" 2>/dev/null)
tpid=$(cat "$TT/pid" 2>/dev/null)
GS=$(printf '\035')

# Everything the relay would send, drained for one command's worth of typing.
# The last record is the line as it stood when the typing stopped.
typed() {  # typed <bytes to write into the pty>  -> the last record's line
  printf '%s' "$1" > "$tpts"
  sleep 0.35
  local rec last=""
  while IFS= read -r -t 0.2 -u "$TFD" rec; do last=$rec; done
  printf '%s' "${last#*$'\t'}"
}

if [ -n "$tpts" ] && [ -n "$tpid" ]; then
  res=$(typed "T\$ ${GS}git com")
  [ "$res" = "git com" ] && ok "the line typed at a prompt reaches the daemon" \
                         || bad "tracked [$res]"
  # The prompt itself is not part of it: the marker is what starts the line.
  case "$res" in *"T\$"*) bad "the prompt leaked into the tracked line" ;;
                 *) ok "the prompt is not mistaken for the line" ;; esac

  res=$(typed "$(printf '\010\033[K')")
  [ "$res" = "git co" ] && ok "backspace shortens it (BS, ESC[K)" || bad "after BS: [$res]"

  # Readline opens a gap before it writes into the middle of a line.
  res=$(typed "$(printf '\033[2D\033[1@X')")
  [ "$res" = "git Xco" ] && ok "an insert in the middle lands where the cursor is" \
                         || bad "after insert: [$res]"
  res=$(typed "$(printf '\033[3P')")
  [ "$res" = "git X" ] && ok "a delete closes the gap (ESC[nP)" || bad "after delete: [$res]"

  # Enter ends it, and what comes next is not a line being typed.
  res=$(typed "$(printf '\r\n')stray output here")
  [ -z "$res" ] && ok "nothing is tracked once the line has been accepted" \
                || bad "output after Enter tracked as typing: [$res]"

  # And Enter says so at once: one empty record the moment the line is over,
  # not at the next prompt. An answer still in flight for the finished line is
  # dropped because of it, instead of being painted under an empty prompt
  # seconds later -- the slower the model, the wider that window.
  printf '%s' "T\$ ${GS}git pu" > "$tpts"; sleep 0.35
  while IFS= read -r -t 0.2 -u "$TFD" rec; do :; done
  printf '\r\n' > "$tpts"; sleep 0.35
  n=0; last="x"
  while IFS= read -r -t 0.2 -u "$TFD" rec; do n=$((n+1)); last=$rec; done
  [ "$n" = 1 ] && [ "$last" = "$(printf '\t')" ] \
    && ok "Enter posts one line-over record immediately" \
    || bad "Enter posted $n records (last: [$last])"
  # The newlines of the command's own output must not repeat it.
  printf 'output line one\noutput line two\n' > "$tpts"; sleep 0.35
  m=0
  while IFS= read -r -t 0.2 -u "$TFD" rec; do m=$((m+1)); done
  [ "$m" = 0 ] && ok "a command's own output does not repeat it" \
               || bad "output newlines posted $m extra records"

  # Reverse search repaints with a prompt of its own, which carries no marker:
  # the CR that starts it is where the tracker gives up.
  res=$(typed "T\$ ${GS}git st$(printf '\r\033[K')(reverse-i-search)\`': ls")
  case "$res" in
    *reverse*|*": ls"*) bad "a readline prompt was tracked as typing: [$res]" ;;
    *) ok "a repaint with no marker stops the tracking" ;;
  esac

  # And a real prompt after it starts a clean line again.
  res=$(typed "T\$ ${GS}echo hi")
  [ "$res" = "echo hi" ] && ok "the next prompt arms the tracker again" || bad "after re-arm: [$res]"

  # A record from the relay has no cwd in it: the relay watches a pty, not a
  # shell, and the daemon fills the field in from the last prompt.
  printf '%s' "T\$ ${GS}whoami" > "$tpts"; sleep 0.35
  rec=""; while IFS= read -r -t 0.2 -u "$TFD" line; do rec=$line; done
  case "$rec" in $'\t'*) ok "the cwd field is left for the daemon to fill" ;;
                 *) bad "relay record carries a cwd: [$rec]" ;; esac

  grep -q "$GS" "$TT/tty" && bad "the prompt marker reached the screen" \
                          || ok "the prompt marker never reaches the screen"
  grep -q 'git com' "$TT/tty" && ok "what was typed still reaches the terminal" \
                              || bad "typing lost on the way through"
else
  bad "the relay did not start for the tracker tests"
fi
exec {TFD}>&-
kill "$tpid" 2>/dev/null
rm -rf "$TT"

# The whole chain, in a real shell on a real pty: type, and a hint appears --
# with no key bound, so bash never repaints the row on the way there.
if command -v script >/dev/null 2>&1; then
  cat > /tmp/namo_rc_trk.sh <<RCEOF
export NAMO_BIN="$PWD/$BIN"
export NAMO_MIN_GAP=0 NAMO_DEBOUNCE=0.3 NAMO_CACHE=0
export NAMO_ENDPOINT="$NAMO_ENDPOINT"
export ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
source "$PWD/shell/namo_complete.bash"
PS1='T\$ '
RCEOF
  trkcap=$( { printf 'zzhint com'; sleep 2.5; printf '\nexit\n'; sleep 0.5; } \
    | script_shell /tmp/namo_rc_trk.sh 2>&1 | tr -d '\r' )
  printf '%s' "$trkcap" | grep -q 'hint: git commit' \
    && ok "typing into a real shell paints a hint, with nothing rebound" \
    || bad "no hint painted: $(printf '%s' "$trkcap" | cat -v | tail -3)"
  printf '%s' "$trkcap" | grep -q 'zzhint com' \
    && ok "what was typed is still echoed by readline" || bad "typing never echoed"
  # The flicker itself: bash repaints the prompt row once per keystroke around a
  # `bind -x` handler, so ten characters used to mean ten prompts on the wire.
  prompts=$(printf '%s' "$trkcap" | grep -o 'T\$' | grep -c .)
  [ "${prompts:-99}" -le 5 ] \
    && ok "the prompt is not repainted per keystroke ($prompts times for 10 characters)" \
    || bad "$prompts prompt repaints for 10 characters -- the row is being redrawn again"
  # NAMO_OUTPUT=0 keeps the relay -- the line comes down that pty too -- and
  # only stops it keeping what commands print.
  sed 's/NAMO_CACHE=0/NAMO_CACHE=0 NAMO_OUTPUT=0/' /tmp/namo_rc_trk.sh > /tmp/namo_rc_trk0.sh
  rm -f /tmp/namo_req.json
  zerocap=$( { printf 'zzquiet com'; sleep 2.5; printf '\nexit\n'; sleep 0.5; } \
    | script_shell /tmp/namo_rc_trk0.sh 2>&1 | tr -d '\r' )
  printf '%s' "$zerocap" | grep -q 'hint: git commit' \
    && ok "hints still work with NAMO_OUTPUT=0" \
    || bad "no hint with output recording off"
  grep -q '<output>' /tmp/namo_req.json 2>/dev/null \
    && bad "output was recorded with NAMO_OUTPUT=0" \
    || ok "and nothing the commands printed is kept"
  rm -f /tmp/namo_rc_trk.sh /tmp/namo_rc_trk0.sh
fi

# The daemon's half of the same deal: a record with an empty cwd is served in
# the directory the shell reported at its last prompt.
DT2=$(mktemp -d)
mkfifo -m 600 "$DT2/fifo" "$DT2/reply"
: > "$DT2/hist"
exec {D2}<>"$DT2/fifo"
rm -f /tmp/namo_req.json
NAMO_SHELL=zsh NAMO_DAEMON=1 NAMO_FIFO="$DT2/fifo" NAMO_REPLY="$DT2/reply" NAMO_HISTFILE="$DT2/hist" \
  NAMO_PIDFILE="$DT2/pid" NAMO_TTY="$DT2/tty" NAMO_DEBOUNCE=0.2 NAMO_QUIET=0.05 \
  NAMO_CACHE=0 "$BIN" </dev/null >/dev/null 2>&1
d2pid=$(cat "$DT2/pid" 2>/dev/null)
printf '%s\t%s\n' "$PWD" "" >&"$D2"          # the shell, at a prompt, in $PWD
sleep 0.2
printf '\t%s\n' "zzcwd probe" >&"$D2"        # the relay, with a line and no cwd
sleep 1.2
if [ -f /tmp/namo_req.json ]; then
  python3 - "$PWD" <<'PYCWD' && ok "the daemon fills the cwd in from the last prompt" \
                             || bad "cwd not carried over to a relay record"
import json, sys
c = json.load(open('/tmp/namo_req.json'))['messages'][0]['content']
assert '<cwd>' + sys.argv[1] + '</cwd>' in c, c[:400]
assert '<shell>zsh</shell>' in c, c[:400]
PYCWD
else
  bad "a relay record never reached the API"
fi
exec {D2}>&-
sleep 0.5
kill "$d2pid" 2>/dev/null
rm -rf "$DT2"

# --------------------------------------------------------------------------
head_ "6. packaging"
# --------------------------------------------------------------------------
# Build the release tarball the same way .github/workflows/release.yml does,
# then install from it into a temp prefix -- so a packaging break is caught
# here rather than at tag time.

FAKEBIN=$(mktemp -d)
printf '#!/usr/bin/env bash\nprintf "unsupported\\n"\n' > "$FAKEBIN/uname"
chmod +x "$FAKEBIN/uname"
unsupported=$(PATH="$FAKEBIN:$PATH" sh ./install.sh --version dev 2>&1); rc=$?
printf '%s\n' "$unsupported" | grep -q 'no prebuilt binary for unsupported/unsupported' && \
  [ "$rc" = 1 ] && ! printf '%s\n' "$unsupported" | grep -q downloading \
  && ok "unsupported platforms fail before downloading" \
  || bad "unsupported platform handling (rc=$rc output=$unsupported)"

PKGTMP=$(mktemp -d)
PNAME=$(./packaging/package.sh v0.0.0-test "$PKGTMP" 2>/dev/null)

[ -s "$PKGTMP/$PNAME.tar.gz" ] && ok "release tarball builds" || bad "tarball missing"
expected=$(awk -v file="$PNAME.tar.gz" '$2 == file { print $1 }' "$PKGTMP/SHA256SUMS")
if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$PKGTMP/$PNAME.tar.gz" | awk '{print $1}')
else
  actual=$(shasum -a 256 "$PKGTMP/$PNAME.tar.gz" | awk '{print $1}')
fi
[ -n "$expected" ] && [ "$actual" = "$expected" ] \
  && ok "checksum verifies" || bad "checksum failed"

mkdir -p "$PKGTMP/x"
tar -C "$PKGTMP/x" -xzf "$PKGTMP/$PNAME.tar.gz"
"$PKGTMP/x/$PNAME/install.sh" --prefix "$PKGTMP/prefix" --no-rc >/dev/null 2>&1
[ -x "$PKGTMP/prefix/bin/namo_complete" ] \
  && ok "installs a runnable binary into the prefix" || bad "binary not installed"
[ -f "$PKGTMP/prefix/share/namo_complete/namo_complete.bash" ] && \
[ -f "$PKGTMP/prefix/share/namo_complete/namo_complete.zsh" ] && \
[ ! -e "$PKGTMP/prefix/share/namo_complete/namo_live.bash" ] \
  && ok "both shell integrations are installed" || bad "shell integrations are incomplete"

out=$(env -u ANTHROPIC_API_KEY NAMO_LINE='gi' NAMO_CWD="$PWD" \
        "$PKGTMP/prefix/bin/namo_complete" </dev/null 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] \
  && ok "installed binary runs" || bad "installed binary misbehaved (rc=$rc out=$out)"

# The whole point of stamping: an installed copy can be asked what it is,
# without the source tree it came from.
"$PKGTMP/prefix/bin/namo_complete" --version 2>/dev/null | grep -q '^namo_complete .*commit ' \
  && ok "the installed binary reports its version and commit" \
  || bad "installed binary has no --version"
# Captured rather than piped: `grep -q` closes the pipe on its first match, and
# the installer runs under `set -o pipefail` here.
instout=$(env BASHRC=/dev/null "$PKGTMP/x/$PNAME/install.sh" \
            --prefix "$PKGTMP/p4" --no-rc 2>/dev/null)
printf '%s\n' "$instout" | grep -q 'namo_complete .*commit ' \
  && ok "the installer prints the build it just installed" \
  || bad "install output does not say which build landed"

# Startup-file handling follows the platform default, stays idempotent, and
# honours --no-rc.
if [ "$TEST_OS" = Darwin ]; then
  RC_FILE="$PKGTMP/zshrc"; RC_PATTERN=namo_complete.zsh; RC_LABEL=.zshrc
else
  RC_FILE="$PKGTMP/bashrc"; RC_PATTERN=namo_complete.bash; RC_LABEL=.bashrc
fi
: > "$RC_FILE"
env BASHRC="$RC_FILE" ZSHRC="$RC_FILE" "$PKGTMP/x/$PNAME/install.sh" --prefix "$PKGTMP/p2" >/dev/null 2>&1
env BASHRC="$RC_FILE" ZSHRC="$RC_FILE" "$PKGTMP/x/$PNAME/install.sh" --prefix "$PKGTMP/p2" >/dev/null 2>&1
n=$(grep -c "$RC_PATTERN" "$RC_FILE" 2>/dev/null || echo 0)
[ "$n" = 1 ] && ok "adds the source line to $RC_LABEL exactly once" \
             || bad "expected 1 source line in $RC_LABEL, found $n"

RC_FILE="${RC_FILE}2"
: > "$RC_FILE"
env BASHRC="$RC_FILE" ZSHRC="$RC_FILE" "$PKGTMP/x/$PNAME/install.sh" --prefix "$PKGTMP/p3" --no-rc >/dev/null 2>&1
[ ! -s "$RC_FILE" ] && ok "--no-rc leaves $RC_LABEL untouched" \
                       || bad "--no-rc modified $RC_LABEL"

res=$(NAMO_BIN="$PKGTMP/prefix/bin/namo_complete" bash -i -c '
  source '"$PKGTMP"'/prefix/share/namo_complete/namo_complete.bash 2>/dev/null
  _namo_find_binary' 2>/dev/null)
[ "$res" = "$PKGTMP/prefix/bin/namo_complete" ] \
  && ok "integration resolves the installed binary" || bad "bin resolution failed ($res)"
rm -rf "$PKGTMP"

# --------------------------------------------------------------------------
if [ "$LIVE" = "--live" ]; then
  head_ "7. live Anthropic API call"
  unset NAMO_ENDPOINT
  if [ -z "${ANTHROPIC_API_KEY_REAL:-}" ]; then
    bad "no real key: put ANTHROPIC_API_KEY in .env for --live"
  else
    export ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY_REAL"
    start=$(ns_now)
    out=$(payload | env NAMO_LINE='git com' NAMO_CWD="$PWD" NAMO_CACHE=0 "$BIN" 2>/tmp/namo_live_err)
    ms=$(( ($(ns_now) - start) / 1000000 ))
    if [ -s /tmp/namo_live_err ]; then
      bad "live call reported an error: $(head -1 /tmp/namo_live_err)"
    elif printf '%s' "$out" | grep -q '^git '; then
      ok "live call returned real completions in ${ms}ms"
      printf '%s\n' "$out" | sed 's/^/        /'
      # The default Opus model gets the wider target its stronger answers
      # require. Haiku remains the lower-latency opt-in.
      target=5000
      case "${NAMO_MODEL:-claude-opus-5}" in
        *haiku*) target=1500 ;;
        *) ;;
      esac
      [ "$ms" -lt "$target" ] && ok "latency under the ${target}ms target for ${NAMO_MODEL:-claude-opus-5}" \
                              || bad "latency ${ms}ms exceeds the ${target}ms target for ${NAMO_MODEL:-claude-opus-5}"
    else
      bad "live call returned no usable completion (got: ${out:-<empty>})"
    fi
  fi
fi


# ---- an answer that outlives its line is dropped, not painted ----
# The user typed, paused, and pressed Enter while the call was still in
# flight. The relay posts a line-over record at Enter (see 5d); the daemon
# sees it waiting when the late answer lands, and leaves the row alone
# instead of painting a hint under a prompt whose line is empty.
PORT4=$(( PORT + 3 ))
cat > /tmp/namo_mock_slow.py <<PY
import http.server, json, time
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('content-length', 0)))
        time.sleep(1.5)
        r = {"id":"m","type":"message","role":"assistant","model":"claude-haiku-4-5",
             "content":[{"type":"text","text":"git commit"}],
             "stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
        o = json.dumps(r).encode()
        self.send_response(200); self.send_header('content-type','application/json')
        self.send_header('content-length', str(len(o))); self.end_headers(); self.wfile.write(o)
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', $PORT4), H).serve_forever()
PY
python3 /tmp/namo_mock_slow.py & SLOW_PID=$!
sleep 1
RT=$(mktemp -d)
mkfifo -m 600 "$RT/fifo"
: > "$RT/hist"
exec {RFD}<>"$RT/fifo"
NAMO_DAEMON=1 NAMO_FIFO="$RT/fifo" NAMO_HISTFILE="$RT/hist" NAMO_PIDFILE="$RT/pid" \
  NAMO_TTY="$RT/tty" NAMO_DEBOUNCE=0.2 NAMO_QUIET=0.05 NAMO_CACHE=0 NAMO_MIN_GAP=0 \
  NAMO_ENDPOINT="http://127.0.0.1:$PORT4/v1/messages" "$BIN" </dev/null >/dev/null 2>&1
sleep 0.3
printf '%s\tgit com\n' "$PWD" >&$RFD
sleep 0.7                      # the call is now in flight; Enter goes by:
printf '\t\n' >&$RFD
sleep 2.0
grep -q 'hint: ' "$RT/tty" \
  && bad "an answer for a finished line was painted under the empty prompt" \
  || ok "an answer that outlives its line is dropped"
[ -s "$RT/pid" ] && kill "$(cat "$RT/pid")" 2>/dev/null
exec {RFD}>&-
rm -rf "$RT" /tmp/namo_mock_slow.py
kill "$SLOW_PID" 2>/dev/null

# --------------------------------------------------------------------------
head_ "8. thinking blocks, and failures the user can see"
# --------------------------------------------------------------------------
# Two things that only show up once NAMO_MODEL names a current model:
# the completions are no longer in content[0], and a request the API refuses
# used to be indistinguishable from having nothing to suggest.
PORT8=$(( PORT + 4 ))
kill_mock8() {
  if [ -n "${MOCK8_PID:-}" ]; then
    kill "$MOCK8_PID" 2>/dev/null
    wait "$MOCK8_PID" 2>/dev/null
  fi
  MOCK8_PID=""
}

# ---- content[0] is a thinking block, as it is on Opus 5 ----
cat > /tmp/namo_mock8.py <<PY
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('content-length', 0)))
        mode = open('/tmp/namo_mock8_mode').read().strip()
        if mode == 'error':
            r = {"type":"error","error":{"type":"invalid_request_error",
                 "message":"\`temperature\` is deprecated for this model."}}
        else:
            # Thinking first, exactly as the real API orders it.
            r = {"id":"m","type":"message","role":"assistant","model":"claude-opus-5",
                 "content":[{"type":"thinking","thinking":"","signature":"sig"},
                            {"type":"text","text":"git commit\ngit commit --amend"}],
                 "stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
        o = json.dumps(r).encode()
        self.send_response(200); self.send_header('content-type','application/json')
        self.send_header('content-length', str(len(o))); self.end_headers(); self.wfile.write(o)
    def log_message(self, *a): pass
class S(http.server.HTTPServer):
    # A mock from an interrupted run can still hold the port in TIME_WAIT,
    # and every assertion below would then fail for a reason that has
    # nothing to do with what is being tested.
    allow_reuse_address = True
S(('127.0.0.1', $PORT8), H).serve_forever()
PY

echo thinking > /tmp/namo_mock8_mode
python3 /tmp/namo_mock8.py & MOCK8_PID=$!
sleep 1.2
kill -0 "$MOCK8_PID" 2>/dev/null \
  || bad "second mock did not start (port $PORT8 busy?); section 8 results are meaningless"
out=$(payload | env NAMO_LINE='git com' NAMO_CWD="$PWD" NAMO_CACHE=0 \
      NAMO_MODEL=claude-opus-5 NAMO_ENDPOINT="http://127.0.0.1:$PORT8/v1/messages" \
      "$BIN" 2>/dev/null)
printf '%s' "$out" | grep -q '^git commit$' \
  && ok "completions found past a leading thinking block" \
  || bad "a thinking block at content[0] hid the completions (got: ${out:-<empty>})"

# ---- a refused request reaches the row instead of vanishing ----
echo error > /tmp/namo_mock8_mode

err=$(payload | env NAMO_LINE='git com' NAMO_CWD="$PWD" NAMO_CACHE=0 \
      NAMO_ENDPOINT="http://127.0.0.1:$PORT8/v1/messages" "$BIN" 2>&1 >/dev/null)
printf '%s' "$err" | grep -q 'deprecated for this model' \
  && ok "the one-shot path prints the API's own message" \
  || bad "one-shot path swallowed the API error (got: ${err:-<empty>})"

# The daemon has no stderr: it is started with 2>/dev/null by the shell
# integration, so the hint row is the only channel it has.
ET=$(mktemp -d)
mkfifo -m 600 "$ET/fifo" "$ET/reply"
printf 'git status\n' > "$ET/hist"
exec {EFD}<>"$ET/fifo"
exec {ERFD}<>"$ET/reply"
NAMO_DAEMON=1 NAMO_FIFO="$ET/fifo" NAMO_REPLY="$ET/reply" NAMO_HISTFILE="$ET/hist" NAMO_PIDFILE="$ET/pid" \
  NAMO_TTY="$ET/tty" NAMO_DEBOUNCE=0.2 NAMO_QUIET=0.05 NAMO_CACHE=0 NAMO_MIN_GAP=0 \
  NAMO_ENDPOINT="http://127.0.0.1:$PORT8/v1/messages" "$BIN" </dev/null >/dev/null 2>&1
sleep 0.3
printf '%s\t%s\n' "$PWD" "git co" >&$EFD
sleep 1.5
grep -q 'error: .*deprecated for this model' "$ET/tty" \
  && ok "the daemon draws the failure in the hint row" \
  || bad "the daemon failed silently, which is the bug this test exists for"
grep -q 'hint: ' "$ET/tty" \
  && bad "a hint was drawn for a call that failed" \
  || ok "no hint row is drawn alongside the error"

# A synchronous ask failure must travel back to the shell instead of looking
# like a successful response with zero candidates.
printf '%s\t\002%s\t%s\t%s\n' "$PWD" 84 a "show files" >&$EFD
sync_error=""
IFS= read -r -t 5 -u "$ERFD" sync_error
printf '%s' "$sync_error" | grep -q $'^84\tE\t.*deprecated for this model' \
  && ok "the synchronous reply carries the API error" || bad "the synchronous reply hid the API error"
# And it must go away again once the API answers.
echo thinking > /tmp/namo_mock8_mode
error_end=$(wc -c < "$ET/tty")
printf '%s\t%s\n' "$PWD" "git com" >&$EFD
hint_after_error=0
for _ in {1..50}; do
  new_paints=$(tail -c "+$((error_end + 1))" "$ET/tty" 2>/dev/null)
  if printf '%s' "$new_paints" | grep -q 'hint: '; then
    hint_after_error=1
    break
  fi
  sleep 0.1
done
# Only bytes written after the error assertion count, so the old paint still
# present in the append-only tty log cannot satisfy this check.
if [ "$hint_after_error" = 1 ]; then
  ok "the error row clears once a call works again"
else
  bad "the error row survived a call that succeeded"
  diag_file "error daemon tty" "$ET/tty"
  diag_file "latest request" /tmp/namo_req.json
  diag_requests /tmp/namo_req.json
  diag_process "$(cat "$ET/pid" 2>/dev/null)"
fi

[ -s "$ET/pid" ] && kill "$(cat "$ET/pid")" 2>/dev/null
exec {EFD}>&-
exec {ERFD}>&-
rm -rf "$ET"
kill_mock8

rm -f /tmp/namo_mock8.py /tmp/namo_mock8_mode

# --------------------------------------------------------------------------
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
