variable "tier" { type = string }
variable "nfs_server" { type = string }

resource "kubernetes_namespace" "nfs_csi" {
  metadata {
    name = "nfs-csi"
    labels = {
      tier = var.tier
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "helm_release" "nfs_csi_driver" {
  namespace        = kubernetes_namespace.nfs_csi.metadata[0].name
  create_namespace = false
  name             = "csi-driver-nfs"
  atomic           = true
  timeout          = 300

  repository = "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts"
  chart      = "csi-driver-nfs"

  values = [yamlencode({
    controller = {
      replicas = 2
      livenessProbe = {
        httpPort = 29653
      }
      resources = {
        csiProvisioner = {
          requests = { cpu = "10m", memory = "128Mi" }
          limits   = { memory = "128Mi" }
        }
        csiResizer = {
          requests = { cpu = "10m", memory = "128Mi" }
          limits   = { memory = "128Mi" }
        }
        csiSnapshotter = {
          requests = { cpu = "10m", memory = "128Mi" }
          limits   = { memory = "128Mi" }
        }
        nfs = {
          requests = { cpu = "10m", memory = "128Mi" }
          limits   = { memory = "128Mi" }
        }
        livenessProbe = {
          requests = { cpu = "10m", memory = "64Mi" }
          limits   = { memory = "64Mi" }
        }
      }
    }
    node = {
      resources = {
        nfs = {
          requests = { cpu = "10m", memory = "128Mi" }
          limits   = { memory = "128Mi" }
        }
        livenessProbe = {
          requests = { cpu = "10m", memory = "64Mi" }
          limits   = { memory = "64Mi" }
        }
        nodeDriverRegistrar = {
          requests = { cpu = "10m", memory = "64Mi" }
          limits   = { memory = "64Mi" }
        }
      }
    }
    storageClass = {
      create = false
    }
  })]
}

# Historical name retained for PV compatibility — 48 bound PVs reference
# storageClassName: nfs-truenas. The actual backend is the Proxmox host NFS
# (var.nfs_server = 192.168.1.127) since TrueNAS was decommissioned
# 2026-04-13. SC names are immutable on PVs, so renaming would require
# migrating every PV. Not worth the churn for a cosmetic change.
resource "kubernetes_storage_class" "nfs_truenas" {
  metadata {
    name = "nfs-truenas"
  }
  storage_provisioner = "nfs.csi.k8s.io"
  reclaim_policy      = "Retain"
  volume_binding_mode = "Immediate"

  mount_options = [
    "nfsvers=4",
    "soft",
    "timeo=30",
    "retrans=3",
    "actimeo=5",
  ]

  parameters = {
    server = var.nfs_server
    share  = "/srv/nfs"
  }
}
