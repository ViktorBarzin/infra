#!/usr/bin/env bash
# Checks the shared Redis's ACL users (B40 R1) offline:
#
#   1. redis-acl-sync (stacks/redis/modules/redis/acl_sync.py) and the
#      redis-v2 init container (acl_init.sh), with pytest against a real
#      redis:8.10.3-alpine container: the seed boots Redis, the sync renders
#      every user of acl_users.json as a #<sha256> hash, every user can AUTH
#      and PING, the restricted users get only their commands, a client on
#      `default` stays connected, a broken input changes nothing.
#   2. The RedisAclSync* alerts and RedisMemoryHigh pass `promtool check
#      rules` and the unit tests in tests/redis-acl/alerts.test.yml.
#
# Needs python3 with pytest, PyYAML, and docker with the redis:8.10.3-alpine
# and prom/prometheus images.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PROM_IMAGE="${REDIS_ACL_PROM_IMAGE:-prom/prometheus:v3.5.0}"
TPL="$HERE/stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILS=0

# 1. pytest.
if ! (cd "$HERE/stacks/redis/modules/redis" && python3 -m pytest acl_sync_test.py -q -p no:cacheprovider); then
  echo "FAIL: acl_sync_test.py"; FAILS=$((FAILS + 1))
fi

# 2. promtool. The rules sit in a larger group; cut them out into a group of
# their own.
mkdir -p "$TMP/t"
python3 - "$TPL" "$TMP/redis-acl.rules.yml" "$TMP/t/redis-acl.rules.yml" <<'PY' || { echo "FAIL: cannot cut the RedisAclSync rules out"; exit 1; }
import re, sys, yaml
text = open(sys.argv[1]).read()
NAMES = "RedisAclSync\\w+|RedisMemoryHigh"
blocks = re.findall(r"^( {10}- alert: (?:" + NAMES + r")\n(?: {12}.*\n|\s*\n)+)", text, re.M)
if len(blocks) != 3:
    sys.exit(f"expected 3 redis-acl rules (2 RedisAclSync, RedisMemoryHigh), found {len(blocks)}")
rules = [yaml.safe_load(re.sub(r"^ {10}", "", b, flags=re.M))[0] for b in blocks]
yaml.safe_dump({"groups": [{"name": "redis-acl", "rules": rules}]}, open(sys.argv[2], "w"), sort_keys=False)
# The unit tests compare labels; `check rules` parses the annotations, so
# the copy the unit tests run on drops them.
for r in rules:
    r.pop("annotations", None)
yaml.safe_dump({"groups": [{"name": "redis-acl", "rules": rules}]}, open(sys.argv[3], "w"), sort_keys=False)
PY
cp "$HERE/tests/redis-acl/alerts.test.yml" "$TMP/t/"
chmod 755 "$TMP" "$TMP/t" && chmod 644 "$TMP"/*.yml "$TMP/t"/*
if ! docker run --rm --entrypoint promtool -v "$TMP:/w:ro" -w /w "$PROM_IMAGE" check rules redis-acl.rules.yml >"$TMP/check.log" 2>&1; then
  echo "FAIL: promtool check rules"; cat "$TMP/check.log"; FAILS=$((FAILS + 1))
fi
if ! docker run --rm --entrypoint promtool -v "$TMP/t:/w:ro" -w /w "$PROM_IMAGE" test rules alerts.test.yml >"$TMP/test.log" 2>&1; then
  echo "FAIL: promtool test rules"; cat "$TMP/test.log"; FAILS=$((FAILS + 1))
fi

if [ "$FAILS" -eq 0 ]; then echo "PASS: redis ACL (sync, init container, alerts)"; else echo "FAIL: $FAILS check group(s)"; exit 1; fi
