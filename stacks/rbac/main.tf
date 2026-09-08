variable "tls_secret_name" { type = string }

# HOW THE SSH PROVISIONERS IN THIS STACK GET A KEY (read this before a red pipeline)
#
# modules/rbac has three null_resources that SSH into the control-plane node as
# `wizard@var.k8s_master_host` and edit files under /etc/kubernetes:
#   etcd-tuning.tf       rewrites the etcd static-pod manifest
#   audit-policy.tf      rewrites the kube-apiserver static-pod manifest
#   apiserver-oidc.tf    writes the AuthenticationConfiguration, health-gated
# plus provisioner-ssh-check.tf, which only echoes and proves the path works.
#
# Until 2026-09-04 `var.ssh_private_key` was set nowhere: not in config.tfvars,
# not in terraform.tfvars, and no TF_VAR_ssh_private_key in any pipeline. So the
# provisioners could not run from Woodpecker. It stayed invisible because a
# null_resource only re-runs when its `triggers` change and these were static
# literals, so the resources sat in state untouched. The day one trigger did
# move (2026-09-03, commit 1a9f2e00), pipeline #1495 died with "SSH
# authentication failed (wizard@10.0.20.100:22)", and because a failed apply
# records no success the resource stayed tainted and retried on every later run
# until the trigger was reverted (2b99b471).
#
# The fix: `local.provisioner_ssh_key` below reads a DEDICATED restricted key
# from Vault, so CI resolves one without anybody exporting a variable.
#   private half   Vault secret/ci/infra -> rbac_provisioner_ssh_key
#   public half    Vault secret/ci/infra -> rbac_provisioner_ssh_key_pub, and
#                  wizard's ~/.ssh/authorized_keys on k8s-master, carrying
#                  from="10.0.20.0/24",no-agent-forwarding,no-port-forwarding,
#                  no-X11-forwarding,no-user-rc
#
# The from= is measured, not assumed. A Woodpecker workflow pod reaches
# 10.0.20.100 SNAT'd to the IP of whatever node it landed on, so sshd sees a
# node address (observed 10.0.20.105 on the 2026-09-04 run), never a Calico pod
# IP. The /24 is the node VLAN, so a node added later is covered without anyone
# remembering to edit the line. One consequence worth knowing before you debug
# it: this key does NOT work from the devvm (10.0.10.10). "Permission denied
# (publickey)" when you try it by hand from there is the restriction doing its
# job, not a broken key.
# It is deliberately NOT Viktor's own key: CI holds a credential that can be
# revoked on its own (delete the authorized_keys line and the two Vault keys)
# without touching his access. The k8s-upgrade-pipeline key in
# stacks/k8s-version-upgrade is the same pattern.
#
# CHANGING A TRIGGER IN THOSE THREE FILES IS A CONTROL-PLANE CHANGE. The key
# makes CI able to run them, not safe to run them unattended: etcd-tuning and
# audit-policy both rewrite a static-pod manifest, and on this single-node
# control plane the kubelet restarts etcd or the apiserver when the file
# changes. Move a trigger there only when you mean that restart to happen.

variable "ssh_private_key" {
  type      = string
  default   = ""
  sensitive = true

  description = <<-DESC
    Override for the control-plane SSH key. Leave unset and the stack falls back
    to the dedicated CI key in Vault (secret/ci/infra). Set it (TF_VAR_ssh_private_key)
    only to apply a provisioner with a different identity from a workstation.
  DESC
}

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "platform"
}

# CI credentials for the infra pipeline. Same secret the Woodpecker
# devvm_ssh_key is mirrored from; the `ci` Vault policy grants read on
# secret/data/*, so a Woodpecker apply resolves this with the token it already
# mints via the kubernetes auth backend.
data "vault_kv_secret_v2" "ci_infra" {
  mount = "secret"
  name  = "ci/infra"
}

locals {
  k8s_users = jsondecode(data.vault_kv_secret_v2.secrets.data["k8s_users"])

  # An explicit var wins, so a workstation apply can still use another identity.
  # `try` keeps a keyless apply working (empty string) if the Vault key is ever
  # missing, which is what provisioner-ssh-check.tf's count guard reads.
  provisioner_ssh_key = (
    var.ssh_private_key != ""
    ? var.ssh_private_key
    : try(data.vault_kv_secret_v2.ci_infra.data["rbac_provisioner_ssh_key"], "")
  )
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
  ssh_private_key = local.provisioner_ssh_key

  agent_oidc_enabled = var.agent_oidc_enabled

  # Issuer URL comes from the Authentik application in authentik-kubernetes.tf,
  # so the slug and the trusted issuer cannot drift apart.
  agent_oidc_issuer_url = local.kubernetes_agent_issuer_url
  agent_oidc_client_id  = authentik_provider_oauth2.kubernetes_agent.client_id
}
