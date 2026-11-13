#!/usr/bin/env bash
# Checks the Kubernetes and Vault boundaries of Cloud's reconciler and of
# Project secrets against a real API server (kind, Kubernetes 1.35 like the
# cluster) and a dev Vault, using exactly the rules Terraform applies:
#   stacks/cloud/access_rules.tf  ClusterRoles and ValidatingAdmissionPolicies
#   stacks/vault/cloud_policies.tf  Vault policies, the namespace selector and
#                                   the namespace-reader rule for Vault
#   stacks/kyverno/modules/kyverno/generate-conditions.tf  which namespaces get
#                                   Kyverno's tls-secret and registry copies
# All three hold only locals, so `terraform console` reads them offline.
#
# What it proves:
#   - the reconciler cannot read Secrets outside a Project namespace;
#   - it creates only p-* namespaces carrying the managed label, tier 4-aux and
#     Pod Security baseline or restricted, sets no other label (keys others
#     set may stay), cannot label or delete other namespaces, and writes only
#     in managed namespaces, even where RBAC would let it;
#   - Pod Security then refuses a hostPath pod in a Project namespace;
#   - it can bind the project role, only to itself, and no stronger role;
#   - in managed namespaces an ExternalSecret cannot use a ClusterSecretStore,
#     a SecretStore is only the cloud-project Vault store, a Service is
#     ClusterIP without externalIPs, an Ingress host is one unreserved label
#     under viktorbarzin.me with no tls.secretName and names only its own or
#     the shared Traefik middlewares, a Middleware cannot reach another
#     namespace (errors, chain, plugin, tap, foreign forwardAuth), and a pod
#     cannot take a priority class above tier-4-aux;
#   - every Traefik Middleware type in the pinned chart's CRD is either
#     allowed or refused, and every Vault auth method in the ESO CRD is
#     refused except Kubernetes;
#   - Kyverno's copy condition skips managed namespaces;
#   - Vault's cloud-project role admits only service account cloud-secrets in a
#     labelled namespace, only once Vault may read namespaces, and its token
#     reads only secret/cloud/<its namespace>/*;
#   - the cloud-reconciler policy writes secret/cloud/*, reads but cannot
#     change secret/cloud/system, and reads only its two database credentials.
# Needs docker, kind, kubectl, helm (for the External Secrets and Traefik CRDs), vault and
# python3 with PyYAML. Takes about two minutes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
KIND_IMAGE="${CLOUD_ACCESS_KIND_IMAGE:-kindest/node:v1.35.0}"
# The External Secrets chart version the cluster runs, read from its stack.
ESO_VERSION="${CLOUD_ACCESS_ESO_VERSION:-$(grep -m1 -oP '^\s*version\s*=\s*"\K[0-9.]+' "$HERE/stacks/external-secrets/main.tf")}"
# The Traefik chart version the cluster runs, read from its stack.
TRAEFIK_VERSION="${CLOUD_ACCESS_TRAEFIK_VERSION:-$(grep -m1 -oP '^\s*version\s*=\s*"\K[0-9.]+' "$HERE/stacks/traefik/modules/traefik/main.tf")}"
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
  'jsonencode({cluster = local.cloud_reconciler_cluster_rules, project = local.cloud_reconciler_project_rules, policies = local.cloud_admission_policies, project_role = local.cloud_project_role_name, mw_allowed = local.cloud_middleware_types_allowed, mw_refused = local.cloud_middleware_types_refused, auth_refused = local.cloud_secretstore_auth_refused})' \
  "$TMP/k8s.raw"
render "$HERE/stacks/vault/cloud_policies.tf" \
  'jsonencode({reconciler = local.cloud_reconciler_policy, project = local.cloud_project_policy_template, selector = local.cloud_project_namespace_selector, ns_reader = local.vault_namespace_reader_rules})' \
  "$TMP/vault.raw"
render "$HERE/stacks/kyverno/modules/kyverno/generate-conditions.tf" \
  'jsonencode({condition = local.generate_skip_system_namespaces})' \
  "$TMP/kyverno.raw"

