# =============================================================================
# CoreDNS — Scaling, Anti-Affinity, PDB
# =============================================================================
#
# CoreDNS is kube-system / kubeadm-managed. We only patch replicas + affinity
# here (the Corefile ConfigMap is in main.tf). The hashicorp/kubernetes v3
# provider removed the *_patch resource family from v2, so we apply the
# desired state via `kubectl patch` inside a null_resource. The patch is
# idempotent — a no-op when the deployment already matches.
#
# Kubeadm upgrades preserve the replica count on the existing deployment but
# reset the pod template (including affinity) from the ClusterConfiguration.
# Re-running `terraform apply` re-asserts the affinity patch; the readiness
# gate in `readiness.tf` catches regressions if the patch is reverted.

resource "null_resource" "coredns_scale_and_affinity" {
  triggers = {
    replicas  = 3
    spec_hash = sha256(file("${path.module}/coredns.tf"))
  }

  provisioner "local-exec" {
    command     = <<-BASH
      set -euo pipefail
      # 1. Scale to 3 replicas.
      kubectl -n kube-system scale deploy/coredns --replicas=3

      # 2. Switch anti-affinity from preferred → required on hostname.
      kubectl -n kube-system patch deploy/coredns --type=json -p='[
        {
          "op": "replace",
          "path": "/spec/template/spec/affinity/podAntiAffinity",
          "value": {
            "requiredDuringSchedulingIgnoredDuringExecution": [
              {
                "labelSelector": {
                  "matchExpressions": [
                    {"key": "k8s-app", "operator": "In", "values": ["kube-dns"]}
                  ]
                },
                "topologyKey": "kubernetes.io/hostname"
              }
            ]
          }
        }
      ]' || true

      # 3. Wait for rollout to settle.
      kubectl -n kube-system rollout status deploy/coredns --timeout=120s
    BASH
    interpreter = ["/bin/bash", "-c"]
  }
}

# PDB — keep at least 2 CoreDNS pods running during voluntary disruptions.
resource "kubernetes_pod_disruption_budget_v1" "coredns" {
  metadata {
    name      = "coredns"
    namespace = "kube-system"
  }
  spec {
    min_available = "2"
    selector {
      match_labels = {
        "k8s-app" = "kube-dns"
      }
    }
  }
}
