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
