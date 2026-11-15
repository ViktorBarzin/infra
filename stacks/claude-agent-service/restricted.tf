# claude-agent-restricted: the same service for callers whose runs must not
# hold Viktor's rights (enforced-identity plan, step 6, 2026-11-15).
#
# The main deployment runs every job with a Vault token that reads all of
# secret/*, the infra git-crypt key, Viktor's GitHub and Forgejo tokens and
# write access across the cluster. Its callers included agents that read
# untrusted input with a shell: recruiter-triage reads recruiters' email,
# book-rescuer reads web pages. A prompt in that input could reach all of it.
# A token minted per run inside the same container would be within the run's
# reach too, so the rights are split by pod instead.
#
# This pod holds none of it: no Vault token or role, no git-crypt or sops key,
# no infra or GitHub token, and a ServiceAccount with no RBAC and no mounted
# token. It clones the public infra repo anonymously, so agents defined there
# (book-rescuer, payslip-extractor) still load. It keeps the shared bearer
# token api_bearer_token, so its callers only change their URL; the main pod
# takes admin_api_token, which only its own callers hold.
#
# Callers here: beads, ebooks, fire-planner, lesson-harvester, payslip-ingest,
# recruiter-responder, reels, tripit. The main pod keeps the fixer, its
# webhook receiver, tv's intake and fixers, and nextcloud-todos-exec.

locals {
  restricted_labels = {
    app = "claude-agent-restricted"
  }
}

resource "kubernetes_manifest" "restricted_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "claude-agent-restricted-secrets"
      namespace = kubernetes_namespace.claude_agent.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "claude-agent-restricted-secrets"
      }
      data = [
        { secretKey = "API_BEARER_TOKEN", remoteRef = { key = "claude-agent-service", property = "api_bearer_token" } },
        { secretKey = "CLAUDE_CODE_OAUTH_TOKEN", remoteRef = { key = "claude-agent-service", property = "claude_oauth_token" } },
        { secretKey = "REELS_TRENDING_TOKEN", remoteRef = { key = "claude-agent-service", property = "reels_trending_token" } },
      ]
    }
  }
}

