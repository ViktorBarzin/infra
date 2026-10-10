# shellcheck shell=bash
# Verify checks for stacks/metallb (docs/runbooks/verify-jobs.md).
VERIFY_GROUP="chart"
VERIFY_NAMESPACES="metallb-system"

_all_lb_have_ips() {
  local out
  out=$(kubectl get svc -A -o json | jq -r '
    [.items[] | select(.spec.type=="LoadBalancer")] as $lb
    | [$lb[] | select((.status.loadBalancer.ingress // []) | length == 0) | "\(.metadata.namespace)/\(.metadata.name)"] as $pending
    | "loadbalancers=\($lb|length) pending=\($pending)", (if ($pending|length)==0 then 0 else 1 end)')
  head -1 <<<"$out"
  [ "$(tail -1 <<<"$out")" = 0 ]
}

_config_valid() {
  local out
  out=$(kubectl get configurationstates.metallb.io -n metallb-system -o json | jq -r '
    [.items[] | {n:.metadata.name, r:(.status.result // "unknown")}] as $a
    | "states=\($a|length) not valid=\([$a[] | select(.r != "Valid") | .n])", (if ([$a[]|select(.r!="Valid")]|length)==0 then 0 else 1 end)')
  head -1 <<<"$out"
  [ "$(tail -1 <<<"$out")" = 0 ]
}

_l2_announced() {
  local n
  n=$(kubectl get servicel2statuses.metallb.io -n metallb-system -o json | jq '[.items[] | select(.status.node != null and .status.node != "")] | length')
  echo "services with an announcing node: $n"
  [ "$n" -ge 1 ]
}

verify_component() {
  check "controller converged" retry 300 10 workload_ready metallb-system deployment/metallb-controller
  check "speakers converged" retry 300 10 workload_ready metallb-system daemonset/metallb-speaker
  check "every LoadBalancer Service has an IP" _all_lb_have_ips
  check "MetalLB configuration is Valid" _config_valid
  check "L2 announcements have a node" _l2_announced
  check "Terraform state DB VIP 10.0.20.200:5432" tcp_open 10.0.20.200 5432
  check "Forgejo SSH VIP 10.0.20.200:22" tcp_open 10.0.20.200 22
  check "DNS VIP 10.0.20.201:53" tcp_open 10.0.20.201 53
  check "ingress VIP 10.0.20.203:443" tcp_open 10.0.20.203 443
  # Not '"level":"error"': memberlist "partial join" errors run at 1-10 an
  # hour on a healthy cluster. 'immutable' is the 2026-05-16 post-mortem
  # signature.
  check "no immutable-field errors in the last 15m" expect_no_log_errors metallb-system app.kubernetes.io/name=metallb 'immutable'
}
