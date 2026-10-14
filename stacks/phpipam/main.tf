variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "mysql_host" { type = string }

# Proxmox API token (terraform-prov@pve: has VM.Audit and VM.GuestAgent.Audit)
# for the VM details in the address inventory.
data "vault_kv_secret_v2" "viktor" {
  mount = "secret"
  name  = "viktor"
}

# Home Assistant long-lived tokens (Sofia and London), the same ones
# `homelab ha token` reads, for the device registries in the address inventory.
data "vault_kv_secret_v2" "openclaw" {
  mount = "secret"
  name  = "openclaw"
}

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "platform"
}

locals {
  technitium_password = data.vault_kv_secret_v2.secrets.data["technitium_password"]
  technitium_username = try(data.vault_kv_secret_v2.secrets.data["technitium_username"], "admin")
  # Optional Technitium PERMANENT API token. A session login is tied to the admin
  # password, so rotating that password silently breaks every consumer of this
  # API; a permanent token survives it. The key is absent from Vault today, so
  # this is "" and phpipam-import falls back to the session login. Minting it
  # is a one-time human step -- POST /api/user/createToken with user, pass and
  # tokenName -- then `vault kv patch secret/platform technitium_api_token=...`,
  # after which the next apply picks it up with no code change.
  technitium_api_token = try(data.vault_kv_secret_v2.secrets.data["technitium_api_token"], "")
  # Read-only use of the Headscale API (GET /api/v1/node) by phpipam-import.
  # Minted 2026-10-13 with `headscale apikeys create --expiration 3650d`.
  headscale_api_key = data.vault_kv_secret_v2.secrets.data["phpipam_headscale_api_key"]
  pve_token_id      = data.vault_kv_secret_v2.viktor.data["proxmox_pm_api_token_id"]
  pve_token_secret  = data.vault_kv_secret_v2.viktor.data["proxmox_pm_api_token_secret"]
  ha_tokens         = jsondecode(data.vault_kv_secret_v2.openclaw.data["skill_secrets"])
}

