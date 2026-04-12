variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }

resource "kubernetes_namespace" "diun" {
  metadata {
    name = "diun"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "diun-secrets"
      namespace = "diun"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "diun-secrets"
      }
      dataFrom = [{
        extract = {
          key = "diun"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.diun]
}

resource "kubernetes_manifest" "external_secret_git" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "diun-git-secrets"
      namespace = "diun"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "diun-git-secrets"
      }
      data = [
        {
          secretKey = "git_token"
          remoteRef = {
            key      = "viktor"
            property = "webhook_handler_git_token"
          }
        },
        {
          secretKey = "git_user"
          remoteRef = {
            key      = "viktor"
            property = "webhook_handler_git_user"
          }
        }
      ]
    }
  }
  depends_on = [kubernetes_namespace.diun]
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.diun.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_service_account" "diun" {
  metadata {
    name      = "diun"
    namespace = kubernetes_namespace.diun.metadata[0].name
  }
}

resource "kubernetes_cluster_role" "diun" {
  metadata {
    name = "diun"
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "watch", "list"]
  }
}
resource "kubernetes_cluster_role_binding" "diun" {
  metadata {
    name = "diun"

  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "diun"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "diun"
    namespace = kubernetes_namespace.diun.metadata[0].name
  }
}

resource "kubernetes_persistent_volume_claim" "repo" {
  wait_until_bound = false
  metadata {
    name      = "diun-repo"
    namespace = kubernetes_namespace.diun.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "diun-data-proxmox"
    namespace = kubernetes_namespace.diun.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}

resource "kubernetes_config_map_v1" "auto_update_script" {
  metadata {
    name      = "diun-auto-update-script"
    namespace = kubernetes_namespace.diun.metadata[0].name
  }
  data = {
    "auto-update.sh" = <<-SCRIPT
      #!/bin/sh
      set -e

      # Only act on updates (not new or unchanged)
      [ "$$DIUN_ENTRY_STATUS" = "update" ] || exit 0

      IMAGE="$$DIUN_ENTRY_IMAGE"
      NEW_TAG="$$DIUN_ENTRY_IMAGETAG"

      echo "[auto-update] Detected update: $$IMAGE -> $$NEW_TAG"

      # Skip databases
      case "$$IMAGE" in
        *postgres*|*mysql*|*redis*|*clickhouse*|*etcd*) echo "[auto-update] Skipping database image"; exit 0 ;;
      esac

      # Skip custom images (handled by CI/CD)
      case "$$IMAGE" in
        viktorbarzin/*|registry.viktorbarzin.me/*|ancamilea/*|mghee/*) echo "[auto-update] Skipping CI/CD-managed image"; exit 0 ;;
      esac

      # Skip kube-system / infrastructure images
      case "$$IMAGE" in
        registry.k8s.io/*|quay.io/tigera/*|quay.io/metallb/*|nvcr.io/*|reg.kyverno.io/*) echo "[auto-update] Skipping infrastructure image"; exit 0 ;;
      esac

      # Acquire lock (serialize concurrent DIUN notifications)
      exec 200>/tmp/auto-update.lock
      flock -n 200 || { echo "[auto-update] Another update in progress, skipping"; exit 0; }

      cd /repo

      # Configure git
      git config user.email "diun@viktorbarzin.me"
      git config user.name "DIUN Auto-Update"

      # Pull latest using HTTPS with token
      git remote set-url origin "https://$${GIT_USER}:$${GIT_TOKEN}@github.com/ViktorBarzin/infra.git"
      git pull --rebase origin master || { echo "[auto-update] git pull failed"; exit 1; }

      # Find .tf files containing this image
      MATCHES=$$(grep -rl "\"$${IMAGE}:" stacks/ --include="*.tf" 2>/dev/null || true)
      [ -z "$$MATCHES" ] && { echo "[auto-update] No .tf file found for $$IMAGE"; exit 0; }

      # Update the image tag in each matching file
      UPDATED=0
      for FILE in $$MATCHES; do
        if sed -i "s|\"$${IMAGE}:[^\"]*\"|\"$${IMAGE}:$${NEW_TAG}\"|g" "$$FILE"; then
          echo "[auto-update] Updated $$FILE"
          UPDATED=1
        fi
      done

      # Check if anything actually changed
      if git diff --quiet; then
        echo "[auto-update] No changes after update for $$IMAGE:$$NEW_TAG (already up to date)"
        exit 0
      fi

      # Commit and push
      git add -A stacks/
      git commit -m "auto-update: $${IMAGE} -> $${NEW_TAG}"
      git push origin master
      echo "[auto-update] Pushed update: $${IMAGE}:$${NEW_TAG}"
    SCRIPT
  }
}

resource "kubernetes_deployment" "diun" {
  metadata {
    name      = "diun"
    namespace = kubernetes_namespace.diun.metadata[0].name
    labels = {
      app  = "diun"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
      "diun.enable"                  = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "diun"
      }
    }
    template {
      metadata {
        labels = {
          app = "diun"
        }
      }
      spec {
        service_account_name = "diun"
        init_container {
          name  = "clone-repo"
          image = "alpine/git:latest"
          command = ["/bin/sh", "-c"]
          args = [<<-EOF
            if [ -d /repo/.git ]; then
              cd /repo && git pull --rebase origin master || true
            else
              git clone https://$${GIT_USER}:$${GIT_TOKEN}@github.com/ViktorBarzin/infra.git /repo
            fi
          EOF
          ]
          env {
            name = "GIT_USER"
            value_from {
              secret_key_ref {
                name = "diun-git-secrets"
                key  = "git_user"
              }
            }
          }
          env {
            name = "GIT_TOKEN"
            value_from {
              secret_key_ref {
                name = "diun-git-secrets"
                key  = "git_token"
              }
            }
          }
          volume_mount {
            name       = "repo"
            mount_path = "/repo"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }
        container {
          image = "viktorbarzin/diun:latest"
          name  = "diun"
          args  = ["serve"]
          env {
            name  = "TZ"
            value = "Europe/Sofia"
          }
          env {
            name  = "DIUN_WATCH_WORKERS"
            value = "20"
          }
          env {
            name  = "DIUN_WATCH_SCHEDULE"
            value = "0 */6 * * *"
          }
          env {
            name  = "DIUN_WATCH_JITTER"
            value = "30s"
          }
          env {
            name  = "DIUN_PROVIDERS_KUBERNETES"
            value = "true"
          }
          env {
            name  = "DIUN_DEFAULTS_WATCHREPO"
            value = "true"
          }
          env {
            name  = "DIUN_DEFAULTS_MAXTAGS"
            value = "3"
          }
          env {
            name  = "DIUN_DEFAULTS_SORTTAGS"
            value = "reverse"
          }
          # Script notifier for auto-updates
          env {
            name  = "DIUN_NOTIF_SCRIPT_CMD"
            value = "/scripts/auto-update.sh"
          }
          # Slack notifier (kept alongside script notifier)
          env {
            name = "DIUN_NOTIF_SLACK_WEBHOOKURL"
            value_from {
              secret_key_ref {
                name = "diun-secrets"
                key  = "slack_url"
              }
            }
          }
          # Git credentials for auto-update script
          env {
            name = "GIT_USER"
            value_from {
              secret_key_ref {
                name = "diun-git-secrets"
                key  = "git_user"
              }
            }
          }
          env {
            name = "GIT_TOKEN"
            value_from {
              secret_key_ref {
                name = "diun-git-secrets"
                key  = "git_token"
              }
            }
          }
          env {
            name  = "LOG_LEVEL"
            value = "debug"
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          volume_mount {
            name       = "scripts"
            mount_path = "/scripts"
          }
          volume_mount {
            name       = "repo"
            mount_path = "/repo"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "128Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data_proxmox.metadata[0].name
          }
        }
        volume {
          name = "scripts"
          config_map {
            name         = kubernetes_config_map_v1.auto_update_script.metadata[0].name
            default_mode = "0755"
          }
        }
        volume {
          name = "repo"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.repo.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}