python3 - "$TMP" <<'PY' || exit 1
import json, sys, pathlib, yaml
d = pathlib.Path(sys.argv[1])
k = json.loads(json.loads((d / "k8s.raw").read_text()))
v = json.loads(json.loads((d / "vault.raw").read_text()))
kc = json.loads(json.loads((d / "kyverno.raw").read_text()))["condition"]

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
(d / "types.json").write_text(json.dumps({"mw_allowed": k["mw_allowed"], "mw_refused": k["mw_refused"], "auth_refused": k["auth_refused"]}))
# Kyverno's copy condition on a real API server: a probe policy refuses a
# namespace labelled kyverno-probe exactly when Kyverno would copy the Secrets.
(d / "kyverno-probe.yaml").write_text(yaml.safe_dump_all([
    {"apiVersion": "admissionregistration.k8s.io/v1", "kind": "ValidatingAdmissionPolicy", "metadata": {"name": "probe-kyverno-copy"},
     "spec": {"failurePolicy": "Fail",
              "matchConstraints": {"resourceRules": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["CREATE"], "resources": ["namespaces"]}]},
              "matchConditions": [{"name": "probe", "expression": "has(object.metadata.labels) && 'kyverno-probe' in object.metadata.labels"},
                                  {"name": "target-namespace", "expression": kc}],
              "validations": [{"expression": "false", "message": "kyverno would copy tls-secret and registry-credentials here"}]}},
    {"apiVersion": "admissionregistration.k8s.io/v1", "kind": "ValidatingAdmissionPolicyBinding", "metadata": {"name": "probe-kyverno-copy"},
     "spec": {"policyName": "probe-kyverno-copy", "validationActions": ["Deny"]}},
]))
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
helm template traefik traefik --repo https://traefik.github.io/charts --version "$TRAEFIK_VERSION" --kube-version 1.35.0 \
  --include-crds >"$TMP/traefik.yaml" 2>"$TMP/helm.err" || { echo "FAIL: helm template traefik"; cat "$TMP/helm.err"; exit 1; }
python3 - "$TMP" <<'PY' || exit 1
import json, sys, pathlib, yaml
d = pathlib.Path(sys.argv[1])
want = {"middlewares.traefik.io", "ingressroutes.traefik.io"}
crds = [c for c in yaml.safe_load_all(open(d / "traefik.yaml")) if c and c.get("kind") == "CustomResourceDefinition" and c["metadata"]["name"] in want]
assert len(crds) == 2, [c["metadata"]["name"] for c in crds]
(d / "traefik-crds.yaml").write_text(yaml.safe_dump_all(crds))
t = json.loads((d / "types.json").read_text())
problems = []
mw = next(c for c in crds if c["metadata"]["name"] == "middlewares.traefik.io")
for ver in mw["spec"]["versions"]:
    have = set(ver["schema"]["openAPIV3Schema"]["properties"]["spec"]["properties"])
    known = set(t["mw_allowed"]) | set(t["mw_refused"])
    if have - known: problems.append(f"Middleware {ver['name']} types in neither list in access_rules.tf: {sorted(have - known)}")
    if known - have: problems.append(f"Middleware {ver['name']} lists name types the CRD lacks: {sorted(known - have)}")
eso = [c for c in yaml.safe_load_all(open(d / "eso-crds.yaml")) if c["metadata"]["name"] == "secretstores.external-secrets.io"][0]
for ver in eso["spec"]["versions"]:
    if not ver.get("served"): continue
    auth = set(ver["schema"]["openAPIV3Schema"]["properties"]["spec"]["properties"]["provider"]["properties"]["vault"]["properties"]["auth"]["properties"])
    extra = auth - set(t["auth_refused"]) - {"kubernetes"}
    if extra: problems.append(f"ESO {ver['name']} Vault auth methods not refused: {sorted(extra)}")
(d / "tripwire.txt").write_text("\n".join(problems))
PY

