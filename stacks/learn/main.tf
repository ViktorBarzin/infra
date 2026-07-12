# === learn Viewer — learn.viktorbarzin.me + plans.viktorbarzin.me ===
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
# Since 2026-07-10 the same pod also serves plans.viktorbarzin.me — the
# monorepo's plans/ tree of published HTML plan snapshots (infra#72); the
# Caddyfile splits the two sites by Host header, module "ingress_plans" below.
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
      	# Two sites split by Host, matchers deliberately non-overlapping so
      	# behavior can't depend on handle ordering: plans.viktorbarzin.me
      	# serves the monorepo's plans/ tree (published HTML plan snapshots,
      	# infra#72); every other host — learn.viktorbarzin.me and the
      	# readiness probe's host-less requests — serves learn/ as before.
      	@plans_owner {
      		host plans.viktorbarzin.me
      		header_regexp X-Authentik-Username ^vbarzin(@.*)?$
      	}
      	@learn_owner {
      		not host plans.viktorbarzin.me
      		header_regexp X-Authentik-Username ^vbarzin(@.*)?$
      	}
      	handle @plans_owner {
      		root * /repo/src/current/plans
      		file_server
      	}
      	handle @learn_owner {
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
      # Scale-to-zero enrollment (ADR-0022): parked when idle, woken by the
      # first request to EITHER learn.viktorbarzin.me or plans.viktorbarzin.me
      # (both ingresses carry the same sablier group). Cold wake re-clones the
      # monorepo shallow via git-sync (~15-50s) — emptyDir content, nothing lost.
      "sablier.enable" = "true"
      "sablier.group"  = "learn"
      # 5s settling delay after k8s readiness: covers Traefik endpoint-list
      # propagation so the first forwarded request never hits a 503 race.
      "sablier.ready-after" = "5s"
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
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      spec[0].replicas,                       # SABLIER_MANAGED_REPLICAS — sablier scales 0<->1 (ADR-0022)
    ]
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
  source = "../../modules/kubernetes/ingress_factory"
  # Scale-to-zero (ADR-0022): held-request wake, 3h idle park. Same group on
  # the plans ingress below — a visit to either host wakes the shared pod.
  sablier = {
    group = "learn"
  }
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

# plans.viktorbarzin.me — published HTML plan snapshots (the monorepo's plans/
# tree, rendered + pushed by the publish-plan skill; spec: infra#72). Served by
# the SAME learn pod: the Caddyfile above picks the site by Host header, with
# the identical owner-only gate. Only the ingress hostname is new.
module "ingress_plans" {
  source = "../../modules/kubernetes/ingress_factory"
  # Scale-to-zero (ADR-0022): same group as the learn ingress above.
  sablier = {
    group = "learn"
  }
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.learn.metadata[0].name
  name            = "plans"
  service_name    = "learn"
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Plans"
    "gethomepage.dev/description"  = "Published plan/spec HTML snapshots (git-backed)"
    "gethomepage.dev/icon"         = "mdi-map-check"
    "gethomepage.dev/group"        = "Productivity"
    "gethomepage.dev/pod-selector" = "app=learn"
  }
}
