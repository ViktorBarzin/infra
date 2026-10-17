# Inputs for one first-party TanStack Start app (ADR-0001 in ~/code/docs/adr,
# 0001-default-app-stack.md). Defaults follow the ADR; README.md explains each
# choice and the env contract the app reads.

# --- Identity of the app -------------------------------------------------------

variable "name" {
  type        = string
  description = "App slug, a DNS label. Also the namespace, Deployment, Service, container, OAuth client_id, Authentik application slug, Vault KV name and the default database name."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.name))
    error_message = "name is a DNS label: a lowercase letter, then lowercase letters, digits and dashes."
  }
}

variable "display_name" {
  type        = string
  description = "Human name, e.g. \"Tasks\". The Authentik application name and the prefix of the default group names."
}

variable "namespace" {
  type        = string
  default     = null
  description = "Kubernetes namespace. null means var.name."
}

variable "tier" {
  type        = string
  default     = "4-aux"
  description = "Tier label on the namespace and Deployment (local.tiers in the stack)."
}

# --- Image and pod ----------------------------------------------------------------

variable "image" {
  type        = string
  description = "Image repository without a tag, e.g. \"ghcr.io/viktorbarzin/tasks\"."
}

variable "image_tag" {
  type        = string
  description = "Tag used when the Deployment is (re)created. The running tag is set by the app's Woodpecker deploy (kubectl set image), and both image fields are ignore_changes'd (CI_SETS_IMAGE)."
}

variable "replicas" {
  type        = number
  default     = 1
  description = "Pod count. Each pod holds a pool of 4 plus 1 LISTEN connection on the shared Postgres (ADR-0001 budget), so more replicas spend more of it."
}

variable "strategy" {
  type        = string
  default     = "Recreate"
  description = "Deployment strategy. Recreate keeps one realtime LISTEN connection and one writer during a rollout."
}

variable "http_port" {
  type        = number
  default     = 3000
  description = "Port the app serves HTTP on. The image defaults PORT to 3000; any other value is passed as PORT."
}

variable "metrics_port" {
  type        = number
  default     = 9090
  description = "Port that serves /metrics. The image defaults METRICS_PORT to 9090; any other value is passed as METRICS_PORT. The ingress never routes it; the Service's prometheus.io annotations point at it."
}

variable "image_pull_secrets" {
  type        = list(string)
  default     = []
  description = "Pull secrets for a private image, e.g. [\"ghcr-credentials\"] (a ghcr package pushed from a private GitHub repo is private). The namespace must also be on the Kyverno ghcr_private_namespaces allowlist, which copies that Secret in."
}

variable "resources" {
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "50m", memory = "128Mi" }
    limits   = { memory = "256Mi" }
  }
  description = "App container resources. tasks measured about 50 MiB idle."
}

variable "migrate_resources" {
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "50m", memory = "64Mi" }
    limits   = { memory = "256Mi" }
  }
  description = "Resources of the `migrate` init container."
}

variable "app_secret_env" {
  type        = map(string)
  default     = {}
  description = "Env var name -> property in secret/<vault_kv_name>, delivered through the `<name>-secrets` ExternalSecret. Empty means no such ExternalSecret."
}

variable "extra_env" {
  type = list(object({
    name  = string
    value = string
  }))
  default     = []
  description = "Plain env vars appended after the platform env. A list because env order is part of the pod spec."
}

variable "emit_group_env" {
  type        = bool
  default     = true
  description = "Emit AUTH_USERS_GROUP, AUTH_ADMINS_GROUP (and AUTH_AGENTS_GROUP when set) after the platform env. False only for an app that reads its group names from code."
}

# --- Hostnames -----------------------------------------------------------------

variable "root_domain" {
  type        = string
  default     = "viktorbarzin.me"
  description = "Domain the default host sits under."
}

variable "host" {
  type        = string
  default     = null
  description = "Full hostname. null means \"<name>.<root_domain>\". Passed to ingress_factory as full_host only when set."
}

variable "extra_public_origins" {
  type        = list(string)
  default     = []
  description = "Extra https:// origins, appended after https://<host> to PUBLIC_ORIGINS and to the OAuth provider's redirect URIs."
}

variable "tls_secret_name" {
  type        = string
  sensitive   = true
  description = "Wildcard TLS secret name (Kyverno clones it into the namespace)."
}

