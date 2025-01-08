resource "kubernetes_namespace" "descheduler" {
  metadata {
    name = "descheduler"
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
    namespace = "descheduler"
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
    namespace = "descheduler"
  }
}

resource "helm_release" "prometheus" {
  namespace = "descheduler"
  name      = "descheduler"

  repository = "https://kubernetes-sigs.github.io/descheduler/"
  chart      = "descheduler"



  values = [templatefile("${path.module}/values.yaml", {})]
}
