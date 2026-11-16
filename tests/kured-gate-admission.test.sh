#!/usr/bin/env bash
# Checks ValidatingAdmissionPolicy kured-sentinel-gate-scope
# (stacks/kured/gate_admission.tf) against a real API server: kind, Kubernetes
# 1.35 like the cluster. The policy is read from the stack's locals with
# `terraform console`, so the test checks exactly what Terraform applies.
#
# What it proves, acting as the gate's service account with its pod's node
# name, the way its token arrives:
#   - a rollout restart is admitted in namespace cloud and in a managed p-*
#     namespace, refused in a p-* namespace without the managed label and in
#     a homelab namespace;
#   - any other Deployment change (replicas, image, another template
#     annotation, a label) is refused, and so are a create and a delete;
#   - it may cordon and uncordon its own Node and set the drain label, but
#     not cordon another Node, set another label, taint its Node, give the
#     drain label another value, or touch any Node without a node name;
#   - admin is not affected.
#
# Needs docker, kind, kubectl, terraform and python3 with PyYAML. Takes about two minutes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
KIND_IMAGE="${KURED_GATE_KIND_IMAGE:-kindest/node:v1.35.0}"
CLUSTER="kured-gate-$$"
TMP="$(mktemp -d)"
export KUBECONFIG="$TMP/kubeconfig"
cleanup() { kind delete cluster --name "$CLUSTER" >/dev/null 2>&1; rm -rf "$TMP"; }
trap cleanup EXIT

FAILS=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; FAILS=$((FAILS + 1)); }
expect_ok()   { local what="$1"; shift; if out="$("$@" 2>&1)"; then ok "$what"; else bad "$what: $out"; fi; }
expect_fail() { local what="$1" pattern="$2"; shift 2
  if out="$("$@" 2>&1)"; then bad "$what: admitted"
  elif grep -qE "$pattern" <<<"$out"; then ok "$what"
  else bad "$what: wrong error: $out"; fi
}

mkdir -p "$TMP/render"
cp "$HERE/stacks/kured/gate_admission.tf" "$TMP/render/"
(cd "$TMP/render" && echo 'jsonencode(local.kured_gate_admission)' | terraform console >"$TMP/policy.raw" 2>"$TMP/render.err") \
  || { echo "FAIL: terraform console could not read stacks/kured/gate_admission.tf"; cat "$TMP/render.err"; exit 1; }
python3 - "$TMP" <<'PY' || exit 1
import json, sys, pathlib
d = pathlib.Path(sys.argv[1])
p = json.loads(json.loads((d / "policy.raw").read_text()))
(d / "policy.json").write_text(json.dumps({"apiVersion": "v1", "kind": "List", "items": [p["policy"], p["binding"]]}))
PY

kind create cluster --name "$CLUSTER" --image "$KIND_IMAGE" --wait 120s >"$TMP/kind.log" 2>&1 \
  || { echo "FAIL: kind create cluster"; cat "$TMP/kind.log"; exit 1; }
NODE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"

ka() { kubectl "$@"; }
# The gate's identity by impersonation, the node name as its token carries it.
# kubectl has no flag for impersonated extras; a kubeconfig user does.
python3 - "$KUBECONFIG" "$TMP/gate.kubeconfig" "$NODE" <<'PY' || exit 1
import sys, yaml
src, dst, node = sys.argv[1:]
cfg = yaml.safe_load(open(src))
user = dict(cfg["users"][0]["user"])
user["as"] = "system:serviceaccount:kured:kured-sentinel-gate"
user["as-groups"] = ["system:serviceaccounts", "system:serviceaccounts:kured", "system:authenticated"]
none = dict(user)
user["as-user-extra"] = {"authentication.kubernetes.io/node-name": [node]}
cfg["users"] = [{"name": "gate", "user": user}, {"name": "gate-none", "user": none}]
ctx = cfg["contexts"][0]["context"]
cfg["contexts"] = [{"name": "gate", "context": dict(ctx, user="gate")}, {"name": "gate-none", "context": dict(ctx, user="gate-none")}]
cfg["current-context"] = "gate"
yaml.safe_dump(cfg, open(dst, "w"))
PY
kg()      { kubectl --kubeconfig "$TMP/gate.kubeconfig" --context gate "$@"; }
kg_none() { kubectl --kubeconfig "$TMP/gate.kubeconfig" --context gate-none "$@"; }

