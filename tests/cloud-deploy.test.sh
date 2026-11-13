#!/usr/bin/env bash
# Checks the Cloud deploy (milestone M4) offline, against the cloud repo's own
# code and a real promtool:
#
#   1. The console's cluster role (stacks/cloud/deploy_rules.tf) reads only
#      what TakenHosts lists, cluster-wide: namespaces, Ingresses and
#      IngressRoutes, with get and list. No Secret, no write.
#   2. Every env variable the stack gives the console and the reconciler is
#      one the cloud code reads (src/server/env.server.ts), so a typo cannot
#      leave a setting at its default unnoticed. The reconciler gets every
#      credential reconcilerSecrets() requires, as a file in a mounted
#      Secret, and Reloader restarts it when one of those Secrets changes.
#   3. The Cloud alert group in stacks/monitoring (prometheus_chart_values.tpl)
#      passes `promtool check rules` and the unit tests in
#      tests/cloud-deploy/alerts.test.yml: what fires, after how long, and
#      that only the reconciler being down and a stuck queue page.
#   4. The kubernetes-service-endpoints keep regex admits every cloud_ metric
#      the alerts read, so none is dropped at scrape time.
#
# The cloud code is read from CLOUD_ENV_SERVER (a path to env.server.ts), or
# else from origin/master of ~/code/cloud.
# Needs terraform, python3, git and docker with the prom/prometheus image.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PROM_IMAGE="${CLOUD_DEPLOY_PROM_IMAGE:-prom/prometheus:v3.5.0}"
TPL="$HERE/stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -n "${CLOUD_ENV_SERVER:-}" ]; then
  cp "$CLOUD_ENV_SERVER" "$TMP/env.server.ts" || { echo "FAIL: cannot read $CLOUD_ENV_SERVER"; exit 1; }
else
  git -C "$HOME/code/cloud" show origin/master:src/server/env.server.ts >"$TMP/env.server.ts" 2>/dev/null \
    || { echo "FAIL: cannot read src/server/env.server.ts from ~/code/cloud origin/master; set CLOUD_ENV_SERVER"; exit 1; }
fi

# deploy_rules.tf and access_rules.tf hold only locals. The stub stands in
# for the stack's variable and for the taken hosts read from the cluster.
mkdir -p "$TMP/locals"
cp "$HERE/stacks/cloud/deploy_rules.tf" "$HERE/stacks/cloud/access_rules.tf" "$TMP/locals/" \
  || { echo "FAIL: stacks/cloud/deploy_rules.tf is missing"; exit 1; }
cat >"$TMP/locals/stub.tf" <<'EOF'
variable "postgresql_host" {
  default = "pg.example"
}
locals {
  cloud_taken_hosts = {}
}
EOF
if ! (cd "$TMP/locals" && echo 'jsonencode({console_rules = local.cloud_console_cluster_rules, console_env = local.cloud_console_env, reconciler_env = local.cloud_reconciler_env, reconciler_files = local.cloud_reconciler_files, reconciler_reload = local.cloud_reconciler_reload, secretstore_vault = local.cloud_secretstore_vault_server})' \
    | terraform console >"$TMP/locals.json" 2>"$TMP/locals.err"); then
  echo "FAIL: terraform console could not evaluate stacks/cloud/deploy_rules.tf (it must hold only locals)"
  cat "$TMP/locals.err"
  exit 1
fi

# The Cloud alert group, cut out of the chart values. Rule groups sit at six
# spaces; the group ends at the next one.
awk '
  /^      - name: Cloud$/ { on = 1; print "groups:"; print substr($0, 7); next }
  on && /^      - name: / { exit }
  on { print substr($0, 7) }
' "$TPL" >"$TMP/cloud.rules.yml"
grep -q '^- name: Cloud$' "$TMP/cloud.rules.yml" || { echo "FAIL: no \"- name: Cloud\" rule group in $TPL"; exit 1; }
# The keep regex of the kubernetes-service-endpoints job: the one that admits
# first-party app prefixes (tripit_.+).
grep -m1 -oP "^\s*regex: '\K[^']*tripit_\.\+[^']*(?=')" "$TPL" >"$TMP/keep.regex" \
  || { echo "FAIL: cannot find the kubernetes-service-endpoints keep regex in $TPL"; exit 1; }

FAILS=0
python3 - "$TMP" <<'PY' || FAILS=$((FAILS + 1))
import json, pathlib, re, sys

d = pathlib.Path(sys.argv[1])
loc = json.loads(json.loads((d / "locals.json").read_text()))
src = (d / "env.server.ts").read_text()
bad = []

# 1. Console cluster role.
want = {("", "namespaces"), ("networking.k8s.io", "ingresses"), ("traefik.io", "ingressroutes")}
got = set()
for r in loc["console_rules"]:
    if sorted(r["verbs"]) != ["get", "list"]:
        bad.append(f"console rule {r} grants verbs other than get and list")
    if r.get("resource_names"):
        bad.append(f"console rule {r} is limited to names; TakenHosts lists everything")
    for g in r["api_groups"]:
        for res in r["resources"]:
            got.add((g, res))
if got != want:
    bad.append(f"console cluster role covers {sorted(got)}, want exactly {sorted(want)}")

