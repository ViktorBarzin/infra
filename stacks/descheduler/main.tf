

resource "kubernetes_namespace" "descheduler" {
  metadata {
    name = "descheduler"
    labels = {
      tier = local.tiers.cluster
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_cluster_role" "descheduler" {
  metadata {
    name = "descheduler-cluster-role"
  }
  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["create", "update"]
  }
  rule {
    api_groups = ["metrics.k8s.io"]
    resources  = ["nodes"]
    verbs      = ["get", "watch", "list"]
  }
  rule {
    api_groups = [""]
    resources  = ["namespaces"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["metrics.k8s.io"]
    resources  = ["pods"]
    verbs      = ["get", "watch", "list", "delete"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods/eviction"]
    verbs      = ["create"]
  }
  rule {
    api_groups = [""]
    resources  = ["scheduling.k8s.io"]
    verbs      = ["get", "watch", "list"]
  }
  rule {
    api_groups = ["scheduling.k8s.io"]
    resources  = ["priorityclasses"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["policy"]
    resources  = ["poddisruptionbudgets"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_service_account" "descheduler" {
  metadata {
    name      = "descheduler-sa"
    namespace = kubernetes_namespace.descheduler.metadata[0].name
  }
}

resource "kubernetes_cluster_role_binding" "descheduler" {
  metadata {
    name = "descheduler-cluster-role-binding"

  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "descheduler-cluster-role"
  }
  subject {
    name      = "descheduler-sa"
    kind      = "ServiceAccount"
    namespace = kubernetes_namespace.descheduler.metadata[0].name
  }
}

resource "helm_release" "descheduler" { # rename me
  namespace = kubernetes_namespace.descheduler.metadata[0].name
  name      = "descheduler"

  repository = "https://kubernetes-sigs.github.io/descheduler/"
  chart      = "descheduler"



  values = [templatefile("${path.module}/values.yaml", {})]
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00

# CI retrigger v3 2026-05-16T14:06:39Z

# CI retrigger v4 2026-05-16T14:13:59Z

# CI retrigger v5 2026-05-16T23:10:38Z

# CI retrigger v6 2026-05-16T23:18:58Z
