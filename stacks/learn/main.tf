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
# Access is GROUP-GATED, then open within the group: Authentik admits only
# "Home Server Admins" (vbarzin, emil.barzin — see module "ingress_pages"),
# and from 2026-08-09 every admitted identity can read every page space.
# pages/<user>/ is an authoring namespace, not an access boundary; unlisted
# identities still get 403. Before that date each identity was pinned to its
# own directory, which meant a page URL handed to the other person resolved
# against THEIR directory and 404'd — sharing a link simply did not work.
# In-cluster callers could spoof the header by curling the Service directly —
# same trust class as ttyd/t3-dispatch, recorded in the ADR.
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
      	# host/auth-agnostic health endpoint so the caddy readiness probe
      	# stays green now that the learn.* handler was removed (repointed).
      	handle /healthz {
      		respond "ok" 200
      	}
      	# pages.viktorbarzin.me: per-user page spaces (pages/<user>/) + a shared
      	# area (pages/shared/), served from the git-synced monorepo pages/ tree.
      	# Every page is readable by every identity that clears the Authentik gate
      	# (allowed-groups "Home Server Admins" — see the ingress below); the
      	# per-user split is a NAMESPACE for authoring, not an access boundary
      	# (Viktor, 2026-08-09). Each identity still maps to STATIC try_files
      	# candidates — the untrusted X-Authentik-Username header is never
      	# interpolated into a path, so a spoofed value can't drive traversal.
      	# Own space is tried FIRST so existing bare-filename URLs keep resolving
      	# to their author's page; the other spaces are the fallback, which is what
      	# makes a handed-over link work instead of 404ing. /assets/* is the shared
      	# stylesheet+mermaid. plans.viktorbarzin.me 301-redirects here (renamed
      	# from plans/ 2026-07-26). learn.viktorbarzin.me is served by the separate 'learning' app stack
      	# (PWA; repointed 2026-07-27).
      	# In-cluster callers can still spoof the header (same trust class as
      	# ttyd, per ADR) — accepted for this 3-user homelab (Viktor, 2026-07-26).
      	@pages_assets {
      		host pages.viktorbarzin.me
      		path /assets/*
      	}
      	handle @pages_assets {
      		root * /repo/src/current/pages
      		file_server
      	}
      	@plans_redirect host plans.viktorbarzin.me
      	handle @plans_redirect {
      		redir https://pages.viktorbarzin.me{uri} permanent
      	}
      	@pages_shared {
      		host pages.viktorbarzin.me
      		path /shared/*
      		header_regexp X-Authentik-Username ^(vbarzin|emil\.barzin)(@.*)?$
      	}
      	handle @pages_shared {
      		root * /repo/src/current/pages
      		file_server
      	}
      	# pages/tools/ is the renderer's source, not published content — the
      	# try_files fallthrough below would otherwise expose it at /tools/*.
      	@pages_tools {
      		host pages.viktorbarzin.me
      		path /tools/*
      	}
      	handle @pages_tools {
      		respond "Not Found" 404
      	}
      	@pages_wizard {
      		host pages.viktorbarzin.me
      		header_regexp X-Authentik-Username ^vbarzin(@.*)?$
      	}
      	handle @pages_wizard {
      		root * /repo/src/current/pages
      		try_files /wizard{path} /wizard{path}index.html /emo{path} /emo{path}index.html /shared{path} /shared{path}index.html
      		file_server
      	}
      	@pages_emo {
      		host pages.viktorbarzin.me
      		header_regexp X-Authentik-Username ^emil\.barzin(@.*)?$
      	}
      	handle @pages_emo {
      		root * /repo/src/current/pages
      		try_files /emo{path} /emo{path}index.html /wizard{path} /wizard{path}index.html /shared{path} /shared{path}index.html
      		file_server
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
      # DELIBERATELY NOT sablier-enrolled (un-enrolled 2026-07-12, Viktor):
      # this pod serves plans.viktorbarzin.me — the plan-review surface he
      # opens on the go — and learn.viktorbarzin.me; both must load instantly,
      # so it stays always-on despite passing the ADR-0022 eligibility
      # checklist. ~40Mi idle; the cold re-clone wait isn't worth it here.
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
              path = "/healthz"
              port = 8080
            }
            # /healthz is host/auth-agnostic (Caddyfile handler), so readiness
            # stays green after the learn.* handler was removed (2026-07-27)
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


# pages.viktorbarzin.me — per-user private page spaces + a shared area (the
# monorepo's pages/ tree, renamed from plans/ 2026-07-26; rendered + pushed by
# publish-page). Served by the SAME learn pod; the Caddyfile above routes by
# Host and per-user by X-Authentik-Username. The homepage tile lives here.
module "ingress_pages" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.learn.metadata[0].name
  name            = "pages"
  service_name    = "learn"
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Pages"
    "gethomepage.dev/description"  = "Published pages — plans/specs/designs (git-backed)"
    "gethomepage.dev/icon"         = "mdi-file-document-multiple"
    "gethomepage.dev/group"        = "Productivity"
    "gethomepage.dev/pod-selector" = "app=learn"
  }
}

# plans.viktorbarzin.me — kept only so Traefik still routes the OLD hostname to
# the pod, where the Caddyfile 301-redirects it to pages.* (name stays "plans"
# so this is an in-place annotation change, not a destroy/recreate). No homepage
# tile — it's a redirect, not a destination. Retire once old links age out.
module "ingress_plans" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.learn.metadata[0].name
  name            = "plans"
  service_name    = "learn"
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  extra_annotations = {
    "gethomepage.dev/enabled" = "false"
  }
}
