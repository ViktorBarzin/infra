#!/usr/bin/env bash
# Checks the Kubernetes and Vault boundaries of Cloud's reconciler and of
# Project secrets against a real API server (kind, Kubernetes 1.35 like the
# cluster) and a dev Vault, using exactly the rules Terraform applies:
#   stacks/cloud/access_rules.tf  ClusterRoles and ValidatingAdmissionPolicies
#   stacks/vault/cloud_policies.tf  Vault policies, the namespace selector and
#                                   the namespace-reader rule for Vault
# Both files hold only locals, so `terraform console` reads them offline.
#
# What it proves:
#   - the reconciler cannot read Secrets outside a Project namespace;
#   - it creates only p-* namespaces carrying the managed label and tier 4-aux,
#     cannot label or delete other namespaces, and writes only in managed
#     namespaces, even where RBAC would let it;
#   - it can bind the project role in its namespaces and no stronger role;
#   - in managed namespaces an ExternalSecret cannot use a ClusterSecretStore;
#   - Vault's cloud-project role admits only service account cloud-secrets in a
#     labelled namespace, only once Vault may read namespaces, and its token
#     reads only secret/cloud/<its namespace>/*;
#   - the cloud-reconciler policy writes secret/cloud/*, reads but cannot
#     change secret/cloud/system, and reads only its two database credentials.
# Needs docker, kind, kubectl, helm (for the External Secrets CRDs), vault and
# python3 with PyYAML. Takes about two minutes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
KIND_IMAGE="${CLOUD_ACCESS_KIND_IMAGE:-kindest/node:v1.35.0}"
ESO_VERSION="${CLOUD_ACCESS_ESO_VERSION:-2.12.0}"
CLUSTER="cloud-access-$$"
TMP="$(mktemp -d)"
VAULT_PID=""
cleanup() {
  [ -n "$VAULT_PID" ] && kill "$VAULT_PID" 2>/dev/null
  kind delete cluster --name "$CLUSTER" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

render() { # <src file> <expression> <out>
  local d; d="$(mktemp -d -p "$TMP")"
  cp "$1" "$d/" || { echo "FAIL: cannot copy $1"; exit 1; }
  if ! (cd "$d" && echo "$2" | terraform console >"$3" 2>"$d/err"); then
    echo "FAIL: terraform console could not evaluate $1 (it must hold only locals)"; cat "$d/err"; exit 1
  fi
}
render "$HERE/stacks/cloud/access_rules.tf" \
  'jsonencode({cluster = local.cloud_reconciler_cluster_rules, project = local.cloud_reconciler_project_rules, policies = local.cloud_admission_policies, project_role = local.cloud_project_role_name})' \
  "$TMP/k8s.raw"
render "$HERE/stacks/vault/cloud_policies.tf" \
  'jsonencode({reconciler = local.cloud_reconciler_policy, project = local.cloud_project_policy_template, selector = local.cloud_project_namespace_selector, ns_reader = local.vault_namespace_reader_rules})' \
  "$TMP/vault.raw"

python3 - "$TMP" <<'PY' || exit 1
import json, sys, pathlib, yaml
d = pathlib.Path(sys.argv[1])
k = json.loads(json.loads((d / "k8s.raw").read_text()))
v = json.loads(json.loads((d / "vault.raw").read_text()))

def rules(rs):
    out = []
    for r in rs:
        o = {"apiGroups": r["api_groups"], "resources": r["resources"], "verbs": r["verbs"]}
        if r.get("resource_names"):
            o["resourceNames"] = r["resource_names"]
        out.append(o)
    return out

sa = lambda name, ns: {"kind": "ServiceAccount", "name": name, "namespace": ns}
docs = [
    {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "cloud", "labels": {"tier": "4-aux"}}},
    {"apiVersion": "v1", "kind": "ServiceAccount", "metadata": {"name": "cloud-reconciler", "namespace": "cloud"}},
    {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRole", "metadata": {"name": "cloud-reconciler"}, "rules": rules(k["cluster"])},
    {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRole", "metadata": {"name": k["project_role"]}, "rules": rules(k["project"])},
    {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRoleBinding", "metadata": {"name": "cloud-reconciler"},
     "subjects": [sa("cloud-reconciler", "cloud")],
     "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "cloud-reconciler"}},
]
(d / "rbac.yaml").write_text(yaml.safe_dump_all(docs))
(d / "vap.yaml").write_text(yaml.safe_dump_all(list(k["policies"].values())))
(d / "project_role").write_text(k["project_role"])

vdocs = [
    {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "vault"}},
    {"apiVersion": "v1", "kind": "ServiceAccount", "metadata": {"name": "vault", "namespace": "vault"}},
    {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRoleBinding", "metadata": {"name": "vault-auth-delegator"},
     "subjects": [sa("vault", "vault")],
     "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "system:auth-delegator"}},
    {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRole", "metadata": {"name": "vault-namespace-reader"}, "rules": rules(v["ns_reader"])},
]
(d / "vault-sa.yaml").write_text(yaml.safe_dump_all(vdocs))
(d / "vault-ns-reader-binding.yaml").write_text(yaml.safe_dump(
    {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRoleBinding", "metadata": {"name": "vault-namespace-reader"},
     "subjects": [sa("vault", "vault")],
     "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "vault-namespace-reader"}}))
(d / "reconciler.hcl").write_text(v["reconciler"])
(d / "project.hcl.tpl").write_text(v["project"])
(d / "selector.json").write_text(v["selector"])
PY

helm template eso external-secrets --repo https://charts.external-secrets.io --version "$ESO_VERSION" \
  --include-crds --set installCRDs=true >"$TMP/eso.yaml" 2>"$TMP/helm.err" || { echo "FAIL: helm template external-secrets"; cat "$TMP/helm.err"; exit 1; }
python3 - "$TMP/eso.yaml" "$TMP/eso-crds.yaml" <<'PY' || exit 1
import sys, yaml
want = {"externalsecrets.external-secrets.io", "secretstores.external-secrets.io", "clustersecretstores.external-secrets.io"}
crds = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d.get("kind") == "CustomResourceDefinition" and d["metadata"]["name"] in want]
assert len(crds) == 3, [c["metadata"]["name"] for c in crds]
open(sys.argv[2], "w").write(yaml.safe_dump_all(crds))
PY

export KUBECONFIG="$TMP/kubeconfig"
kind create cluster --name "$CLUSTER" --image "$KIND_IMAGE" --kubeconfig "$KUBECONFIG" --wait 120s >"$TMP/kind.log" 2>&1 \
  || { echo "FAIL: kind create cluster"; tail -20 "$TMP/kind.log"; exit 1; }

ka() { kubectl "$@"; }
kr() { kubectl --as="system:serviceaccount:cloud:cloud-reconciler" "$@"; }
ka apply --server-side -f "$TMP/eso-crds.yaml" >/dev/null && ka wait --for=condition=Established crd --all --timeout=60s >/dev/null \
  || { echo "FAIL: ESO CRDs"; exit 1; }
# Stand-ins for the Traefik CRDs, so discovery knows the resources RBAC names.
for kind in IngressRoute Middleware; do
  plural="$(tr '[:upper:]' '[:lower:]' <<<"$kind")s"
  cat <<EOF
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: $plural.traefik.io
spec:
  group: traefik.io
  scope: Namespaced
  names: {kind: $kind, plural: $plural, singular: $(tr '[:upper:]' '[:lower:]' <<<"$kind")}
  versions:
  - name: v1alpha1
    served: true
    storage: true
    schema:
      openAPIV3Schema: {type: object, x-kubernetes-preserve-unknown-fields: true}
---
EOF
done | ka apply -f - >/dev/null && ka wait --for=condition=Established crd --all --timeout=60s >/dev/null || { echo "FAIL: Traefik CRDs"; exit 1; }
ka apply -f "$TMP/rbac.yaml" >/dev/null || { echo "FAIL: RBAC"; exit 1; }
ka apply -f "$TMP/vap.yaml" >"$TMP/vap.out" 2>&1 || { echo "FAIL: admission policies"; cat "$TMP/vap.out"; exit 1; }
# A policy is enforced only once the API server has compiled it.
for _ in $(seq 1 60); do
  ka get validatingadmissionpolicy cloud-reconciler-scope -o jsonpath='{.status.typeChecking}' >/dev/null 2>&1 \
    && ! kr create namespace probe-not-p --dry-run=server >/dev/null 2>&1 && break
  sleep 1
done
warn="$(ka get validatingadmissionpolicy -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.typeChecking.expressionWarnings}{"\n"}{end}')"

TOKEN_FILE="$HOME/.vault-token"
token_sum() { [ -f "$TOKEN_FILE" ] && sha256sum "$TOKEN_FILE" | cut -d' ' -f1 || echo absent; }
TOKEN_BEFORE="$(token_sum)"
FAILS=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; FAILS=$((FAILS + 1)); }
expect_ok()   { local what="$1"; shift; if out="$("$@" 2>&1)"; then ok "$what"; else bad "$what: $out"; fi; }
expect_fail() { local what="$1" pattern="$2"; shift 2
  if out="$("$@" 2>&1)"; then bad "$what: succeeded, expected failure"
  elif grep -qiE "$pattern" <<<"$out"; then ok "$what"; else bad "$what: wrong error: $out"; fi; }
can()    { [ "$(kr auth can-i "$@" 2>/dev/null)" = "yes" ]; }
cannot() { ! can "$@"; }
apply_as() { local who="$1"; shift; "$who" apply -f - "$@"; }

if grep -q '\[' <<<"$(sed 's/^[^:]*: //' <<<"$warn" | tr -d '\n')"; then bad "policy type-check warnings: $warn"; else ok "policies type-check cleanly against the ESO $ESO_VERSION CRDs"; fi

ns_doc() { # name managed tier
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n  labels:\n' "$1"
  [ -n "$2" ] && printf '    cloud.viktorbarzin.me/managed: "%s"\n' "$2"
  [ -n "$3" ] && printf '    tier: "%s"\n' "$3"
  true
}
rb_doc() { # namespace clusterrole
  printf 'apiVersion: rbac.authorization.k8s.io/v1\nkind: RoleBinding\nmetadata:\n  name: cloud-reconciler-%s\n  namespace: %s\nsubjects:\n- kind: ServiceAccount\n  name: cloud-reconciler\n  namespace: cloud\nroleRef:\n  apiGroup: rbac.authorization.k8s.io\n  kind: ClusterRole\n  name: %s\n' "$2" "$1" "$2"
}
cm_doc() { printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: probe\n  namespace: %s\ndata:\n  a: b\n' "$1"; }
PROJECT_ROLE="$(cat "$TMP/project_role")"

# --- RBAC --------------------------------------------------------------------
cannot get secrets -n kube-system && ok "reconciler cannot read Secrets in kube-system" || bad "reconciler reads Secrets in kube-system"
cannot list secrets --all-namespaces && ok "reconciler cannot list Secrets cluster-wide" || bad "reconciler lists Secrets cluster-wide"
cannot list pods -n kube-system && ok "reconciler cannot list Pods" || bad "reconciler lists Pods"
cannot create clusterroles && ok "reconciler cannot create ClusterRoles" || bad "reconciler creates ClusterRoles"
can list ingresses.networking.k8s.io --all-namespaces && ok "reconciler lists Ingresses cluster-wide" || bad "reconciler cannot list Ingresses"
can list ingressroutes.traefik.io --all-namespaces && ok "reconciler lists IngressRoutes cluster-wide" || bad "reconciler cannot list IngressRoutes"
cannot create ingresses.networking.k8s.io -n default && ok "reconciler cannot write Ingresses outside its namespaces" || bad "reconciler writes Ingresses anywhere"

# --- namespaces --------------------------------------------------------------
expect_ok   "reconciler creates p-demo (managed, tier 4-aux)" apply_as kr < <(ns_doc p-demo true 4-aux)
expect_ok   "reconciler creates p-other (managed, tier 4-aux)" apply_as kr < <(ns_doc p-other true 4-aux)
expect_fail "reconciler cannot create p-bare without the managed label" "cloud-reconciler may manage only" apply_as kr < <(ns_doc p-bare "" 4-aux)
expect_fail "reconciler cannot create a managed namespace not named p-*" "cloud-reconciler may manage only" apply_as kr < <(ns_doc demo true 4-aux)
expect_fail "reconciler cannot give its namespace another tier" "cloud-reconciler may manage only" apply_as kr < <(ns_doc p-core true 0-core)
expect_fail "reconciler cannot label default as managed" "cloud-reconciler may" kr label namespace default cloud.viktorbarzin.me/managed=true tier=4-aux
expect_ok   "admin creates homelab-app, a namespace Cloud does not own" ka create namespace homelab-app
expect_fail "reconciler cannot delete homelab-app" "cloud-reconciler may manage only" kr delete namespace homelab-app --wait=false
expect_ok   "admin creates p-adopt without the label" apply_as ka < <(ns_doc p-adopt "" 4-aux)
expect_fail "reconciler cannot adopt p-adopt by labelling it" "may not label an existing namespace" kr label namespace p-adopt cloud.viktorbarzin.me/managed=true

# --- RoleBindings and writes inside namespaces -------------------------------
expect_ok   "reconciler binds the project role in p-demo" apply_as kr < <(rb_doc p-demo "$PROJECT_ROLE")
expect_fail "reconciler cannot bind admin in p-demo" "forbidden" apply_as kr < <(rb_doc p-demo admin)
expect_fail "reconciler cannot bind the project role in default" "cloud-reconciler may write only" apply_as kr < <(rb_doc default "$PROJECT_ROLE")
expect_ok   "reconciler writes a ConfigMap in p-demo" apply_as kr < <(cm_doc p-demo)
expect_ok   "reconciler reads Secrets in p-demo" kr get secrets -n p-demo
expect_fail "reconciler cannot write in p-other before binding there" "forbidden" apply_as kr < <(cm_doc p-other)
expect_ok   "admin binds the project role in unlabelled p-adopt (a mistake)" apply_as ka < <(rb_doc p-adopt "$PROJECT_ROLE")
expect_fail "admission still stops the reconciler writing in p-adopt" "cloud-reconciler may write only" apply_as kr < <(cm_doc p-adopt)

# --- ExternalSecrets ---------------------------------------------------------
es_doc() { # ns kind [data-kind]
  cat <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: probe-$(tr '[:upper:]' '[:lower:]' <<<"$2-${3:-none}")
  namespace: $1
spec:
  secretStoreRef:
    name: store
    kind: $2
  target:
    name: probe
  data:
  - secretKey: a
    remoteRef:
      key: cloud/$1/app
      property: a
EOF
  [ -n "${3:-}" ] && printf '    sourceRef:\n      storeRef:\n        name: other\n        kind: %s\n' "$3"
  true
}
expect_ok   "an ExternalSecret on a SecretStore is admitted in p-demo" apply_as kr < <(es_doc p-demo SecretStore)
expect_fail "an ExternalSecret on a ClusterSecretStore is refused in p-demo" "must be a SecretStore" apply_as kr < <(es_doc p-demo ClusterSecretStore)
expect_fail "admin is refused the same in p-demo" "must be a SecretStore" apply_as ka < <(es_doc p-demo ClusterSecretStore)
expect_fail "a data[] sourceRef to a ClusterSecretStore is refused in p-demo" "data\\[\\]" apply_as kr < <(es_doc p-demo SecretStore ClusterSecretStore)
expect_ok   "a ClusterSecretStore reference outside managed namespaces is untouched" apply_as ka < <(es_doc default ClusterSecretStore)

expect_ok   "reconciler deletes p-other" kr delete namespace p-other --wait=false

# --- Vault -------------------------------------------------------------------
VPORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
export VAULT_ADDR="http://127.0.0.1:$VPORT" VAULT_TOKEN="root-$$"
# A dev server writes its root token to the token helper, ~/.vault-token by
# default, which on the devvm holds the user's real Vault token. Never let it:
# -dev-no-store-token, and every vault call runs with HOME in the temp dir.
mkdir -p "$TMP/home"
vault() { HOME="$TMP/home" command vault "$@"; }
vtok() { local t="$1"; shift; HOME="$TMP/home" VAULT_TOKEN="$t" command vault "$@"; }
# `command`, not the function, so $! is Vault's own pid and cleanup stops it.
HOME="$TMP/home" command vault server -dev -dev-no-store-token -dev-root-token-id="$VAULT_TOKEN" -dev-listen-address="127.0.0.1:$VPORT" >"$TMP/vault.log" 2>&1 &
VAULT_PID=$!
for _ in $(seq 1 30); do vault status >/dev/null 2>&1 && break; sleep 1; done
vault status >/dev/null 2>&1 || { echo "FAIL: dev vault did not start"; tail "$TMP/vault.log"; exit 1; }

ka apply -f "$TMP/vault-sa.yaml" >/dev/null || { echo "FAIL: vault service account"; exit 1; }
for n in p-demo p-adopt default; do ka create serviceaccount cloud-secrets -n "$n" >/dev/null; done
ka create serviceaccount other -n p-demo >/dev/null
kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d >"$TMP/ca.crt"
SERVER="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')"
vault auth enable kubernetes >/dev/null
vault write auth/kubernetes/config kubernetes_host="$SERVER" kubernetes_ca_cert=@"$TMP/ca.crt" \
  token_reviewer_jwt="$(ka create token vault -n vault --duration=1h)" disable_local_ca_jwt=true >/dev/null
ACCESSOR="$(vault auth list -format=json | python3 -c 'import json,sys; print(json.load(sys.stdin)["kubernetes/"]["accessor"])')"
sed "s/@@KUBERNETES_ACCESSOR@@/$ACCESSOR/" "$TMP/project.hcl.tpl" >"$TMP/project.hcl"
vault policy write cloud-project "$TMP/project.hcl" >/dev/null
vault policy write cloud-reconciler "$TMP/reconciler.hcl" >/dev/null
vault write auth/kubernetes/role/cloud-project bound_service_account_names=cloud-secrets \
  bound_service_account_namespace_selector="$(cat "$TMP/selector.json")" token_policies=cloud-project token_ttl=3600 >/dev/null
vault write auth/kubernetes/role/cloud-reconciler bound_service_account_names=cloud-reconciler \
  bound_service_account_namespaces=cloud token_policies=cloud-reconciler token_ttl=3600 >/dev/null
vault kv put secret/cloud/p-demo/app a=demo >/dev/null
vault kv put secret/cloud/p-other/app a=other >/dev/null
vault kv put secret/cloud/system authentik_token=t ghcr_pull_token=g >/dev/null
vault kv put secret/viktor x=y >/dev/null

login() { # role namespace sa
  vault write -field=token auth/kubernetes/login role="$1" jwt="$(ka create token "$3" -n "$2" --duration=10m)"
}
expect_fail "cloud-project login fails while Vault cannot read namespaces" "namespace|forbidden|permission denied" login cloud-project p-demo cloud-secrets
ka apply -f "$TMP/vault-ns-reader-binding.yaml" >/dev/null
for _ in $(seq 1 15); do login cloud-project p-demo cloud-secrets >/dev/null 2>&1 && break; sleep 1; done
expect_ok   "cloud-project login works from a managed namespace once Vault reads namespaces" login cloud-project p-demo cloud-secrets
expect_fail "cloud-project login refused from an unlabelled namespace" "namespace|not authorized|permission denied" login cloud-project p-adopt cloud-secrets
expect_fail "cloud-project login refused from default" "namespace|not authorized|permission denied" login cloud-project default cloud-secrets
expect_fail "cloud-project login refused for another service account" "service account|not authorized|permission denied" login cloud-project p-demo other

PT="$(login cloud-project p-demo cloud-secrets 2>/dev/null)"
expect_ok   "p-demo token reads secret/cloud/p-demo/app" vtok "$PT" kv get -field=a secret/cloud/p-demo/app
expect_fail "p-demo token cannot read secret/cloud/p-other/app" "permission denied" vtok "$PT" kv get secret/cloud/p-other/app
expect_fail "p-demo token cannot read secret/cloud/system" "permission denied" vtok "$PT" kv get secret/cloud/system
expect_fail "p-demo token cannot read secret/viktor" "permission denied" vtok "$PT" kv get secret/viktor
expect_fail "p-demo token cannot write its own tree" "permission denied" vtok "$PT" kv put secret/cloud/p-demo/app a=x

RT="$(login cloud-reconciler cloud cloud-reconciler 2>/dev/null)"
[ -n "$RT" ] && ok "cloud-reconciler logs in from namespace cloud" || bad "cloud-reconciler login"
expect_ok   "reconciler writes a Project secret" vtok "$RT" kv put secret/cloud/p-demo/new a=1
expect_ok   "reconciler deletes a Project secret" vtok "$RT" kv metadata delete secret/cloud/p-demo/new
expect_ok   "reconciler reads secret/cloud/system" vtok "$RT" kv get -field=authentik_token secret/cloud/system
expect_fail "reconciler cannot change secret/cloud/system" "permission denied" vtok "$RT" kv put secret/cloud/system authentik_token=x
expect_fail "reconciler cannot read secret/viktor" "permission denied" vtok "$RT" kv get secret/viktor
expect_fail "reconciler cannot write a Vault policy" "permission denied" vtok "$RT" policy write x "$TMP/project.hcl"
caps() { vtok "$RT" token capabilities "$1" 2>&1; }
[ "$(caps database/static-creds/pg-cloud-state)" = "read" ] && ok "reconciler reads pg-cloud-state" || bad "pg-cloud-state caps: $(caps database/static-creds/pg-cloud-state)"
[ "$(caps database/static-creds/pg-cloud-provisioner)" = "read" ] && ok "reconciler reads pg-cloud-provisioner" || bad "pg-cloud-provisioner caps"
[ "$(caps database/static-creds/pg-terraform-state)" = "deny" ] && ok "reconciler cannot read pg-terraform-state" || bad "pg-terraform-state caps: $(caps database/static-creds/pg-terraform-state)"
[ "$(caps auth/kubernetes/role/cloud-project)" = "deny" ] && ok "reconciler cannot touch auth roles" || bad "auth role caps"

[ "$(token_sum)" = "$TOKEN_BEFORE" ] && ok "~/.vault-token untouched" || bad "~/.vault-token CHANGED by this test"

echo
if [ "$FAILS" -eq 0 ]; then echo "PASS: cloud reconciler and Project secret boundaries"; else echo "FAIL: $FAILS check(s)"; exit 1; fi
