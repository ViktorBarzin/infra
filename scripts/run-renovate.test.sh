#!/bin/bash
# Tests for stacks/renovate/files/run-renovate.sh (the Renovate CronJob wrapper).
# A fake `renovate` on PATH stands in for the real binary, and a small node HTTP
# server stands in for Pushgateway and records every push body.
# Run: bash scripts/run-renovate.test.sh   (needs bash and node; no cluster access)
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WRAPPER="$ROOT/stacks/renovate/files/run-renovate.sh"
WORK=$(mktemp -d)
trap 'kill "$PGW_PID" 2>/dev/null; rm -rf "$WORK"' EXIT

# One fake server for everything the wrapper calls:
#   Pushgateway   GET /api/v1/metrics -> 404 (no rails hold), POST -> append body
#   Prometheus    GET /api/v1/query   -> etcd fsync p99 from $WORK/fsync (default 0.05),
#                                        firing etcd alert count from $WORK/alerts (default 0);
#                                        $WORK/prom_down makes it answer 500
#   Woodpecker    GET /api/repos/82/pipelines -> JSON from $WORK/pipelines (default [])
node -e '
  const http = require("http"), fs = require("fs");
  const [log, portFile, dir] = process.argv.slice(1);
  const read = (f, d) => { try { return fs.readFileSync(dir + "/" + f, "utf8").trim(); } catch { return d; } };
  http.createServer((req, res) => {
    let b = ""; req.on("data", c => b += c);
    req.on("end", () => {
      const u = new URL(req.url, "http://x");
      if (req.method === "POST") { fs.appendFileSync(log, b + "---\n"); res.statusCode = 200; return res.end(); }
      if (u.pathname === "/api/v1/query") {
        if (fs.existsSync(dir + "/prom_down")) { res.statusCode = 500; return res.end(); }
        const q = u.searchParams.get("query") || "";
        const v = q.includes("etcd_disk_wal_fsync") ? read("fsync", "0.05") : read("alerts", "0");
        const result = (q.startsWith("count(") && v === "0") ? [] : [{ metric: {}, value: [0, v] }];
        res.setHeader("Content-Type", "application/json");
        return res.end(JSON.stringify({ status: "success", data: { resultType: "vector", result } }));
      }
      if (u.pathname === "/api/repos/82/pipelines") {
        res.setHeader("Content-Type", "application/json");
        return res.end(read("pipelines", "[]"));
      }
      res.statusCode = 404; res.end();
    });
  }).listen(0, "127.0.0.1", function () { fs.writeFileSync(portFile, String(this.address().port)); });
