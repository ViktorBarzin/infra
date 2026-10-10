# shellcheck shell=bash
# Verify checks for stacks/kyverno (docs/runbooks/verify-jobs.md).
# Admission is exercised with server-side dry runs in the verify namespace,
# which persist nothing.
VERIFY_GROUP="chart"
VERIFY_NAMESPACES="kyverno"

_policies_ready() {
  local out
  out=$(kubectl get clusterpolicies.kyverno.io -o json 2>/dev/null | jq -r '
    [.items[] | {n:.metadata.name, r:([.status.conditions[]? | select(.type=="Ready")][0].status // "Unknown")}] as $a
    | [$a[] | select(.r != "True") | .n] as $bad
    | "clusterpolicies=\($a|length) not ready=\($bad)", (if ($a|length) > 0 and ($bad|length)==0 then 0 else 1 end)')
  head -1 <<<"$out"
  [ "$(tail -1 <<<"$out")" = 0 ]
}

_denies_privileged() {
  expect_dry_run_denied '{"apiVersion":"v1","kind":"Pod","metadata":{"name":"verify-kyverno-priv","namespace":"verify"},
    "spec":{"containers":[{"name":"c","image":"docker.io/library/busybox:1.36","securityContext":{"privileged":true}}]}}' 'deny-privileged-containers'
}

_mutates() {
  local out p d
  out=$(printf '%s' '{"apiVersion":"v1","kind":"Pod","metadata":{"name":"verify-kyverno-mut","namespace":"verify"},
    "spec":{"containers":[{"name":"c","image":"docker.io/library/busybox:1.36"}]}}' | kubectl create --dry-run=server -o json -f - 2>&1)
  p=$(jq -r '.spec.priorityClassName // "none"' <<<"$out" 2>/dev/null)
  d=$(jq -r '[.spec.dnsConfig.options[]? | select(.name=="ndots") | .value][0] // "none"' <<<"$out" 2>/dev/null)
  echo "priorityClassName=$p ndots=$d"
  [ "$p" = "tier-4-aux" ] && [ "$d" = "2" ]
}

_reports_off() {
  local a b
  a=$(kubectl get ephemeralreports.reports.kyverno.io -A --no-headers 2>/dev/null | wc -l)
  b=$(kubectl get clusterephemeralreports.reports.kyverno.io --no-headers 2>/dev/null | wc -l)
  echo "ephemeralreports=$a clusterephemeralreports=$b"
  # Reports are off; the 2026-06-21 upgrade created about 10.5k and flapped etcd.
  [ "$a" -lt 100 ] && [ "$b" -lt 100 ]
}

_no_keel_policy() {
  # inject-keel-annotations was deleted in the Keel cutover (2026-10-10).
  local n
  n=$(kubectl get clusterpolicies.kyverno.io inject-keel-annotations --no-headers 2>/dev/null | wc -l)
  echo "inject-keel-annotations present=$n"
  [ "$n" -eq 0 ]
}

_updaterequests_bounded() {
  local n
  n=$(kubectl get updaterequests.kyverno.io -A --no-headers 2>/dev/null | wc -l)
  echo "updaterequests=$n"
  [ "$n" -lt 2000 ]
}

verify_component() {
  check "admission controller converged" retry 300 10 workload_ready kyverno deployment/kyverno-admission-controller
  check "background controller converged" retry 300 10 workload_ready kyverno deployment/kyverno-background-controller
  check "cleanup controller converged" retry 300 10 workload_ready kyverno deployment/kyverno-cleanup-controller
  check "every ClusterPolicy is Ready" _policies_ready
  check "a privileged pod is denied (dry run)" _denies_privileged
  check "a plain pod gets the tier priority and ndots=2 (dry run)" _mutates
  check "policy reports stay off" _reports_off
  check "the Keel annotation policy stays deleted" _no_keel_policy
  check "background update requests are bounded" _updaterequests_bounded
  check "no panics in Kyverno logs (15m)" expect_no_log_errors kyverno app.kubernetes.io/instance=kyverno 'panic|fatal'
}
