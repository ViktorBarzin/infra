# The notify pipe's Authentik half (design: docs/plans/2026-11-17-notify-pipe-
# design.md, ADR-0043). Two parts:
#
# 1. A settings page, https://authentik.viktorbarzin.me/if/flow/notify-settings/,
#    where each Recipient sets their own Channels (a Home Assistant push
#    target, an email address), a choice of Channel per Topic, and a default
#    channel. A prompt stage plus a never-create user_write stage writes them
#    to the signed-in user's attributes.notify.
# 2. Push, no polling: on every user_write and every User model_updated event a
#    Notification Rule calls a webhook transport whose body mapping
#    (files/notify_render.py) renders every Recipient's Apprise config and
#    POSTs it to apprise-api /add/notify, replacing the stored config.

locals {
  # The fixed Topic list, shared with the notify stack and its adapter.
  notify_topics = jsondecode(file("${path.module}/../notify/topics.json"))
  notify_channel_choices = jsonencode([
    { label = "Off", value = "off" },
    { label = "Phone (Home Assistant)", value = "push" },
    { label = "Email", value = "email" },
  ])
}

# --- 1. The settings page ---------------------------------------------------

resource "authentik_stage_prompt_field" "notify_push_instance" {
  name                     = "notify-push-instance"
  field_key                = "attributes.notify.push_instance"
  label                    = "Phone: Home Assistant instance"
  type                     = "dropdown"
  required                 = false
  placeholder_expression   = true
  placeholder              = <<-EOT
    return [
        {"label": "None", "value": "none"},
        {"label": "ha-sofia", "value": "ha-sofia"},
        {"label": "ha-london", "value": "ha-london"},
    ]
  EOT
  initial_value_expression = true
  initial_value            = "return (user.attributes.get('notify') or {}).get('push_instance', 'none')"
  order                    = 10
}

resource "authentik_stage_prompt_field" "notify_push_service" {
  name                     = "notify-push-service"
  field_key                = "attributes.notify.push_service"
  label                    = "Phone: notify service"
  type                     = "text"
  required                 = false
  placeholder              = "mobile_app_your_iphone"
  sub_text                 = "The Home Assistant notify service of your phone's Companion app, without notify. in front."
  initial_value_expression = true
  initial_value            = "return (user.attributes.get('notify') or {}).get('push_service', '')"
  order                    = 20
}

resource "authentik_stage_prompt_field" "notify_email" {
  name                     = "notify-email"
  field_key                = "attributes.notify.email"
  label                    = "Email address"
  type                     = "email"
  required                 = false
  sub_text                 = "Empty means your account email."
  initial_value_expression = true
  initial_value            = "return (user.attributes.get('notify') or {}).get('email') or user.email"
  order                    = 30
}

resource "authentik_stage_prompt_field" "notify_default" {
  name                     = "notify-default"
  field_key                = "attributes.notify.default"
  label                    = "Notifications sent to you by name"
  type                     = "dropdown"
  required                 = false
  placeholder_expression   = true
  placeholder              = "return ${local.notify_channel_choices}"
  initial_value_expression = true
  initial_value            = "return (user.attributes.get('notify') or {}).get('default', 'off')"
  order                    = 40
}

resource "authentik_stage_prompt_field" "notify_topic" {
  for_each                 = local.notify_topics
  name                     = "notify-topic-${each.key}"
  field_key                = "attributes.notify.topics.${each.key}"
  label                    = "Topic: ${each.value}"
  type                     = "dropdown"
  required                 = false
  placeholder_expression   = true
  placeholder              = "return ${local.notify_channel_choices}"
  initial_value_expression = true
  initial_value            = "return ((user.attributes.get('notify') or {}).get('topics') or {}).get('${each.key}', 'off')"
  order                    = 100
}

resource "authentik_stage_prompt" "notify_settings" {
  name = "notify-settings"
  fields = concat(
    [
      authentik_stage_prompt_field.notify_push_instance.id,
      authentik_stage_prompt_field.notify_push_service.id,
      authentik_stage_prompt_field.notify_email.id,
      authentik_stage_prompt_field.notify_default.id,
    ],
    [for k in sort(keys(local.notify_topics)) : authentik_stage_prompt_field.notify_topic[k].id],
  )
}

# never_create: the stage writes to the signed-in user and can never make one.
resource "authentik_stage_user_write" "notify_settings" {
  name               = "notify-settings-write"
  user_creation_mode = "never_create"
}

resource "authentik_flow" "notify_settings" {
  # Created last, so a failed apply never leaves a reachable half-built flow.
  depends_on = [
    authentik_stage_prompt.notify_settings,
    authentik_stage_user_write.notify_settings,
  ]
  name           = "notify-settings"
  slug           = "notify-settings"
  title          = "Notifications"
  designation    = "stage_configuration"
  authentication = "require_authenticated"
}

resource "authentik_flow_stage_binding" "notify_settings_prompt" {
  target = authentik_flow.notify_settings.uuid
  stage  = authentik_stage_prompt.notify_settings.id
  order  = 10
}

resource "authentik_flow_stage_binding" "notify_settings_write" {
  target = authentik_flow.notify_settings.uuid
  stage  = authentik_stage_user_write.notify_settings.id
  order  = 20
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
  expression = replace(file("${path.module}/files/notify_render.py"), "__TOPICS__", jsonencode(sort(keys(local.notify_topics))))
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

resource "authentik_policy_event_matcher" "notify_user_write" {
  name   = "notify-user-write"
  action = "user_write"
}

# Catches admin edits of attributes, which record no user_write. It also fires
# on other User saves; each one is a harmless rewrite of the same config.
resource "authentik_policy_event_matcher" "notify_user_updated" {
  name   = "notify-user-updated"
  action = "model_updated"
  app    = "authentik.core"
  model  = "authentik_core.user"
}

resource "authentik_event_rule" "notify_user_write" {
  name                   = "notify-sync-on-user-write"
  severity               = "notice"
  destination_event_user = true
  transports             = [authentik_event_transport.notify_apprise.id]
}

resource "authentik_event_rule" "notify_user_updated" {
  name                   = "notify-sync-on-user-updated"
  severity               = "notice"
  destination_event_user = true
  transports             = [authentik_event_transport.notify_apprise.id]
}

resource "authentik_policy_binding" "notify_user_write" {
  target = authentik_event_rule.notify_user_write.id
  policy = authentik_policy_event_matcher.notify_user_write.id
  order  = 0
}

resource "authentik_policy_binding" "notify_user_updated" {
  target = authentik_event_rule.notify_user_updated.id
  policy = authentik_policy_event_matcher.notify_user_updated.id
  order  = 0
}
