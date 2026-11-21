variable "image_tag" {
  type        = string
  default     = "latest"
  description = "Image tag used when the Deployment is (re)created. The running tag is set by the Woodpecker deploy (kubectl set image)."
}

variable "postgresql_host" { type = string }

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

# Infra: a private 3D map of the homelab, from the map of Europe down to one
# pod (Forgejo viktor/infra-map, private; design in that repo at
# docs/2026-11-21-infra-map-design.md). Viktor and emo sign in.
#
# secret/infra-map in Vault KV holds better_auth_secret, oidc_client_id and
# oidc_client_secret (seeded by hand on 2026-11-21), forgejo_read_token (the
# restricted Forgejo account infra-map-reader, stacks/forgejo-acl),
# pve_api_token (written by playbooks/pve-host.yml, tag infra-map) and
# ha_sofia_token / ha_london_token (the non-admin Home Assistant user
# infra-map on each instance, minted by hand). The `infra_map` database and
# the Vault static role pg-infra-map come from the dbaas app_databases and
# vault pg_app_roles maps.
#
# The app reads the repo's sites/ directory at runtime through the Forgejo
# API, never from its image, because /assets is served without sign-in.
locals {
  namespace       = "infra-map"
  service_account = "infra-map"

  # Optional source credentials from secret/infra-map. dataFrom extract plus
  # `index` renders a key that is not there yet as an empty value instead of
  # failing the sync, so the pod starts before every source is set up and the
  # app treats an empty value as "source not configured".
  source_keys = {
    PVE_API_TOKEN   = "pve_api_token"
    HA_SOFIA_TOKEN  = "ha_sofia_token"
    HA_LONDON_TOKEN = "ha_london_token"
  }
  sources_secret  = "infra-map-sources"
  goldmane_secret = "infra-map-goldmane-creds"
}

module "app" {
  source = "../../modules/kubernetes/tanstack_app"

  name         = local.namespace
  display_name = "Infra"
  host         = "infra.viktorbarzin.me"
  tier         = local.tiers.aux

  # Private repo, private ghcr package: Kyverno clones ghcr-credentials into
  # this namespace (stacks/kyverno ghcr_private_namespaces).
  image              = "ghcr.io/viktorbarzin/infra-map"
  image_tag          = var.image_tag
  image_pull_secrets = ["ghcr-credentials"]

  postgresql_host = var.postgresql_host
  tls_secret_name = var.tls_secret_name

  # Reads ingresses and PVCs with this account's token (ClusterRole below).
  service_account = { name = local.service_account, automount_token = true }

  app_secret_env = { FORGEJO_READ_TOKEN = "forgejo_read_token" }
  extra_env = [
    { name = "FORGEJO_API_URL", value = "http://forgejo.forgejo.svc.cluster.local/api/v1" },
    { name = "SITES_REPO", value = "viktor/infra-map" },
    { name = "SITES_REF", value = "master" },
    { name = "PROMETHEUS_URL", value = "http://prometheus-server.monitoring.svc.cluster.local" },
    { name = "ALERTMANAGER_URL", value = "http://prometheus-alertmanager.monitoring.svc.cluster.local:9093" },
    { name = "PVE_API_URL", value = "https://192.168.1.127:8006/api2/json" },
    { name = "HA_SOFIA_URL", value = "https://ha-sofia.viktorbarzin.me" },
    { name = "HA_LONDON_URL", value = "https://ha-london.viktorbarzin.me" },
    { name = "GOLDMANE_DATABASE_URL", value = "postgres://goldmane_edges_read@${var.postgresql_host}:5432/goldmane_edges" },
  ]
  secret_env = concat(
    [for env, key in local.source_keys : {
      name     = env
      secret   = local.sources_secret
      key      = replace(key, "_", "-")
      optional = true
    }],
    [{ name = "GOLDMANE_DATABASE_PASSWORD", secret = local.goldmane_secret, key = "password", optional = true }],
  )
  emit_group_env = true

  # Viktor and emo are the Infra Users; Viktor alone is the Infra Admin.
  initial_user_pks = [data.authentik_user.viktor.id, data.authentik_user.emo.id]
  admin_user_pks   = [data.authentik_user.viktor.id]

  ingress = {
    homepage_description = "A 3D map of the homelab, from the building down to the pod"
    homepage_icon        = "mdi-cube-scan"
    homepage_group       = "Infrastructure"
  }
}

# Read access to the cluster: ingresses and PVCs only. Not pods, whose specs
# hold literal secret env values, and not Secrets. Pod placement comes from
# Prometheus kube_pod_info instead.
resource "kubernetes_cluster_role" "infra_map" {
  metadata { name = "infra-map-reader" }
  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses"]
    verbs      = ["get", "list"]
  }
  rule {
    api_groups = [""]
    resources  = ["persistentvolumeclaims"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_cluster_role_binding" "infra_map" {
  metadata { name = "infra-map-reader" }
  subject {
    kind      = "ServiceAccount"
    name      = local.service_account
    namespace = module.app.namespace
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.infra_map.metadata[0].name
  }
}

# Proxmox and Home Assistant tokens, each optional (local.source_keys).
resource "kubernetes_manifest" "sources" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.sources_secret
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { name = "vault-kv", kind = "ClusterSecretStore" }
      target = {
        name = local.sources_secret
        template = {
          data = {
            for env, key in local.source_keys : replace(key, "_", "-") => "{{ index . \"${key}\" }}"
          }
        }
      }
      dataFrom = [{ extract = { key = "infra-map" } }]
    }
  }
  depends_on = [module.app]
}

# The SELECT-only goldmane_edges login (stacks/dbaas pg_goldmane_edges_read,
# Vault static role pg-goldmane-edges-read). Never the owner's credentials.
resource "kubernetes_manifest" "goldmane_creds" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.goldmane_secret
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef  = { name = "vault-database", kind = "ClusterSecretStore" }
      target          = { name = local.goldmane_secret }
      data = [{
        secretKey = "password"
        remoteRef = { key = "static-creds/pg-goldmane-edges-read", property = "password" }
      }]
    }
  }
  depends_on = [module.app]
}
