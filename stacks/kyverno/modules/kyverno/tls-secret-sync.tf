
# =============================================================================
# TLS Certificate — Auto-sync to all namespaces
# =============================================================================
# Source wildcard cert (*.viktorbarzin.me) in kyverno namespace, cloned by
# ClusterPolicy into every NS. Renewal pipeline updates this source secret,
# Kyverno propagates to all namespaces within seconds.

resource "kubernetes_secret" "tls_secret" {
  metadata {
    name      = "tls-secret"
    namespace = kubernetes_namespace.kyverno.metadata[0].name
  }
  type = "kubernetes.io/tls"
  data = {
    "tls.crt" = file("${path.root}/secrets/fullchain.pem")
    "tls.key" = file("${path.root}/secrets/privkey.pem")
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: the sync-tls-secret policy stamps
    # generate.kyverno.io/clone-source onto its own source Secret (with a null
    # value), so Terraform planned to strip it on every run and this stack never
    # went clean. Same treatment the shared setup_tls_secret module already
    # applies downstream. Added 2026-08-14.
    ignore_changes = [metadata[0].labels]
  }
}

resource "kubectl_manifest" "sync_tls_secret" {
  yaml_body = templatefile("${path.module}/policies/generate-clone-secret.yaml", { name = "sync-tls-secret", secret = "tls-secret", condition = local.generate_skip_system_namespaces })

  # Kind changed from the kyverno.io ClusterPolicy types: create the CEL
  # policy before deleting the old one, so admission is never uncovered.
  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    helm_release.kyverno,
    kubernetes_secret.tls_secret,
    kubernetes_cluster_role_binding.kyverno_admission_secret_manager,
    kubernetes_cluster_role_binding.kyverno_background_secret_manager,
  ]
}
