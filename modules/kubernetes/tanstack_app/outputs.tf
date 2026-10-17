output "namespace" {
  value = kubernetes_namespace.this.metadata[0].name
}

output "deployment_name" {
  value = kubernetes_deployment.this.metadata[0].name
}

output "service_name" {
  value = kubernetes_service.this.metadata[0].name
}

output "host" {
  value = local.host
}

output "public_origins" {
  description = "https://<host> first, then extra_public_origins. The app's PUBLIC_ORIGINS."
  value       = local.public_origins
}

output "client_id" {
  value = authentik_provider_oauth2.this.client_id
}

output "application_slug" {
  value = authentik_application.this.slug
}

output "issuer_url" {
  value = "${var.authentik_url}/application/o/${authentik_application.this.slug}/"
}

output "discovery_url" {
  value = "${var.authentik_url}/application/o/${authentik_application.this.slug}/.well-known/openid-configuration"
}

output "users_group_id" {
  value = module.signup.group_id
}

output "users_group_name" {
  value = module.signup.group_name
}

output "admins_group_id" {
  value = authentik_group.admins.id
}

output "agents_group_id" {
  description = "null when agents_group is not set."
  value       = one(authentik_group.agents[*].id)
}

output "approver_username" {
  description = "Request mode: the sign-up approver service account. null in open mode."
  value       = module.signup.approver_username
}