# 2. Env contract. Names the code reads: env("X"), list("X"), the number
# helpers, and secret("X") / required("X"), which also read X_FILE.
read = set(re.findall(r'\b(?:env|list|wholeNumber|positiveNumber)\("([A-Z0-9_]+)"', src))
secrets = set(re.findall(r'\b(?:secret|required)\("([A-Z0-9_]+)"', src))
required = set(re.findall(r'\brequired\("([A-Z0-9_]+)"', src))
read |= secrets | {f"{n}_FILE" for n in secrets}
read |= set(re.findall(r'runtimeEnv\.([A-Z0-9_]+)', src))
# Read outside env.server.ts: @viktorbarzin/pg (pgSettingsFromEnv) reads the
# database pair, and the OS reads HOME.
read |= {"DATABASE_URL", "DATABASE_PASSWORD_FILE", "HOME"}
# Set ahead of the code (docs/architecture/cloud.md, "Agent sign-in"): M6
# reads them once the API verifies cloud-cli tokens.
pending = {"AGENT_OIDC_CLIENT_ID", "AGENT_OIDC_DISCOVERY_URL"}

def names(env):
    return [e["name"] for e in env]

for who, env in (("console", loc["console_env"]), ("reconciler", loc["reconciler_env"])):
    for n in names(env):
        if n not in read and n not in pending:
            bad.append(f"{who} env {n} is not read by the cloud code")
for n in pending:
    if n in read:
        bad.append(f"{n} is read by the cloud code now; drop it from the pending list")

files = loc["reconciler_files"]
renv = {e["name"]: e["value"] for e in loc["reconciler_env"]}
for n in sorted(required):
    if n not in renv and f"{n}_FILE" not in renv:
        bad.append(f"the reconciler requires {n} (or {n}_FILE) and the stack does not set it")
for n, f in files.items():
    path = renv.get(f"{n}_FILE")
    want_path = f"{f['mount']}/{f['key']}"
    if path != want_path:
        bad.append(f"{n}_FILE is {path!r}, want {want_path!r} (secret {f['secret']} key {f['key']})")
    if f["secret"] not in loc["reconciler_reload"] and f.get("reload", True):
        bad.append(f"Reloader does not restart the reconciler when {f['secret']} changes")
mounts = {}
for n, f in files.items():
    if mounts.setdefault(f["mount"], f["secret"]) != f["secret"]:
        bad.append(f"two Secrets share mount {f['mount']}")
if renv.get("VAULT_ADDR") != loc["secretstore_vault"]:
    bad.append(f"VAULT_ADDR {renv.get('VAULT_ADDR')!r} is not the in-cluster Vault address the admission policy pins ({loc['secretstore_vault']!r})")
for n in ("VAULT_TOKEN", "VAULT_TOKEN_FILE"):
    if n in renv:
        bad.append(f"the reconciler gets {n}; it must log in to Vault with its service account")

# 4. Every cloud_ metric the alerts read is kept at scrape time.
rules = (d / "cloud.rules.yml").read_text()
keep = re.compile((d / "keep.regex").read_text().strip())
metrics = set(re.findall(r'\b(cloud_[a-z_]+)\b', "\n".join(l for l in rules.splitlines() if "expr:" in l)))
if not metrics:
    bad.append("the Cloud alert group reads no cloud_ metric")
for m in sorted(metrics):
    if not keep.fullmatch(m):
        bad.append(f"metric {m} is dropped by the kubernetes-service-endpoints keep regex")

for b in bad:
    print("FAIL:", b)
sys.exit(1 if bad else 0)
PY

# 3. promtool.
# The unit tests compare labels; `check rules` above already parsed every
# annotation template, so the copy they run on drops the annotations.
mkdir -p "$TMP/t"
cp "$HERE/tests/cloud-deploy/alerts.test.yml" "$TMP/t/"
python3 - "$TMP/cloud.rules.yml" "$TMP/t/cloud.rules.yml" <<'PY' || { echo "FAIL: cannot parse the Cloud rule group"; exit 1; }
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for g in doc["groups"]:
    for r in g["rules"]:
        r.pop("annotations", None)
yaml.safe_dump(doc, open(sys.argv[2], "w"), sort_keys=False)
PY
# promtool runs as nobody in the container.
chmod 755 "$TMP" "$TMP/t" && chmod 644 "$TMP/cloud.rules.yml" "$TMP/t/"*
if ! docker run --rm --entrypoint promtool -v "$TMP:/w:ro" -w /w "$PROM_IMAGE" check rules cloud.rules.yml >"$TMP/check.log" 2>&1; then
  echo "FAIL: promtool check rules"; cat "$TMP/check.log"; FAILS=$((FAILS + 1))
fi
if ! docker run --rm --entrypoint promtool -v "$TMP/t:/w:ro" -w /w "$PROM_IMAGE" test rules alerts.test.yml >"$TMP/test.log" 2>&1; then
  echo "FAIL: promtool test rules"; cat "$TMP/test.log"; FAILS=$((FAILS + 1))
fi

if [ "$FAILS" -eq 0 ]; then echo "PASS: cloud deploy (console RBAC, env contract, alerts, metric allowlist)"; else echo "FAIL: $FAILS check group(s)"; exit 1; fi
