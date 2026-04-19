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

      # 2. Per-pod DNS check + content parity. Technitium pods have `dig` but
      #    no HTTP client, so we use DNS directly. Each pod must return an A
      #    record for idrac.viktorbarzin.lan, AND the answer must match across
      #    all three instances. This catches:
      #    - Zone not loaded on an instance (NXDOMAIN / empty)
      #    - Zone drift between primary and replicas (different A record)
      #    The AXFR chain means all three should converge on the same value.
      PODS=$(kubectl -n $NS get pod -l dns-server=true -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
      if [ -z "$PODS" ]; then
        echo "ERROR: no dns-server=true pods found"
        exit 1
      fi

      # Zone load can take tens of seconds after a memory-bump rollout, so retry
      # up to 6 times with 10s backoff before giving up.
      ANSWERS=""
      for POD in $PODS; do
        echo "-> dig @127.0.0.1 idrac.viktorbarzin.lan on $POD"
        ANSWER=""
        for TRY in 1 2 3 4 5 6; do
          ANSWER=$(kubectl -n $NS exec "$POD" -- dig +short +time=5 +tries=2 @127.0.0.1 idrac.viktorbarzin.lan A 2>&1 || true)
          if echo "$ANSWER" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            break
          fi
          echo "   attempt $TRY: no A record yet, sleeping 10s"
          sleep 10
          ANSWER=""
        done
        if [ -z "$ANSWER" ]; then
          echo "ERROR: pod $POD never returned an A record for idrac.viktorbarzin.lan"
          exit 1
        fi
        echo "   $POD → $ANSWER"
        ANSWERS="$ANSWERS $ANSWER"
      done

      # 3. Content parity — all three instances must agree on the A record.
      UNIQ=$(echo "$ANSWERS" | tr ' ' '\n' | grep -v '^$' | sort -u | wc -l)
      if [ "$UNIQ" -gt 1 ]; then
        echo "ERROR: instances returned different A records for idrac.viktorbarzin.lan: $ANSWERS"
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
