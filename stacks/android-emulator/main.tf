# Android emulator — shared in-cluster Android 16 (API 36) testing instance.
# Agents drive it over adb (10.0.20.200:5555); humans watch the screen at
# https://android-emulator.viktorbarzin.lan (noVNC). The SDK + system image +
# AVD live on the PVC; the container image is just JDK + cmdline-tools + libs
# (built manually from docker/, see README.md).
#
# Decision record: docs/adr/0001-android-emulator-in-cluster.md
# - privileged + /dev/kvm hostPath (namespace is on the Kyverno exclude list)
# - swiftshader rendering — deliberately NOT on the contended T4 GPU node

resource "kubernetes_namespace" "android-emulator" {
  metadata {
    name = "android-emulator"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.cluster
    }
  }
  lifecycle {
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.android-emulator.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# SDK + system image + AVD + snapshots. First boot downloads ~2.5GB (≈9GB
# unpacked) into here;
# subsequent pod restarts reuse it (boot in ~1 min instead of ~15).
# DELIBERATE deviation from the proxmox-lvm backup convention: no backup
# CronJob — everything on this PVC is a regenerable download/cache (wipe the
# PVC and the next boot rebuilds it; that's also the documented recovery path).
resource "kubernetes_persistent_volume_claim" "sdk" {
  wait_until_bound = false
  metadata {
    name      = "android-emulator-sdk"
    namespace = kubernetes_namespace.android-emulator.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "50%"
      "resize.topolvm.io/storage_limit" = "60Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = {
        storage = "30Gi"
      }
    }
  }
  lifecycle {
    # Autoresizer grows requests.storage up to storage_limit; PVCs can't shrink.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

resource "kubernetes_deployment" "android-emulator" {
  metadata {
    name      = "android-emulator"
    namespace = kubernetes_namespace.android-emulator.metadata[0].name
    labels = {
      app = "android-emulator"
    }
  }
  spec {
    # Scaled to 0 (2026-06-12): the emulator's ~4.7-core swiftshader CPU burn
    # on node3 saturated the single PVE host and starved etcd on the k8s-master
    # VM → control-plane (scheduler/controller-manager/kyverno) leader-election
    # crashloop. It is a shared TEST instance, not a 24/7 service: spin up
    # on-demand (replicas = 1) for a testing session, return to 0 when done.
    # Durable relief pending the structural etcd-protection fix (PVE CPU weight
    # / etcd WAL on SSD).
    replicas = 0
    strategy {
      type = "Recreate" # RWO PVC — old pod must release it first
    }
    selector {
      match_labels = { app = "android-emulator" }
    }
    template {
      metadata {
        labels = { app = "android-emulator" }
      }
      spec {
        node_selector = {
          "nvidia.com/gpu.present" : "true"
        }
        toleration {
          key      = "nvidia.com/gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }
        image_pull_secrets {
          name = "registry-credentials"
        }
        container {
          name  = "emulator"
          image = "ghcr.io/viktorbarzin/android-emulator:${var.image_tag}"

          security_context {
            privileged = true # /dev/kvm access
          }

          env {
            # The GPU operator injects only compute,utility by default — the
            # NVIDIA EGL/GL libraries need the graphics capability, otherwise
            # the emulator's -gpu host silently falls back to Mesa llvmpipe
            # (software GL) inside the container.
            name  = "NVIDIA_DRIVER_CAPABILITIES"
            value = "all"
          }

          port {
            name           = "adb"
            container_port = 5555
          }
          port {
            name           = "novnc"
            container_port = 6080
          }

          volume_mount {
            name       = "sdk"
            mount_path = "/sdk"
          }
          volume_mount {
            name       = "kvm"
            mount_path = "/dev/kvm"
          }

          resources {
            # No CPU limit (cluster-wide rule — CFS throttling). Burstable on
            # memory: the tier-1 quota caps requests.memory at 4Gi per
            # namespace, so requests stay under it while the limit gives the
            # emulator (qemu -memory 4096 + guest overhead + Xvfb/VNC + JVM
            # sdkmanager on first boot) room to peak — same Burstable pattern
            # tiers 3/4 use deliberately.
            requests = {
              cpu    = "2"
              memory = "3Gi"
            }
            limits = {
              memory           = "8Gi"
              "nvidia.com/gpu" = "1" # T4 time-slice; ~0.5-1GiB VRAM while awake
            }
          }

          # First boot downloads the system image + cold-boots Android: allow
          # up to ~30 min before the pod is declared failed.
          startup_probe {
            exec {
              command = ["/bin/bash", "-c", "/sdk/platform-tools/adb shell getprop sys.boot_completed | grep -q 1"]
            }
            period_seconds    = 20
            failure_threshold = 90
          }
          readiness_probe {
            exec {
              command = ["/bin/bash", "-c", "/sdk/platform-tools/adb shell getprop sys.boot_completed | grep -q 1"]
            }
            period_seconds    = 30
            failure_threshold = 3
          }
          liveness_probe {
            exec {
              command = ["/bin/bash", "-c", "/sdk/platform-tools/adb shell getprop sys.boot_completed | grep -q 1"]
            }
            period_seconds    = 60
            failure_threshold = 10 # generous — don't reboot mid-test on a hiccup
          }
        }

        volume {
          name = "sdk"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.sdk.metadata[0].name
          }
        }
        volume {
          name = "kvm"
          host_path {
            path = "/dev/kvm"
            type = "CharDevice"
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      # the wake gate + idle sleeper own replicas (scale-to-zero on demand);
      # an apply must not resurrect or kill the emulator.
      spec[0].replicas,
    ]
  }
}

# adb endpoint for agents/devvms: `adb connect 10.0.20.200:5555`.
# Unauthenticated by nature — LAN-only via MetalLB, never exposed publicly.
resource "kubernetes_service" "adb" {
  metadata {
    name      = "android-emulator-adb"
    namespace = kubernetes_namespace.android-emulator.metadata[0].name
    annotations = {
      "metallb.universe.tf/loadBalancerIPs" = "10.0.20.200"
      "metallb.io/allow-shared-ip"          = "shared"
    }
  }
  spec {
    type = "LoadBalancer"
    selector = {
      app = "android-emulator"
    }
    port {
      name        = "adb"
      port        = 5555
      target_port = 5555
    }
  }
}

resource "kubernetes_service" "novnc" {
  metadata {
    name      = "android-emulator"
    namespace = kubernetes_namespace.android-emulator.metadata[0].name
    labels = {
      app = "android-emulator"
    }
  }
  spec {
    selector = {
      app = "android-emulator"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 6080
    }
  }
}

# Ingress layout, same on both hostnames: the wake gate owns `/` (visiting
# wakes a sleeping emulator), while the noVNC asset/socket paths go straight
# to the emulator service. LAN (.lan) is unauthenticated local-only for
# agents; public (.me) is Authentik-gated for humans.
locals {
  novnc_paths = [
    "/vnc.html", "/app", "/core", "/vendor",
    "/websockify", "/package.json", "/defaults.json", "/mandatory.json",
  ]
}

module "ingress-internal-gate" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": LAN-only (allow_local_access_only) wake gate + screen for
  # the shared test emulator — no user data behind it; agents need cookie-free
  # curl access and Authentik would break the noVNC websocket flow.
  auth                    = "none"
  namespace               = kubernetes_namespace.android-emulator.metadata[0].name
  name                    = "android-emulator"
  root_domain             = "viktorbarzin.lan"
  service_name            = kubernetes_service.gate.metadata[0].name
  tls_secret_name         = var.tls_secret_name
  allow_local_access_only = true
  ssl_redirect            = false
  extra_annotations = {
    "gethomepage.dev/enabled" = "false"
  }
}

module "ingress-internal-novnc" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": LAN-only noVNC paths (see ingress-internal-gate above).
  auth                    = "none"
  namespace               = kubernetes_namespace.android-emulator.metadata[0].name
  name                    = "android-emulator-novnc"
  host                    = "android-emulator"
  root_domain             = "viktorbarzin.lan"
  service_name            = kubernetes_service.novnc.metadata[0].name
  ingress_path            = local.novnc_paths
  tls_secret_name         = var.tls_secret_name
  allow_local_access_only = true
  ssl_redirect            = false
  # noVNC loads ~60 unbundled ES modules in parallel; the default 10/50
  # limiter 429s the tail and the loader hangs forever.
  skip_default_rate_limit = true
  extra_middlewares       = ["traefik-android-emulator-rate-limit@kubernetescrd"]
  extra_annotations = {
    "gethomepage.dev/enabled" = "false"
  }
}

# Remote (off-LAN) access — Authentik-gated at the edge; WebSockets work
# through forward-auth same-origin (proven by stacks/terminal's ttyd).
# adb (5555) deliberately stays LAN-only: it is unauthenticated.
module "ingress-public-gate" {
  source          = "../../modules/kubernetes/ingress_factory"
  auth            = "required"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.android-emulator.metadata[0].name
  name            = "android-emulator-public"
  host            = "android-emulator"
  service_name    = kubernetes_service.gate.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

module "ingress-public-novnc" {
  source          = "../../modules/kubernetes/ingress_factory"
  auth            = "required"
  namespace       = kubernetes_namespace.android-emulator.metadata[0].name
  name            = "android-emulator-public-novnc"
  host            = "android-emulator"
  service_name    = kubernetes_service.novnc.metadata[0].name
  ingress_path    = local.novnc_paths
  tls_secret_name = var.tls_secret_name
  # see ingress-internal-novnc — noVNC's parallel module storm needs the
  # dedicated limiter.
  skip_default_rate_limit = true
  extra_middlewares       = ["traefik-android-emulator-rate-limit@kubernetescrd"]
}
