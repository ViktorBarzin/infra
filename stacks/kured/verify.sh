# shellcheck shell=bash
# Verify checks for stacks/kured (docs/runbooks/verify-jobs.md).
VERIFY_GROUP="chart"
VERIFY_NAMESPACES="kured"

_startup_log() {
  local pod logs
  pod=$(kubectl get pods -n kured -l app.kubernetes.io/name=kured -o jsonpath='{.items[0].metadata.name}')
  # Read the log once into a variable: `kubectl logs | head` under pipefail
  # fails on SIGPIPE even when the line is there.
  logs=$(kubectl logs -n kured "$pod" -c kured 2>/dev/null)
  grep -E 'Kubernetes Reboot Daemon|Reboot schedule|Sentinel checker|Lock Annotation' <<<"$logs" | sed -n 1,4p
  grep -q 'Reboot schedule' <<<"$logs" && ! grep -Eq 'level=(error|fatal)|forbidden' <<<"$logs"
}

_gated_sentinel() {
  local args
  args=$(kubectl get ds -n kured kured -o jsonpath='{.spec.template.spec.containers[0].args}')
  echo "args=$args"
  # The gated sentinel and the Prometheus alert filter are what keep kured
  # from rebooting a node while blocking alerts fire.
  grep -q 'reboot-sentinel=/sentinel/gated-reboot-required' <<<"$args" &&
    grep -q 'prometheus-url=' <<<"$args"
}

_metrics() {
  local ip
  ip=$(kubectl get pods -n kured -l app.kubernetes.io/name=kured -o jsonpath='{.items[0].status.podIP}')
  local m
  m=$(curl -sS --max-time 10 "http://$ip:8080/metrics")
  grep -E '^kured_reboot_required' <<<"$m"
}

verify_component() {
  check "kured DaemonSet converged on every node" retry 300 10 workload_ready kured daemonset/kured
  check "kured-sentinel-gate DaemonSet converged" retry 300 10 workload_ready kured daemonset/kured-sentinel-gate
  check "kured started with its schedule and lock, no errors" _startup_log
  check "kured watches the gated sentinel and Prometheus" _gated_sentinel
  check "kured serves kured_reboot_required" _metrics
}
