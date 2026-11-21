# Who may write where on Forgejo, kept in Terraform (enforced-identity plan,
# docs/plans/2026-11-15-enforced-identity-design.md). Before this, the push
# list and the collaborators of viktor/infra were set by hand in the web UI.
#
# viktor/infra is special: CI applies every push to master with cluster-admin
# rights, so a write there is admin. Only Viktor and the two bots push to
# master. Everyone else reads it and sends a pull request from a fork, which
# Woodpecker runs only after Viktor approves it (require_approval = forks).

variable "forgejo_people" {
  type        = map(string)
  description = "Forgejo username -> Authentik username (config.tfvars)."
}

data "vault_kv_secret_v2" "ci_global" {
  mount = "secret"
  name  = "ci/global"
}

provider "forgejo" {
  host      = "https://forgejo.viktorbarzin.me"
  api_token = data.vault_kv_secret_v2.ci_global.data["forgejo_repo_token"]
}

data "forgejo_repository" "infra" {
  owner = "viktor"
  name  = "infra"
}

locals {
  # The bots that push to viktor/infra master: infra-agent lands agent fixes,
  # renovate-bot lands dependency bumps.
  infra_pushers = ["infra-agent", "renovate-bot", "viktor"]
  infra_collaborators = {
    "infra-agent"  = "write"
    "renovate-bot" = "write"
    # emo lands infra changes as pull requests from ebarzin/infra since
    # 2026-11-15. A write here would let his branch pipelines run with the
    # repo's secrets.
    "ebarzin" = "read"
  }
}

resource "forgejo_collaborator" "infra" {
  for_each      = local.infra_collaborators
  repository_id = data.forgejo_repository.infra.id
  user          = each.key
  permission    = each.value
}

resource "forgejo_branch_protection" "infra_master" {
  branch_name   = "master"
  repository_id = data.forgejo_repository.infra.id

  enable_push              = true
  enable_push_whitelist    = true
  push_whitelist_usernames = local.infra_pushers

  enable_merge_whitelist    = true
  merge_whitelist_usernames = ["renovate-bot", "viktor"]
}

# viktor/infra-map is private. Infra reads its sites/ directory at runtime
# through the Forgejo API (stacks/infra-map, repo README "Site data") as
# infra-map-reader: a restricted account, so this Read grant is the only repo
# it can see. Its one read:repository token is Vault secret/infra-map
# forgejo_read_token. The account was made with the in-pod CLI
# (docs/runbooks/cloud.md, "Forgejo bot accounts", has the commands).
data "forgejo_repository" "infra_map" {
  owner = "viktor"
  name  = "infra-map"
}

resource "forgejo_collaborator" "infra_map_reader" {
  repository_id = data.forgejo_repository.infra_map.id
  user          = "infra-map-reader"
  permission    = "read"
}
