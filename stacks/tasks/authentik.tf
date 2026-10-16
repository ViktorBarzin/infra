# Identity for the TypeScript tasks build (ADR-0001 in ~/code/docs/adr,
# "Identity and access" and "Pilot: port tasks").
#
# The running tasks image still signs people in through forward-auth on
# tasks.viktorbarzin.me (main.tf) and does not use anything in this file. The
# TypeScript build signs in with Better Auth's generic OAuth plugin against
# the OAuth2 application below, first on tasks-next.viktorbarzin.me while it is
# compared with the old build, then on tasks.viktorbarzin.me after cutover.
# Nothing here changes the Deployment, the ingresses or the NetworkPolicy.
#
# Who can sign in:
#   Tasks Users         the app's members. Seeded with the people who already
#                       have a Connected Account, so they skip request +
#                       approve. New people ask for access through the
#                       request + approve sign-up path (module.signup).
#   Tasks Admins        approve requests inside the app.
#   Home Server Admins  as for every other app here.
#
# Secrets. secret/tasks in Vault KV holds, next to fernet_key:
#   better_auth_secret  Better Auth's signing and encryption secret
#   oidc_client_id      "tasks", the client_id below
#   oidc_client_secret  the confidential client's secret
# They were seeded by hand on 2026-10-16, as fernet_key was. CI's Vault role
# can read secret/* but not write it, so this stack reads the client secret
# from Vault rather than generating it. To rotate it, write a new value to
# secret/tasks and apply this stack; the ExternalSecret below picks it up
# within its refresh interval. The approver token is minted by Terraform and
# goes to a Secret in the tasks namespace, as in stacks/f1-stream/members.tf.

data "vault_kv_secret_v2" "authentik_tf" {
  mount = "secret"
  name  = "authentik"
}

data "vault_kv_secret_v2" "tasks" {
  mount = "secret"
  name  = "tasks"
}

provider "authentik" {
  url   = "https://authentik.viktorbarzin.me"
  token = data.vault_kv_secret_v2.authentik_tf.data["tf_api_token"]
}

locals {
  tasks_hosts = [
    "https://tasks.viktorbarzin.me",
    "https://tasks-next.viktorbarzin.me",
  ]
  # Better Auth 1.7 serves every OAuth callback, generic OAuth included, at
  # <basePath>/callback/<providerId> (getOAuthCallbackPath in
  # better-auth/dist/oauth2/utils.mjs, 1.7.10). Before 1.7 the generic OAuth
  # plugin used /api/auth/oauth2/callback/<providerId>. The app configures its
  # provider with providerId "authentik".
  tasks_oidc_callback_path = "/api/auth/callback/authentik"
}

data "authentik_flow" "default_authorization_implicit_consent" {
  slug = "default-provider-authorization-implicit-consent"
}

# Without a signing key Authentik signs HS256 and publishes an empty JWKS.
data "authentik_certificate_key_pair" "signing" {
  name = "authentik Self-signed Certificate"
}

data "authentik_property_mapping_provider_scope" "openid" {
  managed = "goauthentik.io/providers/oauth2/scope-openid"
}

# Carries `groups` and `preferred_username`. The app matches existing
# Connected Account rows on preferred_username once, at cutover.
data "authentik_property_mapping_provider_scope" "profile" {
  managed = "goauthentik.io/providers/oauth2/scope-profile"
}

data "authentik_property_mapping_provider_scope" "email" {
  managed = "goauthentik.io/providers/oauth2/scope-email"
}

data "authentik_group" "home_server_admins" {
  name          = "Home Server Admins"
  include_users = false
}

# Usernames in this instance are email addresses. On 2026-10-16 the tasks
# database had one Connected Account (connected_accounts.authentik_username).
data "authentik_user" "viktor" {
  username = "vbarzin@gmail.com"
}

