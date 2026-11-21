#!/usr/bin/env bash
# Checks stacks/garage (cloud B25, the S3 store for Cloud Buckets) offline:
#
#   1. tests/garage/garage_test.py against the pinned images in docker: the
#      stack's garage.toml starts Garage with --single-node, the layout is
#      made once and survives a restart,
#      /metrics is open while the rest of the admin API needs the token,
#      a PUT past a bucket quota gets 403, and the backup CronJob's scripts
#      (files/backup_prepare.py, files/backup_sync.sh) write the NFS layout
#      Cloud's restore reads: current/, one dated directory per night with
#      what that night overwrote or deleted, a same-day rerun keeping the
#      dated copies, deleted buckets ageing out, 7
#      dated directories kept, Pushgateway metrics, a failed bucket failing
#      the run without moving the success timestamp.
#   2. The Garage alert group in stacks/monitoring passes `promtool check
#      rules` and tests/garage/alerts.test.yml; the `garage` scrape job loads
#      in `promtool check config`.
#   3. Static: every pod-owning resource carries KYVERNO_LIFECYCLE_V1, the
#      backup is suspended and in the nightly chain, there is no Ingress.
#
# Needs python3 (stdlib, plus PyYAML for step 2) and docker.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PROM_IMAGE="${GARAGE_PROM_IMAGE:-prom/prometheus:v3.5.0}"
TPL="$HERE/stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl"
MAIN="$HERE/stacks/garage/main.tf"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILS=0

# 1. Garage and the backup, in docker.
# GARAGE_TEST_ALERTS_ONLY=1 skips it (steps 2 and 3 take seconds).
if [ "${GARAGE_TEST_ALERTS_ONLY:-0}" != 1 ] && ! python3 -I "$HERE/tests/garage/garage_test.py"; then
  echo "FAIL: garage_test.py"; FAILS=$((FAILS + 1))
fi

# 2. promtool. Cut the Garage group and the garage scrape job out of the
# chart values (a Terraform template, so `$${` becomes `${`).
mkdir -p "$TMP/t"
python3 - "$TPL" "$TMP" <<'PY' || { echo "FAIL: cannot cut the Garage rules out"; exit 1; }
import re, sys, yaml
text = open(sys.argv[1]).read().replace("$${", "${")
m = re.search(r"^      - name: Garage\n        rules:\n(.*?)(?=^      - name: )", text, re.M | re.S)
if not m:
    sys.exit("no Garage rule group")
group = yaml.safe_load("- name: Garage\n  rules:\n" + re.sub(r"^ {6}", "", m.group(1), flags=re.M))[0]
names = [r["alert"] for r in group["rules"]]
want = ["GarageDown", "GarageDiskFull", "GarageBackupStale", "GarageBackupNeverRun"]
if names != want:
    sys.exit(f"Garage rules are {names}, expected {want}")
out = sys.argv[2]
yaml.safe_dump({"groups": [group]}, open(f"{out}/garage.rules.yml", "w"), sort_keys=False)
for r in group["rules"]:
    r.pop("annotations", None)
yaml.safe_dump({"groups": [group]}, open(f"{out}/t/garage.rules.yml", "w"), sort_keys=False)
j = re.search(r"^  - job_name: 'garage'\n(?:    .*\n|        .*\n)+", text, re.M)
if not j:
    sys.exit("no garage scrape job")
job = yaml.safe_load(re.sub(r"^  ", "", j.group(0), flags=re.M))[0]
yaml.safe_dump({"scrape_configs": [job]}, open(f"{out}/prometheus.yml", "w"), sort_keys=False)
PY
cp "$HERE/tests/garage/alerts.test.yml" "$TMP/t/"
chmod 755 "$TMP" "$TMP/t" && chmod 644 "$TMP"/*.yml "$TMP/t"/*
run_promtool() { docker run --rm --entrypoint promtool -v "$1:/w:ro" -w /w "$PROM_IMAGE" "${@:2}"; }
if ! run_promtool "$TMP" check rules garage.rules.yml >"$TMP/check.log" 2>&1; then
  echo "FAIL: promtool check rules"; cat "$TMP/check.log"; FAILS=$((FAILS + 1))
fi
if ! run_promtool "$TMP/t" test rules alerts.test.yml >"$TMP/test.log" 2>&1; then
  echo "FAIL: promtool test rules"; cat "$TMP/test.log"; FAILS=$((FAILS + 1))
fi
if ! run_promtool "$TMP" check config --syntax-only prometheus.yml >"$TMP/config.log" 2>&1; then
  echo "FAIL: promtool check config (garage scrape job)"; cat "$TMP/config.log"; FAILS=$((FAILS + 1))
fi

# 3. Static checks on the stack.
static() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }
pods=$(grep -cE '^resource "kubernetes_(deployment|stateful_set|daemon_set|cron_job_v1|job)"' "$MAIN")
markers=$(grep -c 'KYVERNO_LIFECYCLE_V1' "$MAIN")
# The namespace carries one marker of its own (the goldilocks label).
[ "$markers" -ge $((pods + 1)) ] || static "KYVERNO_LIFECYCLE_V1: $pods pod-owning resources, $markers markers"
grep -q '"backup.viktorbarzin.me/nightly-chain" = "daily"' "$MAIN" || static "garage-backup is not in the nightly chain"
grep -qE '^\s*suspend\s*=\s*true' "$MAIN" || static "garage-backup is not suspended (nightly-chain runs it)"
grep -qE 'kubernetes_ingress|ingress_factory' "$MAIN" && static "stacks/garage must not publish an Ingress (decision V6)"
grep -q 'storage_class_name = "proxmox-lvm-encrypted-sas"' "$MAIN" || static "Garage volumes are not on proxmox-lvm-encrypted-sas"
grep -q '"--single-node"' "$MAIN" || static "Garage does not start with --single-node"

if [ "$FAILS" -eq 0 ]; then echo "PASS: garage (server, backup, alerts, stack)"; else echo "FAIL: $FAILS check group(s)"; exit 1; fi
