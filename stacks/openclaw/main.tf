variable "tls_secret_name" { type = string }
variable "openclaw_ssh_key" { type = string }
variable "openclaw_skill_secrets" { type = map(string) }
variable "gemini_api_key" { type = string }
variable "llama_api_key" { type = string }
variable "brave_api_key" { type = string }
variable "modal_api_key" { type = string }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

module "openclaw" {
  source = "../../modules/kubernetes/openclaw"
  tls_secret_name                = var.tls_secret_name
  git_crypt_key_base64           = filebase64("${path.root}/../../.git/git-crypt/keys/default")
  ssh_key                        = var.openclaw_ssh_key
  skill_secrets                  = var.openclaw_skill_secrets
  gemini_api_key                 = var.gemini_api_key
  llama_api_key                  = var.llama_api_key
  brave_api_key                  = var.brave_api_key
  modal_api_key                  = var.modal_api_key
  tier                           = local.tiers.aux
}
