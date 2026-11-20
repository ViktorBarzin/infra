# The notify pipe's Authentik half (design: docs/plans/2026-11-17-notify-pipe-
# design.md, ADR-0043). Each person's notification settings live in their
# user attributes, key `notify` (stacks/notify/files/subs.py lists the keys).
# Two parts:
#
# 1. A service account, notify-settings, that the settings page
#    https://notify.viktorbarzin.me (stacks/notify/files/page.py) uses to read
#    people's settings and write the signed-in person's own. The adapter also
#    reads everyone's settings with it to route each alert.
# 2. Push, no polling: on every User model_updated event (the page's save is
#    one) a Notification Rule calls a webhook transport whose body mapping
#    (files/notify_render.py) renders every person's Channels and POSTs them
#    to apprise-api /add/notify, replacing the stored config.

# --- 1. The settings page's service account -------------------------------
#
# Its role holds view_user and change_user, both global. change_user is what
# writing attributes takes, and it is broad: whoever holds the token can edit
# any account through the API, not only `notify` attributes. Viktor chose this
# over moving the settings out of Authentik (2026-11-20). What limits it:
#   - The token lives only in the Secret notify-authentik-token in namespace
#     notify, mounted into the adapter pod. Nothing else reads it.
#   - The page writes only the signed-in person's own `notify` key; the
#     identity comes from forward auth plus an ingress-only header
#     (stacks/notify/ingress.tf).
# Rotate: taint authentik_token.notify_settings and apply; the kubelet
# refreshes the mounted Secret and the adapter reads it on every call.

resource "authentik_rbac_role" "notify_settings" {
  name = "notify settings"
}

resource "authentik_rbac_permission_role" "notify_settings" {
  for_each   = toset(["authentik_core.view_user", "authentik_core.change_user"])
  role       = authentik_rbac_role.notify_settings.id
  permission = each.value
}

resource "authentik_group" "notify_settings" {
  name  = "notify settings"
  roles = [authentik_rbac_role.notify_settings.id]
  # Holds only the service account below, which the user resource adds.
  lifecycle {
    ignore_changes = [users]
  }
}

resource "authentik_user" "notify_settings" {
  username = "notify-settings"
  name     = "Notify pipe (settings page)"
  type     = "service_account"
  path     = "goauthentik.io/service-accounts"
  groups   = [authentik_group.notify_settings.id]
  attributes = jsonencode({
    managed_by = "infra/stacks/authentik/notify.tf"
    purpose    = "The notify settings page reads people's notify attributes and writes the signed-in person's own"
  })
}

resource "authentik_token" "notify_settings" {
  identifier   = "notify-settings"
  user         = authentik_user.notify_settings.id
  intent       = "api"
  retrieve_key = true
  # Non-expiring: a lapsed token would silently stop every notification.
  expiring    = false
  description = "notify-adapter: the settings page and alert routing. Rotate by tainting this resource."
}

resource "kubernetes_secret" "notify_authentik_token" {
  metadata {
    name      = "notify-authentik-token"
    namespace = "notify"
  }
  data = {
    token = authentik_token.notify_settings.key
  }
}

# --- 2. Push the rendered config to Apprise ---------------------------------

data "kubernetes_secret" "apprise_admin" {
  metadata {
    name      = "apprise-admin"
    namespace = "notify"
  }
}

resource "authentik_property_mapping_notification" "notify_render" {
  name       = "notify-render-apprise-config"
  expression = file("${path.module}/files/notify_render.py")
}

resource "authentik_property_mapping_notification" "notify_apprise_auth" {
  name       = "notify-apprise-auth"
  expression = "return {'Authorization': 'Basic ${base64encode("${data.kubernetes_secret.apprise_admin.data["APPRISE_USER"]}:${data.kubernetes_secret.apprise_admin.data["APPRISE_PASSWORD"]}")}'}"
}

resource "authentik_event_transport" "notify_apprise" {
  name                    = "notify-apprise-config"
  mode                    = "webhook"
  webhook_url             = "http://apprise.notify.svc.cluster.local:8000/add/notify"
  webhook_mapping_body    = authentik_property_mapping_notification.notify_render.id
  webhook_mapping_headers = authentik_property_mapping_notification.notify_apprise_auth.id
  send_once               = true
}

# Every User save, the settings page's included. Other saves cause a harmless
# rewrite of the same config.
resource "authentik_policy_event_matcher" "notify_user_updated" {
  name   = "notify-user-updated"
  action = "model_updated"
  app    = "authentik.core"
  model  = "authentik_core.user"
}

resource "authentik_event_rule" "notify_user_updated" {
  name                   = "notify-sync-on-user-updated"
  severity               = "notice"
  destination_event_user = true
  transports             = [authentik_event_transport.notify_apprise.id]
}

resource "authentik_policy_binding" "notify_user_updated" {
  target = authentik_event_rule.notify_user_updated.id
  policy = authentik_policy_event_matcher.notify_user_updated.id
  order  = 0
}
