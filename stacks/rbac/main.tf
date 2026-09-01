variable "tls_secret_name" { type = string }
variable "ssh_private_key" {
  type      = string
  default   = ""
  sensitive = true
}

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "platform"
}

locals {
  k8s_users = jsondecode(data.vault_kv_secret_v2.secrets.data["k8s_users"])
}

# Agent issuer for the kube-apiserver (design step 4). Default false, so a plain
# apply renders the SAME AuthenticationConfiguration the control plane already
# runs and the module's SSH provisioner stays a no-op. Enabling it is a local
# apply against k8s-master, per docs/runbooks/apiserver-oidc-agent-identity.md.
variable "agent_oidc_enabled" {
  type    = bool
  default = false
}

module "rbac" {
  source          = "./modules/rbac"
  tier            = local.tiers.cluster
  tls_secret_name = var.tls_secret_name
  k8s_users       = local.k8s_users
  ssh_private_key = var.ssh_private_key

  agent_oidc_enabled = var.agent_oidc_enabled

  # Issuer URL comes from the Authentik application in authentik-kubernetes.tf,
  # so the slug and the trusted issuer cannot drift apart.
  agent_oidc_issuer_url = local.kubernetes_agent_issuer_url
  agent_oidc_client_id  = authentik_provider_oauth2.kubernetes_agent.client_id
}
