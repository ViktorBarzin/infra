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
#      M5: the reconciler gets every secret/cloud/system override
#      systemSecretsFromEnv() reads as a file, builds are off unless the
#      stack's builds_enabled says otherwise, and the console gets what
#      buildApiSettings() and the logs tab read. The ExternalSecrets that
#      copy secret/cloud/system render a key Vault does not hold yet as an
#      empty value instead of failing the sync.
#   3. The Cloud alert group in stacks/monitoring (prometheus_chart_values.tpl)
#      passes `promtool check rules` and the unit tests in
#      tests/cloud-deploy/alerts.test.yml: what fires, after how long, and
#      that only the reconciler being down and a stuck queue page.
#   4. The kubernetes-service-endpoints keep regex admits every cloud_ metric
#      the alerts read, so none is dropped at scrape time.
#   5. Cloud's email scope mapping (stacks/cloud email_claim.tf) says
#      email_verified true for exactly the accounts stacks/authentik's
#      cloud-apps-active-users policy admits, both run as Python on the same
#      accounts, and both of Cloud's providers send it in place of the
#      managed scope-email.
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
if ! (cd "$TMP/locals" && echo 'jsonencode({console_rules = local.cloud_console_cluster_rules, console_env = local.cloud_console_env, reconciler_env = local.cloud_reconciler_env, reconciler_files = local.cloud_reconciler_files, reconciler_reload = local.cloud_reconciler_reload, secretstore_vault = local.cloud_secretstore_vault_server, console_secret_env = local.cloud_console_secret_env, reconciler_system_template = local.cloud_reconciler_system_template, console_system_template = local.cloud_console_system_template, reconciler_system_keys = local.cloud_reconciler_system_keys, console_system_keys = local.cloud_console_system_keys, reconciler_system_secret = local.cloud_reconciler_system_secret, console_system_secret = local.cloud_console_system_secret})' \
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
read = set(re.findall(r'\b(?:env|list|wholeNumber|positiveNumber|pinnedImage)\("([A-Z0-9_]+)"', src))
secrets = set(re.findall(r'\b(?:secret|required)\("([A-Z0-9_]+)"', src))
required = set(re.findall(r'\brequired\("([A-Z0-9_]+)"', src))
# systemSecretsFromEnv() reads its names from a table: ["key", "NAME"].
m = re.search(r'export function systemSecretsFromEnv\(\)[\s\S]*?\n}\n', src)
system = set(re.findall(r'\["[A-Za-z]+",\s*"([A-Z0-9_]+)"\]', m.group(0))) if m else set()
if not system:
    bad.append("cannot find the override names in systemSecretsFromEnv()")
secrets |= system
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

console_secret = [{"name": e["name"]} for e in loc["console_secret_env"]]
for who, env in (("console", loc["console_env"] + console_secret), ("reconciler", loc["reconciler_env"])):
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
# M5. Builds: one switch, off until the GitHub tokens exist; the code reads
# it as on unless it is one of its off words.
if renv.get("BUILDS_ENABLED") not in ("true", "false"):
    bad.append(f"the reconciler's BUILDS_ENABLED is {renv.get('BUILDS_ENABLED')!r}, want true or false")
for n in ("FORGEJO_URL", "FORGEJO_AUTH_SOURCE_ID"):
    if n not in renv:
        bad.append(f"the reconciler does not get {n}")
if not re.fullmatch(r"\d+", renv.get("FORGEJO_AUTH_SOURCE_ID", "")):
    bad.append("FORGEJO_AUTH_SOURCE_ID must be a whole number")
# Every override systemSecretsFromEnv() reads comes from the system Secret.
for n in sorted(system):
    f = files.get(n)
    if f is None or f["secret"] != loc["reconciler_system_secret"]:
        bad.append(f"the reconciler does not get {n} as a file from {loc['reconciler_system_secret']}")
    if n not in loc["reconciler_system_keys"]:
        bad.append(f"{n} has no secret/cloud/system key in cloud_reconciler_system_keys")
# The console: what buildApiSettings() reads (GITHUB_API_URL is the e2e
# stub's) and Loki for the logs tab. The two secrets come from Secret keys,
# optional, so a key not in Vault yet leaves the variable unset.
cenv = {e["name"] for e in loc["console_env"]}
for n in ("PROMETHEUS_URL", "LOKI_URL"):
    if n not in cenv:
        bad.append(f"the console does not get {n}")
csec = {e["name"]: e for e in loc["console_secret_env"]}
for n in ("SECRETS_PUBLIC_KEY", "GITHUB_API_TOKEN"):
    e = csec.get(n)
    if e is None or e["secret"] != loc["console_system_secret"]:
        bad.append(f"the console does not get {n} from {loc['console_system_secret']}")
    elif e.get("optional") is False:
        bad.append(f"the console's {n} must be optional")
if "BUILDS_ENABLED" in cenv:
    bad.append("the console gets BUILDS_ENABLED; only the reconciler reads it (buildsConfig)")
# ESO renders templates with missingkey=error: `{{ .key }}` fails the whole
# sync while the key is missing from Vault, `{{ index . "key" }}` renders "".
for who, tpl, keys in (("reconciler", loc["reconciler_system_template"], loc["reconciler_system_keys"]),
                       ("console", loc["console_system_template"], loc["console_system_keys"])):
    want_vals = {f'{{{{ index . "{k}" }}}}' for k in keys.values()}
    if set(tpl.values()) != want_vals:
        bad.append(f"the {who} system template is {sorted(tpl.values())}, want {sorted(want_vals)}")
    if "secrets_private_key" in keys.values() and who == "console":
        bad.append("the console must never get secrets_private_key")
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

# 5. The email claim agrees with the vouch policy.
python3 - "$HERE" <<'PY' || FAILS=$((FAILS + 1))
import pathlib, re, sys, textwrap
from types import SimpleNamespace as NS

root = pathlib.Path(sys.argv[1])
bad = []

def heredoc(text, start):
    m = re.search(re.escape(start) + r'\s*=\s*<<-EOT\n(.*?)\n\s*EOT', text, re.S)
    return textwrap.dedent(m.group(1)) if m else None

def local(text, name):
    m = re.search(r'^\s*' + name + r'\s*=\s*"([^"]*)"', text, re.M)
    return m.group(1) if m else None

apps = (root / "stacks/authentik/cloud-apps.tf").read_text()
claim_tf = (root / "stacks/cloud/email_claim.tf").read_text()
m = re.search(r'resource "authentik_policy_expression" "cloud_apps_active_users" \{(.*?)\n\}', apps, re.S)
policy = heredoc(m.group(1), "expression") if m else None
claim = heredoc(claim_tf, "cloud_email_claim_expression")
if policy is None or claim is None:
    print("FAIL: cannot find the cloud-apps-active-users expression or cloud_email_claim_expression")
    sys.exit(1)
policy = policy.replace("${local.cloud_apps_verified_path}", local(apps, "cloud_apps_verified_path"))
claim = claim.replace("${local.cloud_email_verified_path}", local(claim_tf, "cloud_email_verified_path"))
if "${" in policy or "${" in claim:
    print("FAIL: an expression has an interpolation this test does not fill in")
    sys.exit(1)

def run(body, user):
    src = "def f(request):\n" + textwrap.indent(body, "    ")
    scope = {}
    exec(src, scope)
    return scope["f"](NS(user=user))

def user(**kw):
    base = dict(is_authenticated=True, is_active=True, username="someone", type="internal",
                path="users", attributes={}, email="someone@example.com")
    base.update(kw)
    return NS(**base)

src_attr = {"goauthentik.io/user/sources": ["google"]}
cases = {
    "social source": user(attributes=src_attr),
    "passkey verified path": user(path="users/email-verified"),
    "admin vouched": user(attributes={"cloud_apps_email_vouched": True}),
    "vouched as the string true": user(attributes={"cloud_apps_email_vouched": "true"}),
    "plain invitee": user(),
    "proxy-only with a source": user(attributes={**src_attr, "proxy_only": True}),
    "inactive with a source": user(is_active=False, attributes=src_attr),
    "guest with a source": user(username="guest", attributes=src_attr),
    "service account with a source": user(type="service_account", attributes=src_attr),
    "internal service account": user(type="internal_service_account", path="users/email-verified"),
    "no attributes": user(attributes=None),
    "empty sources list": user(attributes={"goauthentik.io/user/sources": []}),
}
answers = []
for name, u in cases.items():
    want = bool(run(policy, u))
    answers.append(want)
    got = run(claim, u)
    if got.get("email") != u.email:
        bad.append(f"{name}: the claim sends email {got.get('email')!r}, want {u.email!r}")
    if got.get("email_verified") is not want:
        bad.append(f"{name}: email_verified is {got.get('email_verified')!r}, the policy says {want}")
if all(answers) or not any(answers):
    bad.append("the test accounts do not cover both answers")

# Both providers send it, and not the managed mapping beside it.
console = (root / "stacks/cloud/console.tf").read_text()
cli = (root / "stacks/cloud/cli_sign_in.tf").read_text()
if not re.search(r'email_scope_mapping_id\s*=\s*authentik_property_mapping_provider_scope\.cloud_email\.id', console):
    bad.append("the console's provider does not get email_scope_mapping_id = the cloud_email mapping")
m = re.search(r'resource "authentik_provider_oauth2" "cloud_cli" \{.*?property_mappings\s*=\s*\[(.*?)\]', cli, re.S)
if not m or "authentik_property_mapping_provider_scope.cloud_email.id" not in m.group(1):
    bad.append("cloud-cli does not send the cloud_email mapping")
if "scope-email" in cli:
    bad.append("cloud-cli still looks up the managed scope-email")

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

if [ "$FAILS" -eq 0 ]; then echo "PASS: cloud deploy (console RBAC, env contract, alerts, metric allowlist, email claim)"; else echo "FAIL: $FAILS check group(s)"; exit 1; fi
