# Signed-in Members of tv.viktorbarzin.me, formerly f1.viktorbarzin.me
# (f1-stream ADR-0025, ADR-0021, ADR-0042, ADR-0053).
#
# Anyone in "Home Users" or "F1 Users" may sign in to the site, keep their own
# channel order (My channels) and pair a TV that shows it. Home Server Admins
# pass as well. Home Users is the household (stacks/authentik/home-users.tf,
# infra ADR-0031). F1 Users is for other households, who ask from an unpaired
# TV and are let in by an admin in the app (ADR-0042, "Access requests"
# below), whether they sign up there or already had an Authentik account;
# Terraform declares that group but not its members. The app reads
# both names from MEMBER_GROUPS (main.tf).
# Design: f1-stream docs/design/2026-10-10-my-channels.md; wire format:
# docs/design/2026-10-10-my-channels-build-contract.md.
#
# WHY OIDC AND NOT A FORWARD-AUTH PATH. The /admin/login and /pair carve-outs in
# main.tf and tv-pairing.tf sit behind the domain-wide forward-auth
# application, which admits Home Server Admins only (infra ADR-0031 has the
# reasoning). A member of any other group is refused there before the request
# reaches the app. A per-host forward_single application cannot help here
# either, because its login callback would land on the public "/" route. An
# OAuth2 application of its own is how TripIt solved the same problem for its
# website (stacks/tripit/authentik.tf): Authentik enforces the group bindings
# below at the authorize step, the app checks the groups claim again and mints
# its own session cookie.
#
# Membership is declared in stacks/authentik/home-users.tf, which also owns the
# group; this stack only reads it. stacks/authentik is a platform stack and
# applies before this one in the same pipeline, so the group exists by the
# time this plan reads it.
#
# Secrets never leave Terraform state. The OIDC client secret and the
# membership API token were generated and minted here and went straight into
# the f1-stream-members Secret, the way ingress-proof.tf handles its shared
# value. Since the tv rename both are owned by stacks/tv (see below).

data "vault_kv_secret_v2" "authentik_tf" {
  mount = "secret"
  name  = "authentik"
}

provider "authentik" {
  url   = "https://authentik.viktorbarzin.me"
  token = data.vault_kv_secret_v2.authentik_tf.data["tf_api_token"]
}

data "authentik_group" "home_users" {
  name          = "Home Users"
  include_users = false
}

data "authentik_group" "home_server_admins" {
  name          = "Home Server Admins"
  include_users = false
}

data "authentik_group" "f1_users" {
  name          = "F1 Users"
  include_users = false
}

# --- Handed over to stacks/tv (f1-stream plan 2026-11-01-tv-rebrand) ---------
#
# The project is being renamed to tv. stacks/tv adopts the Authentik objects
# below with import blocks and renames them in place (app slug tv, group
# "TV Users"), after stacks/f1-stream has been destroyed by hand during the
# cutover. Until then they keep working exactly as they are; this stack only
# stops tracking them, so the destroy leaves them, the F1 Users group and its
# members, and the access-request grants in place (plan review finding 16).
#
# The f1-stream-members Secret holds the OIDC client secret and both API
# tokens. It is released too rather than rebuilt from the objects it was
# derived from, so the running pods keep reading the same values; it goes
# with the namespace when the stack is destroyed. stacks/tv writes its own.
#
# The resource definitions these replace are in this file's history
# (git log -- stacks/f1-stream/members.tf) and in stacks/tv/members.tf.

removed {
  from = random_password.oidc_client_secret
  lifecycle {
    destroy = false
  }
}

removed {
  from = authentik_provider_oauth2.f1_stream
  lifecycle {
    destroy = false
  }
}

removed {
  from = authentik_application.f1_stream
  lifecycle {
    destroy = false
  }
}

removed {
  from = authentik_policy_binding.f1_stream_home_users
  lifecycle {
    destroy = false
  }
}

removed {
  from = authentik_policy_binding.f1_stream_admins
  lifecycle {
    destroy = false
  }
}

removed {
  from = authentik_policy_binding.f1_stream_f1_users
  lifecycle {
    destroy = false
  }
}

removed {
  from = authentik_policy_binding.f1_stream_access_request
  lifecycle {
    destroy = false
  }
}

# The F1 Users group, the sign-up approver role, its add-to-group grant, the
# approver group, service account and token, and the access-request policy.
removed {
  from = module.f1_users
  lifecycle {
    destroy = false
  }
}

removed {
  from = authentik_rbac_role.f1_membership_reader
  lifecycle {
    destroy = false
  }
}

removed {
  from = authentik_rbac_permission_role.f1_view_user
  lifecycle {
    destroy = false
  }
}

removed {
  from = authentik_rbac_permission_role.f1_view_group
  lifecycle {
    destroy = false
  }
}

removed {
  from = authentik_group.f1_membership_readers
  lifecycle {
    destroy = false
  }
}

removed {
  from = authentik_user.f1_stream
  lifecycle {
    destroy = false
  }
}

removed {
  from = authentik_token.f1_membership
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_secret.f1_members
  lifecycle {
    destroy = false
  }
}

# Forgotten on 2026-10-11 after the authentik stack deleted the F1 Users
# group and the deletion cascaded to this binding.
removed {
  from = authentik_policy_binding.f1_stream_members
  lifecycle {
    destroy = false
  }
}
