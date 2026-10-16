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
