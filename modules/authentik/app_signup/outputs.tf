output "group_id" {
  description = "pk of the app's member group: bind the application to it, and use it in the add_user call."
  value       = authentik_group.users.id
}

output "group_name" {
  value = authentik_group.users.name
}

output "approver_username" {
  description = "Request mode: the approver service account. Null in open mode."
  value       = one(authentik_user.approver[*].username)
}

output "approver_token" {
  description = "Request mode: API token of the approver. Put it in a Secret in the app's namespace, as stacks/f1-stream/members.tf does. Null in open mode."
  value       = one(authentik_token.approver[*].key)
  sensitive   = true
}

output "existing_account_policy_id" {
  description = "Request mode with existing_account_state_prefix: the access-request policy. Bind it to the application next to its group bindings (policy_engine_mode \"any\"); app-access-guard.tf in the authentik stack accepts it by its name, \"<app_slug>-access-request\". Null otherwise."
  value       = one(authentik_policy_expression.existing_account_request[*].id)
}
