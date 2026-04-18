resource "kubernetes_namespace" "proxmox_csi" {
  metadata {
    name = "proxmox-csi"
    labels = {
      tier                               = var.tier
      "resource-governance/custom-quota" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "helm_release" "proxmox_csi" {
  namespace        = kubernetes_namespace.proxmox_csi.metadata[0].name
  create_namespace = false
  name             = "proxmox-csi-plugin"
  atomic           = true
  timeout          = 300

  repository = "oci://ghcr.io/sergelogvinov/charts"
  chart      = "proxmox-csi-plugin"

  values = [yamlencode({
    config = {
      clusters = [{
        url          = var.proxmox_url
        insecure     = true
        token_id     = var.proxmox_token_id
        token_secret = var.proxmox_token_secret
        region       = var.proxmox_cluster_name
      }]
    }

    # StorageClass for block volumes on existing HDD thin pool
    storageClass = [
      {
        name                 = "proxmox-lvm"
        storage              = "local-lvm"
        reclaimPolicy        = "Retain"
        fstype               = "ext4"
        ssd                  = false
        cache                = "none"
        volumeBindingMode    = "WaitForFirstConsumer"
        allowVolumeExpansion = true
      },
      {
        name                 = "proxmox-lvm-encrypted"
        storage              = "local-lvm"
        reclaimPolicy        = "Retain"
        fstype               = "ext4"
        ssd                  = false
        cache                = "none"
        volumeBindingMode    = "WaitForFirstConsumer"
        allowVolumeExpansion = true
        extraParameters = {
          "csi.storage.k8s.io/node-stage-secret-name"       = "proxmox-csi-encryption"
          "csi.storage.k8s.io/node-stage-secret-namespace"  = "kube-system"
          "csi.storage.k8s.io/node-expand-secret-name"      = "proxmox-csi-encryption"
          "csi.storage.k8s.io/node-expand-secret-namespace" = "kube-system"
        }
      },
    ]

    controller = {
      replicas = 2
      resources = {
        requests = { cpu = "10m", memory = "32Mi" }
        limits   = { memory = "64Mi" }
      }
    }

    # LUKS2 Argon2id key derivation needs ~1GiB memory
    node = {
      plugin = {
        resources = {
          requests = { cpu = "10m", memory = "64Mi" }
          limits   = { memory = "1280Mi" }
        }
      }
    }
  })]
}

# Topology labels on K8s nodes — required for Proxmox CSI to map nodes to Proxmox VMs.
# region = Proxmox cluster name, zone = Proxmox node name (where the VM runs).
# All our VMs run on the single Proxmox node "pve".
locals {
  k8s_nodes = {
    "k8s-master" = { vmid = 200, proxmox_node = "pve" }
    "k8s-node1"  = { vmid = 201, proxmox_node = "pve" }
    "k8s-node2"  = { vmid = 202, proxmox_node = "pve" }
    "k8s-node3"  = { vmid = 203, proxmox_node = "pve" }
    "k8s-node4"  = { vmid = 204, proxmox_node = "pve" }
  }
}

resource "null_resource" "node_labels" {
  for_each = local.k8s_nodes

  provisioner "local-exec" {
    command = <<-EOT
      kubectl --kubeconfig=${var.kube_config_path} label node ${each.key} \
        topology.kubernetes.io/region=${var.proxmox_cluster_name} \
        topology.kubernetes.io/zone=${each.value.proxmox_node} \
        node.csi.proxmox.sinextra.dev/name=${each.key} \
        --overwrite
    EOT
  }

  triggers = {
    region = var.proxmox_cluster_name
    zone   = each.value.proxmox_node
  }
}

# --- RBAC for PVE host snapshot restore script ---
# Provides kubectl access from the Proxmox host for the lvm-pvc-snapshot restore subcommand.
# Minimal permissions: read PVs/PVCs/Pods, scale Deployments/StatefulSets.

resource "kubernetes_service_account" "pve_snapshot_admin" {
  metadata {
    name      = "pve-snapshot-admin"
    namespace = "kube-system"
  }
}

resource "kubernetes_secret" "pve_snapshot_admin_token" {
  metadata {
    name      = "pve-snapshot-admin-token"
    namespace = "kube-system"
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account.pve_snapshot_admin.metadata[0].name
    }
  }
  type = "kubernetes.io/service-account-token"
}

resource "kubernetes_cluster_role" "pve_snapshot_admin" {
  metadata {
    name = "pve-snapshot-admin"
  }

  rule {
    api_groups = [""]
    resources  = ["persistentvolumes", "persistentvolumeclaims", "pods"]
    verbs      = ["get", "list"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "statefulsets", "replicasets"]
    verbs      = ["get", "list", "update", "patch"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments/scale", "statefulsets/scale"]
    verbs      = ["get", "update", "patch"]
  }
}

resource "kubernetes_cluster_role_binding" "pve_snapshot_admin" {
  metadata {
    name = "pve-snapshot-admin"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.pve_snapshot_admin.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.pve_snapshot_admin.metadata[0].name
    namespace = "kube-system"
  }
}

# --- ExternalSecret for LUKS encryption passphrase ---
# Creates K8s Secret "proxmox-csi-encryption" in kube-system from Vault KV.
# Referenced by the proxmox-lvm-encrypted StorageClass for node-stage and node-expand.
resource "kubernetes_manifest" "external_secret_encryption" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "proxmox-csi-encryption"
      namespace = "kube-system"
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        kind = "ClusterSecretStore"
        name = "vault-kv"
      }
      target = {
        name           = "proxmox-csi-encryption"
        creationPolicy = "Owner"
        deletionPolicy = "Retain"
      }
      data = [{
        secretKey = "encryption-passphrase"
        remoteRef = {
          key      = "viktor"
          property = "proxmox_csi_encryption_passphrase"
        }
      }]
    }
  }
}
