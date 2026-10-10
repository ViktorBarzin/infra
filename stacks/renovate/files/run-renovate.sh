#!/bin/bash
# CronJob entrypoint for stacks/renovate (2026-10-10).
# Runs Renovate once, then records the outcome in Pushgateway:
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

renovate "$@"
rc=$?
record "$rc"
exit "$rc"
