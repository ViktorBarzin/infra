#!/usr/bin/env bash
# Pure-bash tests for the t3 updater's install, activation, rollback, prune,
# health-check and busy-unit helpers in t3-safe-restart.sh. No root, no bats,
# no Docker: npm and t3 are fakes, the symlink and version dirs live in a temp dir.
#
# What they pin (2026-10-19):
#   - a build is installed into its own prefix and switched in with one rename,
#     so running serves never see their files change (the 2026-09-28 404s);
#   - the health check waits for a slow first start instead of a fixed 30s, ends
#     early when the serve dies or logs a migration error, and stops the whole
#     process group, because the 0.1.0 launcher does not forward signals and
#     killing it alone orphaned the native server on the smoke port;
#   - unit_busy looks at the whole cgroup, since 0.1.0's agents are not direct
#     children of the unit's MainPID.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
holders=""
cleanup() { for p in $holders; do kill "$p" 2>/dev/null; done; pkill -f "$TMP/" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

mkdir -p "$TMP/bin"
: >"$TMP/calls"
printf '#!/bin/sh\necho "logger $*" >>"%s/calls"\n' "$TMP" >"$TMP/bin/logger"

# Fake server: GET / -> 200, POST /api/auth/browser-session -> t3_session cookie.
cat >"$TMP/fake-server.py" <<'EOF'
import http.server, os, sys, time
mode = os.environ.get("FAKE_MODE", "ok")
if mode == "exit":
    sys.exit(1)
if mode == "migerr":
    print("PersistenceSqlError: migration failed", flush=True)
    time.sleep(3600)
time.sleep(float(os.environ.get("FAKE_DELAY", "0")))
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def do_POST(self):
        self.send_response(200); self.send_header("Set-Cookie", "t3_session=x; Path=/"); self.end_headers()
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF

# Fake launcher, shaped like 0.1.0's: it starts the real server as a child and
# does not forward SIGTERM, so killing only the launcher orphans the server.
cat >"$TMP/fake-t3" <<EOF
#!/usr/bin/env bash
here="\$(dirname "\$(readlink -f "\$0")")"
case "\$1" in
  --version) echo "t3 v\$(cat "\$here/VERSION")" ;;
  auth) echo '{"credential":"cred123"}' ;;
  serve) port=""; while [ \$# -gt 0 ]; do [ "\$1" = --port ] && port="\$2"; shift; done
         python3 -I "$TMP/fake-server.py" "\$port" &
         wait ;;
esac
EOF
chmod +x "$TMP/fake-t3"

# Fake npm: `npm i --prefix DIR t3@VER` lays out node_modules like the real one.
cat >"$TMP/bin/npm" <<EOF
#!/usr/bin/env bash
echo "npm \$*" >>"$TMP/calls"
[ "\${FAKE_NPM_FAIL:-0}" = 1 ] && exit 1
if [ "\$1 \$2" = "i --prefix" ]; then
  d="\$3"; v="\${4#t3@}"
  mkdir -p "\$d/node_modules/t3/bin" "\$d/node_modules/.bin"
  cp "$TMP/fake-t3" "\$d/node_modules/t3/bin/t3.js"; echo "\$v" >"\$d/node_modules/t3/bin/VERSION"
  ln -s ../t3/bin/t3.js "\$d/node_modules/.bin/t3"
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/bin/logger" "$TMP/bin/npm"
export PATH="$TMP/bin:$PATH"

export T3_VERSIONS_DIR="$TMP/versions" T3_LINK="$TMP/usr-bin/t3" T3_LEGACY_DIR="$TMP/legacy/node_modules/t3"
export T3_SMOKE_PORT=$((20000 + RANDOM % 20000)) T3_TMPDIR="$TMP" T3_STATE_DIR="$TMP/state"
mkdir -p "$TMP/usr-bin"
# shellcheck source=/dev/null
. "$HERE/scripts/t3-safe-restart.sh"

pass=0; fail=0
ok()   { if "$@"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $*"; fi; }
notok(){ if "$@"; then fail=$((fail+1)); echo "FAIL (expected non-zero): $*"; else pass=$((pass+1)); fi; }
eq()   { if [ "$1" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: got '$1' want '$2' ($3)"; fi; }
no_orphan() { ! pgrep -f "fake-server.py $T3_SMOKE_PORT" >/dev/null; }

# --- install_version: own prefix, staged, reusable; a failed install leaves nothing ---
ok    install_version 0.2.0
ok    test -x "$(version_entry 0.2.0)"
eq    "$(ls -A "$T3_VERSIONS_DIR" | grep -c staging)" "0" "no staging dir left behind"
: >"$TMP/calls"; ok install_version 0.2.0
eq    "$(grep -c '^npm' "$TMP/calls")" "0" "a complete install is reused, not refetched"
FAKE_NPM_FAIL=1 notok install_version 0.9.9
ok    test ! -e "$T3_VERSIONS_DIR/0.9.9"
eq    "$(ls -A "$T3_VERSIONS_DIR" | grep -c staging)" "0" "failed install cleaned up"
notok version_entry 0.9.9

# --- activate_version: one rename, the link runs the chosen build ---
ok    activate_version 0.2.0
eq    "$("$T3_LINK" --version)" "t3 v0.2.0" "link runs 0.2.0"
ok    install_version 0.3.0
ok    activate_version 0.3.0
eq    "$("$T3_LINK" --version)" "t3 v0.3.0" "link switched to 0.3.0"
notok activate_version 0.9.9
eq    "$("$T3_LINK" --version)" "t3 v0.3.0" "failed activation leaves the link alone"
eq    "$(ls "$TMP/usr-bin")" "t3" "no temp link left beside T3_LINK"

# --- rollback_binary: a symlink swap to last-good, npm -g only as a fallback ---
: >"$TMP/calls"; target=0.3.0 last_good=0.2.0
ok    rollback_binary
eq    "$("$T3_LINK" --version)" "t3 v0.2.0" "rolled back to 0.2.0"
eq    "$(grep -c '^npm' "$TMP/calls")" "0" "no npm call for an installed last-good"
# the legacy npm -g install (every build before this change) is a valid target
mkdir -p "$T3_LEGACY_DIR/dist"; cp "$TMP/fake-t3" "$T3_LEGACY_DIR/dist/bin.mjs"; echo 0.0.38 >"$T3_LEGACY_DIR/dist/VERSION"
printf '{\n  "name": "t3",\n  "version": "0.0.38",\n  "bin": {}\n}\n' >"$T3_LEGACY_DIR/package.json"
last_good=0.0.38
ok    rollback_binary
eq    "$("$T3_LINK" --version)" "t3 v0.0.38" "rolled back to the legacy global install"
: >"$TMP/calls"; last_good=0.0.1
ok    rollback_binary
eq    "$(grep -c '^npm i -g t3@0.0.1' "$TMP/calls")" "1" "unknown last-good falls back to npm -g"

# --- prune_versions: newest N, named ones, and in-use ones survive ---
for v in 0.4.0 0.5.0 0.6.0; do install_version "$v"; done
touch -d '-5 days' "$T3_VERSIONS_DIR/0.2.0"; touch -d '-4 days' "$T3_VERSIONS_DIR/0.3.0"
touch -d '-3 days' "$T3_VERSIONS_DIR/0.4.0"; touch -d '-2 days' "$T3_VERSIONS_DIR/0.5.0"
( exec -a "$T3_VERSIONS_DIR/0.3.0/node_modules/t3/held" sleep 300 ) & holders="$holders $!"
T3_KEEP_VERSIONS=2 prune_versions 0.2.0
ok    test -d "$T3_VERSIONS_DIR/0.6.0"     # newest
ok    test -d "$T3_VERSIONS_DIR/0.5.0"     # second newest
ok    test -d "$T3_VERSIONS_DIR/0.2.0"     # named (last-good)
ok    test -d "$T3_VERSIONS_DIR/0.3.0"     # a running process uses it
ok    test ! -e "$T3_VERSIONS_DIR/0.4.0"   # none of the above

# --- health_check: waits for a slow start, then stops the whole group ---
start=$(date +%s)
FAKE_DELAY=4 SMOKE_READY_TIMEOUT=60 ok health_check "$(version_entry 0.6.0)"
ok    test $(( $(date +%s) - start )) -ge 4     # it waited past the slow start
ok    no_orphan
ok    test "$(ls -d "$TMP"/tmp.* 2>/dev/null | wc -l)" -eq 0   # scratch dir removed

# never ready: gives up at the timeout and leaves no server behind
start=$(date +%s)
FAKE_DELAY=600 SMOKE_READY_TIMEOUT=4 notok health_check "$(version_entry 0.6.0)"
ok    test $(( $(date +%s) - start )) -lt 20
ok    no_orphan
grep -q 'wait=timeout/4s' "$TMP/calls"; eq "$?" 0 "timeout is named in the log line"

# serve exits at once: no point waiting out the timeout
start=$(date +%s)
FAKE_MODE=exit SMOKE_READY_TIMEOUT=120 notok health_check "$(version_entry 0.6.0)"
ok    test $(( $(date +%s) - start )) -lt 20
ok    no_orphan

# migration error in the log: fail without waiting, report migerr=1
start=$(date +%s)
FAKE_MODE=migerr SMOKE_READY_TIMEOUT=120 notok health_check "$(version_entry 0.6.0)"
ok    test $(( $(date +%s) - start )) -lt 20
ok    no_orphan
grep -q 'migerr=1 wait=migration-error' "$TMP/calls"; eq "$?" 0 "migration error is named in the log line"

# --- unit_busy: an agent anywhere in the unit's cgroup counts ---
cat >"$TMP/bin/systemctl" <<'EOF'
#!/bin/sh
echo "/system.slice/t3-serve@u.service"
EOF
chmod +x "$TMP/bin/systemctl"
export T3_CGROUP_ROOT="$TMP/cg"; cg="$TMP/cg/system.slice/t3-serve@u.service"; mkdir -p "$cg/sub"
( exec -a t3 sleep 300 ) & srv=$!; holders="$holders $srv"
echo "$srv" >"$cg/cgroup.procs"; : >"$cg/sub/cgroup.procs"
notok unit_busy t3-serve@u.service                       # only the server: idle
( exec -a claude sleep 300 ) & agent=$!; holders="$holders $agent"
echo "$agent" >"$cg/sub/cgroup.procs"
ok    unit_busy t3-serve@u.service                       # agent in a nested cgroup: busy
: >"$cg/sub/cgroup.procs"
( exec -a "/x/t3 serve --host 0.0.0.0 --base-dir /home/claude/.t3" sleep 300 ) & s2=$!; holders="$holders $s2"
echo "$s2" >"$cg/sub/cgroup.procs"
notok unit_busy t3-serve@u.service                       # a serve whose args mention claude is not an agent

echo; echo "t3-autoupdate-install: pass=$pass fail=$fail"
[ "$fail" = 0 ]