resource "kubernetes_service_account" "claude_agent_restricted" {
  metadata {
    name      = "claude-agent-restricted"
    namespace = kubernetes_namespace.claude_agent.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_deployment" "claude_agent_restricted" {
  metadata {
    name      = "claude-agent-restricted"
    namespace = kubernetes_namespace.claude_agent.metadata[0].name
    labels    = local.restricted_labels
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = local.restricted_labels
    }

    template {
      metadata {
        labels = local.restricted_labels
      }

      spec {
        service_account_name            = kubernetes_service_account.claude_agent_restricted.metadata[0].name
        automount_service_account_token = false

        image_pull_secrets {
          name = "registry-credentials"
        }

        security_context {
          run_as_user  = 1000
          run_as_group = 1000
          fs_group     = 1000
        }

        init_container {
          name    = "fix-perms"
          image   = "busybox:1.38@sha256:a46257e06c82ad85242d0d38077d0a52d9896389ca60a1a59d3463db586e5fa4"
          command = ["sh", "-c", "mkdir -p /workspace/infra /persistent && chown -R 1000:1000 /workspace /persistent && chmod 0775 /workspace/infra /persistent"]
          security_context {
            run_as_user = 0
          }
          volume_mount {
            name       = "workspace"
            mount_path = "/workspace"
          }
          volume_mount {
            name       = "persistent"
            mount_path = "/persistent"
          }
          resources {
            requests = { memory = "32Mi" }
            limits   = { memory = "64Mi" }
          }
        }

        init_container {
          name    = "copy-claude-creds"
          image   = "busybox:1.38@sha256:a46257e06c82ad85242d0d38077d0a52d9896389ca60a1a59d3463db586e5fa4"
          command = ["sh", "-c", "cp /secrets/claude/.credentials.json /home/agent/.claude/.credentials.json && chown 1000:1000 /home/agent/.claude/.credentials.json"]
          security_context {
            run_as_user = 0
          }
          volume_mount {
            name       = "claude-credentials-secret"
            mount_path = "/secrets/claude"
          }
          volume_mount {
            name       = "claude-home"
            mount_path = "/home/agent/.claude"
          }
          resources {
            requests = { memory = "32Mi" }
            limits   = { memory = "64Mi" }
          }
        }

        # The public infra repo, cloned with no credentials and left locked.
        init_container {
          name  = "git-init"
          image = "${local.image}:${local.image_tag}"
          command = ["sh", "-c", <<-EOF
            set -e
            git config --global user.name "Claude Agent Service"
            git config --global user.email "claude-agent@viktorbarzin.me"
            git config --global --add safe.directory /workspace/infra
            if [ ! -d /workspace/infra/.git ]; then
              git clone https://forgejo.viktorbarzin.me/viktor/infra.git /workspace/infra
            fi
          EOF
          ]
          volume_mount {
            name       = "workspace"
            mount_path = "/workspace"
          }
          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { memory = "512Mi" }
          }
        }

        init_container {
          name  = "seed-agents"
          image = "${local.image}:${local.image_tag}"
          command = ["sh", "-c", <<-EOT
            set -e
            mkdir -p /workspace/.beads /workspace/scratch /home/agent/.claude/agents
            cp /usr/share/agent-seed/beads-metadata.json /workspace/.beads/metadata.json
            cp /usr/share/agent-seed/beads-task-runner.md /home/agent/.claude/agents/beads-task-runner.md
            cp /usr/share/agent-seed/recruiter-triage.md /home/agent/.claude/agents/recruiter-triage.md
            cp /usr/share/agent-seed/nextcloud-todos-planner.md /home/agent/.claude/agents/nextcloud-todos-planner.md
          EOT
          ]
          volume_mount {
            name       = "workspace"
            mount_path = "/workspace"
          }
          volume_mount {
            name       = "claude-home"
            mount_path = "/home/agent/.claude"
          }
          resources {
            requests = { memory = "32Mi" }
            limits   = { memory = "128Mi" }
          }
        }

        container {
          name  = "claude-agent-service"
          image = "${local.image}:${local.image_tag}"

          port {
            container_port = 8080
          }

          env_from {
            secret_ref {
              name = "claude-agent-restricted-secrets"
            }
          }
          env {
            name  = "WORKSPACE_DIR"
            value = "/workspace/infra"
          }
          env {
            name  = "MAX_CONCURRENCY"
            value = "10"
          }
          # The fixer loop is the main pod's: with an empty allowlist the
          # receiver here admits nothing.
          env {
            name  = "AFK_KILL_SWITCH"
            value = "true"
          }
          env {
            name  = "AFK_ALLOWLIST"
            value = ""
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }
          readiness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          volume_mount {
            name       = "workspace"
            mount_path = "/workspace"
          }
          volume_mount {
            name       = "persistent"
            mount_path = "/persistent"
          }
          volume_mount {
            name       = "claude-home"
            mount_path = "/home/agent/.claude"
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "512Mi"
            }
            limits = {
              memory = "2Gi"
            }
          }
        }

        volume {
          name = "workspace"
          empty_dir {}
        }
        volume {
          name = "persistent"
          empty_dir {}
        }
        volume {
          name = "claude-credentials-secret"
          secret {
            secret_name  = kubernetes_secret.claude_credentials.metadata[0].name
            default_mode = "0600"
          }
        }
        volume {
          name = "claude-home"
          empty_dir {}
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].labels["tier"],                             # stamped by Kyverno sync-tier-label-from-namespace
      spec[0].template[0].spec[0].container[0].image,         # CI_SETS_IMAGE: claude-agent-service/.woodpecker/deploy.yml
      spec[0].template[0].spec[0].init_container[2].image,    # CI_SETS_IMAGE
      spec[0].template[0].spec[0].init_container[3].image,    # CI_SETS_IMAGE
    ]
  }

  depends_on = [kubernetes_manifest.restricted_external_secret]
}

resource "kubernetes_service" "claude_agent_restricted" {
  metadata {
    name      = "claude-agent-restricted"
    namespace = kubernetes_namespace.claude_agent.metadata[0].name
    labels    = local.restricted_labels
    annotations = {
      "uptime.viktorbarzin.me/internal-monitor"      = "true"
      "uptime.viktorbarzin.me/internal-monitor-name" = "claude-agent-restricted"
      "uptime.viktorbarzin.me/internal-monitor-path" = "/health"
    }
  }
  spec {
    selector = local.restricted_labels
    port {
      port        = 8080
      target_port = 8080
    }
    type = "ClusterIP"
  }
}
