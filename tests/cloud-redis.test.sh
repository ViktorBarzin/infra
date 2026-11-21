#!/usr/bin/env bash
# Checks cloud-redis (cloud B27 option b, stacks/cloud-redis) offline:
#
#   1. The Key Value tenant code (stacks/redis/modules/redis/acl_sync.py, the
#      tenant section) with pytest against a real redis:8.10.3-alpine running
#      cloud-redis's own redis.conf (read from stacks/cloud-redis/main.tf) and
#      users (acl_users.json): default off, the client limits nest, a legal
#      32 MiB value is neither cut off nor evicted, unread replies are cut off
#      at the output limit, the probe fails on BUSY, and the tenant and full
#      rule sets.
#   2. cloud-redis's alerts (CloudRedis*, CloudKeyValueTotalHigh,
#      CloudKeyValueTenantsFetchFailing, RedisForeignUser,
#      RedisScriptCacheHigh) pass `promtool check rules` and the unit tests in
#      tests/cloud-redis/alerts.test.yml.
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

# 1. pytest: the tenant tests run on a cloud-redis box.
if ! (cd "$HERE/stacks/redis/modules/redis" && python3 -m pytest acl_sync_test.py -q -p no:cacheprovider \
    -k "tenant or cloud_redis or 32_mib or unread or keyless or modules or search_index or measurement or purge or foreign or full or kv or probe or acl_cat"); then
  echo "FAIL: acl_sync_test.py (cloud-redis)"; FAILS=$((FAILS + 1))
fi

# 2. promtool.
mkdir -p "$TMP/t"
python3 - "$TPL" "$TMP/cloud-redis.rules.yml" "$TMP/t/cloud-redis.rules.yml" <<'PY' || { echo "FAIL: cannot cut the cloud-redis rules out"; exit 1; }
import re, sys, yaml
text = open(sys.argv[1]).read()
NAMES = "CloudRedis\\w+|CloudKeyValueTotalHigh|CloudKeyValueTenantsFetchFailing|RedisForeignUser|RedisScriptCacheHigh"
blocks = re.findall(r"^( {10}- alert: (?:" + NAMES + r")\n(?: {12}.*\n|\s*\n)+)", text, re.M)
if len(blocks) != 12:
    sys.exit(f"expected 12 cloud-redis rules (8 CloudRedis*, 4 Key Value), found {len(blocks)}")
rules = [yaml.safe_load(re.sub(r"^ {10}", "", b, flags=re.M))[0] for b in blocks]
yaml.safe_dump({"groups": [{"name": "cloud-redis", "rules": rules}]}, open(sys.argv[2], "w"), sort_keys=False)
for r in rules:
    r.pop("annotations", None)
yaml.safe_dump({"groups": [{"name": "cloud-redis", "rules": rules}]}, open(sys.argv[3], "w"), sort_keys=False)
PY
cp "$HERE/tests/cloud-redis/alerts.test.yml" "$TMP/t/"
chmod 755 "$TMP" "$TMP/t" && chmod 644 "$TMP"/*.yml "$TMP/t"/*
if ! docker run --rm --entrypoint promtool -v "$TMP:/w:ro" -w /w "$PROM_IMAGE" check rules cloud-redis.rules.yml >"$TMP/check.log" 2>&1; then
  echo "FAIL: promtool check rules"; cat "$TMP/check.log"; FAILS=$((FAILS + 1))
fi
if ! docker run --rm --entrypoint promtool -v "$TMP/t:/w:ro" -w /w "$PROM_IMAGE" test rules alerts.test.yml >"$TMP/test.log" 2>&1; then
  echo "FAIL: promtool test rules"; cat "$TMP/test.log"; FAILS=$((FAILS + 1))
fi

if [ "$FAILS" -eq 0 ]; then echo "PASS: cloud-redis (tenant code, config, alerts)"; else echo "FAIL: $FAILS check group(s)"; exit 1; fi
