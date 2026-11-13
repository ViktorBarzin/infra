#!/usr/bin/env bash
# Live check of the one Cloud boundary no offline test can reach: Calico's tier
# authorization (docs/agents/security.md, Cloud item (11)).
#
# The network floor (stacks/cloud, tier `cloud`) stops a stolen reconciler
# credential only if Calico's API server refuses that credential a policy in
# any tier but `default`. The reconciler holds `networkpolicies` with every
# verb and no resource name; only the per-tier pseudo-resource
# `tier.networkpolicies` (resource names `default.*`) and `get` on tier
# `default` keep it out of tier `cloud`. kind has no calico-apiserver and no
# tier authorization, so tests/cloud-access.test.sh cannot prove this.
#
# Run it once after `stacks/cloud` is applied, and from M4's live isolation
# test. It needs a kubeconfig that may impersonate service accounts (admin).
#
# What it writes, as the reconciler, and removes again: one namespace
# p-tier-check-<pid> with the contract's labels and the RoleBinding to the
# project role. Every policy below is a server-side dry run, so no Calico
# policy is ever created.
#
# Expects, as system:serviceaccount:cloud:cloud-reconciler in that namespace:
#   a NetworkPolicy in tier default            admitted (dry run)
#   one in tier cloud, kube-admin, calico-system  Forbidden
#   reading or changing either floor           Forbidden
#   a GlobalNetworkPolicy, a Tier               Forbidden
# Exit 0 only when every expectation holds.
set -uo pipefail
AS="system:serviceaccount:cloud:cloud-reconciler"
NS="p-tier-check-$$"
ROLE="cloud-reconciler-project"
kr() { kubectl --as="$AS" "$@"; }

FAILS=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; FAILS=$((FAILS + 1)); }
expect_ok()   { local what="$1"; shift; if out="$("$@" 2>&1)"; then ok "$what"; else bad "$what: $out"; fi; }
expect_forbidden() { local what="$1"; shift
  if out="$("$@" 2>&1)"; then bad "$what: admitted, expected Forbidden"
  elif grep -qiE "forbidden" <<<"$out"; then ok "$what"; else bad "$what: wrong error: $out"; fi; }

kubectl get tiers.projectcalico.org cloud >/dev/null 2>&1 || { echo "FAIL: tier cloud does not exist; apply stacks/cloud first"; exit 1; }

cleanup() { kr delete namespace "$NS" --wait=false >/dev/null 2>&1; }
trap cleanup EXIT

kr apply --server-side --field-manager=cloud-tier-check -f - >/dev/null <<EOF || { echo "FAIL: the reconciler cannot create $NS"; exit 1; }
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
  labels:
    cloud.viktorbarzin.me/managed: "true"
    tier: "4-aux"
    pod-security.kubernetes.io/enforce: restricted
    resource-governance/custom-quota: "true"
    resource-governance/custom-limitrange: "true"
EOF
kr apply --server-side --field-manager=cloud-tier-check -f - >/dev/null <<EOF || { echo "FAIL: the reconciler cannot bind $ROLE in $NS"; exit 1; }
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: cloud-reconciler-$ROLE
  namespace: $NS
subjects:
- kind: ServiceAccount
  name: cloud-reconciler
  namespace: cloud
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: $ROLE
EOF
# RBAC caches settle within a second or two.
for _ in $(seq 1 15); do kr auth can-i create configmaps -n "$NS" >/dev/null 2>&1 && break; sleep 1; done

np() { # tier
  cat <<EOF
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: $1.tier-check
  namespace: $NS
spec:
  tier: $1
  order: 1
  selector: all()
  types: [Ingress, Egress]
  ingress: [{action: Allow}]
  egress: [{action: Allow}]
EOF
}
expect_ok        "an Allow-all NetworkPolicy in tier default is admitted (dry run)" kr create --dry-run=server -f - < <(np default)
for tier in cloud kube-admin calico-system; do
  expect_forbidden "an Allow-all NetworkPolicy in tier $tier is Forbidden" kr create --dry-run=server -f - < <(np "$tier")
done
for floor in cloud.project-egress-floor cloud.project-ingress-floor; do
  expect_forbidden "reading $floor is Forbidden" kr get globalnetworkpolicies.projectcalico.org "$floor"
  expect_forbidden "deleting $floor is Forbidden" kr delete globalnetworkpolicies.projectcalico.org "$floor" --dry-run=server
done
expect_forbidden "a GlobalNetworkPolicy is Forbidden" kr create --dry-run=server -f - <<'EOF'
apiVersion: projectcalico.org/v3
kind: GlobalNetworkPolicy
metadata:
  name: default.tier-check
spec:
  tier: default
  order: 1
  selector: all()
  types: [Egress]
  egress: [{action: Allow}]
EOF
expect_forbidden "a Tier is Forbidden" kr create --dry-run=server -f - <<'EOF'
apiVersion: projectcalico.org/v3
kind: Tier
metadata:
  name: tier-check
spec:
  order: 1
EOF

echo
if [ "$FAILS" -eq 0 ]; then echo "PASS: Calico refuses the reconciler every tier but default"; else echo "FAIL: $FAILS check(s)"; exit 1; fi