resource "authentik_provider_oauth2" "tasks" {
  name          = "tasks"
  client_id     = "tasks" # mirrored in secret/tasks oidc_client_id for the ExternalSecret
  client_type   = "confidential"
  client_secret = data.vault_kv_secret_v2.tasks.data["oidc_client_secret"]

  authorization_flow = data.authentik_flow.default_authorization_implicit_consent.id
  # Pinned literal, as in stacks/tripit/authentik.tf and stacks/f1-stream:
  # default-provider-invalidation-flow.
  invalidation_flow = "b0a43377-0fa6-45d1-89fc-ed298bb1bb53"

  allowed_redirect_uris = [
    for host in local.tasks_hosts : {
      matching_mode     = "strict"
      url               = "${host}${local.tasks_oidc_callback_path}"
      redirect_uri_type = "authorization"
    }
  ]

  # The app keys users on `sub` and never on email. The issuer is
  # https://authentik.viktorbarzin.me/application/o/tasks/, which the app's
  # token verifier pins along with RS256 and aud = client_id.
  sub_mode    = "hashed_user_id"
  issuer_mode = "per_provider"
  signing_key = data.authentik_certificate_key_pair.signing.id

  # ADR-0001: access tokens last 15 minutes at most, so removing someone from
  # the group takes effect within that time.
  access_token_validity      = "minutes=15"
  include_claims_in_id_token = true

  # Web sign-in does not request offline_access, so no offline_access
  # mapping and no refresh_token grant. Device-code login for CLIs is a
  # separate decision (ADR-0001, "API tokens").
  property_mappings = [
    data.authentik_property_mapping_provider_scope.openid.id,
    data.authentik_property_mapping_provider_scope.profile.id,
    data.authentik_property_mapping_provider_scope.email.id,
  ]

  # Authentik 2026.x creates a provider with an empty list, which refuses every
  # authorize request.
  grant_types = ["authorization_code"]
}

resource "authentik_application" "tasks" {
  name               = "Tasks"
  slug               = "tasks"
  protocol_provider  = authentik_provider_oauth2.tasks.id
  meta_launch_url    = "https://tasks.viktorbarzin.me"
  policy_engine_mode = "any"
}

# "Tasks Users" and request + approve sign-up. app_slug must match the
# application slug above: the shared sign-up flow (stacks/authentik/
# app-signup.tf) finds this group through it. After sign-up a requester lands
# on pending_url. That page exists only in the TypeScript build, so until
# cutover tasks.viktorbarzin.me answers it with the old build behind
# forward-auth.
module "signup" {
  source = "../../modules/authentik/app_signup"

  app_slug      = authentik_application.tasks.slug
  group_name    = "Tasks Users"
  mode          = "request"
  pending_url   = "https://tasks.viktorbarzin.me/pending"
  initial_users = [data.authentik_user.viktor.id]
}

# Approves requests inside the app. Membership is declared here and is
# authoritative.
resource "authentik_group" "tasks_admins" {
  name  = "Tasks Admins"
  users = [data.authentik_user.viktor.id]
}

# Every binding is a group membership check, which app-access-guard.tf in the
# authentik stack requires under policy_engine_mode "any".
resource "authentik_policy_binding" "tasks_users" {
  target = authentik_application.tasks.uuid
  group  = module.signup.group_id
  order  = 0
}

resource "authentik_policy_binding" "tasks_admins" {
  target = authentik_application.tasks.uuid
  group  = authentik_group.tasks_admins.id
  order  = 1
}

resource "authentik_policy_binding" "tasks_home_server_admins" {
  target = authentik_application.tasks.uuid
  group  = data.authentik_group.home_server_admins.id
  order  = 2
}

# --- Secrets for the TypeScript build ------------------------------------------
#
# Neither Secret is referenced by the running Deployment.

resource "kubernetes_secret" "authentik_approver" {
  metadata {
    name      = "tasks-authentik-approver"
    namespace = kubernetes_namespace.tasks.metadata[0].name
  }
  data = {
    AUTHENTIK_APPROVER_TOKEN = module.signup.approver_token
    AUTHENTIK_USERS_GROUP_ID = module.signup.group_id
  }
}

resource "kubernetes_manifest" "auth_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "tasks-auth"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "tasks-auth"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
        }
      }
      data = [
        { secretKey = "BETTER_AUTH_SECRET", remoteRef = { key = "tasks", property = "better_auth_secret" } },
        { secretKey = "OIDC_CLIENT_ID", remoteRef = { key = "tasks", property = "oidc_client_id" } },
        { secretKey = "OIDC_CLIENT_SECRET", remoteRef = { key = "tasks", property = "oidc_client_secret" } },
      ]
    }
  }
  depends_on = [kubernetes_namespace.tasks]
}