' "$WORK/pushes" "$WORK/port" "$WORK" &
PGW_PID=$!
for _ in $(seq 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done
PGW="http://127.0.0.1:$(cat "$WORK/port")"

fails=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

# fake_renovate <body>: writes a fake renovate binary whose script is <body>.
fake_renovate() {
  mkdir -p "$WORK/bin"
  printf '#!/bin/bash\n%s\n' "$1" >"$WORK/bin/renovate"
  chmod +x "$WORK/bin/renovate"
}

run_wrapper() { # -> sets OUT, RC, SECS
  : >"$WORK/pushes"
  local start; start=$(date +%s)
  OUT=$(env -u WOODPECKER_REPO_ID PATH="$WORK/bin:$PATH" PUSHGATEWAY_URL="$PGW" PROMETHEUS_URL="$PGW" \
    ${WP:+WOODPECKER_REPO_ID=82 WOODPECKER_URL=$PGW} \
    RENOVATE_STOP_GRACE=3 RENOVATE_STOP_AFTER_AUTOMERGE="${STOP_AFTER_AUTOMERGE:-}" timeout 60 bash "$WRAPPER" 2>&1)
  RC=$?
  SECS=$(($(date +%s) - start))
}

last_exit_code() { grep '^renovate_last_run_exit_code ' "$WORK/pushes" | tail -1 | awk '{print $2}'; }
has_success() { grep -q '^renovate_last_success_timestamp_seconds ' "$WORK/pushes"; }

# 1. With RENOVATE_STOP_AFTER_AUTOMERGE=1, after the first automerge Renovate
#    restarts its repository job; the wrapper stops it there, records success
#    and exits 0 well before the fake would end.
STOP_AFTER_AUTOMERGE=1
fake_renovate 'echo " INFO: Branch created (repository=viktor/infra, branch=renovate/x)"
echo " INFO: Branch automerged (repository=viktor/infra, branch=renovate/x)"
echo " INFO: Restarting repository job after automerge result (repository=viktor/infra)"
echo " INFO: Repository started (repository=viktor/infra)"
sleep 40
echo "SHOULD-NOT-PRINT"'
run_wrapper
[ "$RC" = 0 ] && pass "stop after automerge: exit 0" || fail "stop after automerge: exit $RC"
[ "$SECS" -lt 15 ] && pass "stop after automerge: ends in ${SECS}s" || fail "stop after automerge: took ${SECS}s"
[ "$(last_exit_code)" = 0 ] && pass "stop after automerge: records 0" || fail "stop after automerge: records '$(last_exit_code)'"
has_success && pass "stop after automerge: success timestamp" || fail "stop after automerge: no success timestamp"
grep -q "Branch automerged" <<<"$OUT" && pass "stop after automerge: passes output through" || fail "stop after automerge: output missing"
grep -q "SHOULD-NOT-PRINT" <<<"$OUT" && fail "stop after automerge: renovate kept running" || pass "stop after automerge: renovate stopped"
grep -q "stopping Renovate before its post-automerge restart" <<<"$OUT" && pass "stop after automerge: says why" || fail "stop after automerge: no explanation line"

# 2. A Renovate that ignores SIGTERM is killed after the grace period.
fake_renovate 'trap "" TERM
echo " INFO: Restarting repository job after automerge result (repository=viktor/infra)"
for i in $(seq 40); do sleep 1; done'
run_wrapper
[ "$RC" = 0 ] && pass "TERM ignored: exit 0" || fail "TERM ignored: exit $RC"
[ "$SECS" -lt 15 ] && pass "TERM ignored: killed after grace (${SECS}s)" || fail "TERM ignored: took ${SECS}s"

unset STOP_AFTER_AUTOMERGE

# 3. A normal run with nothing to land keeps Renovate's exit code and success push.
fake_renovate 'echo " INFO: Repository finished (repository=viktor/infra)"; exit 0'
run_wrapper
[ "$RC" = 0 ] && [ "$(last_exit_code)" = 0 ] && has_success && pass "plain success" || fail "plain success: rc=$RC recorded=$(last_exit_code)"

# 4. A failing run keeps its exit code and pushes no success timestamp.
fake_renovate 'echo " ERROR: something broke"; exit 1'
run_wrapper
[ "$RC" = 1 ] && pass "failure: exit 1" || fail "failure: exit $RC"
[ "$(last_exit_code)" = 1 ] && pass "failure: records 1" || fail "failure: records '$(last_exit_code)'"
has_success && fail "failure: pushed a success timestamp" || pass "failure: no success timestamp"

# 5. Arguments reach renovate unchanged (the runbook's --dry-run=full path).
fake_renovate 'echo "ARGS:$*"'
: >"$WORK/pushes"
OUT=$(env -u WOODPECKER_REPO_ID PATH="$WORK/bin:$PATH" PUSHGATEWAY_URL="$PGW" PROMETHEUS_URL="$PGW" timeout 30 bash "$WRAPPER" --dry-run=full 2>&1)
grep -q "ARGS:--dry-run=full" <<<"$OUT" && pass "args passed through" || fail "args not passed through: $OUT"

# 6. By default the wrapper lets Renovate finish the run after an automerge, so
#    the post-automerge pass refreshes the Dependency Dashboard and the caches.
fake_renovate 'echo " INFO: Branch automerged (repository=viktor/infra, branch=renovate/x)"
echo " INFO: Restarting repository job after automerge result (repository=viktor/infra)"
sleep 2
echo " INFO: Dependency Dashboard updated FINISHED-MARKER"
exit 0'
run_wrapper
[ "$RC" = 0 ] && pass "default: exit 0 after automerge" || fail "default: exit $RC"
grep -q "FINISHED-MARKER" <<<"$OUT" && pass "default: run continues past the automerge restart" || fail "default: run was stopped at the automerge restart"
[ "$(last_exit_code)" = 0 ] && has_success && pass "default: records success" || fail "default: recorded '$(last_exit_code)'"

# 7. Calm gate: a slow etcd (fsync p99 above CALM_MAX_FSYNC, default 0.5 s)
#    skips the run without starting Renovate and records 75.
fake_renovate 'echo "RENOVATE-RAN"'
echo 2.4 >"$WORK/fsync"
run_wrapper
grep -q RENOVATE-RAN <<<"$OUT" && fail "slow etcd: renovate ran" || pass "slow etcd: renovate not started"
[ "$(last_exit_code)" = 75 ] && pass "slow etcd: records 75" || fail "slow etcd: records '$(last_exit_code)'"
grep -q "Control plane not calm" <<<"$OUT" && pass "slow etcd: says why" || fail "slow etcd: no reason printed"
rm -f "$WORK/fsync"

# 8. Calm gate: a firing EtcdWalFsyncSlow / EtcdBackendCommitSlow alert skips too.
echo 1 >"$WORK/alerts"
run_wrapper
grep -q RENOVATE-RAN <<<"$OUT" && fail "etcd alert: renovate ran" || pass "etcd alert: renovate not started"
rm -f "$WORK/alerts"

# 9. Calm gate fails closed: Prometheus unreachable means no run.
touch "$WORK/prom_down"
run_wrapper
grep -q RENOVATE-RAN <<<"$OUT" && fail "prometheus down: renovate ran" || pass "prometheus down: renovate not started"
rm -f "$WORK/prom_down"

# 10. Calm cluster: Renovate runs.
run_wrapper
grep -q RENOVATE-RAN <<<"$OUT" && pass "calm: renovate runs" || fail "calm: renovate did not run: $OUT"

# 11. Gap between bumps: a Renovate pipeline that finished less than
#     RENOVATE_MIN_GAP (default 1200 s) ago skips the run; an older one does not.
now=$(date +%s)
echo "[{\"number\":2,\"status\":\"success\",\"author\":\"renovate-bot\",\"finished\":$((now - 300))},{\"number\":1,\"status\":\"success\",\"author\":\"viktor\",\"finished\":$((now - 30))}]" >"$WORK/pipelines"
WP=1 run_wrapper
grep -q RENOVATE-RAN <<<"$OUT" && fail "recent bump: renovate ran" || pass "recent bump: renovate not started"
grep -q "last Renovate pipeline finished" <<<"$OUT" && pass "recent bump: says why" || fail "recent bump: no reason printed: $OUT"
echo "[{\"number\":2,\"status\":\"success\",\"author\":\"renovate-bot\",\"finished\":$((now - 1500))}]" >"$WORK/pipelines"
WP=1 run_wrapper
grep -q RENOVATE-RAN <<<"$OUT" && pass "old bump: renovate runs" || fail "old bump: renovate did not run: $OUT"
rm -f "$WORK/pipelines"

echo
[ "$fails" = 0 ] && { echo "all passed"; exit 0; } || { echo "$fails failed"; exit 1; }
