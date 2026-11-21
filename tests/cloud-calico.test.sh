#!/usr/bin/env bash
# Checks that Calico enforces Cloud's network isolation, on a real Calico
# (the version stacks/calico pins, installed by its tigera-operator chart) in
# kind with the default CNI turned off. tests/cloud-access.test.sh runs on
# the same Calico with every admission policy applied (calico-apiserver runs
# them too) and checks the API stays available; this test runs the floors
# through Felix with probe pods, so it applies no admission policies (the
# probe pods carry Cloud's labels without Cloud's pinned images).
#
#   1. Tier `cloud` and both floors (stacks/cloud access_rules.tf, read with
#      `terraform console`) are applied through the real calico-apiserver.
#   2. tests/cloud-calico-tier.live.sh runs against this cluster: calico-
#      apiserver refuses the reconciler a policy in any tier but `default`,
#      and refuses it the floors, GlobalNetworkPolicies and Tiers.
#   3. Cloud's renderer and real OpenTofu modules apply a Project (a private
#      App, a public App connected to a Postgres Service and to an internal
#      App, the internal App, the Postgres Service) as the reconciler, so Cloud's own Project policy goes through
#      calico-apiserver and the reconciler's RBAC there. While it exists,
#      tests/cloud-calico/matrix.sh checks a connectivity matrix with probe
#      pods carrying Cloud's labels: Traefik reaches every App's edge only,
#      and only an edge pod with the Caddyfile digest label (none from before
#      app-kit K1);
#      each edge reaches only its own App and its own oauth2-proxy on 4180;
#      oauth2-proxy reaches no edge and no App; only the App that connects
#      to the internal App reaches it, on the App port 3000, and no other
#      App, edge, Traefik, homelab namespace or other Project does; in a
#      Project with no policy the floor alone keeps another Project off a
#      public App's pods on 3000 (it passes only access=internal pods); App pods reach the CNPG primary and DNS, and
#      not the Authentik server, a replica, Vault, other namespaces, the API
#      server ClusterIP, the node or the home WAN IP; oauth2-proxy reaches the
#      Authentik server; the kubelet's readiness probes pass the floors; TCP
#      25, 465, 587 and 2525 are denied even to a pod the sender may reach on
#      8080 (and to smtp.gmail.com with CLOUD_CALICO_INTERNET=1, where
#      1.1.1.1:443 connects).
#      Cloud's Project policy for a Project with no Key Value keeps App pods
#      off cloud-redis (B27).
#      Then, with an allow-all Project policy in the default tier, the floor
#      alone still denies Traefik to oauth2-proxy pods, oauth2-proxy pods to
#      edge pods (the private App's path before app-kit K1), Traefik to
#      App pods (the internal App too), App pods to App pods off the App
#      port, a homelab namespace to the internal App, and the mail ports; it
#      passes App pods and a toolbox pod to cloud-redis on 6379 (B27)
#      and still denies the toolbox everything else.
#
# Needs docker, kind, kubectl, helm, python3 with PyYAML, bun, terraform (for
# `terraform console`) and a cloud repo checkout with its pinned OpenTofu and
# provider mirror (.tools/). CLOUD_REPO as in cloud-access.test.sh. Set
# CLOUD_CALICO_INTERNET=1 where pods can reach 1.1.1.1:443.
#
# The kind cluster and Calico come from tests/cloud-calico/kind.sh, which
# refuses to start when too many other kind clusters hold inotify instances.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=cloud-calico/kind.sh
. "$HERE/tests/cloud-calico/kind.sh"
KIND_IMAGE="${CLOUD_CALICO_KIND_IMAGE:-kindest/node:v1.35.0}"
CALICO_VERSION="${CLOUD_CALICO_VERSION:-$(grep -m1 -oP '^\s*version\s*=\s*"\Kv[0-9.]+' "$HERE/stacks/calico/main.tf")}"
ESO_VERSION="${CLOUD_CALICO_ESO_VERSION:-$(grep -m1 -oP '^\s*version\s*=\s*"\K[0-9.]+' "$HERE/stacks/external-secrets/main.tf")}"
AGNHOST_IMAGE="${CLOUD_CALICO_AGNHOST:-registry.k8s.io/e2e-test-images/agnhost:2.53}"
BUN="${BUN:-/usr/local/bin/bun}"
if [ -z "${CLOUD_REPO:-}" ]; then
  for c in "$HOME/code/cloud" "$HOME/code/cloud/.worktrees/v1-m2-reconciler"; do
    [ -f "$c/modules/project/main.tf" ] && CLOUD_REPO="$c" && break
  done
