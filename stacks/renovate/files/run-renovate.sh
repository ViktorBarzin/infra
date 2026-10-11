#!/bin/bash
# CronJob entrypoint for stacks/renovate (2026-10-10).
# Runs Renovate once (stopping it after the first automerge, see below), then
# records the outcome in Pushgateway:
#   renovate_last_run_timestamp_seconds      every run
#   renovate_last_run_exit_code              every run (0 ok, 1 renovate error, 75 skipped:
#                                            Woodpecker busy or rails hold cool-down)
#   renovate_last_run_duration_seconds       every run
#   renovate_last_success_timestamp_seconds  only when renovate exited 0
# POST (not PUT) replaces only the metrics named in the body, so a failed run
# leaves the previous success timestamp in place for the liveness alert.
# Uses node (always present in renovate/renovate) so the script does not depend
# on curl being in the image.
# RENOVATE_INSTANCE (default "infra") is the Pushgateway instance label. The
# RenovateNotSucceeding alert reads instance="infra" only, so a hand-started
# test run sets another value (e.g. "dryrun") and does not count as a success.
set -uo pipefail

PGW="${PUSHGATEWAY_URL:-http://prometheus-prometheus-pushgateway.monitoring:9091}"
GROUP="${PGW}/metrics/job/renovate/instance/${RENOVATE_INSTANCE:-infra}"
start=$(date +%s)

push() { # $1 = exposition-format body
  node -e '
    const [url, body] = process.argv.slice(1);
    fetch(url, { method: "POST", body, headers: { "Content-Type": "text/plain; version=0.0.4" } })
      .then(r => { if (!r.ok) { console.error("pushgateway HTTP", r.status); process.exit(1); } })
      .catch(e => { console.error("pushgateway", e.message); process.exit(1); });
  ' "$GROUP" "$1" || echo "WARN: Pushgateway push failed" >&2
}

record() { # $1 = exit code to record
  local now; now=$(date +%s)
  local body
  body="# TYPE renovate_last_run_timestamp_seconds gauge
renovate_last_run_timestamp_seconds ${now}
# TYPE renovate_last_run_exit_code gauge
renovate_last_run_exit_code $1
# TYPE renovate_last_run_duration_seconds gauge
renovate_last_run_duration_seconds $((now - start))
"
  if [ "$1" -eq 0 ]; then
    body="${body}# TYPE renovate_last_success_timestamp_seconds gauge
renovate_last_success_timestamp_seconds ${now}
"
  fi
  push "$body"
}

# Guard: do not push while a Woodpecker pipeline on viktor/infra is still
# running or queued. Woodpecker cancels a running pipeline when the next push
# arrives, so a Renovate commit landing mid-rails would cancel the previous
# bump's verify/revert. Enabled when WOODPECKER_REPO_ID is set (viktor/infra
# is id 82; the repo is public, so the token is optional).
if [ -n "${WOODPECKER_REPO_ID:-}" ]; then
  busy=$(node -e '
    const [base, repo, token] = process.argv.slice(1);
    fetch(`${base}/api/repos/${repo}/pipelines?page=1&perPage=10`, token ? { headers: { Authorization: `Bearer ${token}` } } : {})
      .then(r => r.ok ? r.json() : Promise.reject(new Error("HTTP " + r.status)))
      .then(ps => console.log(ps.filter(p => ["running", "pending", "blocked"].includes(p.status)).length))
      .catch(e => { console.error("woodpecker", e.message); console.log("error"); });
  ' "${WOODPECKER_URL:-https://ci.viktorbarzin.me}" "$WOODPECKER_REPO_ID" "${WOODPECKER_TOKEN:-}")
  if [ "$busy" != "0" ]; then
    echo "Woodpecker busy or unreachable (${busy}); skipping this run"
    record 75
    exit 0
  fi
fi

# Hold cool-down: when the Woodpecker rails held a bump (upgrade gate blocked
# or the pre-upgrade snapshot failed; scripts/renovate-rails in the infra repo)
# within the last RAILS_HOLD_COOLDOWN seconds, skip this run, so Renovate does
# not push the same bump into a blocked gate every 30 minutes. The rails write
# renovate_rails_hold_timestamp_seconds to Pushgateway (job renovate-rails).
# An unreachable Pushgateway does not block the run.
age=$(node -e '
  const [base] = process.argv.slice(1);
  fetch(`${base}/api/v1/metrics`)
    .then(r => r.ok ? r.json() : Promise.reject(new Error("HTTP " + r.status)))
    .then(j => {
      const g = (j.data || []).find(x => x.labels && x.labels.job === "renovate-rails");
      const m = g && g.renovate_rails_hold_timestamp_seconds;
      const v = m && m.metrics && m.metrics[0] && Number(m.metrics[0].value);
      console.log(v ? Math.round(Date.now() / 1000 - v) : "none");
    })
    .catch(e => { console.error("pushgateway", e.message); console.log("none"); });
' "$PGW")
if [ "$age" != "none" ] && [ "$age" -lt "${RAILS_HOLD_COOLDOWN:-7200}" ] 2>/dev/null; then
  echo "The rails held a bump ${age}s ago; skipping this run (cool-down ${RAILS_HOLD_COOLDOWN:-7200}s)"
  record 75
  exit 0
fi

# Optional stop after the first automerge (RENOVATE_STOP_AFTER_AUTOMERGE=1).
# Once a branch is automerged, Renovate logs "Restarting repository job after
# automerge result" and runs the whole repository job again. With
# prCommitsPerRunLimit=1 that second pass lands nothing, but it is the pass
# that rewrites the Dependency Dashboard issue and the repository cache.
# On 2026-10-11 Woodpecker step pods (tier-3-edge) preempted the then
# tier-4-aux Renovate pod in that window twice, so this stop was turned on
# by default; it also kept the dashboard from ever refreshing. The pod now
# runs at the renovate PriorityClass (same value as tier-3-edge, never
# preempts), so the default is to let the run finish. Set it to 1 to go back
# to stopping. RENOVATE_STOP_GRACE (default 20 s) bounds the wait after
# SIGTERM before SIGKILL. Output is still passed through line by line.
fifo=$(mktemp -u /tmp/run-renovate.XXXXXX)
mkfifo "$fifo"
# Job control gives Renovate its own process group, so the signals below also
# reach its git child processes.
set -m
renovate "$@" >"$fifo" 2>&1 &
pid=$!
set +m
stopped=0
while IFS= read -r line || [ -n "$line" ]; do
  printf '%s\n' "$line"
  if [ "${RENOVATE_STOP_AFTER_AUTOMERGE:-0}" = 1 ] && [ "$stopped" = 0 ] && [[ "$line" == *"Restarting repository job after automerge result"* ]]; then
    stopped=1
    echo "run-renovate: one bump landed; stopping Renovate before its post-automerge restart (prCommitsPerRunLimit=1 skips every branch in it)"
    kill -TERM -- "-$pid" 2>/dev/null
    (
      sleep "${RENOVATE_STOP_GRACE:-20}"
      kill -KILL -- "-$pid" 2>/dev/null
    ) >/dev/null 2>&1 &
    break
  fi
done <"$fifo"
if [ "$stopped" = 1 ]; then
  # Keep draining so a Renovate still writing on its way out does not block.
  cat "$fifo" >/dev/null 2>&1 &
fi
wait "$pid"
rc=$?
rm -f "$fifo"
[ "$stopped" = 1 ] && rc=0
record "$rc"
exit "$rc"
