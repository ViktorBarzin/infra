# Cloud's Bucket Services (the cloud repo's B26): the restore side here.
# Garage itself, its nightly backup and its own NetworkPolicy are in
# stacks/garage (B25). What Cloud's processes get to reach Garage is in
# deploy_rules.tf (env and the admin token file) and reconciler.tf (its
# ExternalSecret); the Project egress floor's Pass to Garage, the restore
# Job's admission policies and the mount guard are in access_rules.tf.
#
# `cloud bucket restore` runs a Job bucket-restore-<9 hex> in this namespace
# (the cloud repo's reconciler, like the Postgres tasks in pg_backups.tf). It
# reads one key from the nightly backup that stacks/garage writes to
#   /srv/nfs/cloud-buckets/current/<bucket>/<key>       last night's mirror
#   /srv/nfs/cloud-buckets/<YYYY-MM-DD>/<bucket>/<key>  what that night's
#                                                       sync overwrote or deleted
# and puts it back into the bucket with the Project's own Garage key. The
# volume is read-only twice over (ReadOnlyMany and the ro mount option), and
# admission policy cloud-bucket-backups-mount lets no pod but a restore pod
# mount it.

locals {
  cloud_bucket_backups_storage = "100Gi"
}

# A static NFS volume, as pg_backups.tf makes its nightly one. The claimRef
# binds it to cloud/cloud-bucket-backups alone, so no claim elsewhere can
# take it.
resource "kubernetes_persistent_volume" "cloud_bucket_backups" {
  metadata {
    name = local.cloud_bucket_task.claim
  }
  spec {
    capacity = {
      storage = local.cloud_bucket_backups_storage
    }
    access_modes                     = ["ReadOnlyMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "nfs-pve"
    volume_mode                      = "Filesystem"
    mount_options                    = ["nfsvers=4.1", "soft", "timeo=30", "retrans=3", "actimeo=5", "ro"]
    claim_ref {
      name      = local.cloud_bucket_task.claim
      namespace = module.console.namespace
    }
    persistent_volume_source {
      csi {
        driver        = "nfs.csi.k8s.io"
        volume_handle = local.cloud_bucket_task.claim
        read_only     = true
        volume_attributes = {
          server = var.nfs_server
          share  = local.cloud_bucket_task.nfs_path
        }
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "cloud_bucket_backups" {
  metadata {
    name      = local.cloud_bucket_task.claim
    namespace = module.console.namespace
  }
  spec {
    access_modes       = ["ReadOnlyMany"]
    storage_class_name = "nfs-pve"
    volume_name        = kubernetes_persistent_volume.cloud_bucket_backups.metadata[0].name
    resources {
      requests = {
        storage = local.cloud_bucket_backups_storage
      }
    }
  }
}

# A restore pod takes no connection. It reaches DNS and Garage's S3 port,
# nothing else: not the admin API, not the internet, not another pod.
resource "kubernetes_network_policy_v1" "cloud_bucket_tasks" {
  metadata {
    name      = "cloud-bucket-tasks"
    namespace = module.console.namespace
  }
  spec {
    pod_selector {
      match_labels = { (local.cloud_component_label) = local.cloud_bucket_task.component }
    }
    policy_types = ["Ingress", "Egress"]
    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
        pod_selector {
          match_labels = { "k8s-app" = "kube-dns" }
        }
      }
      to {
        ip_block {
          cidr = "10.96.0.10/32"
        }
      }
      ports {
        port     = "53"
        protocol = "UDP"
      }
      ports {
        port     = "53"
        protocol = "TCP"
      }
    }
    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = local.cloud_garage.namespace }
        }
        pod_selector {
          match_labels = { (local.cloud_garage.pod_label.key) = local.cloud_garage.pod_label.value }
        }
      }
      ports {
        port     = tostring(local.cloud_garage.s3_port)
        protocol = "TCP"
      }
    }
  }
}
