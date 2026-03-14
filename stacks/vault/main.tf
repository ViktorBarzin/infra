variable "tls_secret_name" {
  type      = string
  sensitive = true
}

variable "vault_authentik_client_id" { type = string }
variable "vault_authentik_client_secret" {
  type      = string
  sensitive = true
}
resource "kubernetes_namespace" "vault" {
  metadata {
    name = "vault"
    labels = {
      tier = local.tiers.core
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.vault.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "helm_release" "vault" {
  name             = "vault"
  namespace        = kubernetes_namespace.vault.metadata[0].name
  create_namespace = false
  repository       = "https://helm.releases.hashicorp.com"
  chart            = "vault"
  version          = "0.29.1"
  atomic           = true
  timeout          = 300

  values = [yamlencode({
    global = {
      enabled = true
    }

    server = {
      enabled = true

      resources = {
        requests = { memory = "64Mi", cpu = "50m" }
        limits   = { memory = "256Mi" }
      }

      dataStorage = {
        enabled      = true
        size         = "1Gi"
        storageClass = "nfs-truenas"
      }

      standalone = {
        enabled = true
        config  = <<-EOT
          ui = true

          listener "tcp" {
            tls_disable = 1
            address     = "[::]:8200"
            cluster_address = "[::]:8201"
          }

          storage "file" {
            path = "/vault/data"
          }
        EOT
      }

      ha = {
        enabled = false
      }
    }

    ui = {
      enabled = true
    }

    injector = {
      enabled = false
    }

    csi = {
      enabled = false
    }
  })]
}

# --- OIDC Authentication via Authentik ---

resource "vault_jwt_auth_backend" "oidc" {
  path               = "oidc"
  type               = "oidc"
  oidc_discovery_url = "https://authentik.viktorbarzin.me/application/o/vault/"
  oidc_client_id     = var.vault_authentik_client_id
  oidc_client_secret = var.vault_authentik_client_secret
  default_role       = "default"
  tune {
    listing_visibility = "hidden"
  }
  depends_on = [helm_release.vault]
}

resource "vault_jwt_auth_backend_role" "default" {
  backend        = vault_jwt_auth_backend.oidc.path
  role_name      = "default"
  token_policies = ["default"]
  token_ttl      = 3600
  token_max_ttl  = 86400
  user_claim     = "email"
  groups_claim   = "groups"
  role_type      = "oidc"
  allowed_redirect_uris = [
    "https://vault.viktorbarzin.me/ui/vault/auth/oidc/oidc/callback",
    "http://localhost:8250/oidc/callback",
  ]
  oidc_scopes = ["openid", "email", "profile"]
}

resource "vault_policy" "admin" {
  name   = "vault-admin"
  policy = <<-EOT
    path "*" {
      capabilities = ["create", "read", "update", "delete", "list", "sudo"]
    }
  EOT
}

resource "vault_identity_group" "admins" {
  name     = "authentik-admins"
  type     = "external"
  policies = [vault_policy.admin.name]
}

resource "vault_identity_group_alias" "admins" {
  name           = "authentik Admins"
  mount_accessor = vault_jwt_auth_backend.oidc.accessor
  canonical_id   = vault_identity_group.admins.id
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.vault.metadata[0].name
  name            = "vault"
  tls_secret_name = var.tls_secret_name
  port            = 8200
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Vault"
    "gethomepage.dev/description"  = "HashiCorp Vault - Secrets Management"
    "gethomepage.dev/icon"         = "vault.png"
    "gethomepage.dev/group"        = "Core Platform"
    "gethomepage.dev/pod-selector" = ""
  }
}