export KUBECONFIG="$TMP/kubeconfig"
kind create cluster --name "$CLUSTER" --image "$KIND_IMAGE" --kubeconfig "$KUBECONFIG" --wait 120s >"$TMP/kind.log" 2>&1 \
  || { echo "FAIL: kind create cluster"; tail -20 "$TMP/kind.log"; exit 1; }

ka() { kubectl "$@"; }
kr() { kubectl --as="system:serviceaccount:cloud:cloud-reconciler" "$@"; }
ka apply --server-side -f "$TMP/eso-crds.yaml" >/dev/null && ka wait --for=condition=Established crd --all --timeout=60s >/dev/null \
  || { echo "FAIL: ESO CRDs"; exit 1; }
ka apply --server-side -f "$TMP/traefik-crds.yaml" >/dev/null && ka wait --for=condition=Established crd --all --timeout=60s >/dev/null \
  || { echo "FAIL: Traefik CRDs"; exit 1; }
# The priority classes the cluster has (stacks/kyverno resource-governance.tf).
for pc in tier-0-core:1000000:PreemptLowerPriority tier-4-aux:200000:Never; do
  IFS=: read -r name value policy <<<"$pc"
  printf 'apiVersion: scheduling.k8s.io/v1\nkind: PriorityClass\nmetadata:\n  name: %s\nvalue: %s\npreemptionPolicy: %s\n---\n' "$name" "$value" "$policy"
done | ka apply -f - >/dev/null || { echo "FAIL: priority classes"; exit 1; }
ka apply -f "$TMP/rbac.yaml" >/dev/null || { echo "FAIL: RBAC"; exit 1; }
ka apply -f "$TMP/vap.yaml" -f "$TMP/kyverno-probe.yaml" >"$TMP/vap.out" 2>&1 || { echo "FAIL: admission policies"; cat "$TMP/vap.out"; exit 1; }
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

if grep -q '\[' <<<"$(sed 's/^[^:]*: //' <<<"$warn" | tr -d '\n')"; then bad "policy type-check warnings: $warn"; else ok "policies type-check cleanly against the ESO $ESO_VERSION and Traefik $TRAEFIK_VERSION CRDs"; fi
if [ -s "$TMP/tripwire.txt" ]; then bad "CRD fields the policies do not sort: $(cat "$TMP/tripwire.txt")"; else ok "every Traefik Middleware type and ESO Vault auth method is allowed or refused"; fi