resource "kubernetes_namespace" "phpipam" {
  metadata {
    name = "phpipam"
    labels = {
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "phpipam-secrets"
      namespace = "phpipam"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "phpipam-secrets"
      }
      data = [{
        secretKey = "db_password"
        remoteRef = {
          key      = "static-creds/mysql-phpipam"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.phpipam]
}

resource "kubernetes_manifest" "external_secret_pfsense_ssh" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "phpipam-pfsense-ssh"
      namespace = "phpipam"
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "phpipam-pfsense-ssh"
      }
      data = [{
        secretKey = "ssh_key"
        remoteRef = {
          key      = "viktor"
          property = "phpipam_pfsense_ssh_key"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.phpipam]
}

resource "kubernetes_manifest" "external_secret_admin" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "phpipam-admin-password"
      namespace = "phpipam"
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "phpipam-admin-password"
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "viktor"
          property = "phpipam_admin_password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.phpipam]
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.phpipam.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "phpipam_web" {
  metadata {
    name      = "phpipam-web"
    namespace = kubernetes_namespace.phpipam.metadata[0].name
    labels = {
      app  = "phpipam"
      tier = local.tiers.aux
    }
    annotations = {
      # Named, not "auto": auto would also watch the phpipam-topology ConfigMap
      # mounted below and restart phpIPAM every 5 minutes.
      "secret.reloader.stakater.com/reload" = "phpipam-secrets"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "phpipam"
      }
    }
    template {
      metadata {
        labels = {
          app = "phpipam"
        }
        annotations = {
          "diun.enable"                    = "true"
          "dependency.kyverno.io/wait-for" = "mysql.dbaas:3306"
        }
      }
      spec {
        container {
          image = "phpipam/phpipam-www:v1.8.3"
          name  = "phpipam-web"
          port {
            container_port = 80
          }
          env {
            name  = "TZ"
            value = "Europe/Sofia"
          }
          env {
            name  = "IPAM_DATABASE_HOST"
            value = var.mysql_host
          }
          env {
            name  = "IPAM_DATABASE_USER"
            value = "phpipam"
          }
          env {
            name = "IPAM_DATABASE_PASS"
            value_from {
              secret_key_ref {
                name = "phpipam-secrets"
                key  = "db_password"
              }
            }
          }
          env {
            name  = "IPAM_DATABASE_NAME"
            value = "phpipam"
          }
          env {
            name  = "IPAM_TRUST_X_FORWARDED"
            value = "true"
          }
          # The topology page phpipam_topology.py writes; served at /topology/.
          # Not a subPath mount, so ConfigMap updates reach the pod.
          volume_mount {
            name       = "topology"
            mount_path = "/phpipam/topology"
            read_only  = true
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
        volume {
          name = "topology"
          config_map {
            name = kubernetes_config_map.phpipam_topology.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      # Stakater Reloader stamps this on every secret-triggered restart. The
      # 2026-08-14 switch to reloadStrategy = annotations (stacks/reloader) moved
      # the marker onto this pod-template annotation on the expectation that
      # Terraform does not manage it, but it does wherever the pod template
      # declares annotations, so it planned as a removal on every run.
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
      spec[0].template[0].spec[0].dns_config,                                                  # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # LEGACY_TEMPLATE_ANNOTATIONS
    ]
  }
}

# phpipam-cron container removed — discovery now handled by phpipam-pfsense-import CronJob
# which queries Kea DHCP leases + pfSense ARP table directly (no fping needed)

resource "kubernetes_service" "phpipam" {
  metadata {
    name      = "phpipam"
    namespace = kubernetes_namespace.phpipam.metadata[0].name
    labels = {
      app = "phpipam"
    }
  }
  spec {
    selector = {
      app = "phpipam"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 80
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.phpipam.metadata[0].name
  name            = "phpipam"
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "phpIPAM"
    "gethomepage.dev/description"  = "IP Address Management"
    "gethomepage.dev/icon"         = "phpipam.png"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/pod-selector" = ""
  }
}

# The address inventory (ADR-0032, docs/plans/2026-10-13-phpipam-inventory.md).
# One CronJob reads every Source (site routers and pfSense over the pfSense SSH
# hop, the Kubernetes API, Headscale, Technitium), reconciles phpIPAM rows, and
# publishes the names it owns to viktorbarzin.lan. Logic and tests live in
# files/phpipam_import.py; files/fetch_sources.sh fetches the raw router data.
# It replaced phpipam-pfsense-import, phpipam-remote-import and phpipam-dns-sync
# on 2026-10-13; the two imports had written nothing since 2026-04-10 because
# their MariaDB client could not log in to MySQL 8.4.
resource "kubernetes_config_map" "phpipam_import" {
  metadata {
    name      = "phpipam-import"
    namespace = kubernetes_namespace.phpipam.metadata[0].name
  }
  data = {
    "phpipam_import.py"   = file("${path.module}/files/phpipam_import.py")
    "phpipam_enrich.py"   = file("${path.module}/files/phpipam_enrich.py")
    "phpipam_topology.py" = file("${path.module}/files/phpipam_topology.py")
    "fetch_sources.sh"    = file("${path.module}/files/fetch_sources.sh")
    "devices.yaml"        = file("${path.module}/files/devices.yaml")
  }
}

# Reads node addresses and LoadBalancer addresses, and writes the topology page.
resource "kubernetes_service_account" "phpipam_import" {
  metadata {
    name      = "phpipam-import"
    namespace = kubernetes_namespace.phpipam.metadata[0].name
  }
}

resource "kubernetes_cluster_role" "phpipam_import" {
  metadata {
    name = "phpipam-import"
  }
  rule {
    api_groups = [""]
    resources  = ["nodes", "services"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_cluster_role_binding" "phpipam_import" {
  metadata {
    name = "phpipam-import"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.phpipam_import.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.phpipam_import.metadata[0].name
    namespace = kubernetes_namespace.phpipam.metadata[0].name
  }
}

# The network topology page (files/phpipam_topology.py). phpipam-import
# replaces index.html on every run; Terraform creates the ConfigMap with a
# placeholder and leaves its data alone afterwards.
resource "kubernetes_config_map" "phpipam_topology" {
  metadata {
    name      = "phpipam-topology"
    namespace = kubernetes_namespace.phpipam.metadata[0].name
  }
  data = {
    "index.html" = "<!doctype html><title>Network topology</title><p>Not drawn yet; phpipam-import draws it every 5 minutes.</p>"
  }
  lifecycle {
    ignore_changes = [data]
  }
}

# Lets the import job replace that one ConfigMap and nothing else.
resource "kubernetes_role" "phpipam_topology" {
  metadata {
    name      = "phpipam-topology-writer"
    namespace = kubernetes_namespace.phpipam.metadata[0].name
  }
  rule {
    api_groups     = [""]
    resources      = ["configmaps"]
    resource_names = [kubernetes_config_map.phpipam_topology.metadata[0].name]
    verbs          = ["get", "patch"]
  }
}

resource "kubernetes_role_binding" "phpipam_topology" {
  metadata {
    name      = "phpipam-topology-writer"
    namespace = kubernetes_namespace.phpipam.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.phpipam_topology.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.phpipam_import.metadata[0].name
    namespace = kubernetes_namespace.phpipam.metadata[0].name
  }
}

resource "kubernetes_cron_job_v1" "phpipam_import" {
  metadata {
    name      = "phpipam-import"
    namespace = kubernetes_namespace.phpipam.metadata[0].name
  }
  spec {
    schedule                      = "*/5 * * * *"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    concurrency_policy            = "Forbid"
    job_template {
      metadata {}
      spec {
        backoff_limit = 0
        # A normal run takes about 15 s. With Forbid, one hung run (an apk
        # fetch that never returns, as pfsense-import saw on 2026-08-10) would
        # block every run after it; PhpipamImportStale fires if that happens.
        active_deadline_seconds = 240
        template {
          metadata {
            annotations = {
              "checksum/script" = sha1(join("", [for f in ["phpipam_import.py", "phpipam_enrich.py", "phpipam_topology.py", "fetch_sources.sh", "devices.yaml"] : file("${path.module}/files/${f}")]))
            }
          }
          spec {
            restart_policy       = "Never"
            service_account_name = kubernetes_service_account.phpipam_import.metadata[0].name
            container {
              name  = "import"
              image = "alpine:3.24"
              command = ["/bin/sh", "-c", <<-EOT
                set -eu
                apk add --no-cache -q openssh-client python3 py3-pymysql py3-netaddr py3-websockets py3-yaml > /dev/null
                mkdir -p /root/.ssh
                cp /ssh/ssh_key /root/.ssh/id_rsa
                chmod 600 /root/.ssh/id_rsa
                echo "StrictHostKeyChecking no" > /root/.ssh/config
                sh /app/fetch_sources.sh /tmp/sources
                rc=0
                python3 /app/phpipam_import.py || rc=$?
                # Drawn even when a Source failed: the page then shows that
                # site's router as not seen. A failed drawing leaves the last
                # page up, with its timestamp, and does not fail the import.
                python3 /app/phpipam_topology.py || echo "topology failed"
                exit $rc
              EOT
              ]
              env {
                name  = "SOURCE_DIR"
                value = "/tmp/sources"
              }
              env {
                name  = "TECH_URL"
                value = "http://technitium-web.technitium.svc.cluster.local:5380"
              }
              env {
                name  = "TECH_USER"
                value = local.technitium_username
              }
              env {
                name  = "TECH_PASS"
                value = local.technitium_password
              }
              env {
                name  = "TECH_API_TOKEN"
                value = local.technitium_api_token
              }
              env {
                name  = "DEVICES_FILE"
                value = "/app/devices.yaml"
              }
              # Through Traefik like every other client; both ingresses forward
              # websockets.
              env {
                name  = "HA_SOFIA_URL"
                value = "https://ha-sofia.viktorbarzin.me"
              }
              env {
                name  = "HA_SOFIA_TOKEN"
                value = local.ha_tokens["home_assistant_sofia_token"]
              }
              env {
                name  = "HA_LONDON_URL"
                value = "https://ha-london.viktorbarzin.me"
              }
              env {
                name  = "HA_LONDON_TOKEN"
                value = local.ha_tokens["home_assistant_token"]
              }
              # The Proxmox host, the same target pve_exporter scrapes.
              env {
                name  = "PVE_URL"
                value = "https://192.168.1.127:8006"
              }
              env {
                name  = "PVE_TOKEN_ID"
                value = local.pve_token_id
              }
              env {
                name  = "PVE_TOKEN_SECRET"
                value = local.pve_token_secret
              }
              env {
                name  = "HEADSCALE_URL"
                value = "http://headscale.headscale.svc.cluster.local:8080"
              }
              env {
                name  = "HEADSCALE_API_KEY"
                value = local.headscale_api_key
              }
              env {
                name  = "DB_HOST"
                value = var.mysql_host
              }
              env {
                name  = "DB_USER"
                value = "phpipam"
              }
              env {
                name = "DB_PASS"
                value_from {
                  secret_key_ref {
                    name = "phpipam-secrets"
                    key  = "db_password"
                  }
                }
              }
              env {
                name  = "DB_NAME"
                value = "phpipam"
              }
              volume_mount {
                name       = "ssh-key"
                mount_path = "/ssh"
                read_only  = true
              }
              volume_mount {
                name       = "script"
                mount_path = "/app"
                read_only  = true
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
            volume {
              name = "ssh-key"
              secret {
                secret_name  = "phpipam-pfsense-ssh"
                default_mode = "0400"
              }
            }
            volume {
              name = "script"
              config_map {
                name = kubernetes_config_map.phpipam_import.metadata[0].name
              }
            }
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00
