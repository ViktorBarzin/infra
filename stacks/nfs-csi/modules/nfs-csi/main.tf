variable "tier" { type = string }
variable "nfs_server" { type = string }

resource "kubernetes_namespace" "nfs_csi" {
  metadata {
    name = "nfs-csi"
    labels = {
      tier               = var.tier
      "keel.sh/enrolled" = "true"
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
  # Pinned 2026-05-17. Keel polled and rolled csi-driver-nfs 4.13.1 → 4.13.2,
  # which broke the cluster:
  #   * Controller pods ended up on k8s-master because the new chart removed
  #     control-plane exclusion from the default node selector.
  #   * Two controller replicas on the same node fought over hostNetwork ports
  #     19809 (node-driver-registrar) and 29653 (liveness-probe). One replica
  #     CrashLoopBackOff'd with `bind: address already in use`.
  #   * Rolling back live (helm rollback) left zombie containerd containers
  #     holding the ports — only a kubelet restart cleared them.
  # nfs-csi namespace is in the Kyverno keel exclude list (keel-annotations.tf)
  # so Keel will not touch it again. This version pin is the second line of
  # defense against accidental floating-version drift on `terraform apply`.
  version = "4.13.1"

  values = [yamlencode({
    controller = {
      replicas = 2
      # Required to coexist with the v4.13.1 chart on a 1-master + 4-worker
      # cluster:
      #   * podAntiAffinity forces the 2 controller replicas onto DIFFERENT
      #     hosts (host network ports 19809/29653 are per-host).
      #   * nodeAffinity excludes the control-plane node entirely so the
      #     scheduler can't pick master when a worker is briefly NotReady.
      # Without these, Kubernetes can schedule both replicas on the same node
      # (port conflict) or on master itself (which already runs the DaemonSet
      # pod and would conflict with it).
      affinity = {
        nodeAffinity = {
          requiredDuringSchedulingIgnoredDuringExecution = {
            nodeSelectorTerms = [{
              matchExpressions = [{
                key      = "node-role.kubernetes.io/control-plane"
                operator = "DoesNotExist"
              }]
            }]
          }
        }
        podAntiAffinity = {
          requiredDuringSchedulingIgnoredDuringExecution = [{
            labelSelector = {
              matchLabels = {
                app = "csi-nfs-controller"
              }
            }
            topologyKey = "kubernetes.io/hostname"
          }]
        }
      }
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

# Legacy name, now being migrated away from (Viktor, 2026-09-01 — this reverses
# the "not worth the churn" call recorded here previously). The backend is the
# Proxmox host NFS (var.nfs_server = 192.168.1.127); TrueNAS was decommissioned
# 2026-04-13, so this name points at a product that no longer exists here. The
# count has grown from 48 bound PVs to 74, which is the argument for doing it
# now rather than later: the cost only rises.
#
# It is NOT renamed in place. storageClassName is immutable on both PV and PVC,
# so a change recreates the pair, and pvc-protection blocks that until no pod
# mounts the claim — a stack has to be scaled to zero for its own migration.
# So nfs-pve is added ALONGSIDE and stacks move over one at a time by passing
# storage_class_name to modules/kubernetes/nfs_volume. This object stays until
# the last PV referencing it is gone. Note that a bound pair does not consult
# the StorageClass object at all, so nothing breaks while both exist.
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

# The same Proxmox-host export as nfs-truenas above, under a name that says
# what it actually is. New volumes should use this; existing ones migrate
# per stack. Identical parameters and mount options on purpose — this is a
# renaming, not a behaviour change.
resource "kubernetes_storage_class" "nfs_pve" {
  metadata {
    name = "nfs-pve"
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

# The Synology (192.168.1.13), a different machine entirely. Exactly one volume
# lives here today — navidrome-music on /volume1/music — and until 2026-09-01 it
# was labelled nfs-truenas like everything else, because the module hardcoded
# that name regardless of which server the caller passed. That is how a 5.76 TB
# Synology share came to be reported as a 10Gi PVC "91.1% full" by the health
# check. Its free space is watched by OffsiteDestinationFillingUp / AlmostFull,
# not by PVC thresholds.
resource "kubernetes_storage_class" "nfs_synology" {
  metadata {
    name = "nfs-synology"
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
    server = var.synology_nfs_server
    share  = "/volume1"
  }
}

variable "synology_nfs_server" {
  description = "Synology NFS server. Distinct from var.nfs_server (the Proxmox host); only navidrome-music uses it today."
  type        = string
  default     = "192.168.1.13"
}
