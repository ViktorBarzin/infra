# === learn Viewer — learn.viktorbarzin.me (cluster-native, git-backed) ===
#
# Authentik-gated web surface for the /teach skill's learning workspaces
# (monorepo learn/ — lessons are interactive HTML with quizzes, so they need
# a real browser, not a PNG render). v2 (2026-07-09): runs IN the cluster —
# a Caddy container serving the `learn/` tree of the GitHub monorepo, kept
# fresh by a git-sync sidecar (30s poll, SSH deploy key). Viktor explicitly
# preferred everything codified in Terraform over the v1 devvm-Caddy live
# serving ("devvm is not supposed to host prod services"); the trade-off —
# lessons appear on PUSH (~30-60s), not on file-write — is accepted, and the
# teach skill commits+pushes each lesson when it writes it. Decision +
# history: monorepo learn/docs/adr/0002 (supersedes 0001, the devvm design).
#
# Access is OWNER-ONLY: the repo is Viktor's, so only his Authentik identity
# (vbarzin, injected by authentik-forward-auth as a full email) is served;
# everyone else gets 403. Other users get their own repo wired in if they
# ever adopt /teach. In-cluster callers could spoof the header by curling
# the Service directly — same trust class as ttyd/t3-dispatch, recorded in
# the ADR.
#
# Deploy key: read-only on ViktorBarzin/monorepo ("learn-viewer git-sync"),
# private key + github known_hosts in Vault secret/learn (ssh, known_hosts)
# → ExternalSecret → Secret learn-git-creds (git-sync's default paths under
# /etc/git-secret).

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

resource "kubernetes_namespace" "learn" {
  metadata {
    name = "learn"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.learn.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# SSH deploy key for git-sync: Vault secret/learn → Secret learn-git-creds
resource "kubernetes_manifest" "git_creds_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "learn-git-creds"
      namespace = kubernetes_namespace.learn.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "learn-git-creds"
      }
      data = [
        {
          secretKey = "ssh"
          remoteRef = {
            key      = "learn"
            property = "ssh"
          }
        },
        {
          secretKey = "known_hosts"
          remoteRef = {
            key      = "learn"
            property = "known_hosts"
          }
        },
      ]
    }
  }
}

resource "kubernetes_config_map" "caddyfile" {
  metadata {
    name      = "learn-caddyfile"
    namespace = kubernetes_namespace.learn.metadata[0].name
  }
  data = {
    Caddyfile = <<-EOT
      {
      	admin off
      	auto_https off
      }
      :8080 {
      	# Owner-only: Authentik injects the username as a full email
      	# (vbarzin@...); only Viktor's identity is served (ADR-0002).
      	@owner header_regexp X-Authentik-Username ^vbarzin(@.*)?$
      	handle @owner {
      		root * /repo/src/current/learn
      		file_server browse
      	}
      	handle {
      		respond "Forbidden" 403
      	}
      }
    EOT
  }
}

resource "kubernetes_deployment" "learn" {
  metadata {
    name      = "learn"
    namespace = kubernetes_namespace.learn.metadata[0].name
    labels = {
      app = "learn"
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "learn"
      }
    }
    template {
      metadata {
        labels = {
          app = "learn"
        }
        annotations = {
          # Roll the pod when the Caddyfile changes (config mounts don't restart pods)
          "viktorbarzin.me/caddyfile-sha" = sha1(kubernetes_config_map.caddyfile.data["Caddyfile"])
        }
      }
      spec {
        security_context {
          # git-sync SSH key readability (official git-sync docs/ssh.md pattern)
          fs_group = 65533
        }

        container {
          name  = "git-sync"
          image = "registry.k8s.io/git-sync/git-sync:v4.7.0"
          args = [
            "--repo=git@github.com:ViktorBarzin/monorepo.git",
            "--ref=master",
            "--period=30s",
            "--depth=1",
            # --root must be a SUBDIR of the volume (git-sync README)
            "--root=/repo/src",
            "--link=current",
          ]
          security_context {
            run_as_user = 65533
          }
          volume_mount {
            name       = "repo"
            mount_path = "/repo"
          }
          volume_mount {
            name       = "git-secret"
            mount_path = "/etc/git-secret"
            read_only  = true
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }

        container {
          name  = "caddy"
          image = "docker.io/library/caddy:2.10.2-alpine"
          port {
            container_port = 8080
            name           = "http"
          }
          volume_mount {
            name       = "repo"
            mount_path = "/repo"
            read_only  = true
          }
          volume_mount {
            name       = "caddyfile"
            mount_path = "/etc/caddy"
            read_only  = true
          }
          readiness_probe {
            http_get {
              path = "/"
              port = 8080
              http_header {
                name  = "X-Authentik-Username"
                value = "vbarzin"
              }
            }
            # 404 until git-sync's first clone lands → the pod goes Ready
            # only once real content is being served
            initial_delay_seconds = 5
            period_seconds        = 10
            failure_threshold     = 6
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }

        volume {
          name = "repo"
          empty_dir {}
        }
        volume {
          name = "git-secret"
          secret {
            secret_name = "learn-git-creds"
            # 0400 — SSH refuses laxer keys; fsGroup 65533 grants git-sync read
            default_mode = "0400"
          }
        }
        volume {
          name = "caddyfile"
          config_map {
            name = kubernetes_config_map.caddyfile.metadata[0].name
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }

  depends_on = [kubernetes_manifest.git_creds_external_secret]
}

resource "kubernetes_service" "learn" {
  metadata {
    name      = "learn"
    namespace = kubernetes_namespace.learn.metadata[0].name
    labels = {
      app = "learn"
    }
  }

  spec {
    selector = {
      app = "learn"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.learn.metadata[0].name
  name            = "learn"
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Learn"
    "gethomepage.dev/description"  = "Learning-workspace Viewer (lessons, git-backed)"
    "gethomepage.dev/icon"         = "mdi-school"
    "gethomepage.dev/group"        = "Productivity"
    "gethomepage.dev/pod-selector" = "app=learn"
  }
}
