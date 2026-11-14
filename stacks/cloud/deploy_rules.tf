# What the console and the reconciler Deployments get (milestones M4 and M5):
# the console's cluster role, the env both processes read and the
# reconciler's credential files. Locals only (plus var.postgresql_host and
# var.builds_enabled, which have no other inputs), so
# tests/cloud-deploy.test.sh checks them offline against the cloud repo's
# src/server/env.server.ts. console.tf and reconciler.tf turn them into
# resources; docs/architecture/cloud.md has the credentials table.

# The M5 switch for builds and Deploys (buildsConfig() in the cloud code).
# On since 2026-11-14: the GitHub tokens are Viktor's existing PAT
# (secret/viktor github_pat), his choice (docs/runbooks/cloud.md, "Turning
# builds on"). Off is the M5 rollback: the reconciler stops polling branches
# and dispatching builds, and everything else keeps working.
variable "builds_enabled" {
  type    = bool
  default = true
}

locals {
  # One name each, defined in access_rules.tf: the console module's name is
  # the namespace the admission policies name, and the reconciler's objects
  # carry its service account's name.
  cloud_console_name = local.cloud_namespace
  cloud_console_sa   = "cloud-console"
  cloud_reconciler   = local.cloud_reconciler_sa

  # The console's DATABASE_URL, which the reconciler shares. Written out here
  # so tests/cloud-deploy.test.sh can evaluate it offline; a precondition on
  # the reconciler Deployment checks it against module.console.database_url.
  cloud_database_url = "postgres://${local.cloud_console_name}@${var.postgresql_host}:5432/${local.cloud_console_name}"

  # The second Authentik client, for the CLI and MCP sign-in (cli_sign_in.tf).
  cloud_cli_client_id = "cloud-cli"
  cloud_authentik_url = "https://authentik.viktorbarzin.me"

  # TakenHosts in the console (src/server/taken-hosts.server.ts in the cloud
  # repo) lists namespaces with Cloud's label, and every Ingress and
  # IngressRoute, cluster-wide, so a Plan refuses a host the homelab already
  # routes. Read only, and nothing else: no Secrets, no ConfigMaps, no write.
  # The reconciler reads the same objects itself before each apply
  # (local.cloud_reconciler_cluster_rules in access_rules.tf).
  cloud_console_cluster_rules = [
    { api_groups = [""], resources = ["namespaces"], verbs = ["get", "list"], resource_names = null },
    { api_groups = ["networking.k8s.io"], resources = ["ingresses"], verbs = ["get", "list"], resource_names = null },
    { api_groups = ["traefik.io"], resources = ["ingressroutes"], verbs = ["get", "list"], resource_names = null },
  ]

  # Appended to the tanstack_app module's platform env (DATABASE_URL,
  # OIDC_DISCOVERY_URL, the group names and the rest).
  cloud_console_env = [
    # Plans ask the cluster for taken hosts; needs the token and the role above.
    { name = "TAKEN_HOSTS_FROM_CLUSTER", value = "true" },
    # Bearer tokens from both Authentik clients: the console's own (device
    # code on the confidential client) and cloud-cli (public, refreshable).
    { name = "API_TOKEN_AUDIENCES", value = join(",", [local.cloud_console_name, local.cloud_cli_client_id]) },
    # The agent client: the API verifies cloud-cli tokens against it, and
    # `cloud login` and the MCP Protected Resource Metadata use it
    # (docs/architecture/cloud.md, "Agent sign-in").
    { name = "AGENT_OIDC_CLIENT_ID", value = local.cloud_cli_client_id },
    { name = "AGENT_OIDC_DISCOVERY_URL", value = "${local.cloud_authentik_url}/application/o/${local.cloud_cli_client_id}/.well-known/openid-configuration" },
    # M5: the Metrics tab and the logs tab. In-cluster, no auth; the console
    # reaches both through the tier 4-aux egress allow (docs/architecture/
    # cloud.md, "Network").
    { name = "PROMETHEUS_URL", value = local.cloud_prometheus_url },
    { name = "LOKI_URL", value = local.cloud_loki_url },
    # The same switch as the reconciler's: GET /api/v1/builds answers from
    # it, and the Deploys tab and the Add Service wizard say pushes do not
    # deploy while it is false. Unset, the console counts builds as on.
    { name = "BUILDS_ENABLED", value = tostring(var.builds_enabled) },
  ]

  cloud_prometheus_url = "http://prometheus-server.monitoring.svc.cluster.local"
  cloud_loki_url       = "http://loki.monitoring.svc.cluster.local:3100"
  # Forgejo's Service in namespace forgejo (port 80), and its Authentik login
  # source: `forgejo admin auth list` shows 1 "Authentik" (checked
  # 2026-11-13; the source is disabled for new sign-ins, and the accounts it
  # made still carry it).
  cloud_forgejo_url            = "http://forgejo.forgejo.svc.cluster.local"
  cloud_forgejo_auth_source_id = 1

  # secret/cloud/system keys copied into the console's Secret, by env name.
  # buildApiSettings() reads both inline:
  #   SECRETS_PUBLIC_KEY  the X25519 public key (SPKI PEM) the API seals App
  #                       secrets with; the reconciler holds the private key
  #   GITHUB_API_TOKEN    optional, a GitHub token with no permissions, so
  #                       the private-repo check is not rate limited to 60
  #                       requests an hour
  # Never secrets_private_key: the console only seals.
  cloud_console_system_keys = {
    SECRETS_PUBLIC_KEY = "secrets_public_key"
    GITHUB_API_TOKEN   = "github_api_token"
  }
  cloud_console_system_secret = "${local.cloud_console_name}-console-system"

  # The secret/cloud/system overrides the reconciler gets as files
  # (systemSecretsFromEnv() in the cloud code). Without them it reads the same
  # keys from Vault with its own token (src/reconciler/system-secrets.ts,
  # every 5 minutes), so the files are a copy that keeps working while Vault
  # does not answer. An empty file counts as unset and falls back to Vault.
  cloud_reconciler_system_keys = {
    GITHUB_DISPATCH_TOKEN   = "github_dispatch_token"
    GITHUB_OWNER_READ_TOKEN = "github_owner_read_token"
    FORGEJO_READ_TOKEN      = "forgejo_read_token"
    FORGEJO_ADMIN_TOKEN     = "forgejo_admin_token"
    SECRETS_PRIVATE_KEY     = "secrets_private_key"
    # Optional. The reconciler skips Vault once the files set every other
    # key, so the delete token must come as a file too, or gone Apps' ghcr
    # images are never deleted (found 2026-11-14, rows stuck at 0 attempts).
    GHCR_DELETE_TOKEN = "ghcr_delete_token"
  }
  cloud_reconciler_system_secret = "${local.cloud_reconciler}-system"

  # The ExternalSecrets read all of secret/cloud/system (dataFrom extract) and
  # write only these keys. ESO renders templates with missingkey=error, so
  # `{{ .github_dispatch_token }}` would fail the whole sync until Viktor
  # stores that token; `index` renders a missing key as "" instead. The
  # Secret key is the Vault key with dashes.
  cloud_reconciler_system_template = {
    for env, key in local.cloud_reconciler_system_keys : replace(key, "_", "-") => "{{ index . \"${key}\" }}"
  }
  cloud_console_system_template = {
    for env, key in local.cloud_console_system_keys : replace(key, "_", "-") => "{{ index . \"${key}\" }}"
  }

  # Env from Secret keys (the module's secret_env). Optional, so the pod
  # starts before the Secret exists; an empty value counts as unset.
  cloud_console_secret_env = [
    for env, key in local.cloud_console_system_keys : {
      name     = env
      secret   = local.cloud_console_system_secret
      key      = replace(key, "_", "-")
      optional = true
    }
  ]

  # The reconciler's credentials, each a file in a mounted Secret, read again
  # on every job (src/reconciler/credentials.ts), so a rotation reaches the
  # next job without a restart; Reloader restarts the pod as well, after the
  # running job (local.cloud_reconciler_reload). <NAME>_FILE points at
  # <mount>/<key>.
  #   CLOUD_STATE_URL  the cloud_state database URL with the cloud_state
  #                    password (Vault static role pg-cloud-state), for the
  #                    OpenTofu pg backend and the state-schema drop
  #   POSTGRES_PROVISIONER_PASSWORD  cloud_provisioner (pg-cloud-provisioner)
  #   REGISTRY_TOKEN   the read:packages ghcr token from secret/cloud/system
  #                    (ghcr_pull_token), copied into each Project; M5 also
  #                    reads the digest a build pushed with it
  #   GITHUB_DISPATCH_TOKEN, GITHUB_OWNER_READ_TOKEN, FORGEJO_READ_TOKEN,
  #   FORGEJO_ADMIN_TOKEN, SECRETS_PRIVATE_KEY  M5, from secret/cloud/system
  #                    (local.cloud_reconciler_system_keys). These are read
  #                    once at start, so Reloader's restart is what brings a
  #                    rotated value in.
  # Cloud's own database password is the console's cloud-db-creds, read by
  # @viktorbarzin/pg on every new connection like the console does, so it
  # needs no restart (reload = false).
  cloud_reconciler_files = merge(
    {
      DATABASE_PASSWORD             = { secret = "${local.cloud_console_name}-db-creds", secret_key = "DB_PASSWORD", key = "password", mount = "/secrets/db", reload = false }
      CLOUD_STATE_URL               = { secret = "${local.cloud_reconciler}-postgres", secret_key = "state-url", key = "state-url", mount = "/secrets/postgres", reload = true }
      POSTGRES_PROVISIONER_PASSWORD = { secret = "${local.cloud_reconciler}-postgres", secret_key = "provisioner-password", key = "provisioner-password", mount = "/secrets/postgres", reload = true }
      REGISTRY_TOKEN                = { secret = "${local.cloud_reconciler}-registry", secret_key = "token", key = "token", mount = "/secrets/registry", reload = true }
    },
    {
      for env, key in local.cloud_reconciler_system_keys : env => {
        secret = local.cloud_reconciler_system_secret, secret_key = replace(key, "_", "-"), key = replace(key, "_", "-"), mount = "/secrets/system", reload = true
      }
    },
  )

  cloud_reconciler_reload = sort(distinct([for f in local.cloud_reconciler_files : f.secret if f.reload]))

  # Settings besides the files. Everything else stays at the defaults in the
  # cloud repo's src/app.config.ts (`reconciler`), which name this cluster.
  cloud_reconciler_env = concat(
    [
      { name = "DATABASE_URL", value = local.cloud_database_url },
      # The address the SecretStores it renders must carry; admission refuses
      # any other (M2 spike: a VAULT_ADDR from the shell was refused).
      { name = "VAULT_ADDR", value = local.cloud_secretstore_vault_server },
      { name = "POSTGRES_HOST", value = var.postgresql_host },
      # Each job's temporary directory, on the emptyDir; the root
      # filesystem is read-only.
      { name = "RECONCILER_WORK_DIR", value = "/tmp" },
      { name = "HOME", value = "/tmp" },
      # M5 (buildsConfig()). The builder repo, the GitHub owner and the
      # minutes allowance stay at the code's defaults.
      { name = "BUILDS_ENABLED", value = tostring(var.builds_enabled) },
      { name = "FORGEJO_URL", value = local.cloud_forgejo_url },
      { name = "FORGEJO_AUTH_SOURCE_ID", value = tostring(local.cloud_forgejo_auth_source_id) },
      # The images every Project's edge and oauth2-proxy run, from the same
      # locals the admission policies pin (access_rules.tf), so a Renovate
      # bump here moves the rendered image and the policy together. A second
      # pin in the cloud repo drifted on 2026-11-13 and every edge pod was
      # refused.
      { name = "EDGE_IMAGE", value = local.cloud_edge.image },
      { name = "OAUTH2_PROXY_IMAGE", value = local.cloud_oauth2_proxy.image },
    ],
    [for name, f in local.cloud_reconciler_files : { name = "${name}_FILE", value = "${f.mount}/${f.key}" }],
  )
}
