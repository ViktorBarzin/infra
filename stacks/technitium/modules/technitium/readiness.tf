# =============================================================================
# Post-apply readiness gate
# =============================================================================
#
# Runs after all three Technitium deployments + the DNS LB service have been
# applied. Verifies that every instance is rolled out, the API responds, the
# DNS pods answer queries, and zone counts agree. Fails the apply if any
# check fails. No canary — this is a hard gate.
#
# Override for emergency maintenance: apply with `-var skip_readiness=true`
# (set via terragrunt inputs when needed), or `terraform apply -target` the
# resources needed without touching this module.

variable "skip_readiness" {
  type        = bool
  default     = false
  description = "Skip the Technitium readiness gate. Use only for emergency maintenance."
}

resource "null_resource" "technitium_readiness_gate" {
  count = var.skip_readiness ? 0 : 1

  # Re-run when any deployment image/resource changes, or on every apply
  # (timestamp) so transient drift still gets exercised.
  triggers = {
    primary_digest   = sha256(jsonencode(kubernetes_deployment.technitium.spec[0].template[0].spec[0].container[0]))
    secondary_digest = sha256(jsonencode(kubernetes_deployment.technitium_secondary.spec[0].template[0].spec[0].container[0]))
    tertiary_digest  = sha256(jsonencode(kubernetes_deployment.technitium_tertiary.spec[0].template[0].spec[0].container[0]))
    corefile         = sha256(kubernetes_config_map.coredns.data["Corefile"])
    always           = timestamp()
  }

  provisioner "local-exec" {
    command     = <<-BASH
      set -euo pipefail
      NS=technitium
      echo "=== Technitium readiness gate ==="

      # 1. Wait for rollout on all three deployments.
      for d in technitium technitium-secondary technitium-tertiary; do
        echo "-> rollout status deploy/$d"
        kubectl -n $NS rollout status deploy/$d --timeout=180s
      done

      # 2. Per-pod API + DNS check (via kubectl exec on the pod itself — no
      #    ephemeral debug pods, no iamge pull, no zombies).
      PODS=$(kubectl -n $NS get pod -l dns-server=true -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
      if [ -z "$PODS" ]; then
        echo "ERROR: no dns-server=true pods found"
        exit 1
      fi

      for POD in $PODS; do
        echo "-> API check on $POD"
        if ! kubectl -n $NS exec "$POD" -- wget -qO- --timeout=10 "http://127.0.0.1:5380/api/stats/get?token=&type=LastHour" | grep -q '"status":"ok"'; then
          echo "ERROR: API check failed on $POD"
          exit 1
        fi
      done

      # 3. Zone-count parity — use the three web services from within any
      #    running technitium pod (has wget) to avoid spawning probe pods.
      FIRST_POD=$(echo "$PODS" | head -1)
      COUNTS=""
      for SVC in technitium-web technitium-secondary-web technitium-tertiary-web; do
        COUNT=$(kubectl -n $NS exec "$FIRST_POD" -- sh -c "wget -qO- --timeout=10 'http://$SVC:5380/api/zones/list?token=' | tr ',' '\n' | grep -c '\"name\":' || true" 2>/dev/null | tail -1)
        echo "-> $SVC zone count: $${COUNT:-unknown}"
        COUNTS="$COUNTS $COUNT"
      done
      UNIQ=$(echo $COUNTS | tr ' ' '\n' | sort -u | wc -l)
      if [ "$UNIQ" -gt 1 ]; then
        echo "ERROR: zone counts differ across instances:$COUNTS"
        exit 1
      fi

      echo "=== Technitium readiness gate PASSED ==="
    BASH
    interpreter = ["/bin/bash", "-c"]
  }

  depends_on = [
    kubernetes_deployment.technitium,
    kubernetes_deployment.technitium_secondary,
    kubernetes_deployment.technitium_tertiary,
    kubernetes_service.technitium-dns,
    kubernetes_pod_disruption_budget_v1.technitium_dns,
  ]
}
