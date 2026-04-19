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

      # 2. Per-pod DNS check. Technitium pods have `dig` but no HTTP client,
      #    so we probe the DNS answer directly — if the pod can resolve
      #    idrac.viktorbarzin.lan from its local zone data, the server is
      #    functional.
      PODS=$(kubectl -n $NS get pod -l dns-server=true -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
      if [ -z "$PODS" ]; then
        echo "ERROR: no dns-server=true pods found"
        exit 1
      fi

      # Zone load can take tens of seconds after a memory-bump rollout, so retry
      # up to 6 times with 10s backoff before giving up.
      for POD in $PODS; do
        echo "-> dig @127.0.0.1 idrac.viktorbarzin.lan on $POD"
        OK=0
        for TRY in 1 2 3 4 5 6; do
          ANSWER=$(kubectl -n $NS exec "$POD" -- dig +short +time=5 +tries=2 @127.0.0.1 idrac.viktorbarzin.lan A 2>&1 || true)
          if echo "$ANSWER" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            OK=1; break
          fi
          echo "   attempt $TRY: no A record yet, sleeping 10s"
          sleep 10
        done
        if [ "$OK" -eq 0 ]; then
          echo "ERROR: pod $POD never returned an A record for idrac.viktorbarzin.lan (last: $ANSWER)"
          exit 1
        fi
      done

      # 3. Zone-count parity via an ephemeral curl pod (technitium image has
      #    no HTTP client). Pod auto-deletes on success via --rm.
      JOB_NAME="readiness-probe-$RANDOM"
      CHECK_SCRIPT='
        set -e
        for SVC in technitium-web technitium-secondary-web technitium-tertiary-web; do
          COUNT=$(curl -sf --max-time 10 http://$SVC:5380/api/zones/list?token= | tr "," "\n" | grep -c "\"name\":" || true)
          printf "%s %s\n" "$SVC" "$${COUNT:-0}"
        done
      '
      RESULT=$(kubectl -n $NS run $JOB_NAME --rm -i --restart=Never --quiet \
        --image=curlimages/curl:latest --image-pull-policy=IfNotPresent \
        --timeout=60s -- sh -c "$CHECK_SCRIPT" 2>/dev/null || true)
      echo "$RESULT"

      COUNTS=$(echo "$RESULT" | awk '{print $2}' | grep -E '^[0-9]+$')
      if [ -z "$COUNTS" ]; then
        echo "ERROR: zone-count probe returned no valid counts"
        exit 1
      fi
      # Sanity: Technitium always has built-in zones (localhost, reverse ptrs).
      # All-zeros means the probe failed to reach the API, not a true parity pass.
      MIN=$(echo "$COUNTS" | sort -n | head -1)
      if [ "$MIN" -eq 0 ]; then
        echo "ERROR: zone-count probe returned 0 for at least one instance — probe likely failed to reach API"
        exit 1
      fi
      UNIQ=$(echo "$COUNTS" | sort -u | wc -l)
      if [ "$UNIQ" -gt 1 ]; then
        echo "ERROR: zone counts differ across instances"
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