ns_doc() { # name managed tier [pod-security level, default baseline; "-" for none] [extra label line]
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n  labels:\n' "$1"
  [ -n "$2" ] && printf '    cloud.viktorbarzin.me/managed: "%s"\n' "$2"
  [ -n "$3" ] && printf '    tier: "%s"\n' "$3"
  [ "${4:-baseline}" != "-" ] && printf '    pod-security.kubernetes.io/enforce: "%s"\n' "${4:-baseline}"
  [ -n "${5:-}" ] && printf '    %s\n' "$5"
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
expect_fail "reconciler cannot create p-nopsa without a Pod Security label" "pod-security.kubernetes.io/enforce=baseline or restricted" apply_as kr < <(ns_doc p-nopsa true 4-aux -)
expect_fail "reconciler cannot create p-priv with Pod Security privileged" "pod-security.kubernetes.io/enforce=baseline or restricted" apply_as kr < <(ns_doc p-priv true 4-aux privileged)
expect_fail "reconciler cannot create p-x with chrome-service.viktorbarzin.me/client=true" "may set only these namespace labels" \
  apply_as kr < <(ns_doc p-x true 4-aux baseline 'chrome-service.viktorbarzin.me/client: "true"')
expect_fail "reconciler cannot add resource-governance/custom-quota=true to p-demo" "may set only these namespace labels" kr label namespace p-demo resource-governance/custom-quota=true
expect_fail "reconciler cannot drop the Pod Security label from p-demo" "pod-security.kubernetes.io/enforce=baseline or restricted" kr label namespace p-demo pod-security.kubernetes.io/enforce-
expect_ok   "reconciler raises p-demo to restricted" kr label --overwrite namespace p-demo pod-security.kubernetes.io/enforce=restricted
expect_ok   "admin stamps a label on p-demo (as Kyverno does)" ka label namespace p-demo goldilocks.fairwinds.com/vpa-update-mode=off
expect_ok   "reconciler updates p-demo while keeping that label" kr label --overwrite namespace p-demo pod-security.kubernetes.io/enforce=baseline
expect_fail "reconciler cannot change the label someone else set" "may set only these namespace labels" kr label --overwrite namespace p-demo goldilocks.fairwinds.com/vpa-update-mode=auto
expect_fail "Pod Security refuses a hostPath pod in p-demo, even from admin" "violates PodSecurity" \
  ka run hostpath -n p-demo --image=busybox --dry-run=server --overrides='{"spec":{"volumes":[{"name":"root","hostPath":{"path":"/"}}],"containers":[{"name":"hostpath","image":"busybox","volumeMounts":[{"name":"root","mountPath":"/host"}]}]}}'
expect_fail "Pod Security refuses a privileged pod in p-demo" "violates PodSecurity" \
  ka run priv -n p-demo --image=busybox --dry-run=server --overrides='{"spec":{"containers":[{"name":"priv","image":"busybox","securityContext":{"privileged":true}}]}}'

# --- Kyverno copies ------------------------------------------------------------
# The probe policy refuses exactly the namespaces Kyverno would copy tls-secret
# and registry-credentials into (a dry run, so nothing is created).
probe_ns() { ns_doc "$@" | sed 's/^  labels:$/  labels:\n    kyverno-probe: "1"/'; }
for _ in $(seq 1 30); do ! apply_as ka --dry-run=server < <(probe_ns probe-wait "" "") >/dev/null 2>&1 && break; sleep 1; done
expect_fail "Kyverno copies the wildcard key and registry token into an ordinary namespace" "kyverno would copy" \
  apply_as ka --dry-run=server < <(probe_ns homelab-probe "" 4-aux)
expect_ok   "Kyverno copies neither into a new managed p-* namespace" apply_as ka --dry-run=server < <(probe_ns p-probe true 4-aux)

# --- RoleBindings and writes inside namespaces -------------------------------
expect_ok   "reconciler binds the project role in p-demo" apply_as kr < <(rb_doc p-demo "$PROJECT_ROLE")
expect_fail "reconciler cannot bind admin in p-demo" "forbidden" apply_as kr < <(rb_doc p-demo admin)
expect_fail "reconciler cannot bind the project role in default" "cloud-reconciler may write only" apply_as kr < <(rb_doc default "$PROJECT_ROLE")
rb_subject_doc() { # namespace subject-yaml
  printf 'apiVersion: rbac.authorization.k8s.io/v1\nkind: RoleBinding\nmetadata:\n  name: probe-subject\n  namespace: %s\nsubjects:\n- %s\nroleRef:\n  apiGroup: rbac.authorization.k8s.io\n  kind: ClusterRole\n  name: %s\n' "$1" "$2" "$PROJECT_ROLE"
}
expect_fail "reconciler cannot bind the project role to another namespace's service account" "may bind only" \
  apply_as kr < <(rb_subject_doc p-demo '{kind: ServiceAccount, name: default, namespace: p-other}')
expect_fail "reconciler cannot bind the project role to system:authenticated" "may bind only" \
  apply_as kr < <(rb_subject_doc p-demo '{kind: Group, apiGroup: rbac.authorization.k8s.io, name: "system:authenticated"}')
expect_ok   "reconciler writes a ConfigMap in p-demo" apply_as kr < <(cm_doc p-demo)
expect_ok   "reconciler reads Secrets in p-demo" kr get secrets -n p-demo
expect_fail "reconciler cannot write in p-other before binding there" "forbidden" apply_as kr < <(cm_doc p-other)
expect_ok   "admin binds the project role in unlabelled p-adopt (a mistake)" apply_as ka < <(rb_doc p-adopt "$PROJECT_ROLE")
expect_fail "admission still stops the reconciler writing in p-adopt" "cloud-reconciler may write only" apply_as kr < <(cm_doc p-adopt)
expect_ok   "admin creates homelab-labelled, labelled managed though not named p-* (a mistake)" apply_as ka < <(ns_doc homelab-labelled true 4-aux)
expect_ok   "admin binds the project role in homelab-labelled (a mistake)" apply_as ka < <(rb_doc homelab-labelled "$PROJECT_ROLE")
expect_fail "admission stops the reconciler writing in a labelled namespace not named p-*" "namespaces named p-\\*" apply_as kr < <(cm_doc homelab-labelled)

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

# --- SecretStores --------------------------------------------------------------
ss_doc() { # ns name provider-yaml
  printf 'apiVersion: external-secrets.io/v1\nkind: SecretStore\nmetadata:\n  name: %s\n  namespace: %s\nspec:\n  provider: %s\n' "$2" "$1" "$3"
}
vault_ss() { # server role auth-extra
  printf '{vault: {server: "%s", path: secret, version: v2, auth: {kubernetes: {mountPath: kubernetes, role: %s, serviceAccountRef: {name: cloud-secrets}}%s}}}' "$1" "$2" "${3:-}"
}
VS="http://vault-active.vault.svc.cluster.local:8200"
expect_ok   "the cloud-project Vault SecretStore is admitted in p-demo" apply_as kr < <(ss_doc p-demo store "$(vault_ss "$VS" cloud-project)")
expect_fail "a webhook SecretStore is refused in p-demo" "must use provider vault" \
  apply_as kr < <(ss_doc p-demo hook '{webhook: {url: "http://vault.vault.svc:8200/v1/secret/data/viktor", result: {jsonPath: "$"}}}')
expect_fail "a SecretStore on another Vault server is refused in p-demo" "must use provider vault" apply_as kr < <(ss_doc p-demo other "$(vault_ss http://evil.example.com:8200 cloud-project)")
expect_fail "a SecretStore with Vault role eso is refused in p-demo" "role cloud-project" apply_as kr < <(ss_doc p-demo eso "$(vault_ss "$VS" eso)")
expect_fail "a SecretStore with a token Secret is refused in p-demo" "only with Kubernetes auth" \
  apply_as kr < <(ss_doc p-demo tok "$(vault_ss "$VS" cloud-project ', tokenSecretRef: {name: t, key: token}')")

# --- Services -----------------------------------------------------------------
svc_doc() { # ns name spec-yaml
  printf 'apiVersion: v1\nkind: Service\nmetadata:\n  name: %s\n  namespace: %s\nspec: %s\n' "$2" "$1" "$3"
}
expect_ok   "a ClusterIP Service is admitted in p-demo" apply_as kr < <(svc_doc p-demo web '{ports: [{port: 80}], selector: {app: web}}')
expect_fail "an ExternalName Service is refused in p-demo" "must be type ClusterIP" apply_as kr < <(svc_doc p-demo ext '{type: ExternalName, externalName: vault.vault.svc.cluster.local}')
expect_fail "a LoadBalancer Service is refused in p-demo" "must be type ClusterIP" apply_as kr < <(svc_doc p-demo lb '{type: LoadBalancer, ports: [{port: 80}]}')
expect_fail "a NodePort Service is refused in p-demo, even from admin" "must be type ClusterIP" apply_as ka < <(svc_doc p-demo np '{type: NodePort, ports: [{port: 80}]}')
expect_fail "externalIPs are refused in p-demo" "externalIPs" apply_as kr < <(svc_doc p-demo eip '{ports: [{port: 80}], externalIPs: [192.168.1.10]}')
expect_ok   "an ExternalName Service outside managed namespaces is untouched" apply_as ka < <(svc_doc default ext '{type: ExternalName, externalName: example.com}')

# --- Ingresses ----------------------------------------------------------------
ing_doc() { # ns name spec-yaml
  printf 'apiVersion: networking.k8s.io/v1\nkind: Ingress\nmetadata:\n  name: %s\n  namespace: %s\nspec: %s\n' "$2" "$1" "$3"
}
rule() { printf '{host: "%s", http: {paths: [{path: /, pathType: Prefix, backend: {service: {name: web, port: {number: 80}}}}]}}' "$1"; }
expect_ok   "an Ingress for demo.viktorbarzin.me is admitted in p-demo" apply_as kr < <(ing_doc p-demo ok "{rules: [$(rule demo.viktorbarzin.me)], tls: [{hosts: [demo.viktorbarzin.me]}]}")
expect_fail "a wildcard Ingress host is refused in p-demo" "one label, no wildcard" apply_as kr < <(ing_doc p-demo wild "{rules: [$(rule '*.viktorbarzin.me')]}")
expect_fail "a two-level Ingress host is refused in p-demo" "one label, no wildcard" apply_as kr < <(ing_doc p-demo deep "{rules: [$(rule a.b.viktorbarzin.me)]}")
expect_fail "an Ingress host on another domain is refused in p-demo" "one label, no wildcard" apply_as kr < <(ing_doc p-demo other "{rules: [$(rule demo.example.com)]}")
expect_fail "a wildcard TLS host is refused in p-demo" "TLS host" apply_as kr < <(ing_doc p-demo wildtls "{rules: [$(rule demo.viktorbarzin.me)], tls: [{hosts: ['*.viktorbarzin.me']}]}")
expect_fail "a host-less Ingress rule is refused in p-demo" "needs a host" \
  apply_as kr < <(ing_doc p-demo nohost '{rules: [{http: {paths: [{path: /, pathType: Prefix, backend: {service: {name: web, port: {number: 80}}}}]}}]}')
expect_fail "an Ingress defaultBackend is refused in p-demo" "defaultBackend" apply_as kr < <(ing_doc p-demo defb '{defaultBackend: {service: {name: web, port: {number: 80}}}}')
expect_fail "the reserved name vault is refused in p-demo" "reserved name" apply_as kr < <(ing_doc p-demo vault "{rules: [$(rule vault.viktorbarzin.me)]}")
expect_fail "the reserved name cloud is refused in p-demo, even from admin" "reserved name" apply_as ka < <(ing_doc p-demo cloud "{rules: [$(rule cloud.viktorbarzin.me)]}")
expect_fail "auth-prefixed names are refused in p-demo" "reserved name" apply_as kr < <(ing_doc p-demo authx "{rules: [$(rule authx.viktorbarzin.me)]}")
expect_ok   "a wildcard Ingress outside managed namespaces is untouched" apply_as ka < <(ing_doc default wild "{rules: [$(rule '*.viktorbarzin.me')]}")
expect_fail "an Ingress tls.secretName is refused in p-demo" "tls.secretName" \
  apply_as kr < <(ing_doc p-demo tlssecret "{rules: [$(rule demo.viktorbarzin.me)], tls: [{hosts: [demo.viktorbarzin.me], secretName: tls-secret}]}")
ing_mw_doc() { # ns name annotation-key annotation-value
  printf 'apiVersion: networking.k8s.io/v1\nkind: Ingress\nmetadata:\n  name: %s\n  namespace: %s\n  annotations:\n    %s: "%s"\nspec: {rules: [%s]}\n' "$2" "$1" "$3" "$4" "$(rule demo.viktorbarzin.me)"
}
MWA="traefik.ingress.kubernetes.io/router.middlewares"
expect_ok   "an Ingress naming its own and a shared middleware is admitted in p-demo" \
  apply_as kr < <(ing_mw_doc p-demo mwok "$MWA" "p-demo-auth@kubernetescrd, traefik-strip-client-identity@kubernetescrd")
expect_fail "an Ingress naming another namespace's middleware is refused in p-demo" "router.middlewares may name only" \
  apply_as kr < <(ing_mw_doc p-demo mwx "$MWA" "terminal-tl-proxy-secret@kubernetescrd")
expect_fail "an Ingress naming a middleware of a namespace that extends p-demo's name is refused" "router.middlewares may name only" \
  apply_as kr < <(ing_mw_doc p-demo mwext "$MWA" "p-demo-x-secret@kubernetescrd")
expect_fail "an Ingress naming a file-provider middleware is refused in p-demo" "router.middlewares may name only" \
  apply_as kr < <(ing_mw_doc p-demo mwfile "$MWA" "authentik-forward-auth@file")
expect_fail "another Traefik annotation is refused in p-demo" "only Traefik annotations" \
  apply_as kr < <(ing_mw_doc p-demo prio traefik.ingress.kubernetes.io/router.priority "100000")
expect_ok   "router.entrypoints websecure is admitted in p-demo" \
  apply_as kr < <(ing_mw_doc p-demo ep traefik.ingress.kubernetes.io/router.entrypoints "websecure")

# --- Middlewares -----------------------------------------------------------------
mw_doc() { # ns name spec-yaml
  printf 'apiVersion: traefik.io/v1alpha1\nkind: Middleware\nmetadata:\n  name: %s\n  namespace: %s\nspec: %s\n' "$2" "$1" "$3"
}
expect_ok   "a forwardAuth Middleware to a Service in p-demo is admitted" apply_as kr < <(mw_doc p-demo auth '{forwardAuth: {address: "http://oauth2proxy.p-demo.svc.cluster.local:4180/oauth2/auth"}}')
expect_ok   "a headers Middleware is admitted in p-demo" apply_as kr < <(mw_doc p-demo hdr '{headers: {customResponseHeaders: {X-Frame-Options: DENY}}}')
expect_fail "a forwardAuth Middleware to another namespace is refused in p-demo" "forwardAuth.address" apply_as kr < <(mw_doc p-demo fa '{forwardAuth: {address: "http://vault.vault.svc.cluster.local:8200/v1/sys/health"}}')
expect_fail "a forwardAuth address with userinfo is refused in p-demo" "forwardAuth.address" apply_as kr < <(mw_doc p-demo faui '{forwardAuth: {address: "http://x.p-demo.svc@vault.vault.svc:8200/"}}')
expect_fail "an errors Middleware on a Service in namespace vault is refused in p-demo" "may not be of type" \
  apply_as kr < <(mw_doc p-demo err '{errors: {status: ["500-599"], query: "/", service: {name: vault, namespace: vault, port: 8200}}}')
expect_fail "a chain Middleware is refused in p-demo" "may not be of type" apply_as kr < <(mw_doc p-demo chn '{chain: {middlewares: [{name: tl-proxy-secret, namespace: terminal}]}}')
expect_fail "a plugin Middleware is refused in p-demo" "may not be of type" apply_as kr < <(mw_doc p-demo plg '{plugin: {sablier: {group: x}}}')
expect_fail "a Middleware name with a dash is refused in p-demo" "letters and digits only" apply_as kr < <(mw_doc p-demo x-secret '{headers: {customResponseHeaders: {A: b}}}')
expect_ok   "an errors Middleware outside managed namespaces is untouched" apply_as ka < <(mw_doc default err '{errors: {status: ["500"], query: "/", service: {name: vault, namespace: vault, port: 8200}}}')

# --- Pod priority ------------------------------------------------------------------
pod_prio() { # ns [priorityClassName]
  local o='{"spec":{"containers":[{"name":"c","image":"busybox"}]}}'
  [ -n "${2:-}" ] && o="{\"spec\":{\"priorityClassName\":\"$2\",\"containers\":[{\"name\":\"c\",\"image\":\"busybox\"}]}}"
  ka run "prio-${2:-none}" -n "$1" --image=busybox --dry-run=server --overrides="$o"
}
expect_fail "a pod with priority class tier-0-core is refused in p-demo" "only priority class tier-4-aux" pod_prio p-demo tier-0-core
expect_fail "a pod with system-node-critical is refused in p-demo" "only priority class tier-4-aux" pod_prio p-demo system-node-critical
expect_ok   "a pod with tier-4-aux is admitted in p-demo" pod_prio p-demo tier-4-aux
expect_ok   "a pod with no priority class is admitted in p-demo" pod_prio p-demo
expect_ok   "a tier-0-core pod outside managed namespaces is untouched" pod_prio default tier-0-core

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
