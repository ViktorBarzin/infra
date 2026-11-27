#!/usr/bin/env bash
# Checks the infra CI red alert offline:
#
#   1. The infra-ci-status poller (stacks/ci-pipeline-health/files/
#      infra_ci_status.py): red streak and last success from repo 82's
#      pipelines, the metrics it pushes.
#   2. The Infra CI alert group in stacks/monitoring (prometheus_chart_values.tpl)
#      passes `promtool check rules` and tests/infra-ci-status/alerts.test.yml:
#      InfraCIRed fires on 2+ red with no success for 1h, not on 1 red, and
#      InfraCIStatusStale fires when the poller stops.
#   3. shellcheck finds no warning or error in the daily sweep
#      (stacks/ci-pipeline-health/files/sweep.sh).
#
# Needs python3, docker with the prom/prometheus image, and shellcheck.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PROM_IMAGE="${INFRA_CI_PROM_IMAGE:-prom/prometheus:v3.5.0}"
TPL="$HERE/stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl"
FILES="$HERE/stacks/ci-pipeline-health/files"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILS=0

# 1. The poller.
(cd "$FILES" && python3 infra_ci_status_test.py) || { echo "FAIL: infra_ci_status_test.py"; FAILS=$((FAILS + 1)); }

# 2. The rule group, cut out of the chart values. Rule groups sit at six
# spaces; the group ends at the next one.
awk '
  /^      - name: Infra CI$/ { on = 1; print "groups:"; print substr($0, 7); next }
  on && /^      - name: / { exit }
  on { print substr($0, 7) }
' "$TPL" >"$TMP/infra-ci.rules.yml"
if ! grep -q '^- name: Infra CI$' "$TMP/infra-ci.rules.yml"; then
  echo "FAIL: no \"- name: Infra CI\" rule group in $TPL"; exit 1
fi
cp "$HERE/tests/infra-ci-status/alerts.test.yml" "$TMP/"
# promtool runs as nobody in the container; mktemp -d is 0700.
chmod 755 "$TMP" && chmod 644 "$TMP"/*.yml
if ! docker run --rm --entrypoint promtool -v "$TMP:/w:ro" -w /w "$PROM_IMAGE" check rules infra-ci.rules.yml >"$TMP/check.log" 2>&1; then
  echo "FAIL: promtool check rules"; cat "$TMP/check.log"; FAILS=$((FAILS + 1))
fi
if ! docker run --rm --entrypoint promtool -v "$TMP:/w:ro" -w /w "$PROM_IMAGE" test rules alerts.test.yml >"$TMP/test.log" 2>&1; then
  echo "FAIL: promtool test rules"; cat "$TMP/test.log"; FAILS=$((FAILS + 1))
fi

# 3. The sweep. Style notes (SC2181) predate this check.
if ! shellcheck -s sh -S warning "$FILES/sweep.sh"; then
  echo "FAIL: shellcheck sweep.sh"; FAILS=$((FAILS + 1))
fi

if [ "$FAILS" -eq 0 ]; then echo "PASS: infra-ci-status"; else echo "FAIL: $FAILS check(s)"; fi
exit "$FAILS"
