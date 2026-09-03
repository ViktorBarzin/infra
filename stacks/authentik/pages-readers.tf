# "Pages Readers" — a non-admin, read-only door to pages.viktorbarzin.me.
#
# Why a group rather than adding someone to "Home Server Admins": that group is
# the break-glass identity in admin-services-restriction.tf and passes every
# forward-auth host, so using it to share one page would hand over the whole
# estate. This group is named on exactly one ingress (module "ingress_pages" in
# stacks/learn), and the Caddyfile there gives each identity its own static
# try_files list, so a Pages Reader sees only their own pages/<user>/ space.
#
# ORDERING, and it matters: the authorization table in this stack is GENERATED
# from the live ingress annotations at apply time. stacks/learn must be applied
# BEFORE this stack, or the table is rebuilt from the old annotation and the new
# group is granted nothing. That is why the two halves landed as two pushes
# (2026-09-03).
#
# Membership is declared here rather than left to the Authentik UI (the pattern
# "TripIt Users" uses), because the group has one member for one purpose and the
# commit is the record of who was let in and when. Removing her is deleting a
# line. Usernames in this instance are email addresses, verified live against
# /api/v3/core/users on 2026-09-03.

data "authentik_user" "anca" {
  # "Anca Milea", last login 2026-07-26, already in Wrongmove / Headscale /
  # Forgejo / TripIt Users. NOT anca.r.cristian10@gmail.com — that second
  # account of hers last logged in Jul 2025 and holds only Wrongmove.
  username = "ancaelena98@gmail.com"
}

resource "authentik_group" "pages_readers" {
  name = "Pages Readers"
  users = [
    data.authentik_user.anca.id,
  ]
}
