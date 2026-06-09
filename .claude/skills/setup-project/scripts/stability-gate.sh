#!/usr/bin/env bash
# 10-minute deploy stability gate for setup-project skill.
# Polls pod readiness + HTTP 200 on target URL every 30s for 20 iterations.
# Requires 18/20 probes to succeed (tolerates 2 blips for restarts/DNS propagation).
#
# Usage:
#   stability-gate.sh <namespace> <app-label> <url>
#
# Example:
#   stability-gate.sh myapp myapp https://myapp.viktorbarzin.me
#
# Exit codes:
#   0  - Stable (>=18/20 probes OK)
#   1  - Unstable (<18/20 probes OK)
#   2  - Usage error

set -u

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <namespace> <app-label> <url>" >&2
  exit 2
fi

NS="$1"
APP="$2"
URL="$3"

TOTAL_PROBES=20
MIN_SUCCESSES=18
INTERVAL_SECONDS=30

ok_count=0
fail_count=0

echo "stability-gate: ns=$NS app=$APP url=$URL"
echo "stability-gate: $TOTAL_PROBES probes x ${INTERVAL_SECONDS}s (need $MIN_SUCCESSES/$TOTAL_PROBES)"

for i in $(seq 1 "$TOTAL_PROBES"); do
  probe_ok=true

  if ! kubectl wait --for=condition=Ready pod -l "app=$APP" -n "$NS" --timeout=25s >/dev/null 2>&1; then
    probe_ok=false
  fi

  status=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 "$URL" || echo "000")
  if [ "$status" != "200" ]; then
    probe_ok=false
  fi

  if [ "$probe_ok" = "true" ]; then
    ok_count=$((ok_count + 1))
    printf "  probe %2d/%d: OK (http=%s)\n" "$i" "$TOTAL_PROBES" "$status"
  else
    fail_count=$((fail_count + 1))
    printf "  probe %2d/%d: FAIL (http=%s)\n" "$i" "$TOTAL_PROBES" "$status"
  fi

  if [ "$i" -lt "$TOTAL_PROBES" ]; then
    sleep "$INTERVAL_SECONDS"
  fi
done

echo "stability-gate: results ok=$ok_count fail=$fail_count"

if [ "$ok_count" -ge "$MIN_SUCCESSES" ]; then
  echo "stability-gate: PASS"
  exit 0
fi

echo "stability-gate: FAIL (need $MIN_SUCCESSES, got $ok_count)" >&2
exit 1