variable "ingress" {
  type = object({
    dns_type                       = optional(string, "proxied")
    custom_content_security_policy = optional(string, "frame-ancestors 'none'")
    extra_middlewares              = optional(list(string), ["traefik-strip-auth-headers@kubernetescrd"])
    anti_ai_scraping               = optional(bool, false)
    turnstile                      = optional(bool, false)
    homepage_description           = optional(string)
    homepage_icon                  = optional(string)
  })
  default     = {}
  description = <<-EOT
    ingress_factory settings. The ingress is always auth = "app" with the
    default rate limit, whose real-ip plugin sets the X-Real-Ip that Better
    Auth's rate limiter keys on. Defaults:
      custom_content_security_policy  frame-ancestors 'none'. The default
                                      csp-headers middleware lets any
                                      *.<root_domain> page frame the app.
      extra_middlewares               strip-auth-headers, so no public route
                                      carries a client-sent X-authentik-*.
      anti_ai_scraping = false        every page past the sign-in wall needs
                                      a session, so there is nothing to mine,
                                      and the bot-block forwardAuth would sit
                                      on every API call.
      turnstile = false               installed PWAs run in a standalone
                                      webview and a Turnstile pass is tied to
                                      the network that solved it, so a phone
                                      changing networks would meet the
                                      challenge page mid-session.
  EOT
}

variable "ingress_from_namespaces" {
  type        = list(string)
  default     = ["traefik"]
  description = "Namespaces allowed to reach http_port."
}

variable "metrics_from_namespaces" {
  type        = list(string)
  default     = ["monitoring"]
  description = "Namespaces allowed to reach metrics_port."
}

# --- Database ------------------------------------------------------------------

variable "postgresql_host" {
  type        = string
  description = "Shared CNPG host (var.postgresql_host in the stack)."
}

variable "database" {
  type = object({
    name       = optional(string)
    user       = optional(string)
    vault_role = optional(string)
  })
  default     = {}
  description = "Database name, role and Vault static role. Defaults: replace(name, \"-\", \"_\") for both name and user, \"pg-<name>\" for the role. The database comes from the dbaas app_databases map and the role from the vault pg_app_roles map."
}

variable "vault_kv_name" {
  type        = string
  default     = null
  description = "Vault KV v2 secret under mount `secret` holding better_auth_secret, oidc_client_id, oidc_client_secret and any app_secret_env properties. null means var.name."
}

# --- Authentik -------------------------------------------------------------------

variable "authentik_url" {
  type        = string
  default     = "https://authentik.viktorbarzin.me"
  description = "Authentik base URL. AUTHENTIK_API_URL and the issuer and discovery URLs derive from it."
}

variable "signup_mode" {
  type        = string
  default     = "request"
  description = "\"request\": new accounts wait for an admin to approve them in the app. \"open\": sign-up adds them to the users group at once. Open mode is passed to the app as SIGNUP_MODE=open."

  validation {
    condition     = contains(["request", "open"], var.signup_mode)
    error_message = "signup_mode is \"request\" or \"open\"."
  }
}

variable "pending_path" {
  type        = string
  default     = "/pending"
  description = "Path in the app a requester lands on after signing up in request mode."
}

variable "users_group" {
  type        = string
  default     = null
  description = "Member group. null means \"<display_name> Users\"."
}

variable "admins_group" {
  type        = string
  default     = null
  description = "Admin group (approves requests in the app). null means \"<display_name> Admins\"."
}

variable "agents_group" {
  type        = string
  default     = null
  description = "Optional group for non-human clients. null means none is created or bound."
}

variable "initial_user_pks" {
  type        = list(number)
  default     = []
  description = "Authentik user pks seeded into the users group on creation only; later approvals are runtime state. Admins are not members by default, so list the app's owner here too."
}

variable "admin_user_pks" {
  type        = list(number)
  default     = []
  description = "Authentik user pks in the admins group. Authoritative: members added in the Authentik UI are removed on the next apply. In request mode at least one is required, since only an admin can approve access requests."
}

variable "bind_home_server_admins" {
  type        = bool
  default     = true
  description = "Also let Home Server Admins sign in, as for every other app here."
}

variable "oidc_callback_path" {
  type        = string
  default     = "/api/auth/callback/authentik"
  description = "Better Auth 1.7 callback for providerId \"authentik\" (<basePath>/callback/<providerId>)."
}

variable "access_token_validity" {
  type        = string
  default     = "minutes=15"
  description = "ADR-0001: access tokens last 15 minutes at most, so removing someone from the group takes effect within that time."
}

variable "grant_types" {
  type        = list(string)
  default     = ["authorization_code"]
  description = "OAuth grant types. Set explicitly: Authentik 2026.x creates a provider with an empty list, which refuses every authorize request."
}

variable "invalidation_flow" {
  type        = string
  default     = "b0a43377-0fa6-45d1-89fc-ed298bb1bb53"
  description = "default-provider-invalidation-flow, pinned as in stacks/tripit and stacks/f1-stream."
}

variable "reader_managed_by" {
  type        = string
  default     = "infra/modules/kubernetes/tanstack_app"
  description = "managed_by attribute on the membership-reader service account. tasks passes its old path so the attribute stays unchanged."
}
