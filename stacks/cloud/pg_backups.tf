# Cloud's Postgres backups, exports and restores (the cloud repo's B28b and
# B28c; `cloud pg backups`, `backup`, `export`, `restore`). The reconciler
# runs each as a Job in this namespace (src/reconciler/pg-task-jobs.ts there);
# admission policies cloud-pg-task and cloud-pg-task-secret in access_rules.tf
# admit only those shapes.
#
# The dumps live on the Proxmox host's NFS beside the homelab's, in two
# directories of their own that stacks/dbaas postgresql-backup writes and
# rotates (14 days):
#   /srv/nfs/postgresql-backup/cloud-per-db/<db>/dump_<ts>.dump   nightly
#   /srv/nfs/postgresql-backup/cloud-manual/<db>/manual_<ts>.dump  on demand
# The nightly volume is read-only twice over (ReadOnlyMany and the ro mount
# option), so no Job can change a nightly dump. Only a backup Job mounts the
# manual volume writable. Nothing here mounts /backup/per-db, the homelab's
# own dumps (critique M7).

variable "nfs_server" { type = string }

locals {
  cloud_pg_backup_volumes = {
    nightly = {
      claim  = local.cloud_pg_task.nightly_claim
      path   = "/srv/nfs/postgresql-backup/cloud-per-db"
      modes  = ["ReadOnlyMany"]
      extras = ["ro"]
    }
    manual = {
      claim  = local.cloud_pg_task.manual_claim
      path   = "/srv/nfs/postgresql-backup/cloud-manual"
      modes  = ["ReadWriteMany"]
      extras = []
    }
  }
}

# Static NFS volumes, as modules/kubernetes/nfs_volume makes them, plus the
# read-only access mode and mount option the module has no input for.
resource "kubernetes_persistent_volume" "cloud_pg_backups" {
  for_each = local.cloud_pg_backup_volumes
  metadata {
    name = each.value.claim
  }
  spec {
    capacity = {
      storage = "10Gi"
    }
    access_modes                     = each.value.modes
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "nfs-pve"
    volume_mode                      = "Filesystem"
    mount_options                    = concat(["nfsvers=4.1", "soft", "timeo=30", "retrans=3", "actimeo=5"], each.value.extras)
    persistent_volume_source {
      csi {
        driver        = "nfs.csi.k8s.io"
        volume_handle = each.value.claim
        read_only     = contains(each.value.extras, "ro")
        volume_attributes = {
          server = var.nfs_server
          share  = each.value.path
        }
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "cloud_pg_backups" {
  for_each = local.cloud_pg_backup_volumes
  metadata {
    name      = each.value.claim
    namespace = module.console.namespace
  }
  spec {
    access_modes       = each.value.modes
    storage_class_name = "nfs-pve"
    volume_name        = kubernetes_persistent_volume.cloud_pg_backups[each.key].metadata[0].name
    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }
}

# The reconciler's rights here: local.cloud_reconciler_cloud_rules.
resource "kubernetes_role" "cloud_reconciler_tasks" {
  metadata {
    name      = "cloud-reconciler-tasks"
    namespace = module.console.namespace
  }
  dynamic "rule" {
    for_each = local.cloud_reconciler_cloud_rules
    content {
      api_groups     = rule.value.api_groups
      resources      = rule.value.resources
      verbs          = rule.value.verbs
      resource_names = rule.value.resource_names
    }
  }
}

resource "kubernetes_role_binding" "cloud_reconciler_tasks" {
  metadata {
    name      = "cloud-reconciler-tasks"
    namespace = module.console.namespace
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.cloud_reconciler.metadata[0].name
    namespace = module.console.namespace
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.cloud_reconciler_tasks.metadata[0].name
  }
}

# Task pods take no connection, but for an export's: the console fetches
# the dump from the pod on its export port, with the task's token. They
# reach only DNS and the shared Postgres (dbaas, both CNPG clusters' pods,
# so a switch of the active cluster needs no change here).
resource "kubernetes_network_policy_v1" "cloud_pg_tasks" {
  metadata {
    name      = "cloud-pg-tasks"
    namespace = module.console.namespace
  }
  spec {
    pod_selector {
      match_expressions {
        key      = local.cloud_component_label
        operator = "In"
        values   = [for k in local.cloud_pg_task.kinds : "pg-${k}"]
      }
    }
    policy_types = ["Ingress", "Egress"]
    ingress {
      from {
        pod_selector {
          match_labels = { app = local.cloud_console_name }
        }
      }
      ports {
        port     = tostring(local.cloud_pg_task.export_port)
        protocol = "TCP"
      }
    }
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
          match_labels = { "kubernetes.io/metadata.name" = "dbaas" }
        }
        pod_selector {
          match_labels = { "cnpg.io/podRole" = "instance" }
        }
      }
      ports {
        port     = "5432"
        protocol = "TCP"
      }
    }
  }
}
