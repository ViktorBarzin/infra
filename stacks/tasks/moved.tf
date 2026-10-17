# One-time moves into module.app (modules/kubernetes/tanstack_app), 2026-10-17.
# Remove once applied: a follow-up plan without them must say "No changes".

moved {
  from = kubernetes_namespace.tasks
  to   = module.app.kubernetes_namespace.this
}
moved {
  from = kubernetes_manifest.external_secret
  to   = module.app.kubernetes_manifest.app_secrets[0]
}
moved {
  from = kubernetes_manifest.db_external_secret
  to   = module.app.kubernetes_manifest.db_creds
}
moved {
  from = kubernetes_manifest.auth_external_secret
  to   = module.app.kubernetes_manifest.auth_secrets
}
moved {
  from = kubernetes_deployment.tasks
  to   = module.app.kubernetes_deployment.this
}
moved {
  from = kubernetes_service.tasks
  to   = module.app.kubernetes_service.this
}
moved {
  from = module.ingress
  to   = module.app.module.ingress
}
moved {
  from = kubernetes_network_policy_v1.tasks_ingress
  to   = module.app.kubernetes_network_policy_v1.ingress
}
moved {
  from = authentik_provider_oauth2.tasks
  to   = module.app.authentik_provider_oauth2.this
}
moved {
  from = authentik_application.tasks
  to   = module.app.authentik_application.this
}
moved {
  from = module.signup
  to   = module.app.module.signup
}
moved {
  from = authentik_group.tasks_admins
  to   = module.app.authentik_group.admins
}
moved {
  from = authentik_policy_binding.tasks_users
  to   = module.app.authentik_policy_binding.users
}
moved {
  from = authentik_policy_binding.tasks_admins
  to   = module.app.authentik_policy_binding.admins
}
moved {
  from = authentik_policy_binding.tasks_home_server_admins
  to   = module.app.authentik_policy_binding.home_server_admins[0]
}
moved {
  from = kubernetes_secret.authentik_approver
  to   = module.app.kubernetes_secret.authentik_approver[0]
}
moved {
  from = kubernetes_secret.authentik_reader
  to   = module.app.kubernetes_secret.authentik_reader
}
moved {
  from = authentik_rbac_role.membership_reader
  to   = module.app.authentik_rbac_role.membership_reader
}
moved {
  from = authentik_rbac_permission_role.reader_view_user
  to   = module.app.authentik_rbac_permission_role.reader_view_user
}
moved {
  from = authentik_rbac_permission_role.reader_view_users_group
  to   = module.app.authentik_rbac_permission_role.reader_view_users_group
}
moved {
  from = authentik_group.membership_readers
  to   = module.app.authentik_group.membership_readers
}
moved {
  from = authentik_user.membership_reader
  to   = module.app.authentik_user.membership_reader
}
moved {
  from = authentik_token.membership_reader
  to   = module.app.authentik_token.membership_reader
}
