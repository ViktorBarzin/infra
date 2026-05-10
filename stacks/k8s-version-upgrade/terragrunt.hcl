include "root" {
  path = find_in_parent_folders()
}

# ExternalSecret hits ESO which needs to be alive when the manifest applies.
dependency "external_secrets" {
  config_path  = "../external-secrets"
  skip_outputs = true
}

# Upgrade Gates rules (incl. K8sVersionSkew + EtcdPreUpgradeSnapshotMissing)
# live in the monitoring stack — make the relationship visible so reapplies
# don't race the alerts being available.
dependency "monitoring" {
  config_path  = "../monitoring"
  skip_outputs = true
}

# Note: stacks/claude-agent-service has no terragrunt.hcl yet (manual apply
# pattern) — its ServiceAccount + Namespace are referenced by name from this
# stack's RoleBindings, which is fine because RoleBindings allow forward
# references. Apply order: claude-agent-service first (or already deployed),
# then this stack.
