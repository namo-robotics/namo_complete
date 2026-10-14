#!/usr/bin/env bash
# Check the workspace-only CLI and release packaging without network access.
set -uo pipefail
cd "$(dirname "$0")"
BIN=./bin/namo_complete
TEST_OS=$(uname -s)
pass=0; fail=0
ok() { printf 'PASS %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }
out=$("$BIN" </dev/null 2>&1); rc=$?
[[ $rc == 125 && $out == *'requires an interactive terminal'* ]] && ok 'redirected input cannot start a legacy mode' || bad 'terminal requirement'
"$BIN" --version | grep -q '^namo_complete ' && ok 'version works without a terminal' || bad 'version'
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
  command -v -- "$NAMO_BIN"' 2>/dev/null)
[ "$res" = "$PKGTMP/prefix/bin/namo_complete" ] \
  && ok "installed binary resolves" || bad "bin resolution failed ($res)"
rm -rf "$PKGTMP"

rm -rf "$FAKEBIN"
printf '%s passed, %s failed\n' "$pass" "$fail"
[[ $fail == 0 ]]