fi
[ -n "${CLOUD_REPO:-}" ] && [ -f "$CLOUD_REPO/modules/project/main.tf" ] && [ -f "$CLOUD_REPO/src/reconciler/render.ts" ] \
  || { echo "FAIL: no cloud repo with modules/project and src/reconciler/render.ts; set CLOUD_REPO"; exit 1; }
TOFU="${TOFU_BIN:-$CLOUD_REPO/.tools/tofu}"
TOFU_PLUGINS="${TOFU_PLUGIN_DIR:-$CLOUD_REPO/.tools/providers}"
[ -x "$TOFU" ] && [ -d "$TOFU_PLUGINS" ] || { echo "FAIL: no pinned OpenTofu at $TOFU or provider mirror at $TOFU_PLUGINS"; exit 1; }

cloud_calico_preflight || exit 1

CLUSTER="cloud-calico-$$"
TMP="$(mktemp -d)"
cleanup() { kind delete cluster --name "$CLUSTER" >/dev/null 2>&1; rm -rf "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/home"

FAILS=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; FAILS=$((FAILS + 1)); }

# --- what infra applies ------------------------------------------------------------
d="$TMP/console"; mkdir -p "$d"; cp "$HERE/stacks/cloud/access_rules.tf" "$d/"
# access_rules.tf reads the taken hosts from taken_hosts.tf, which needs a
# cluster; this test uses none of the policies.
printf 'locals {\n  cloud_taken_hosts = {}\n}\n' >"$d/taken_hosts_stub.tf"
(cd "$d" && echo 'jsonencode({cluster = local.cloud_reconciler_cluster_rules, project = local.cloud_reconciler_project_rules, project_role = local.cloud_project_role_name, tier = local.cloud_tier, floors = [local.cloud_project_egress_floor, local.cloud_project_ingress_floor]})' \
  | terraform console >"$TMP/k8s.raw" 2>"$d/err") || { echo "FAIL: terraform console on access_rules.tf"; cat "$d/err"; exit 1; }
(cd "$CLOUD_REPO" && HOME="$TMP/home" "$BUN" "$HERE/tests/cloud-access/render.ts" "$CLOUD_REPO" "$TMP/tofu") >"$TMP/render.log" 2>&1 \
  || { echo "FAIL: Cloud's renderer ($CLOUD_REPO)"; cat "$TMP/render.log"; exit 1; }
python3 - "$TMP" <<'PY' || exit 1
import json, sys, pathlib, yaml
d = pathlib.Path(sys.argv[1])
k = json.loads(json.loads((d / "k8s.raw").read_text()))
def rules(rs):
    out = []
    for r in rs:
        o = {"apiGroups": r["api_groups"], "resources": r["resources"], "verbs": r["verbs"]}
        if r.get("resource_names"):
            o["resourceNames"] = r["resource_names"]
        out.append(o)
    return out
