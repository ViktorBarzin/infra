# What the console and the reconciler Deployments get (milestone M4): the
# console's cluster role, the env both processes read and the reconciler's
# credential files. Locals only (plus var.postgresql_host), so
# tests/cloud-deploy.test.sh checks them offline against the cloud repo's
# src/server/env.server.ts. console.tf and reconciler.tf turn them into
# resources; docs/architecture/cloud.md has the credentials table.

locals {
  cloud_console_name = "cloud"
  cloud_console_sa   = "cloud-console"
  cloud_reconciler   = "cloud-reconciler"

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
    # Not read by the code yet: M6 points the CLI, MCP discovery and the
    # token verifier at cloud-cli with these (docs/architecture/cloud.md,
    # "Agent sign-in").
    { name = "AGENT_OIDC_CLIENT_ID", value = local.cloud_cli_client_id },
    { name = "AGENT_OIDC_DISCOVERY_URL", value = "${local.cloud_authentik_url}/application/o/${local.cloud_cli_client_id}/.well-known/openid-configuration" },
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
  #                    (ghcr_pull_token), copied into each Project
  # Cloud's own database password is the console's cloud-db-creds, read by
  # @viktorbarzin/pg on every new connection like the console does, so it
  # needs no restart (reload = false).
  cloud_reconciler_files = {
    DATABASE_PASSWORD             = { secret = "${local.cloud_console_name}-db-creds", secret_key = "DB_PASSWORD", key = "password", mount = "/secrets/db", reload = false }
    CLOUD_STATE_URL               = { secret = "${local.cloud_reconciler}-postgres", secret_key = "state-url", key = "state-url", mount = "/secrets/postgres", reload = true }
    POSTGRES_PROVISIONER_PASSWORD = { secret = "${local.cloud_reconciler}-postgres", secret_key = "provisioner-password", key = "provisioner-password", mount = "/secrets/postgres", reload = true }
    REGISTRY_TOKEN                = { secret = "${local.cloud_reconciler}-registry", secret_key = "token", key = "token", mount = "/secrets/registry", reload = true }
  }

  cloud_reconciler_reload = sort(distinct([for f in local.cloud_reconciler_files : f.secret if f.reload]))

  # Settings besides the files. Everything else stays at the defaults in the
  # cloud repo's src/app.config.ts (`reconciler`), which name this cluster.
  cloud_reconciler_env = concat(
    [
      { name = "DATABASE_URL", value = "postgres://cloud@${var.postgresql_host}:5432/cloud" },
      # The address the SecretStores it renders must carry; admission refuses
      # any other (M2 spike: a VAULT_ADDR from the shell was refused).
      { name = "VAULT_ADDR", value = local.cloud_secretstore_vault_server },
      { name = "POSTGRES_HOST", value = var.postgresql_host },
      # Each job's temporary directory, on the emptyDir; the root
      # filesystem is read-only.
      { name = "RECONCILER_WORK_DIR", value = "/tmp" },
      { name = "HOME", value = "/tmp" },
    ],
    [for name, f in local.cloud_reconciler_files : { name = "${name}_FILE", value = "${f.mount}/${f.key}" }],
  )
}