ka create namespace kured >/dev/null
ka create serviceaccount kured-sentinel-gate -n kured >/dev/null
# The gate's ClusterRole as stacks/kured/main.tf grants it.
ka create clusterrole kured-sentinel-gate --verb=get,list,watch,patch --resource=nodes,deployments.apps >/dev/null
ka create clusterrolebinding kured-sentinel-gate --clusterrole=kured-sentinel-gate --serviceaccount=kured:kured-sentinel-gate >/dev/null
for ns in cloud p-demo p-bare homelab; do ka create namespace "$ns" >/dev/null; done
ka label namespace p-demo cloud.viktorbarzin.me/managed=true >/dev/null
ka label namespace p-bare cloud.viktorbarzin.me/managed=false >/dev/null
for ns in cloud p-demo p-bare homelab; do
  ka create deployment web -n "$ns" --image=registry.k8s.io/pause:3.10 >/dev/null
done
ka create -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Node
metadata:
  name: other-node
EOF

expect_ok "admin applies the policy and its binding" ka apply -f "$TMP/policy.json"
# The policy takes a moment to reach the admission chain.
for _ in $(seq 1 30); do
  kg_none patch node other-node --type=merge -p '{"spec":{"unschedulable":true}}' --dry-run=server >/dev/null 2>&1 || break
  sleep 2
done

expect_ok   "gate rollout-restarts a Deployment in cloud" kg rollout restart deployment/web -n cloud
expect_ok   "gate rollout-restarts a Deployment in a managed p-* namespace" kg rollout restart deployment/web -n p-demo
expect_fail "gate cannot restart in a p-* namespace not labelled managed" "only in namespace cloud" kg rollout restart deployment/web -n p-bare
expect_fail "gate cannot restart in a homelab namespace" "only in namespace cloud" kg rollout restart deployment/web -n homelab
expect_fail "gate cannot scale a Deployment" "only rollout-restart" kg patch deployment web -n p-demo --type=merge -p '{"spec":{"replicas":2}}'
expect_fail "gate cannot change the image" "only rollout-restart" kg set image deployment/web -n p-demo pause=registry.k8s.io/pause:3.9
expect_fail "gate cannot add another template annotation" "only rollout-restart" \
  kg patch deployment web -n p-demo --type=merge -p '{"spec":{"template":{"metadata":{"annotations":{"other":"x"}}}}}'
expect_fail "gate cannot label a Deployment" "only rollout-restart" kg label deployment web -n p-demo x=y
expect_fail "gate cannot delete a Deployment" "forbidden" kg delete deployment web -n p-demo --wait=false

# kubectl cordon exits 0 even when the API refuses it, so the refusals are
# checked with the same patch it sends, and the admitted ones by the state.
unschedulable() { [ "$(ka get node "$1" -o jsonpath='{.spec.unschedulable}')" = "$2" ]; }
CORDON='{"spec":{"unschedulable":true}}'
expect_ok   "gate cordons its own Node" kg cordon "$NODE"
expect_ok   "its Node is then unschedulable" unschedulable "$NODE" true
expect_ok   "gate sets the drain label on its own Node" kg label node "$NODE" cloud.viktorbarzin.me/drain=handed-off --overwrite
expect_ok   "gate uncordons its own Node" kg uncordon "$NODE"
expect_ok   "its Node is then schedulable" unschedulable "$NODE" ""
expect_fail "gate cannot cordon another Node" "its own pod runs on" kg patch node other-node --type=merge -p "$CORDON"
expect_ok   "another Node stays schedulable after kubectl cordon as the gate" bash -c "kubectl --kubeconfig '$TMP/gate.kubeconfig' --context gate cordon other-node >/dev/null 2>&1; [ \"\$(kubectl get node other-node -o jsonpath='{.spec.unschedulable}')\" = '' ]"
expect_fail "gate cannot cordon without a node name in its token" "its own pod runs on" kg_none patch node "$NODE" --type=merge -p "$CORDON"
expect_fail "gate cannot set another label on its Node" "may change only spec.unschedulable" kg label node "$NODE" x=y
expect_fail "gate cannot give the drain label another value" "may change only spec.unschedulable" kg label node "$NODE" cloud.viktorbarzin.me/drain=evil --overwrite
expect_fail "gate cannot taint its Node" "may change only spec.unschedulable" kg taint node "$NODE" x=y:NoSchedule
expect_fail "gate cannot delete a Node" "forbidden" kg delete node other-node --wait=false

expect_ok   "admin still scales a Deployment in p-demo" ka patch deployment web -n p-demo --type=merge -p '{"spec":{"replicas":2}}'
expect_ok   "admin still cordons another Node" ka cordon other-node

[ "$FAILS" -eq 0 ] && echo "all passed" || { echo "FAIL: $FAILS check(s)"; exit 1; }
