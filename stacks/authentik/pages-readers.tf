# "Pages Readers" — a non-admin, read-only door to pages.viktorbarzin.me.
#
# Why a group rather than adding someone to "Home Server Admins": that group is
# the break-glass identity in admin-services-restriction.tf and passes every
# forward-auth host, so using it to share one page would hand over the whole
# estate. This group is named on exactly one ingress (module "ingress_pages" in
# stacks/learn), and the Caddyfile there gives each identity its own static
# try_files list, so a Pages Reader sees only their own pages/<user>/ space.
#
# ORDERING, and it cost three pipelines on 2026-09-03 to get right. Two rules
# pull in opposite directions:
#
#   1. scripts/check-allowed-groups.py is STATIC. It scans the repo for
#      authentik_group names, so this file must be in the SAME commit as the
#      ingress that names "Pages Readers", or that stack fails before apply.
#   2. The authorization table in admin-services-restriction.tf is GENERATED
#      from live ingress annotations at apply time. Within one pipeline this
#      stack runs before stacks/learn, so it rebuilds the table from the
#      annotation that learn is about to replace, and the new group is granted
#      nothing.
#
# So the sequence is: land both stacks together (satisfies 1), then apply THIS
# stack once more (satisfies 2). Verified after the fact by reading
# /api/v3/policies/expression/07a11b85-.../ and checking that the HOST_GROUPS
# row for pages.viktorbarzin.me actually lists the group. If you ever add
# another non-admin group to an ingress, expect the same two-phase sequence.
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
