#!/usr/bin/env bash
# Checks the "Internal DNS freshness" alert group in stacks/monitoring
# (prometheus_chart_values.tpl) offline with a real promtool: the group passes
# `promtool check rules`, and the unit tests in
# tests/technitium-replication/alerts.test.yml say what fires and when
# (replica SOA serial behind the primary, SOA probe failing, external-dns-cloud
# stale or failing).
# Needs python3 (PyYAML) and docker with the prom/prometheus image.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PROM_IMAGE="${PROM_IMAGE:-prom/prometheus:v3.5.0}"
TPL="$HERE/stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILS=0

# Rule groups sit at six spaces; the group ends at the next one.
awk '
  /^      - name: "Internal DNS freshness"$/ { on = 1; print "groups:"; print substr($0, 7); next }
  on && /^      - name: / { exit }
  on && /^      #/ { next }
  on { print substr($0, 7) }
' "$TPL" >"$TMP/dns.rules.yml"
grep -q '^- name: "Internal DNS freshness"$' "$TMP/dns.rules.yml" || { echo "FAIL: no \"Internal DNS freshness\" rule group in $TPL"; exit 1; }

mkdir -p "$TMP/t"
cp "$HERE/tests/technitium-replication/alerts.test.yml" "$TMP/t/"
# The unit tests compare labels; `check rules` parses every annotation
# template, so the copy the tests run on drops the annotations.
python3 - "$TMP/dns.rules.yml" "$TMP/t/dns.rules.yml" <<'PY' || { echo "FAIL: cannot parse the rule group"; exit 1; }
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for g in doc["groups"]:
    for r in g["rules"]:
        r.pop("annotations", None)
yaml.safe_dump(doc, open(sys.argv[2], "w"), sort_keys=False)
PY
# promtool runs as nobody in the container.
chmod 755 "$TMP" "$TMP/t" && chmod 644 "$TMP/dns.rules.yml" "$TMP/t/"*
if ! docker run --rm --entrypoint promtool -v "$TMP:/w:ro" -w /w "$PROM_IMAGE" check rules dns.rules.yml >"$TMP/check.log" 2>&1; then
  echo "FAIL: promtool check rules"; cat "$TMP/check.log"; FAILS=$((FAILS + 1))
fi
if ! docker run --rm --entrypoint promtool -v "$TMP/t:/w:ro" -w /w "$PROM_IMAGE" test rules alerts.test.yml >"$TMP/test.log" 2>&1; then
  echo "FAIL: promtool test rules"; cat "$TMP/test.log"; FAILS=$((FAILS + 1))
fi

if [ "$FAILS" -eq 0 ]; then echo "PASS: internal DNS freshness alerts"; else echo "FAIL: $FAILS check(s)"; exit 1; fi
