variable "name" {
  description = "Unique name for PV and PVC (convention: <service>-<purpose>)"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace for the PVC"
  type        = string
}

variable "nfs_server" {
  description = "NFS server address"
  type        = string
}

variable "nfs_path" {
  description = "NFS export path (e.g. /mnt/main/myservice)"
  type        = string
}

variable "storage" {
  description = "Storage capacity (informational for NFS)"
  type        = string
  default     = "10Gi"
}

variable "access_modes" {
  description = "PV/PVC access modes"
  type        = list(string)
  default     = ["ReadWriteMany"]
}

resource "kubernetes_persistent_volume" "this" {
  metadata {
    name = var.name
  }
  spec {
    capacity = {
      storage = var.storage
    }
    access_modes                     = var.access_modes
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "nfs-truenas"
    volume_mode                      = "Filesystem"

    mount_options = [
      "nfsvers=4",
      "soft",
      "timeo=30",
      "retrans=3",
      "actimeo=5",
    ]

    persistent_volume_source {
      csi {
        driver        = "nfs.csi.k8s.io"
        volume_handle = var.name
        volume_attributes = {
          server = var.nfs_server
          share  = var.nfs_path
        }
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
  }
  spec {
    access_modes       = var.access_modes
    storage_class_name = "nfs-truenas"
    volume_name        = kubernetes_persistent_volume.this.metadata[0].name

    resources {
      requests = {
        storage = var.storage
      }
    }
  }
}

output "claim_name" {
  description = "PVC name to use in pod spec persistent_volume_claim blocks"
  value       = kubernetes_persistent_volume_claim.this.metadata[0].name
}
