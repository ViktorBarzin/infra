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

variable "storage_class_name" {
  description = <<-EOT
    Binding label for the PV/PVC pair. NOT a provisioner: every volume this
    module makes is STATIC, so the class name is only the string Kubernetes
    matches a claim to a volume by, and the StorageClass object is not even
    consulted once a pair is bound.

    DEFAULT MUST STAY nfs-truenas. The name is wrong (TrueNAS was
    decommissioned 2026-04-13; var.nfs_server is the Proxmox host) and it is
    being migrated to nfs-pve one stack at a time (Viktor, 2026-09-01).

    Migration is still incremental, but it recreates LESS than this comment
    used to say. Measured end to end on stacks/ebooks, 2026-09-03:
    storageClassName is immutable on the PVC only. The PV updates IN PLACE —
    all 7 planned as `~ storage_class_name = "nfs-truenas" -> "nfs-pve"` with
    nothing else in the diff, applied in 0s each, and the live PVs kept their
    csi volumeAttributes.share untouched. Only the PVC forces replacement, so
    no data moves and no volume is recreated.

    What does gate it, and is easy to miss:

      - The pvc-protection finalizer holds the PVC Terminating for as long as
        ANY pod mounts it, so the mounting workload has to be scaled to zero.
        The next apply restores its replicas from HCL.
      - Deleting the PVC leaves the PV Released with a stale spec.claimRef, and
        this module pins volume_name on the PVC (below), so the replacement
        claim binds to nothing and terraform waits on wait_until_bound forever.
        Clear it first:
          kubectl patch pv <name> --type=merge -p '{"spec":{"claimRef":null}}'
        which takes the PV Released -> Available.

    Flipping this default would aim that at all 74 volumes at once, and 7 are in
    PLATFORM stacks (dbaas, vault, redis, mailserver, monitoring, headscale,
    vaultwarden) which CI applies on ANY modules/ change. It would try to
    recreate the databases PVCs unattended and hang. Opt in per stack instead,
    by passing storage_class_name = "nfs-pve".
  EOT
  type        = string
  default     = "nfs-truenas"
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
    storage_class_name               = var.storage_class_name
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
    storage_class_name = var.storage_class_name
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
