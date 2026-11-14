# Cloud's console and API (TanStack Start, Forgejo viktor/cloud) on the shared
# first-party app module (modules/kubernetes/tanstack_app, docs/agents/new-app.md).
# The module owns the namespace `cloud`, the console's service account (both
# moved here from M2, main.tf), the Deployment `cloud` with its `migrate` init
# container, Service, ingress for cloud.viktorbarzin.me, NetworkPolicy, the
# ExternalSecrets and the Authentik application, groups and tokens.
#
# Before the first apply, seed secret/cloud-console (not secret/cloud, which
# is the Project subtree Cloud owns): docs/runbooks/cloud.md, "Seed the
# console's secrets". The `cloud` database and the pg-cloud static role come
# from stacks/dbaas (app_databases.tf) and stacks/vault (app_db_roles.tf).

variable "image_tag" {
  type        = string
  default     = "latest" # used only when a Deployment is created; CI sets the running tag
  description = "Tag of ghcr.io/viktorbarzin/cloud and ghcr.io/viktorbarzin/cloud-reconciler used when the Deployments are (re)created. The running tags are set by the Woodpecker deploy (kubectl set image)."
}

variable "postgresql_host" { type = string }

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

module "console" {
  source = "../../modules/kubernetes/tanstack_app"

  name         = local.cloud_console_name
  display_name = "Cloud"
  tier         = local.tiers.aux

  # Private ghcr package (the GitHub mirror is private): ghcr-credentials is
  # copied in by Kyverno (stacks/kyverno ghcr-credentials.tf, "cloud").
  image              = "ghcr.io/viktorbarzin/cloud"
  image_tag          = var.image_tag
  image_pull_secrets = ["ghcr-credentials"]

  postgresql_host = var.postgresql_host
  tls_secret_name = var.tls_secret_name

  # secret/cloud is the Project subtree (secret/cloud/system,
  # secret/cloud/p-*), so the console's own secrets live beside it.
  vault_kv_name = "cloud-console"

  # TakenHosts reads the cluster with this account's token
  # (local.cloud_console_cluster_rules, bound below).
  service_account = { name = local.cloud_console_sa, automount_token = true }

  # The GLOSSARY's Users and Operators. Operators are the auth package's
  # admins: they approve access requests and see the Operator side.
  users_group  = "Cloud Users"
  admins_group = "Cloud Operators"
  signup_mode  = "request"

  # Device code on the console's own client (Cloud v1 plan, "How do agents
  # sign in?"). The client is confidential, and Authentik 2026.8 requires its
  # secret at the token endpoint for this grant (providers/oauth2/token/
  # base.py), so only a holder of the secret can complete a device sign-in
  # here and a link from an outsider grants nothing. A CLI cannot hold the
  # secret: agents sign in on cloud-cli (cli_sign_in.tf).
  grant_types = ["authorization_code", "urn:ietf:params:oauth:grant-type:device_code"]

  extra_env = local.cloud_console_env
  # M5: SECRETS_PUBLIC_KEY and GITHUB_API_TOKEN from Secret
  # cloud-console-system (below), optional. TELEMETRY_WRITE_KEY, SENTRY_DSN
  # and SENTRY_BROWSER_DSN from Secret cloud-telemetry (telemetry.tf).
  secret_env = concat(local.cloud_console_secret_env, local.telemetry_secret_env)

  # email_verified true only for accounts whose email something vouched for
  # (email_claim.tf), so the owner check can match a Forgejo account by a
  # verified email. The managed mapping sends false.
  email_scope_mapping_id = authentik_property_mapping_provider_scope.cloud_email.id

  initial_user_pks = [data.authentik_user.viktor.id]
  admin_user_pks   = [data.authentik_user.viktor.id]

  ingress = {
    homepage_description = "Projects for invited Users: Apps and Postgres"
    homepage_icon        = "mdi-cloud-outline"
    homepage_group       = "Infrastructure"
  }
}

resource "kubernetes_cluster_role" "cloud_console" {
  metadata { name = local.cloud_console_sa }
  dynamic "rule" {
    for_each = local.cloud_console_cluster_rules
    content {
      api_groups     = rule.value.api_groups
      resources      = rule.value.resources
      verbs          = rule.value.verbs
      resource_names = rule.value.resource_names
    }
  }
}

resource "kubernetes_cluster_role_binding" "cloud_console" {
  metadata { name = local.cloud_console_sa }
  subject {
    kind      = "ServiceAccount"
    name      = local.cloud_console_sa
    namespace = module.console.namespace
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.cloud_console.metadata[0].name
  }
}

# M5: the console's copy of two secret/cloud/system keys
# (local.cloud_console_system_keys in deploy_rules.tf): the public key for
# sealing App secrets, which exists, and the optional GitHub API token, which
# may not. dataFrom extract plus `index` renders a missing key as an empty
# value instead of failing the sync. The console has no Vault token of its
# own; External Secrets reads Vault, and only these two keys reach the Secret.
resource "kubernetes_manifest" "console_system" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.cloud_console_system_secret
      namespace = module.console.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = local.cloud_console_system_secret
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = local.cloud_console_system_template
        }
      }
      dataFrom = [{ extract = { key = "cloud/system" } }]
    }
  }
}
