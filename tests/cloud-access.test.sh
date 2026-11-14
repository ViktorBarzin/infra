#!/usr/bin/env bash
# Checks the Kubernetes and Vault boundaries of Cloud's reconciler and of
# Project namespaces against a real API server (kind, Kubernetes 1.35 like the
# cluster, with the Calico and calico-apiserver stacks/calico pins) and a dev
# Vault, using exactly the rules Terraform applies:
#   stacks/cloud/access_rules.tf  ClusterRoles, ValidatingAdmissionPolicies,
#                                 the Calico tier and both floors
#   stacks/vault/cloud_policies.tf  Vault policies, the namespace selector and
#                                   the namespace-reader rule for Vault
#   stacks/kyverno/modules/kyverno/generate-conditions.tf  which namespaces get
#                                   Kyverno's tls-secret and registry copies
# All three hold only locals, so `terraform console` reads them offline.
#
# It also renders a Project with Cloud's own renderer and applies Cloud's real
# OpenTofu modules (the cloud repo's modules/) into the kind cluster as the
# reconciler, with real Kubernetes and mocked Vault, Postgres and random
# providers (`tofu test`). So the objects checked are the ones Cloud
# writes, through the reconciler's own RBAC and every admission policy.
#
# What it proves:
#   - calico-apiserver stays available with every admission policy applied
#     (it runs them too, and a policy with a parameter made it unready), after
#     each Project apply and each destroy; no policy takes a parameter, and a
#     control policy that does is seen to take the API down;
#   - calico-apiserver applies cloud-reconciler-scope to Calico policies: the
#     reconciler writes one in a managed p-* namespace and is refused one in a
#     namespace where only RBAC would allow it;
#   - Cloud's renderer and infra agree on the edge and oauth2-proxy images,
#     the strip list, the Authentik slug and the egress exclusions; the egress
#     floor mixes no IP families in a rule, allows DNS both ways, and ends in
#     Deny; the ingress floor lets Traefik reach only edge and oauth2-proxy
#     pods, App pods only edge pods, and ends in Deny;
#   - Cloud's modules apply a private App, a public App and a Postgres Service
#     as the reconciler, every Deployment's pod is admitted (Pod Security
#     restricted, cloud-managed-pod), and the destroy succeeds; then the same
#     for each of Cloud's snapshot fixtures (render.fixtures.ts FIXTURES: one
#     App, one Postgres with no pods, a Service removed, hostile env values
#     and the rest), each object and a pod from each template admitted again;
#   - each rendered object is admitted again as a dry run, and each variant
#     the M2 contract forbids is refused with its rule's message: namespace
#     labels, volumes other than emptyDir/configMap/secret/projected/
#     downwardAPI, emptyDirs without a sizeLimit, containers without an
#     ephemeral-storage limit, runtimeClassName, nodeName, nodeSelector,
#     affinity, tolerations, host network, priority, GPU, service account,
#     init containers, probe hosts, prometheus.io annotations, the component
#     label, the edge pod (image, args, env, port number, readiness probe,
#     mounts, a second container) and its Caddyfile (structure, upstream and
#     the homelab cookies it must strip), the oauth2-proxy pod (image, args,
#     upstream, client id, env, port, mounts), edge and oauth2-proxy Services
#     (selector, ports), Ingress annotations, entrypoints, middlewares, class,
#     backends and homelab hosts, quota and limit range labels, names, scope
#     and ephemeral storage, SecretStore and ExternalSecret stores, and any
#     Traefik Middleware;
#   - the reconciler cannot read Secrets outside a Project namespace;
#   - it creates only p-* namespaces carrying the contract's labels, cannot
#     label or delete other namespaces, and writes only in managed namespaces,
#     even where RBAC would let it;
#   - it cannot change or delete Kyverno's tier-quota;
#   - cloud-managed-ingress refuses the homelab's hosts with 600 of them
#     written in, and the API server refuses the policy itself if the hosts
#     were never written in (the marker left in place);
#   - the live host guard (Kyverno ValidatingPolicy cloud-ingress-live-hosts,
#     on the cluster's Kyverno chart and forceFailurePolicyIgnore setting)
#     refuses a Project Ingress host that a homelab Ingress or IngressRoute
#     took after the static map was written, admits a fresh host and an
#     update of the Project's own Ingress, leaves homelab namespaces alone,
#     and Kyverno's admission controller can read what it looks up;
#   - it can bind the project role, only to itself, and no stronger role;
#   - every Vault auth method in the ESO CRD is refused except Kubernetes;
#   - Kyverno's copy condition skips managed namespaces;
#   - Vault's cloud-project role admits only service account cloud-secrets in a
#     labelled namespace, only once Vault may read namespaces, and its token
#     reads only secret/cloud/<its namespace>/*, Services and _cloud/ alike,
#     never secret/cloud/system;
#   - the cloud-reconciler policy writes and patches secret/cloud/p-*, nothing
#     else under secret/cloud, reads but cannot change secret/cloud/system
#     (the shared Cloud Apps client), and reads only its two database
#     credentials;
#   - stacks/authentik writes the client id the oauth2-proxy pin expects.
#
# Needs docker, kind, kubectl, helm (Calico's operator, Kyverno, the External
# Secrets and Traefik CRDs), vault, python3 with PyYAML, bun, and a cloud repo
# checkout with its pinned OpenTofu and provider mirror (.tools/, see its
# README). CLOUD_REPO names the checkout; otherwise the first of ~/code/cloud
# and the M2 worktree ~/code/cloud/.worktrees/v1-m2-reconciler that holds
# modules/project is used (the modules reach the cloud repo's master with
# M2). The kind cluster and Calico come from tests/cloud-calico/kind.sh, which
# refuses to start when too many other kind clusters hold inotify instances.
# Takes about ten minutes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=cloud-calico/kind.sh
. "$HERE/tests/cloud-calico/kind.sh"
KIND_IMAGE="${CLOUD_ACCESS_KIND_IMAGE:-kindest/node:v1.35.0}"
# The External Secrets chart version the cluster runs, read from its stack.
ESO_VERSION="${CLOUD_ACCESS_ESO_VERSION:-$(grep -m1 -oP '^\s*version\s*=\s*"\K[0-9.]+' "$HERE/stacks/external-secrets/main.tf")}"
# The Traefik chart version the cluster runs, read from its stack.
TRAEFIK_VERSION="${CLOUD_ACCESS_TRAEFIK_VERSION:-$(grep -m1 -oP '^\s*version\s*=\s*"\K[0-9.]+' "$HERE/stacks/traefik/modules/traefik/main.tf")}"
# The Calico version the cluster runs, read from its stack.
CALICO_VERSION="${CLOUD_ACCESS_CALICO_VERSION:-$(grep -m1 -oP '^\s*version\s*=\s*"\Kv[0-9.]+' "$HERE/stacks/calico/main.tf")}"
# The Kyverno chart version the cluster runs, and whether its
# forceFailurePolicyIgnore feature is on, read from its stack.
KYVERNO_VERSION="${CLOUD_ACCESS_KYVERNO_VERSION:-$(grep -m1 -oP '^\s*version\s*=\s*"\K[0-9.]+' "$HERE/stacks/kyverno/modules/kyverno/main.tf")}"
KYVERNO_FORCE_IGNORE="$(grep -A1 -P '^\s*forceFailurePolicyIgnore\s*=\s*\{' "$HERE/stacks/kyverno/modules/kyverno/main.tf" | grep -oP 'enabled\s*=\s*\K(true|false)')"
[ -n "$KYVERNO_VERSION" ] && [ -n "$KYVERNO_FORCE_IGNORE" ] || { echo "FAIL: cannot read the Kyverno chart version or forceFailurePolicyIgnore from stacks/kyverno"; exit 1; }
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
[ -x "$TOFU" ] && [ -d "$TOFU_PLUGINS" ] || { echo "FAIL: no pinned OpenTofu at $TOFU or provider mirror at $TOFU_PLUGINS (cloud repo README, \"Reconciler\")"; exit 1; }
cloud_calico_preflight || exit 1
CLUSTER="cloud-access-$$"
TMP="$(mktemp -d)"
VAULT_PID=""
cleanup() {
  [ -n "$VAULT_PID" ] && kill "$VAULT_PID" 2>/dev/null
  kind delete cluster --name "$CLUSTER" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT
# Nothing here may write to the real home directory: the dev Vault's token
# helper, OpenTofu's plugin cache and bun all get this one.
mkdir -p "$TMP/home"

TOKEN_FILE="$HOME/.vault-token"
token_sum() { [ -f "$TOKEN_FILE" ] && sha256sum "$TOKEN_FILE" | cut -d' ' -f1 || echo absent; }
TOKEN_BEFORE="$(token_sum)"

render() { # <src file> <expression> <out> [extra file]
  local d; d="$(mktemp -d -p "$TMP")"
  cp "$1" "$d/" || { echo "FAIL: cannot copy $1"; exit 1; }
  [ -n "${4:-}" ] && cp "$4" "$d/"
  if ! (cd "$d" && echo "$2" | terraform console >"$3" 2>"$d/err"); then
    echo "FAIL: terraform console could not evaluate $1 (it must hold only locals)"; cat "$d/err"; exit 1
  fi
}
# The taken hosts taken_hosts.tf would read from the cluster: two real ones
# and 600 more, about three times the homelab's count, so the policy is
# checked at a size the cluster can reach.
python3 - "$TMP/taken_hosts_stub.tf" <<'PY'
import json, sys
hosts = {"nextcloud.viktorbarzin.me": "ingress nextcloud/nextcloud", "t3.viktorbarzin.me": "ingressroute t3code/t3-native"}
hosts.update({f"homelab-host-{i:03d}.viktorbarzin.me": f"ingress ns-{i:03d}/web-{i:03d}" for i in range(600)})
open(sys.argv[1], "w").write("locals {\n  cloud_taken_hosts = " + json.dumps(hosts) + "\n}\n")
PY
render "$HERE/stacks/cloud/access_rules.tf" \
  'jsonencode({cluster = local.cloud_reconciler_cluster_rules, project = local.cloud_reconciler_project_rules, policies = local.cloud_admission_policies_applied, raw_policies = local.cloud_admission_policies, marker = local.cloud_taken_hosts_marker, project_role = local.cloud_project_role_name, auth_refused = local.cloud_secretstore_auth_refused, tier = local.cloud_tier, floor = local.cloud_project_egress_floor, ingress_floor = local.cloud_project_ingress_floor, egress = local.cloud_egress_excluded, edge = local.cloud_edge, oauth2_proxy = local.cloud_oauth2_proxy, client_id = local.cloud_apps_client_id, strip_required = local.cloud_strip_cookies_required, live_guard = local.cloud_live_host_guard, live_guard_role = local.cloud_live_host_guard_kyverno_role})' \
  "$TMP/k8s.raw" "$TMP/taken_hosts_stub.tf"
render "$HERE/stacks/vault/cloud_policies.tf" \
  'jsonencode({reconciler = local.cloud_reconciler_policy, project = local.cloud_project_policy_template, selector = local.cloud_project_namespace_selector, ns_reader = local.vault_namespace_reader_rules})' \
  "$TMP/vault.raw"
render "$HERE/stacks/kyverno/modules/kyverno/generate-conditions.tf" \
  'jsonencode({condition = local.generate_skip_system_namespaces})' \
  "$TMP/kyverno.raw"

# Cloud's renderer, run from its own checkout.
(cd "$CLOUD_REPO" && HOME="$TMP/home" "$BUN" "$HERE/tests/cloud-access/render.ts" "$CLOUD_REPO" "$TMP/tofu") >"$TMP/render.log" 2>&1 \
  || { echo "FAIL: Cloud's renderer ($CLOUD_REPO)"; cat "$TMP/render.log"; exit 1; }

python3 - "$TMP" <<'PY' || exit 1
import json, sys, pathlib, yaml
d = pathlib.Path(sys.argv[1])
k = json.loads(json.loads((d / "k8s.raw").read_text()))
v = json.loads(json.loads((d / "vault.raw").read_text()))
kc = json.loads(json.loads((d / "kyverno.raw").read_text()))["condition"]
contract = json.loads((d / "tofu" / "contract.json").read_text())

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
# cloud-managed-ingress as it would be applied without the taken hosts.
(d / "vap-ingress-unfilled.yaml").write_text(yaml.safe_dump(k["raw_policies"]["managed_ingress"]))
(d / "tier.yaml").write_text(yaml.safe_dump(k["tier"]))
(d / "floors.yaml").write_text(yaml.safe_dump_all([k["floor"], k["ingress_floor"]]))
(d / "types.json").write_text(json.dumps({"auth_refused": k["auth_refused"]}))
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
# The live host guard: Kyverno's ValidatingPolicy and the ClusterRole that
# lets Kyverno's admission controller read IngressRoutes.
lr = k["live_guard_role"]
(d / "kyverno-guard-role.yaml").write_text(yaml.safe_dump(
    {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRole", "metadata": {"name": lr["name"], "labels": lr["labels"]}, "rules": rules(lr["rules"])}))
(d / "kyverno-guard.yaml").write_text(yaml.safe_dump(k["live_guard"]))
(d / "kyverno-guard-name").write_text(k["live_guard"]["metadata"]["name"])

# The contract between Cloud's renderer and infra, and the floor's shape.
# The floors are applied through calico-apiserver below;
# tests/cloud-calico.test.sh also runs them through Felix.
problems = []
# calico-apiserver runs every admission policy in the cluster; a paramKind
# starts an informer it may not have the RBAC for (access_rules.tf).
for name, pol in k["policies"].items():
    if "paramKind" in pol.get("spec", {}) or "paramRef" in pol.get("spec", {}):
        problems.append(f"{name} takes a parameter, which makes calico-apiserver unready")
raw, applied = json.dumps(k["raw_policies"]), json.dumps(k["policies"])
if raw.count(k["marker"]) != 1 or k["marker"] not in json.dumps(k["raw_policies"]["managed_ingress"]):
    problems.append(f"the taken-hosts marker {k['marker']} should appear once, in cloud-managed-ingress")
if k["marker"] in applied or "homelab-host-599.viktorbarzin.me" not in applied:
    problems.append("cloud_admission_policies_applied does not write the taken hosts in place of the marker")
if contract["images"]["edge"] != k["edge"]["image"]:
    problems.append(f"edge image: Cloud renders {contract['images']['edge']}, infra requires {k['edge']['image']}")
if contract["images"]["oauth2Proxy"] != k["oauth2_proxy"]["image"]:
    problems.append(f"oauth2-proxy image: Cloud renders {contract['images']['oauth2Proxy']}, infra requires {k['oauth2_proxy']['image']}")
missing = set(k["strip_required"]) - set(contract["stripCookies"])
if missing:
    problems.append(f"Cloud's strip list {contract['stripCookies']} lacks {sorted(missing)}")
if contract["authentik"]["appSlug"] != "cloud-apps" or f"/application/o/{contract['authentik']['appSlug']}/" not in " ".join(k["oauth2_proxy"]["args"]):
    problems.append(f"Authentik slug: Cloud uses {contract['authentik']['appSlug']}, infra's oauth2-proxy pin expects cloud-apps")
if f"--client-id={k['client_id']}" not in k["oauth2_proxy"]["args"]:
    problems.append(f"oauth2-proxy pin does not use client id {k['client_id']}")
# The home WAN IP (hairpin into Traefik) and backup-mx, which admits the home
# WAN IP on 22 and 9100 (access_rules.tf, cloud_egress_excluded).
for net in ["176.12.22.76/32", "92.5.132.215/32"]:
    if net not in k["egress"]["ipv4"]:
        problems.append(f"egress exclusions: infra's list lacks {net}")
for fam in ["ipv4", "ipv6"]:
    if sorted(contract["egressExcluded"][fam]) != sorted(k["egress"][fam]):
        problems.append(f"egress exclusions ({fam}): Cloud {sorted(contract['egressExcluded'][fam])}, infra {sorted(k['egress'][fam])}")
egress = k["floor"]["spec"]["egress"]
for i, r in enumerate(egress):
    nets = r.get("destination", {}).get("nets", []) + r.get("destination", {}).get("notNets", [])
    if len({":" in n for n in nets}) > 1:
        problems.append(f"floor rule {i} mixes IPv4 and IPv6 (Calico refuses it): {r}")
if egress[-1] != {"action": "Deny"}:
    problems.append(f"floor does not end in Deny: {egress[-1]}")
for fam, net in [("ipv4", "0.0.0.0/0"), ("ipv6", "::/0")]:
    internet = [r for r in egress if r.get("destination", {}).get("nets") == [net]]
    if len(internet) != 1 or internet[0]["action"] != "Pass" or sorted(internet[0]["destination"].get("notNets", [])) != sorted(k["egress"][fam]):
        problems.append(f"floor: no single Pass to {net} minus the {fam} exclusions: {internet}")
dns = [r for r in egress if r.get("action") == "Allow" and 53 in r.get("destination", {}).get("ports", [])]
if not any(r["destination"].get("nets") == ["10.96.0.10/32"] for r in dns) or not any("kube-dns" in r["destination"].get("selector", "") for r in dns):
    problems.append(f"floor: DNS must be allowed to the kube-dns ClusterIP and the CoreDNS pods: {dns}")
if any(r.get("action") == "Allow" and r.get("destination", {}).get("nets", [None])[0] in ("0.0.0.0/0", "::/0") for r in egress):
    problems.append("floor: an Allow to the internet would stop the Project policy narrowing it")
# The ingress floor: Traefik reaches only edge and oauth2-proxy pods, App pods
# accept only edge pods, and everything else is denied.
ing = k["ingress_floor"]["spec"]
if ing.get("types") != ["Ingress"] or ing.get("tier") != "cloud" or ing["ingress"][-1] != {"action": "Deny"}:
    problems.append(f"ingress floor: not an Ingress policy in tier cloud ending in Deny: {ing}")
comp = "cloud.viktorbarzin.me/component"
for r in ing["ingress"][:-1]:
    if r["action"] != "Pass":
        problems.append(f"ingress floor: a rule other than Pass before the Deny: {r}")
    dst = r.get("destination", {}).get("selector", "")
    src = r.get("source", {})
    if "'app'" in dst and src.get("selector") != f"{comp} == 'edge'":
        problems.append(f"ingress floor: App pods reachable from something other than edge pods: {r}")
    if "traefik" in src.get("namespaceSelector", "") and ("'app'" in dst or not dst):
        problems.append(f"ingress floor: Traefik reaches App pods: {r}")
if not any("traefik" in r.get("source", {}).get("namespaceSelector", "") and "'edge'" in r["destination"]["selector"] and "'oauth2-proxy'" in r["destination"]["selector"] for r in ing["ingress"][:-1]):
    problems.append("ingress floor: Traefik cannot reach edge and oauth2-proxy pods")
(d / "contract-problems.txt").write_text("\n".join(problems))

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
eso = [c for c in yaml.safe_load_all(open(d / "eso-crds.yaml")) if c["metadata"]["name"] == "secretstores.external-secrets.io"][0]
for ver in eso["spec"]["versions"]:
    if not ver.get("served"): continue
    auth = set(ver["schema"]["openAPIV3Schema"]["properties"]["spec"]["properties"]["provider"]["properties"]["vault"]["properties"]["auth"]["properties"])
    extra = auth - set(t["auth_refused"]) - {"kubernetes"}
    if extra: problems.append(f"ESO {ver['name']} Vault auth methods not refused: {sorted(extra)}")
(d / "tripwire.txt").write_text("\n".join(problems))
PY

export KUBECONFIG="$TMP/kubeconfig"
cloud_calico_kind_up "$CLUSTER" "$KIND_IMAGE" "$CALICO_VERSION" "$TMP" || exit 1

ka() { kubectl "$@"; }
kr() { kubectl --as="system:serviceaccount:cloud:cloud-reconciler" "$@"; }
ka apply --server-side -f "$TMP/eso-crds.yaml" -f "$TMP/traefik-crds.yaml" >/dev/null \
  && ka wait --for=condition=Established crd --all --timeout=60s >/dev/null || { echo "FAIL: CRDs"; exit 1; }
# Kyverno, for the live host guard: the cluster's chart version and
# forceFailurePolicyIgnore setting, admission controller only. It installs
# in the background while the checks before the guard's run.
cat >"$TMP/kyverno-values.yaml" <<EOF
features:
  forceFailurePolicyIgnore: {enabled: $KYVERNO_FORCE_IGNORE}
  policyReports: {enabled: false}
  admissionReports: {enabled: false}
  aggregateReports: {enabled: false}
  backgroundScan: {enabled: false}
admissionController: {replicas: 1}
backgroundController: {enabled: false}
cleanupController: {enabled: false}
reportsController: {enabled: false}
EOF
helm install kyverno kyverno --repo https://kyverno.github.io/kyverno/ --version "$KYVERNO_VERSION" \
  --namespace kyverno --create-namespace --values "$TMP/kyverno-values.yaml" --wait --timeout 8m \
  >"$TMP/kyverno-install.log" 2>&1 &
KYVERNO_PID=$!
# The priority classes the cluster has (stacks/kyverno resource-governance.tf
# and the GPU class Kyverno's inject-gpu-workload-priority sets).
for pc in tier-0-core:1000000:PreemptLowerPriority tier-4-aux:200000:Never gpu-workload:1200000:PreemptLowerPriority; do
  IFS=: read -r name value policy <<<"$pc"
  printf 'apiVersion: scheduling.k8s.io/v1\nkind: PriorityClass\nmetadata:\n  name: %s\nvalue: %s\npreemptionPolicy: %s\n---\n' "$name" "$value" "$policy"
done | ka apply -f - >/dev/null || { echo "FAIL: priority classes"; exit 1; }
# One of the cluster's GPU runtime classes, so a pod naming it reaches the
# admission policies instead of failing RuntimeClass admission first.
printf 'apiVersion: node.k8s.io/v1\nkind: RuntimeClass\nmetadata:\n  name: nvidia\nhandler: nvidia\n' | ka apply -f - >/dev/null \
  || { echo "FAIL: runtime class"; exit 1; }
ka apply -f "$TMP/rbac.yaml" >/dev/null || { echo "FAIL: RBAC"; exit 1; }
ka apply -f "$TMP/tier.yaml" >"$TMP/tier.out" 2>&1 && ka apply -f "$TMP/floors.yaml" >>"$TMP/tier.out" 2>&1 \
  || { echo "FAIL: calico-apiserver refused tier cloud or a floor"; cat "$TMP/tier.out"; exit 1; }
ka apply -f "$TMP/vap.yaml" -f "$TMP/kyverno-probe.yaml" >"$TMP/vap.out" 2>&1 || { echo "FAIL: admission policies"; cat "$TMP/vap.out"; exit 1; }
# A policy is enforced only once the API server has compiled it.
for _ in $(seq 1 60); do
  ka get validatingadmissionpolicy cloud-reconciler-scope -o jsonpath='{.status.typeChecking}' >/dev/null 2>&1 \
    && ! kr create namespace probe-not-p --dry-run=server >/dev/null 2>&1 && break
  sleep 1
done
sleep 2
warn="$(ka get validatingadmissionpolicy -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.typeChecking.expressionWarnings}{"\n"}{end}')"

FAILS=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; FAILS=$((FAILS + 1)); }
expect_ok()   { local what="$1"; shift; if out="$("$@" 2>&1)"; then ok "$what"; else bad "$what: $out"; fi; }
expect_fail() { local what="$1" pattern="$2"; shift 2
  if out="$("$@" 2>&1)"; then bad "$what: succeeded, expected failure"
  elif grep -qiE "$pattern" <<<"$out"; then ok "$what"; else bad "$what: wrong error: $out"; fi; }
can()    { [ "$(kr auth can-i "$@" 2>/dev/null)" = "yes" ]; }
cannot() { ! can "$@"; }
# Server-side apply: client-side apply would add the last-applied annotation,
# which cloud-managed-ingress refuses like any other unrendered annotation.
apply_as() { local who="$1"; shift; "$who" apply --server-side --force-conflicts --field-manager=cloud-access-test -f - "$@"; }

if grep -q '\[' <<<"$(sed 's/^[^:]*: //' <<<"$warn" | tr -d '\n')"; then bad "policy type-check warnings: $warn"; else ok "policies type-check cleanly against the ESO $ESO_VERSION and Traefik $TRAEFIK_VERSION CRDs"; fi
if [ -s "$TMP/tripwire.txt" ]; then bad "CRD fields the policies do not sort: $(cat "$TMP/tripwire.txt")"; else ok "every ESO Vault auth method is allowed or refused"; fi
if [ -s "$TMP/contract-problems.txt" ]; then bad "Cloud and infra disagree: $(cat "$TMP/contract-problems.txt")"; else ok "Cloud ($CLOUD_REPO) and infra agree on the edge and oauth2-proxy images, strip list, Authentik slug and egress exclusions; both floors are well formed; no policy takes a parameter; the taken hosts are written in"; fi
# calico-apiserver fails its readiness check some seconds after a policy it
# cannot serve arrives, so the API is sampled for a minute.
calico_api_steady() { # <what>
  local i
  for i in $(seq 1 12); do
    cloud_calico_api_available || { bad "$1: v3.projectcalico.org went unavailable: $(kubectl get apiservice v3.projectcalico.org -o jsonpath='{.status.conditions}') $(kubectl logs -n calico-system -l k8s-app=calico-apiserver --tail=5 2>&1)"; return; }
    sleep 5
  done
  ok "$1: v3.projectcalico.org stays available for a minute"
}
calico_api_steady "calico-apiserver with tier cloud, both floors and every admission policy applied"

ns_doc() { # name managed tier [pod-security level, default restricted; "-" for none] [extra label line] [no-governance]
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n  labels:\n' "$1"
  [ -n "$2" ] && printf '    cloud.viktorbarzin.me/managed: "%s"\n' "$2"
  [ -n "$3" ] && printf '    tier: "%s"\n' "$3"
  [ "${4:-restricted}" != "-" ] && printf '    pod-security.kubernetes.io/enforce: "%s"\n' "${4:-restricted}"
  [ -z "${6:-}" ] && printf '    resource-governance/custom-quota: "true"\n    resource-governance/custom-limitrange: "true"\n'
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
expect_ok   "reconciler creates p-demo (the contract's labels)" apply_as kr < <(ns_doc p-demo true 4-aux)
expect_ok   "reconciler creates p-other (the contract's labels)" apply_as kr < <(ns_doc p-other true 4-aux)
expect_fail "reconciler cannot create p-bare without the managed label" "cloud-reconciler may manage only" apply_as kr < <(ns_doc p-bare "" 4-aux)
expect_fail "reconciler cannot create a managed namespace not named p-*" "cloud-reconciler may manage only" apply_as kr < <(ns_doc demo true 4-aux)
expect_fail "reconciler cannot give its namespace another tier" "cloud-reconciler may manage only" apply_as kr < <(ns_doc p-core true 0-core)
expect_fail "reconciler cannot label default as managed" "cloud-reconciler may" kr label namespace default cloud.viktorbarzin.me/managed=true tier=4-aux
expect_ok   "admin creates homelab-app, a namespace Cloud does not own" ka create namespace homelab-app
expect_fail "reconciler cannot delete homelab-app" "cloud-reconciler may manage only" kr delete namespace homelab-app --wait=false
expect_ok   "admin creates p-adopt without the label" apply_as ka < <(ns_doc p-adopt "" 4-aux)
expect_fail "reconciler cannot adopt p-adopt by labelling it" "may not label an existing namespace" kr label namespace p-adopt cloud.viktorbarzin.me/managed=true
expect_fail "reconciler cannot create p-nopsa without a Pod Security label" "must carry" apply_as kr < <(ns_doc p-nopsa true 4-aux -)
expect_fail "reconciler cannot create p-base with Pod Security baseline" "must carry" apply_as kr < <(ns_doc p-base true 4-aux baseline)
expect_fail "reconciler cannot create p-gov without the resource-governance labels" "must carry" apply_as kr < <(ns_doc p-gov true 4-aux restricted "" no-governance)
expect_fail "reconciler cannot create p-x with chrome-service.viktorbarzin.me/client=true" "may set only these namespace labels" \
  apply_as kr < <(ns_doc p-x true 4-aux restricted 'chrome-service.viktorbarzin.me/client: "true"')
expect_fail "reconciler cannot drop the Pod Security label from p-demo" "must carry" kr label namespace p-demo pod-security.kubernetes.io/enforce-
expect_fail "reconciler cannot lower p-demo to baseline" "must carry" kr label --overwrite namespace p-demo pod-security.kubernetes.io/enforce=baseline
expect_fail "reconciler cannot drop resource-governance/custom-quota from p-demo" "must carry" kr label namespace p-demo resource-governance/custom-quota-
expect_ok   "admin stamps a label on p-demo (as Kyverno does)" ka label namespace p-demo goldilocks.fairwinds.com/vpa-update-mode=off
expect_ok   "reconciler updates p-demo while keeping that label" kr label --overwrite namespace p-demo pod-security.kubernetes.io/warn=restricted
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

# --- Kyverno's tier-quota --------------------------------------------------------
# Kyverno generates tier-quota without Cloud's managed-by label wherever
# custom-quota is not true; one stands in for it here.
expect_ok   "admin creates tier-quota in p-demo, as Kyverno would" \
  apply_as ka < <(printf 'apiVersion: v1\nkind: ResourceQuota\nmetadata:\n  name: tier-quota\n  namespace: p-demo\nspec:\n  hard:\n    pods: "20"\n')
expect_fail "reconciler cannot raise tier-quota" "may write only ResourceQuota cloud-quota" \
  kr patch resourcequota tier-quota -n p-demo --type=merge -p '{"spec":{"hard":{"pods":"2000"}}}'
expect_fail "reconciler cannot label tier-quota as its own" "may write only ResourceQuota cloud-quota" \
  kr label resourcequota tier-quota -n p-demo app.kubernetes.io/managed-by=cloud
expect_fail "reconciler cannot delete tier-quota" "may write only ResourceQuota cloud-quota" kr delete resourcequota tier-quota -n p-demo

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
expect_fail "admin is refused an ExternalSecret on a ClusterSecretStore in p-demo" "must be a SecretStore" apply_as ka < <(es_doc p-demo ClusterSecretStore)
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
expect_fail "a webhook SecretStore is refused in p-demo" "must use provider vault" \
  apply_as kr < <(ss_doc p-demo hook '{webhook: {url: "http://vault.vault.svc:8200/v1/secret/data/viktor", result: {jsonPath: "$"}}}')
expect_fail "a SecretStore on another Vault server is refused in p-demo" "must use provider vault" apply_as kr < <(ss_doc p-demo other "$(vault_ss http://evil.example.com:8200 cloud-project)")
expect_fail "a SecretStore with a token Secret is refused in p-demo" "only with Kubernetes auth" \
  apply_as kr < <(ss_doc p-demo tok "$(vault_ss "$VS" cloud-project ', tokenSecretRef: {name: t, key: token}')")

# --- Kubernetes Services ----------------------------------------------------------
svc_doc() { # ns name spec-yaml
  printf 'apiVersion: v1\nkind: Service\nmetadata:\n  name: %s\n  namespace: %s\nspec: %s\n' "$2" "$1" "$3"
}
expect_ok   "a ClusterIP Kubernetes Service is admitted in p-demo" apply_as kr < <(svc_doc p-demo web '{ports: [{port: 80}], selector: {app: web}}')
expect_fail "an ExternalName Kubernetes Service is refused in p-demo" "must be type ClusterIP" apply_as kr < <(svc_doc p-demo ext '{type: ExternalName, externalName: vault.vault.svc.cluster.local}')
expect_fail "a LoadBalancer Kubernetes Service is refused in p-demo" "must be type ClusterIP" apply_as kr < <(svc_doc p-demo lb '{type: LoadBalancer, ports: [{port: 80}]}')
expect_fail "externalIPs are refused in p-demo" "externalIPs" apply_as kr < <(svc_doc p-demo eip '{ports: [{port: 80}], externalIPs: [192.168.1.10]}')
expect_ok   "an ExternalName Kubernetes Service outside managed namespaces is untouched" apply_as ka < <(svc_doc default ext '{type: ExternalName, externalName: example.com}')

# --- Ingress hosts ------------------------------------------------------------------
ing_doc() { # ns name host [tls-host]
  printf 'apiVersion: networking.k8s.io/v1\nkind: Ingress\nmetadata:\n  name: %s\n  namespace: %s\n  annotations:\n    traefik.ingress.kubernetes.io/router.entrypoints: websecure\nspec:\n  ingressClassName: traefik\n  rules: [{host: "%s", http: {paths: [{path: /, pathType: Prefix, backend: {service: {name: edge-x, port: {name: edge}}}}]}}]\n' "$2" "$1" "$3"
  [ -n "${4:-}" ] && printf '  tls: [{hosts: ["%s"]}]\n' "$4"
  true
}
expect_ok   "an Ingress for demo.viktorbarzin.me is admitted in p-demo" apply_as kr --dry-run=server < <(ing_doc p-demo ok demo.viktorbarzin.me demo.viktorbarzin.me)
expect_fail "a wildcard Ingress host is refused in p-demo" "one label, no wildcard" apply_as kr --dry-run=server < <(ing_doc p-demo wild '*.viktorbarzin.me')
expect_fail "a two-level Ingress host is refused in p-demo" "one label, no wildcard" apply_as kr --dry-run=server < <(ing_doc p-demo deep a.b.viktorbarzin.me)
expect_fail "an Ingress host on another domain is refused in p-demo" "one label, no wildcard" apply_as kr --dry-run=server < <(ing_doc p-demo other demo.example.com)
expect_fail "a wildcard TLS host is refused in p-demo" "TLS host" apply_as kr --dry-run=server < <(ing_doc p-demo wildtls demo.viktorbarzin.me '*.viktorbarzin.me')
expect_fail "the reserved name cloud is refused in p-demo, even from admin" "reserved name" apply_as ka --dry-run=server < <(ing_doc p-demo cloud cloud.viktorbarzin.me)
expect_fail "auth-prefixed names are refused in p-demo" "reserved name" apply_as kr --dry-run=server < <(ing_doc p-demo authx authx.viktorbarzin.me)
expect_fail "a host-less Ingress rule is refused in p-demo" "needs a host" \
  apply_as kr --dry-run=server < <(ing_doc p-demo nohost x.viktorbarzin.me | sed 's/{host: "x.viktorbarzin.me", /{/')
expect_fail "an Ingress defaultBackend is refused in p-demo" "defaultBackend" \
  apply_as kr --dry-run=server < <(ing_doc p-demo defb demo.viktorbarzin.me; printf '  defaultBackend: {service: {name: edge-x, port: {name: edge}}}\n')
expect_ok   "a wildcard Ingress outside managed namespaces is untouched" apply_as ka --dry-run=server < <(ing_doc default wild '*.viktorbarzin.me')
expect_fail "a homelab host (Ingress) is refused in p-demo, even from admin" "already routes" apply_as ka --dry-run=server < <(ing_doc p-demo nc nextcloud.viktorbarzin.me)
expect_fail "a homelab host (IngressRoute) is refused as a TLS host in p-demo" "already routes" apply_as kr --dry-run=server < <(ing_doc p-demo t3 demo.viktorbarzin.me t3.viktorbarzin.me)
expect_fail "the 600th taken host is refused in p-demo" "already routes" apply_as kr --dry-run=server < <(ing_doc p-demo h599 homelab-host-599.viktorbarzin.me)
# The policy as it would be applied if the hosts were never written in: the
# API server compiles it and refuses it, so the apply fails and the policy in
# place stays.
expect_fail "the API server refuses cloud-managed-ingress with the taken-hosts marker left in" "compilation failed" ka apply -f "$TMP/vap-ingress-unfilled.yaml"
expect_fail "after that refusal a homelab host is still refused in p-demo" "already routes" apply_as kr --dry-run=server < <(ing_doc p-demo nc nextcloud.viktorbarzin.me)

# --- Live host guard (Kyverno) ------------------------------------------------------
# Homelab hosts added after the last cloud apply, so not in the static map:
# an Ingress (rule and TLS host) and IngressRoutes (one host, and two in one
# Host() clause) in homelab-app, which is not managed.
if wait "$KYVERNO_PID"; then ok "Kyverno $KYVERNO_VERSION installs (forceFailurePolicyIgnore=$KYVERNO_FORCE_IGNORE, as stacks/kyverno)"
else bad "Kyverno $KYVERNO_VERSION did not install: $(tail -20 "$TMP/kyverno-install.log")"; fi
KSA="system:serviceaccount:kyverno:kyverno-admission-controller"
[ "$(ka auth can-i list ingressroutes.traefik.io -A --as="$KSA" 2>/dev/null)" = "no" ] \
  && ok "without the guard's ClusterRole Kyverno cannot list IngressRoutes" || bad "Kyverno lists IngressRoutes without the guard's ClusterRole"
ka apply -f "$TMP/kyverno-guard-role.yaml" >/dev/null || bad "the guard's ClusterRole was refused"
for _ in $(seq 1 30); do [ "$(ka auth can-i list ingressroutes.traefik.io -A --as="$KSA" 2>/dev/null)" = "yes" ] && break; sleep 1; done
for r in ingressroutes.traefik.io ingresses.networking.k8s.io namespaces; do
  [ "$(ka auth can-i list "$r" -A --as="$KSA" 2>/dev/null)" = "yes" ] && ok "Kyverno's admission controller lists $r cluster-wide" || bad "Kyverno's admission controller cannot list $r cluster-wide"
done
ka apply -f - >/dev/null <<'EOF' || bad "could not create the late homelab routes"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: {name: late, namespace: homelab-app}
spec:
  rules: [{host: late-ingress.viktorbarzin.me, http: {paths: [{path: /, pathType: Prefix, backend: {service: {name: web, port: {number: 80}}}}]}}]
  tls: [{hosts: [late-tls.viktorbarzin.me]}]
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata: {name: late, namespace: homelab-app}
spec:
  entryPoints: [websecure]
  routes:
  - {kind: Rule, match: "Host(`late-route.viktorbarzin.me`) && PathPrefix(`/api`)", services: [{name: web, port: 80}]}
  - {kind: Rule, match: "Host(`late-a.viktorbarzin.me`, `Late-B.viktorbarzin.me`)", services: [{name: web, port: 80}]}
EOF
GUARD="$(cat "$TMP/kyverno-guard-name")"
ka apply -f "$TMP/kyverno-guard.yaml" >/dev/null || bad "Kyverno refused ValidatingPolicy $GUARD"
# Ready, then registered in Kyverno's webhook: wait for the first refusal.
for _ in $(seq 1 120); do
  ! apply_as kr --dry-run=server < <(ing_doc p-demo g0 late-ingress.viktorbarzin.me) >/dev/null 2>&1 && break
  sleep 1
done
[ "$(ka get validatingpolicies.policies.kyverno.io "$GUARD" -o jsonpath='{.status.conditionStatus.ready}' 2>/dev/null)" = "true" ] \
  && ok "ValidatingPolicy $GUARD is Ready" || bad "ValidatingPolicy $GUARD is not Ready: $(ka get validatingpolicies.policies.kyverno.io "$GUARD" -o jsonpath='{.status}' 2>&1)"
expect_fail "the guard refuses a host a homelab Ingress took after the last apply" "homelab routes now: late-ingress.viktorbarzin.me" \
  apply_as kr --dry-run=server < <(ing_doc p-demo g1 late-ingress.viktorbarzin.me)
expect_fail "the guard refuses a homelab Ingress's TLS host" "homelab routes now: late-tls.viktorbarzin.me" \
  apply_as kr --dry-run=server < <(ing_doc p-demo g2 late-tls.viktorbarzin.me)
expect_fail "the guard refuses a host in an IngressRoute's Host() match" "homelab routes now: late-route.viktorbarzin.me" \
  apply_as kr --dry-run=server < <(ing_doc p-demo g3 late-route.viktorbarzin.me)
expect_fail "the guard refuses the second host of a Host() clause, compared without case" "homelab routes now: late-b.viktorbarzin.me" \
  apply_as kr --dry-run=server < <(ing_doc p-demo g4 late-b.viktorbarzin.me)
expect_fail "the guard refuses a homelab host as the TLS host of a Project Ingress" "homelab routes now: late-a.viktorbarzin.me" \
  apply_as kr --dry-run=server < <(ing_doc p-demo g5 fresh-app.viktorbarzin.me late-a.viktorbarzin.me)
expect_fail "the guard refuses admin too" "homelab routes now" apply_as ka --dry-run=server < <(ing_doc p-demo g6 late-ingress.viktorbarzin.me)
expect_ok   "the guard admits a fresh host in p-demo" apply_as kr < <(ing_doc p-demo fresh fresh-app.viktorbarzin.me fresh-app.viktorbarzin.me)
expect_ok   "the guard admits an update of that Ingress (its own host does not clash)" \
  apply_as kr < <(ing_doc p-demo fresh fresh-app.viktorbarzin.me fresh-app.viktorbarzin.me | sed 's|path: /,|path: /v2,|')
expect_ok   "the guard leaves homelab namespaces alone (a second homelab Ingress on a homelab host)" \
  apply_as ka --dry-run=server < <(ing_doc homelab-app late2 late-ingress.viktorbarzin.me)
kr delete ingress fresh -n p-demo >/dev/null 2>&1
# Kyverno's webhook for the guard: Fail as the policy says, unless the chart
# forces every policy to Ignore (stacks/kyverno forceFailurePolicyIgnore).
fp="$(ka get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg -o json \
  | python3 -c 'import json,sys; g=sys.argv[1]; print(" ".join(sorted({w["failurePolicy"] for w in json.load(sys.stdin)["webhooks"] if g in w["clientConfig"]["service"].get("path", "")})))' "$GUARD")"
want="$([ "$KYVERNO_FORCE_IGNORE" = "true" ] && echo Ignore || echo Fail)"
[ "$fp" = "$want" ] && ok "Kyverno registers the guard with failurePolicy $fp (forceFailurePolicyIgnore=$KYVERNO_FORCE_IGNORE)" \
  || bad "Kyverno registers the guard with failurePolicy '$fp', expected $want (forceFailurePolicyIgnore=$KYVERNO_FORCE_IGNORE)"

# --- Calico policies through calico-apiserver ----------------------------------------
# calico-apiserver runs the cluster's admission policies itself, so
# cloud-reconciler-scope reaches Calico writes, not only RBAC.
cnp_doc() { # ns
  printf 'apiVersion: projectcalico.org/v3\nkind: NetworkPolicy\nmetadata:\n  name: default.scope-probe\n  namespace: %s\nspec:\n  tier: default\n  order: 1\n  selector: all()\n  types: [Ingress]\n' "$1"
}
expect_ok   "reconciler writes a Calico policy in p-demo (dry run)" kr create --dry-run=server -f - < <(cnp_doc p-demo)
expect_fail "calico-apiserver refuses the reconciler a Calico policy in p-adopt, where only RBAC allows it" "cloud-reconciler may write only" \
  kr create --dry-run=server -f - < <(cnp_doc p-adopt)
pod_prio() { # ns priorityClassName
  ka run "prio-$2" -n "$1" --image=busybox --dry-run=server --overrides="{\"spec\":{\"priorityClassName\":\"$2\",\"containers\":[{\"name\":\"c\",\"image\":\"busybox\"}]}}"
}
expect_ok   "a tier-0-core pod outside managed namespaces is untouched" pod_prio default tier-0-core

# --- Cloud's real modules, applied as the reconciler ----------------------------
# render.ts wrote the root module and variables into $TMP/tofu. tofu test
# applies them with the real Kubernetes provider (the reconciler's token) and
# mocks for the rest, runs dump.sh before the destroy, then destroys.
NS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["namespace"])' "$TMP/tofu/contract.json")"
SERVER="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')"
CA_DATA="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
cat >"$TMP/reconciler.kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters: [{name: kind, cluster: {server: "$SERVER", certificate-authority-data: "$CA_DATA"}}]
users: [{name: cloud-reconciler, user: {token: "$(ka create token cloud-reconciler -n cloud --duration=1h)"}}]
contexts: [{name: cloud-reconciler, context: {cluster: kind, user: cloud-reconciler}}]
current-context: cloud-reconciler
EOF
mkdir -p "$TMP/dump"
ln -s "$CLOUD_REPO/modules" "$TMP/tofu/modules"
: >"$TMP/tofu/tofurc"
cat >"$TMP/tofu/zz_dump.tf.json" <<'EOF'
{"resource": {"terraform_data": {"cloud_access_dump": {
  "depends_on": ["module.project", "module.app", "module.postgres"],
  "provisioner": [{"local-exec": {"command": "bash \"$CLOUD_DUMP_SCRIPT\""}}]
}}}}
EOF
cat >"$TMP/tofu/cloud-access.tftest.hcl" <<'EOF'
mock_provider "postgresql" {}
mock_provider "random" {}
# The shared Cloud Apps client stacks/authentik writes to secret/cloud/system.
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
# TOFU_DIR is the root module to run, DUMP_DIR where dump.sh saves its objects.
TOFU_DIR="$TMP/tofu" DUMP_DIR="$TMP/dump"
tofu() {
  # The reconciler refuses an apply without a pull token (registry_password
  # validation), so the test passes a dummy one the way the worker does.
  (cd "$TOFU_DIR" && env HOME="$TMP/home" TF_CLI_CONFIG_FILE="$TMP/tofu/tofurc" TF_IN_AUTOMATION=1 \
    TF_VAR_registry_password=test-pull-token KUBE_CONFIG_PATH="$TMP/reconciler.kubeconfig" ADMIN_KUBECONFIG="$KUBECONFIG" CLOUD_NAMESPACE="$NS" \
    CLOUD_DUMP_DIR="$DUMP_DIR" CLOUD_DUMP_SCRIPT="$HERE/tests/cloud-access/dump.sh" "$TOFU" "$@")
}
# What the dump of one apply shows: no pod refused, a pod for every
# Deployment, and (with all-kinds) every kind the combined Project has.
pods_check() { # <dump dir> <cases dir> [all-kinds]
  python3 - "$1" "$2" "${3:-}" <<'PY2'
import json, sys, pathlib
dump, cases, all_kinds = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3] == "all-kinds"
s = json.loads((cases / "summary.json").read_text())
events = json.loads((dump / "events.json").read_text())["items"]
failed = [e["message"] for e in events if e.get("reason") == "FailedCreate"]
want = {"Deployment", "Service", "Ingress", "ConfigMap", "ResourceQuota", "LimitRange", "SecretStore", "ExternalSecret", "RoleBinding", "NetworkPolicy", "Pod"}
problems = []
if failed: problems.append("pods refused: " + " | ".join(failed))
if len(s["pods"]) < len(s["deployments"]): problems.append(f"{len(s['pods'])} pods for {len(s['deployments'])} Deployments {s['deployments']}")
if all_kinds and want - set(s["kinds"]): problems.append(f"kinds missing from the render: {sorted(want - set(s['kinds']))}")
print("; ".join(problems) if problems else f"{len(s['pods'])} pods for Deployments {', '.join(s['deployments']) or '(none)'}")
sys.exit(1 if problems else 0)
PY2
}
# Sends every case variants.py wrote as a server-side dry run; sets CASES_RUN.
run_cases() { # <cases dir>
  local file who expect what n=0
  while IFS=$'\t' read -r -u 3 file who expect what; do
    n=$((n + 1))
    if [ "$expect" = "ok" ]; then
      expect_ok "admitted: $what" "$who" create --dry-run=server -f "$1/$file"
    else
      expect_fail "refused: $what" "$expect" "$who" create --dry-run=server -f "$1/$file"
    fi
  done 3<"$1/cases.tsv"
  CASES_RUN=$n
}
if ! tofu init -backend=false -input=false -no-color -plugin-dir="$TOFU_PLUGINS" >"$TMP/tofu-init.log" 2>&1; then
  bad "tofu init of Cloud's modules: $(tail -20 "$TMP/tofu-init.log")"
elif tofu test -no-color >"$TMP/tofu-test.log" 2>&1 && grep -q "1 passed, 0 failed" "$TMP/tofu-test.log"; then
  ok "Cloud's modules apply and destroy a private App, a public App and a Postgres Service in $NS as the reconciler"
else
  bad "Cloud's modules did not apply and destroy cleanly as the reconciler: $(grep -v '^\s*$' "$TMP/tofu-test.log" | tail -40)"
fi

# dump.sh records the APIService while the Project exists; check it again
# now that the destroy has run.
api_after() { # <dump dir> <what>
  if [ "$(cat "$1/apiservice.txt" 2>/dev/null)" = "True" ] && cloud_calico_api_available; then
    ok "$2: v3.projectcalico.org available after the apply and after the destroy"
  else
    bad "$2: v3.projectcalico.org after the apply: $(cat "$1/apiservice.txt" 2>/dev/null || echo unknown), after the destroy: $(kubectl get apiservice v3.projectcalico.org -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')"
  fi
}
api_after "$TMP/dump" "combined Project"
if [ -s "$TMP/dump/objects.json" ] && python3 "$HERE/tests/cloud-access/variants.py" "$TMP/dump" "$TMP/cases" p-demo >"$TMP/variants.log" 2>&1; then
  check="$(pods_check "$TMP/dump" "$TMP/cases" all-kinds)" && ok "every rendered Deployment's pod was admitted: $check" || bad "rendered pods: $check"
  # The SecretStore's service account must exist for a pod to name it.
  ka create serviceaccount cloud-secrets -n p-demo >/dev/null 2>&1
  run_cases "$TMP/cases"
  [ "$CASES_RUN" -gt 80 ] && ok "$CASES_RUN cases built from Cloud's real objects" || bad "only $CASES_RUN cases built from Cloud's real objects"
else
  bad "no objects from Cloud's modules to check: $(cat "$TMP/variants.log" 2>/dev/null)"
fi

# --- Cloud's snapshot fixtures, each applied as the reconciler -----------------
# The shapes Cloud's own tests render (render.fixtures.ts FIXTURES): one App,
# one Postgres (quota pods 0, no Deployment), an App connected to Postgres, a
# private App with an allow list, a public App, a Service removed, hostile env
# values. Each is applied and destroyed in turn in the same namespace, and its
# objects and a pod from each Deployment template are admitted again in p-demo.
n_fx="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$TMP/tofu/fixtures.json")"
[ "$n_fx" -ge 7 ] && ok "Cloud has $n_fx snapshot fixtures to apply" || bad "only $n_fx snapshot fixtures in Cloud's render.fixtures.ts"
for i in $(seq 0 $((n_fx - 1))); do
  IFS=$'\t' read -r fx_dir fx_name fx_ns < <(python3 -c 'import json,sys; f=json.load(open(sys.argv[1]))[int(sys.argv[2])]; print(f["dir"], f["name"], f["namespace"], sep="\t")' "$TMP/tofu/fixtures.json" "$i")
  # The previous destroy deletes the namespace; a new one with the same name
  # cannot be created while it terminates.
  ka wait --for=delete "namespace/$fx_ns" --timeout=300s >/dev/null 2>&1
  TOFU_DIR="$TMP/tofu/$fx_dir" DUMP_DIR="$TMP/dump-fx$i" NS="$fx_ns"
  mkdir -p "$DUMP_DIR"
  ln -s "$CLOUD_REPO/modules" "$TOFU_DIR/modules"
  cp "$TMP/tofu/zz_dump.tf.json" "$TMP/tofu/cloud-access.tftest.hcl" "$TOFU_DIR/"
  if ! tofu init -backend=false -input=false -no-color -plugin-dir="$TOFU_PLUGINS" >"$TOFU_DIR/init.log" 2>&1; then
    bad "fixture \"$fx_name\": tofu init: $(tail -20 "$TOFU_DIR/init.log")"; continue
  fi
  if tofu test -no-color >"$TOFU_DIR/test.log" 2>&1 && grep -q "1 passed, 0 failed" "$TOFU_DIR/test.log"; then
    ok "fixture \"$fx_name\": Cloud's modules apply and destroy it in $fx_ns as the reconciler"
  else
    bad "fixture \"$fx_name\": did not apply and destroy cleanly: $(grep -v '^\s*$' "$TOFU_DIR/test.log" | tail -30)"; continue
  fi
  api_after "$DUMP_DIR" "fixture \"$fx_name\""
  if [ -s "$DUMP_DIR/objects.json" ] && python3 "$HERE/tests/cloud-access/variants.py" "$DUMP_DIR" "$TMP/cases-fx$i" p-demo admitted-only >"$TMP/variants-fx$i.log" 2>&1; then
    check="$(pods_check "$DUMP_DIR" "$TMP/cases-fx$i")" && ok "fixture \"$fx_name\": every Deployment's pods were admitted: $check" || bad "fixture \"$fx_name\": $check"
    run_cases "$TMP/cases-fx$i"
  else
    bad "fixture \"$fx_name\": no objects to check: $(cat "$TMP/variants-fx$i.log" 2>/dev/null)"
  fi
done
TOFU_DIR="$TMP/tofu" DUMP_DIR="$TMP/dump"

expect_ok   "reconciler deletes p-other" kr delete namespace p-other --wait=false

# --- control: a policy with a parameter takes calico-apiserver down -------------------
# Shows the APIService checks above can see the failure they guard against.
# calico-apiserver's service account may not list ConfigMaps, so a ConfigMap
# parameter leaves its informer unsynced and its readiness check failing.
ka apply -f - >/dev/null <<'YAML'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: probe-param
spec:
  failurePolicy: Fail
  paramKind: {apiVersion: v1, kind: ConfigMap}
  matchConstraints:
    resourceRules: [{apiGroups: ["probe.example.com"], apiVersions: ["*"], operations: ["CREATE"], resources: ["*"]}]
  validations: [{expression: "true"}]
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: probe-param
spec:
  policyName: probe-param
  validationActions: [Deny]
  paramRef: {name: probe, namespace: default, parameterNotFoundAction: Deny}
YAML
down=""
for _ in $(seq 1 36); do cloud_calico_api_available || { down=1; break; }; sleep 5; done
[ -n "$down" ] && ok "control: a ConfigMap parameter makes v3.projectcalico.org unavailable" \
  || bad "control: v3.projectcalico.org stayed available with a ConfigMap parameter for 3 minutes, so the checks above may be blind"
# Deleting the policy is not enough: the informer stays in calico-apiserver,
# which did not recover in 5 minutes on 2026-11-13. A restart clears it.
ka delete validatingadmissionpolicybinding probe-param >/dev/null; ka delete validatingadmissionpolicy probe-param >/dev/null
ka get pods -n calico-system -o name | grep calico-apiserver | xargs -r kubectl delete -n calico-system --wait=false >/dev/null
for _ in $(seq 1 60); do cloud_calico_api_available && break; sleep 5; done
cloud_calico_api_available && ok "control: v3.projectcalico.org is available again once that policy is gone and calico-apiserver restarts" \
  || bad "control: v3.projectcalico.org did not recover after the parameter policy was deleted and calico-apiserver restarted"

# --- Vault -------------------------------------------------------------------
VPORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
export VAULT_ADDR="http://127.0.0.1:$VPORT" VAULT_TOKEN="root-$$"
# A dev server writes its root token to the token helper, ~/.vault-token by
# default, which on the devvm holds the user's real Vault token. Never let it:
# -dev-no-store-token, and every vault call runs with HOME in the temp dir.
vault() { HOME="$TMP/home" command vault "$@"; }
vtok() { local t="$1"; shift; HOME="$TMP/home" VAULT_TOKEN="$t" command vault "$@"; }
# `command`, not the function, so $! is Vault's own pid and cleanup stops it.
HOME="$TMP/home" command vault server -dev -dev-no-store-token -dev-root-token-id="$VAULT_TOKEN" -dev-listen-address="127.0.0.1:$VPORT" >"$TMP/vault.log" 2>&1 &
VAULT_PID=$!
for _ in $(seq 1 30); do vault status >/dev/null 2>&1 && break; sleep 1; done
vault status >/dev/null 2>&1 || { echo "FAIL: dev vault did not start"; tail "$TMP/vault.log"; exit 1; }

ka apply -f "$TMP/vault-sa.yaml" >/dev/null || { echo "FAIL: vault service account"; exit 1; }
for n in p-demo p-adopt default; do ka create serviceaccount cloud-secrets -n "$n" >/dev/null 2>&1; done
ka create serviceaccount other -n p-demo >/dev/null
kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d >"$TMP/ca.crt"
vault auth enable kubernetes >/dev/null
vault write auth/kubernetes/config kubernetes_host="$SERVER" kubernetes_ca_cert=@"$TMP/ca.crt" \
  token_reviewer_jwt="$(ka create token vault -n vault --duration=1h)" disable_local_ca_jwt=true >/dev/null
ACCESSOR="$(vault auth list -format=json | python3 -c 'import json,sys; print(json.load(sys.stdin)["kubernetes/"]["accessor"])')"
sed "s/@@KUBERNETES_ACCESSOR@@/$ACCESSOR/" "$TMP/project.hcl.tpl" >"$TMP/project.hcl"
vault policy write cloud-project "$TMP/project.hcl" >/dev/null
vault policy write cloud-reconciler "$TMP/reconciler.hcl" >/dev/null
vault write auth/kubernetes/role/cloud-project bound_service_account_names=cloud-secrets \
  bound_service_account_namespace_selector="$(cat "$TMP/selector.json")" token_policies=cloud-project token_ttl=3600 >/dev/null 2>&1
vault write auth/kubernetes/role/cloud-reconciler bound_service_account_names=cloud-reconciler \
  bound_service_account_namespaces=cloud token_policies=cloud-reconciler token_ttl=3600 >/dev/null 2>&1
vault kv put secret/cloud/p-demo/app a=demo >/dev/null
vault kv put secret/cloud/p-demo/_cloud/registry server=ghcr.io username=u password=p >/dev/null
vault kv put secret/cloud/p-other/app a=other >/dev/null
vault kv put secret/cloud/p-other/_cloud/registry server=ghcr.io username=u password=p >/dev/null
vault kv put secret/cloud/system cloud_apps_client_id=cloud-apps cloud_apps_client_secret=s ghcr_pull_token=g >/dev/null
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
expect_ok   "p-demo token reads a Service entry, secret/cloud/p-demo/app" vtok "$PT" kv get -field=a secret/cloud/p-demo/app
expect_ok   "p-demo token reads Cloud's entry secret/cloud/p-demo/_cloud/registry" vtok "$PT" kv get -field=server secret/cloud/p-demo/_cloud/registry
expect_fail "p-demo token cannot read secret/cloud/p-other/app" "permission denied" vtok "$PT" kv get secret/cloud/p-other/app
expect_fail "p-demo token cannot read secret/cloud/p-other/_cloud/registry" "permission denied" vtok "$PT" kv get secret/cloud/p-other/_cloud/registry
expect_fail "p-demo token cannot read secret/cloud/system" "permission denied" vtok "$PT" kv get secret/cloud/system
expect_fail "p-demo token cannot read secret/viktor" "permission denied" vtok "$PT" kv get secret/viktor
expect_fail "p-demo token cannot write its own tree" "permission denied" vtok "$PT" kv put secret/cloud/p-demo/app a=x

RT="$(login cloud-reconciler cloud cloud-reconciler 2>/dev/null)"
[ -n "$RT" ] && ok "cloud-reconciler logs in from namespace cloud" || bad "cloud-reconciler login"
expect_ok   "reconciler writes a Service entry" vtok "$RT" kv put secret/cloud/p-demo/new a=1
expect_ok   "reconciler writes a _cloud/ entry" vtok "$RT" kv put secret/cloud/p-demo/_cloud/recipes-oauth2-proxy client_secret=c cookie_secret=k
expect_ok   "reconciler deletes a Project secret with all versions" vtok "$RT" kv metadata delete secret/cloud/p-demo/new
expect_fail "reconciler cannot write outside the p-* trees" "permission denied" vtok "$RT" kv put secret/cloud/homelab/x a=1
# M5: App secrets are KV v2 merge patches (HTTP PATCH), so other keys stay.
# -method=patch: the CLI's default falls back to read-then-write on a 403.
expect_ok   "reconciler patches an App secret (M5)" vtok "$RT" kv patch -method=patch secret/cloud/p-demo/app b=2
[ "$(vtok "$RT" kv get -field=a secret/cloud/p-demo/app 2>&1)" = "demo" ] && ok "the patch keeps the App secret's other keys" || bad "the patch dropped key a of secret/cloud/p-demo/app"
expect_fail "reconciler cannot patch secret/cloud/system" "permission denied" vtok "$RT" kv patch -method=patch secret/cloud/system ghcr_pull_token=x
expect_fail "reconciler cannot patch outside the p-* trees" "permission denied" vtok "$RT" kv patch -method=patch secret/cloud/homelab/x a=1
expect_ok   "reconciler reads the shared client from secret/cloud/system" vtok "$RT" kv get -field=cloud_apps_client_secret secret/cloud/system
expect_fail "reconciler cannot change secret/cloud/system" "permission denied" vtok "$RT" kv put secret/cloud/system cloud_apps_client_secret=x
expect_fail "reconciler cannot delete secret/cloud/system" "permission denied" vtok "$RT" kv metadata delete secret/cloud/system
expect_fail "reconciler cannot read secret/viktor" "permission denied" vtok "$RT" kv get secret/viktor
expect_fail "reconciler cannot write a Vault policy" "permission denied" vtok "$RT" policy write x "$TMP/project.hcl"
caps() { vtok "$RT" token capabilities "$1" 2>&1; }
[ "$(caps database/static-creds/pg-cloud-state)" = "read" ] && ok "reconciler reads pg-cloud-state" || bad "pg-cloud-state caps: $(caps database/static-creds/pg-cloud-state)"
[ "$(caps database/static-creds/pg-cloud-provisioner)" = "read" ] && ok "reconciler reads pg-cloud-provisioner" || bad "pg-cloud-provisioner caps"
[ "$(caps database/static-creds/pg-terraform-state)" = "deny" ] && ok "reconciler cannot read pg-terraform-state" || bad "pg-terraform-state caps: $(caps database/static-creds/pg-terraform-state)"
[ "$(caps auth/kubernetes/role/cloud-project)" = "deny" ] && ok "reconciler cannot touch auth roles" || bad "auth role caps"

# The client id the oauth2-proxy pin expects is the one stacks/authentik
# gives the shared provider (not a locals-only file, so read as text).
want_id="$(python3 -c 'import json,sys; print(json.loads(json.loads(open(sys.argv[1]).read()))["client_id"])' "$TMP/k8s.raw")"
grep -qE "^\s*cloud_apps_client_id\s*=\s*\"$want_id\"" "$HERE/stacks/authentik/cloud-apps.tf" \
  && grep -qE "^\s*client_id\s*=\s*local.cloud_apps_client_id" "$HERE/stacks/authentik/cloud-apps.tf" \
  && ok "stacks/authentik gives the shared client the id the oauth2-proxy pin expects ($want_id)" \
  || bad "stacks/authentik/cloud-apps.tf does not set client_id \"$want_id\""

[ "$(token_sum)" = "$TOKEN_BEFORE" ] && ok "~/.vault-token untouched" || bad "~/.vault-token CHANGED by this test"

echo
if [ "$FAILS" -eq 0 ]; then echo "PASS: cloud reconciler, Project namespaces and Project secret boundaries"; else echo "FAIL: $FAILS check(s)"; exit 1; fi
