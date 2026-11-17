# "Deal Watchers": the people who may add, list and remove deal watches
# (docs/runbooks/deal-watches.md). Created 2026-11-17.
#
# Membership gives two things:
#   - the changedetection web UI: its ingress names this group in
#     allowed_groups, and forward-auth-apps.json gives the host its own
#     forward_single application bound to it;
#   - the changedetection API key for `homelab deals`: the Vault external
#     group "deal-watchers" (stacks/vault) maps this group to a policy that
#     reads secret/workstation/shared/deal-watches. That covers OIDC logins.
#     A devvm periodic token carries no group, so a member who works from the
#     devvm also needs that path in the policy their token holds (projects-emo
#     for emo; vault-admin covers wizard).
#
# Both can change every watch: the list is one list for the household.
# Membership is declared here and is authoritative.
resource "authentik_group" "deal_watchers" {
  name = "Deal Watchers"
  users = [
    data.authentik_user.wizard.id,
    data.authentik_user.emo.id,
  ]
}