sa = {"kind": "ServiceAccount", "name": "cloud-reconciler", "namespace": "cloud"}
(d / "rbac.yaml").write_text(yaml.safe_dump_all([
    {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "cloud"}},
    {"apiVersion": "v1", "kind": "ServiceAccount", "metadata": {"name": "cloud-reconciler", "namespace": "cloud"}},
    {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRole", "metadata": {"name": "cloud-reconciler"}, "rules": rules(k["cluster"])},
    {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRole", "metadata": {"name": k["project_role"]}, "rules": rules(k["project"])},
    {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRoleBinding", "metadata": {"name": "cloud-reconciler"}, "subjects": [sa],
     "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "cloud-reconciler"}},
]))
(d / "tier.yaml").write_text(yaml.safe_dump(k["tier"]))
(d / "floors.yaml").write_text(yaml.safe_dump_all(k["floors"]))
PY

helm template eso external-secrets --repo https://charts.external-secrets.io --version "$ESO_VERSION" \
  --include-crds --set installCRDs=true >"$TMP/eso.yaml" 2>"$TMP/helm.err" || { echo "FAIL: helm template external-secrets"; cat "$TMP/helm.err"; exit 1; }
python3 - "$TMP/eso.yaml" "$TMP/eso-crds.yaml" <<'PY' || exit 1
import sys, yaml
want = {"externalsecrets.external-secrets.io", "secretstores.external-secrets.io"}
crds = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d.get("kind") == "CustomResourceDefinition" and d["metadata"]["name"] in want]
open(sys.argv[2], "w").write(yaml.safe_dump_all(crds))
PY

# --- kind with Calico -----------------------------------------------------------------
export KUBECONFIG="$TMP/kubeconfig"
cloud_calico_kind_up "$CLUSTER" "$KIND_IMAGE" "$CALICO_VERSION" "$TMP" || exit 1
ok "Calico $CALICO_VERSION and calico-apiserver run in kind"

kubectl apply --server-side -f "$TMP/eso-crds.yaml" >/dev/null && kubectl wait --for=condition=Established crd --all --timeout=60s >/dev/null \
  || { echo "FAIL: ESO CRDs"; exit 1; }
printf 'apiVersion: scheduling.k8s.io/v1\nkind: PriorityClass\nmetadata:\n  name: tier-4-aux\nvalue: 200000\npreemptionPolicy: Never\n' | kubectl apply -f - >/dev/null
kubectl apply -f "$TMP/rbac.yaml" >/dev/null || { echo "FAIL: RBAC"; exit 1; }
if kubectl apply -f "$TMP/tier.yaml" >/dev/null 2>"$TMP/apply.err" && kubectl apply -f "$TMP/floors.yaml" >/dev/null 2>>"$TMP/apply.err"; then
  ok "calico-apiserver accepts tier cloud and both floors as infra renders them"
else
  bad "calico-apiserver refused the tier or a floor: $(cat "$TMP/apply.err")"
fi

# --- tier authorization ---------------------------------------------------------------
if bash "$HERE/tests/cloud-calico-tier.live.sh" >"$TMP/tier.log" 2>&1; then
  ok "calico-apiserver refuses the reconciler every tier but default ($(grep -c '^ok' "$TMP/tier.log") checks, tests/cloud-calico-tier.live.sh)"
else
  bad "tier authorization: $(grep -v '^ok' "$TMP/tier.log")"
fi
sed 's/^/     /' "$TMP/tier.log"

# --- stand-ins for the homelab --------------------------------------------------------
# Pods with the labels the floors and Cloud's policy select, each listening on
# the real service's port.
standin() { # namespace name labels(json) port
  kubectl get namespace "$1" >/dev/null 2>&1 || kubectl create namespace "$1" >/dev/null
  kubectl apply -f - >/dev/null <<EOF
{"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "$2", "namespace": "$1", "labels": $3},
 "spec": {"containers": [{"name": "c", "image": "$AGNHOST_IMAGE", "args": ["netexec", "--http-port=$4", "--udp-port=-1"]}]}}
EOF
}
standin traefik client '{"app.kubernetes.io/name": "traefik"}' 8080
standin homelab-app client '{"app": "client"}' 8080
standin authentik server '{"app.kubernetes.io/name": "authentik", "app.kubernetes.io/component": "server"}' 9000
standin dbaas primary '{"cnpg.io/cluster": "pg", "cnpg.io/instanceRole": "primary"}' 5432
standin dbaas replica '{"cnpg.io/cluster": "pg", "cnpg.io/instanceRole": "replica"}' 5432
standin vault vault '{"app.kubernetes.io/name": "vault"}' 8200
# cloud-redis (B27, Key Value), on its real port and label.
standin cloud-redis redis '{"app": "cloud-redis"}' 6379
kubectl create service clusterip pg -n dbaas --tcp=5432:5432 >/dev/null
kubectl set selector service pg -n dbaas 'cnpg.io/instanceRole=primary' >/dev/null
# Two more Project namespaces for the cross-Project checks, with no Project
# policy: p-third holds the floor-alone cases.
for n in p-other p-third; do cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: $n
  labels:
    cloud.viktorbarzin.me/managed: "true"
    pod-security.kubernetes.io/enforce: restricted
EOF
done
for n in traefik homelab-app authentik dbaas vault cloud-redis; do
  kubectl wait --for=condition=Ready pod --all -n "$n" --timeout=180s >/dev/null || { bad "stand-in pods in $n not Ready"; }
done

# --- Cloud's Project, applied as the reconciler -----------------------------------------
NS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["namespace"])' "$TMP/tofu/contract.json")"
SERVER="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')"
CA_DATA="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
cat >"$TMP/reconciler.kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters: [{name: kind, cluster: {server: "$SERVER", certificate-authority-data: "$CA_DATA"}}]
users: [{name: cloud-reconciler, user: {token: "$(kubectl create token cloud-reconciler -n cloud --duration=1h)"}}]
contexts: [{name: cloud-reconciler, context: {cluster: kind, user: cloud-reconciler}}]
current-context: cloud-reconciler
EOF
ln -s "$CLOUD_REPO/modules" "$TMP/tofu/modules"
: >"$TMP/tofu/tofurc"
cat >"$TMP/tofu/zz_matrix.tf.json" <<'EOF'
{"resource": {"terraform_data": {"cloud_calico_matrix": {
  "depends_on": ["module.project", "module.app", "module.postgres"],
  "provisioner": [{"local-exec": {"command": "bash \"$CLOUD_MATRIX_SCRIPT\""}}]
}}}}
EOF
cat >"$TMP/tofu/cloud-calico.tftest.hcl" <<'EOF'
mock_provider "postgresql" {}
mock_provider "random" {}
mock_provider "vault" {
  mock_data "vault_kv_secret_v2" {
    defaults = {
      data = {
        cloud_apps_client_id     = "cloud-apps"
        cloud_apps_client_secret = "s3cret"
      }
    }
  }
}
run "apply" {
  command = apply
}
EOF
: >"$TMP/results"
tofu() {
  # modules/project refuses an empty pull token (registry_password), so the
  # test passes a dummy one, as cloud-access.test.sh and the worker do.
  (cd "$TMP/tofu" && env HOME="$TMP/home" TF_CLI_CONFIG_FILE="$TMP/tofu/tofurc" TF_IN_AUTOMATION=1 \
    TF_VAR_registry_password=test-pull-token KUBE_CONFIG_PATH="$TMP/reconciler.kubeconfig" ADMIN_KUBECONFIG="$KUBECONFIG" CLOUD_NAMESPACE="$NS" \
    CALICO_RESULTS="$TMP/results" AGNHOST_IMAGE="$AGNHOST_IMAGE" CALICO_INTERNET="${CLOUD_CALICO_INTERNET:-0}" \
    CLOUD_MATRIX_SCRIPT="$HERE/tests/cloud-calico/matrix.sh" "$TOFU" "$@")
}
if ! tofu init -backend=false -input=false -no-color -plugin-dir="$TOFU_PLUGINS" >"$TMP/tofu-init.log" 2>&1; then
  bad "tofu init of Cloud's modules: $(tail -20 "$TMP/tofu-init.log")"
elif tofu test -no-color >"$TMP/tofu-test.log" 2>&1 && grep -q "1 passed, 0 failed" "$TMP/tofu-test.log"; then
  ok "Cloud's modules apply and destroy a private App, a public App, an internal App and a Postgres Service in $NS as the reconciler, through calico-apiserver"
else
  bad "Cloud's modules did not apply and destroy cleanly as the reconciler: $(grep -v '^\s*$' "$TMP/tofu-test.log" | tail -40)"
fi
while IFS= read -r line; do
  case "$line" in
    ok*) echo "$line" ;;
    FAIL*) echo "$line"; FAILS=$((FAILS + 1)) ;;
  esac
done <"$TMP/results"
n="$(grep -c . "$TMP/results")"
[ "$n" -ge 25 ] && ok "$n connectivity checks ran" || bad "only $n connectivity checks ran"

echo
if [ "$FAILS" -eq 0 ]; then echo "PASS: Calico enforces Cloud's tiers, floors and Project policy"; else echo "FAIL: $FAILS check(s)"; exit 1; fi
