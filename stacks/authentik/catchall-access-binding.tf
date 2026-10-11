# The "Domain wide catch all" application's own group binding, adopted into
# Terraform 2026-09-19.
#
# WHY THIS FILE EXISTS. Every auth="required" host that is not in
# forward-auth-apps.json is served by the single catch-all forward_domain
# provider, and this binding is its only gate: Home Server Admins, nobody else.
# Removing it would drop every such host to authentik's default of "allow any
# authenticated user".
#
# Until 2026-10-11 a second, UI-managed binding sat at order 10, attaching the
# expression policy "admin-services-restriction" (ADR-0023). From 2026-09-19 it
# returned False, for the reason below. It was deleted with the change that gave
# non-admin hosts their own providers (ADR-0031, forward-auth-apps.tf), and
# deleting the policy removed its binding with it.
#
# WHY THE EXPRESSION POLICY COULD NOT WORK (measured 2026-09-19, ADR-0023 revisited).
# ADR-0023 assumed the policy would be re-evaluated per request with the visited
# host in `request.context["host"]`. It is not. In domain-level forward auth the
# policy engine is never in the per-request path at all: the outpost answers from
# the session cookie and never calls Python. The single evaluation happens once,
# at the OAuth authorize step, against authentik.viktorbarzin.me, where `host` is
# empty and the policy's first branch grants. Authentik's maintainer states the
# consequence directly in goauthentik/authentik discussion #13823: "authorization
# will happen once when the user access anything.my.com and then the user will
# have access to *.my.com without further re-authorization." The product docs say
# the same: domain-level forward auth "cannot restrict individual applications to
# different users with separate application-level policies".
#
# Live proof, not inference: an account in "Pages Readers" only was served 200 on
# learn.viktorbarzin.me and plotting-book.viktorbarzin.me, both listed
# admins-only, the second of them 22 minutes after its one and only
# authorize_application event and with no re-authorization in between. The
# July verification used the policy-test API, which SUPPLIES a host in the test
# context, so it exercised the expression and never the enforcement path.
#
# The pbm_uuid is pinned as a literal for the same reason app-access-bindings.tf
# pins its own: this provider version has no `data "authentik_application"`.
# Re-fetch after an application recreate via `ak shell` in goauthentik-server:
#   Application.objects.get(name="Domain wide catch all").pbm_uuid
#   Group.objects.get(name="Home Server Admins").group_uuid

import {
  to = authentik_policy_binding.catchall_admins
  id = "0b61c3f3-c9dc-4a50-8dfa-3d7862fc8cd7"
}

resource "authentik_policy_binding" "catchall_admins" {
  target = "901c7e95-15cc-4ad7-b68d-1bb515d9ff01" # app "Domain wide catch all"
  group  = "54559f22-54be-4701-9c91-ac8a16cc7d30" # Home Server Admins
  order  = 0
}
