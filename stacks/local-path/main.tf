# local-path-provisioner
#
# Rancher's local-path provisioner — backs PVCs with node-local
# /opt/local-path-provisioner directories. Currently serves as the default
# StorageClass. Deployed via raw kubectl apply 55d ago; adopted into TF
# (Wave 5c) on 2026-04-18.
#
# Upstream: https://github.com/rancher/local-path-provisioner
# Version pinned to rancher/local-path-provisioner:v0.0.31

resource "kubernetes_namespace" "local_path_storage" {
  metadata {
    name = "local-path-storage"
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_service_account" "local_path_provisioner" {
  metadata {
    name      = "local-path-provisioner-service-account"
    namespace = kubernetes_namespace.local_path_storage.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_cluster_role" "local_path_provisioner" {
  metadata {
    name = "local-path-provisioner-role"
  }
  rule {
    api_groups = [""]
    resources  = ["nodes", "persistentvolumeclaims", "configmaps", "pods", "pods/log"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = [""]
    resources  = ["persistentvolumes"]
    verbs      = ["get", "list", "watch", "create", "patch", "update", "delete"]
  }
  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["create", "patch"]
  }
  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["storageclasses"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "local_path_provisioner" {
  metadata {
    name = "local-path-provisioner-bind"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.local_path_provisioner.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.local_path_provisioner.metadata[0].name
    namespace = kubernetes_namespace.local_path_storage.metadata[0].name
  }
}

resource "kubernetes_config_map" "local_path_config" {
  metadata {
    name      = "local-path-config"
    namespace = kubernetes_namespace.local_path_storage.metadata[0].name
  }
  data = {
    "config.json" = jsonencode({
      nodePathMap = [{
        node  = "DEFAULT_PATH_FOR_NON_LISTED_NODES"
        paths = ["/opt/local-path-provisioner"]
      }]
    })
    "helperPod.yaml" = <<-EOT
      apiVersion: v1
      kind: Pod
      metadata:
        name: helper-pod
      spec:
        priorityClassName: system-node-critical
        tolerations:
          - key: node.kubernetes.io/disk-pressure
            operator: Exists
            effect: NoSchedule
        containers:
        - name: helper-pod
          image: busybox
          imagePullPolicy: IfNotPresent
    EOT
    "setup"          = <<-EOT
      #!/bin/sh
      set -eu
      mkdir -m 0777 -p "$VOL_DIR"
    EOT
    "teardown"       = <<-EOT
      #!/bin/sh
      set -eu
      rm -rf "$VOL_DIR"
    EOT
  }
}

resource "kubernetes_storage_class_v1" "local_path" {
  metadata {
    name = "local-path"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }
  storage_provisioner    = "rancher.io/local-path"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = false
}

resource "kubernetes_deployment" "local_path_provisioner" {
  metadata {
    name      = "local-path-provisioner"
    namespace = kubernetes_namespace.local_path_storage.metadata[0].name
    labels = {
      tier = "default"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "local-path-provisioner"
      }
    }
    template {
      metadata {
        labels = {
          app = "local-path-provisioner"
        }
      }
      spec {
        service_account_name            = kubernetes_service_account.local_path_provisioner.metadata[0].name
        automount_service_account_token = false
        enable_service_links            = false
        container {
          name              = "local-path-provisioner"
          image             = "rancher/local-path-provisioner:v0.0.31"
          image_pull_policy = "IfNotPresent"
          command = [
            "local-path-provisioner",
            "--debug",
            "start",
            "--config",
            "/etc/config/config.json",
          ]
          env {
            name = "POD_NAMESPACE"
            value_from {
              field_ref {
                field_path = "metadata.namespace"
              }
            }
          }
          env {
            name  = "CONFIG_MOUNT_PATH"
            value = "/etc/config/"
          }
          volume_mount {
            name       = "config-volume"
            mount_path = "/etc/config/"
          }
        }
        volume {
          name = "config-volume"
          config_map {
            name = kubernetes_config_map.local_path_config.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}







