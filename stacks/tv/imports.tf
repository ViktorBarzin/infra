# Adopted from stacks/f1-stream at the tv cutover (f1-stream plan
# 2026-11-01-tv-rebrand, review findings 16 and 17).
#
# stacks/f1-stream released these objects with `removed { destroy = false }`
# blocks before it was destroyed, so they are still live and in nobody's state.
# The first apply of this stack imports each one and renames it in place (app
# slug f1-stream -> tv, group "F1 Users" -> "TV Users", provider and client id
# tv, the service accounts svc-tv and svc-tv-approver), which
# keeps the group's members, the bindings and the zone-wide Cloudflare rulesets.
#
# The ids were read on 2026-11-01 from the f1-stream state through a read-only
# `homelab tf plan f1-stream` of the release change. Per docs/agents/terraform.md
# ("Adopting Existing Resources"): apply, check the plan is clean, then delete
# this file in a follow-up change.

locals {
  cloudflare_zone_id = "fd2c5dd4efe8fe38958944e74d0ced6d"
}

# --- Authentik: sign-in ------------------------------------------------------

import {
  to = authentik_provider_oauth2.tv
  id = "157"
}

import {
  to = authentik_application.tv
  id = "f1-stream" # the slug; the apply changes it to tv
}

import {
  to = authentik_policy_binding.tv_home_users
  id = "2e5ee84d-e6a9-47ec-bec6-3f4060d490ef"
}

import {
  to = authentik_policy_binding.tv_admins
  id = "ed1006dd-5c55-4e58-a502-cf971c2f0cc4"
}

import {
  to = authentik_policy_binding.tv_tv_users
  id = "879dc4eb-3718-4108-a764-b9e6fde20ab7"
}

import {
  to = authentik_policy_binding.tv_access_request
  id = "734e1263-fcc5-4766-8337-a95ef6c480c9"
}

# --- Authentik: TV Users and access requests (modules/authentik/app_signup) --

import {
  to = module.tv_users.authentik_group.users
  id = "255bed1c-4838-4817-90b9-17fafe134837"
}

import {
  to = module.tv_users.authentik_rbac_role.approver[0]
  id = "92bb6313-d869-4471-9167-dd8611751fe0"
}

import {
  to = module.tv_users.authentik_group.approvers[0]
  id = "01e4c6a7-5207-4e26-bcd1-fb513fef8be7"
}

import {
  to = module.tv_users.authentik_user.approver[0]
  id = "322"
}

import {
  to = module.tv_users.authentik_policy_expression.existing_account_request[0]
  id = "2265c958-6229-4478-ad94-d0c5759eaa6b"
}

# --- Authentik: the membership check account --------------------------------

import {
  to = authentik_rbac_role.tv_membership_reader
  id = "acc87fe7-efcf-4f3d-afa4-8c222ceea3ac"
}

import {
  to = authentik_group.tv_membership_readers
  id = "1d8dbd93-eb91-44b4-b87e-04cc6560066b"
}

import {
  to = authentik_user.tv
  id = "282"
}

# Not imported: the three authentik_rbac_permission_role grants (ids 18476,
# 18477 and module.tv_users add_to_group 62526). The provider reads one back
# only with its role already in state, so an import by id fails with
# "permission not found". The apply assigns each permission to its role again;
# Authentik keeps one assignment per role and permission, so the roles end up
# with the same grants.

# --- Authentik: the two f1-stream API tokens, retired ---------------------
#
# Not adopted as the tv tokens: a token imported by id has no key in state
# (the provider reads it only with retrieve_key on an existing resource), so
# an in-place rename would write an empty key into the tv-members Secret on
# the first apply. members.tf and modules/authentik/app_signup mint new tokens
# (svc-tv-membership, svc-tv-approver) for the same two service accounts
# instead, and their keys reach the Secret in the same apply.
#
# The old tokens, which never expire, are imported here as they are so that
# Terraform can delete them: removing this file after the first apply (the
# step the import protocol already asks for) destroys both.

import {
  to = authentik_token.f1_stream_membership_retired
  id = "svc-f1-stream-membership"
}

resource "authentik_token" "f1_stream_membership_retired" {
  identifier  = "svc-f1-stream-membership"
  user        = authentik_user.tv.id
  intent      = "api"
  expiring    = false
  description = "f1-stream membership check. Rotate by tainting this resource."
}

import {
  to = authentik_token.f1_stream_approver_retired
  id = "svc-f1-stream-approver"
}

resource "authentik_token" "f1_stream_approver_retired" {
  identifier = "svc-f1-stream-approver"
  # The approver service account, module.tv_users.authentik_user.approver[0]
  # (pk 322, imported above). The module exposes its username, not its pk.
  user        = 322
  intent      = "api"
  expiring    = false
  description = "f1-stream sign-up approvals. Rotate by tainting this resource."
}

# --- Cloudflare: zone-wide cache and redirect --------------------------------

import {
  to = cloudflare_ruleset.tv_cache
  id = "zones/${local.cloudflare_zone_id}/71a8f64d3dee4b6591ea6e077acc7e18"
}

import {
  to = cloudflare_ruleset.f1_redirect
  id = "zones/${local.cloudflare_zone_id}/c0cbd8386e864c658be642950599f4a0"
}

import {
  to = cloudflare_tiered_cache.zone_smart
  id = local.cloudflare_zone_id
}

import {
  to = cloudflare_argo_tiered_caching.zone_smart
  id = local.cloudflare_zone_id
}
