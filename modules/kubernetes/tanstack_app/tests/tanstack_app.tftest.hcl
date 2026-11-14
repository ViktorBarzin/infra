# terraform test, offline (every provider mocked). From this directory:
#   terraform init -backend=false && terraform test
# Checks what the module renders for the inputs a new app is most likely to
# change, and that the default rendering (the one tasks relies on) holds.
mock_provider "kubernetes" {}
mock_provider "authentik" {
  mock_resource "authentik_application" { defaults = { slug = "demo-one" } }
}
mock_provider "vault" {
  mock_data "vault_kv_secret_v2" { defaults = { data = { oidc_client_secret = "s" } } }
}
mock_provider "cloudflare" {}
mock_provider "kubectl" {}

variables {
  name            = "demo-one"
  display_name    = "Demo One"
  image           = "ghcr.io/viktorbarzin/demo-one"
  image_tag       = "latest"
  postgresql_host = "pg.example"
  tls_secret_name = "tls"
  admin_user_pks  = [7]
}

run "defaults" {
  command = plan
  assert {
    condition     = [for e in kubernetes_deployment.this.spec[0].template[0].spec[0].container[0].env : e.name] == ["DATABASE_URL", "DATABASE_PASSWORD_FILE", "NODE_ENV", "PUBLIC_ORIGINS", "OIDC_DISCOVERY_URL", "AUTHENTIK_API_URL", "AUTH_USERS_GROUP", "AUTH_ADMINS_GROUP"]
    error_message = "default env changed"
  }
  assert {
    condition     = kubernetes_deployment.this.wait_for_rollout == false
    error_message = "wait_for_rollout"
  }
  assert {
    condition     = length(kubernetes_deployment.this.spec[0].template[0].spec[0].image_pull_secrets) == 0
    error_message = "no pull secrets by default"
  }
  assert {
    condition     = local.db_name == "demo_one"
    error_message = "db name"
  }
}

run "ports_signup_pullsecret" {
  command = plan
  variables {
    http_port          = 8080
    metrics_port       = 9100
    signup_mode        = "open"
    image_pull_secrets = ["ghcr-credentials"]
  }
  assert {
    condition     = [for e in kubernetes_deployment.this.spec[0].template[0].spec[0].container[0].env : "${e.name}=${e.value}" if contains(["PORT", "METRICS_PORT", "SIGNUP_MODE"], e.name)] == ["PORT=8080", "METRICS_PORT=9100", "SIGNUP_MODE=open"]
    error_message = "settings env"
  }
  assert {
    condition     = kubernetes_deployment.this.spec[0].template[0].spec[0].image_pull_secrets[0].name == "ghcr-credentials"
    error_message = "pull secret"
  }
  assert {
    condition     = kubernetes_deployment.this.spec[0].template[0].spec[0].container[0].readiness_probe[0].http_get[0].port == "8080"
    error_message = "probe port"
  }
}

run "request_mode_needs_an_admin" {
  command = plan
  variables {
    admin_user_pks = []
  }
  expect_failures = [authentik_group.admins]
}

run "open_mode_without_admins_is_fine" {
  command = plan
  variables {
    admin_user_pks = []
    signup_mode    = "open"
  }
}

run "no_volumes_by_default" {
  command = plan
  assert {
    condition     = length(kubernetes_deployment.this.spec[0].template[0].spec[0].volume) == 1
    error_message = "only the db-password volume by default"
  }
  assert {
    condition     = kubernetes_deployment.this.spec[0].template[0].spec[0].security_context[0].fs_group_change_policy == null
    error_message = "fs_group_change_policy unset by default, so existing apps render unchanged"
  }
}

run "nfs_volume_mounts_without_rechowning" {
  command = plan
  variables {
    volumes = [{ name = "data", claim_name = "demo-one-data", mount_path = "/data", read_only = false }]
  }
  assert {
    condition     = [for v in kubernetes_deployment.this.spec[0].template[0].spec[0].volume : v.name] == ["db-password", "data"]
    error_message = "the data volume is added after db-password"
  }
  assert {
    condition     = one([for v in kubernetes_deployment.this.spec[0].template[0].spec[0].volume : v.persistent_volume_claim[0].claim_name if v.name == "data"]) == "demo-one-data"
    error_message = "claim name"
  }
  assert {
    condition     = one([for m in kubernetes_deployment.this.spec[0].template[0].spec[0].container[0].volume_mount : m.mount_path if m.name == "data"]) == "/data"
    error_message = "mount path"
  }
  assert {
    condition     = kubernetes_deployment.this.spec[0].template[0].spec[0].security_context[0].fs_group_change_policy == "OnRootMismatch"
    error_message = "OnRootMismatch, or the kubelet re-owns every file on the volume at each pod start"
  }
}

run "secret_env_reads_single_keys_and_restarts_on_change" {
  command = plan
  variables {
    secret_env = [
      { name = "TELEMETRY_WRITE_KEY", secret = "demo-one-telemetry", key = "write_key" },
      { name = "SENTRY_DSN", secret = "demo-one-telemetry", key = "sentry_dsn", optional = false },
    ]
  }
  assert {
    condition     = [for e in kubernetes_deployment.this.spec[0].template[0].spec[0].container[0].env : e.name if e.value_from != null && length(e.value_from) > 0] == ["TELEMETRY_WRITE_KEY", "SENTRY_DSN"]
    error_message = "secret env comes after the plain env, in order"
  }
  assert {
    condition     = [for e in kubernetes_deployment.this.spec[0].template[0].spec[0].container[0].env : "${e.value_from[0].secret_key_ref[0].name}/${e.value_from[0].secret_key_ref[0].key}/${e.value_from[0].secret_key_ref[0].optional}" if e.value_from != null && length(e.value_from) > 0] == ["demo-one-telemetry/write_key/true", "demo-one-telemetry/sentry_dsn/false"]
    error_message = "secret_key_ref name, key and optional (default true)"
  }
  assert {
    condition     = contains(split(",", kubernetes_deployment.this.metadata[0].annotations["secret.reloader.stakater.com/reload"]), "demo-one-telemetry")
    error_message = "Reloader restarts the pod when the telemetry Secret changes"
  }
}

run "no_service_account_by_default" {
  command = plan
  assert {
    condition     = length(kubernetes_service_account.this) == 0
    error_message = "no service account unless asked for, so existing apps render unchanged"
  }
  assert {
    condition     = kubernetes_deployment.this.spec[0].template[0].spec[0].automount_service_account_token == null || kubernetes_deployment.this.spec[0].template[0].spec[0].automount_service_account_token == true
    error_message = "the pod spec keeps the provider default"
  }
}

run "own_service_account_with_api_token" {
  command = plan
  variables {
    service_account = { name = "demo-one-console", automount_token = true }
  }
  assert {
    condition     = kubernetes_service_account.this[0].metadata[0].name == "demo-one-console"
    error_message = "service account name"
  }
  assert {
    condition     = kubernetes_service_account.this[0].automount_service_account_token == true
    error_message = "service account mounts its token"
  }
  assert {
    condition     = kubernetes_deployment.this.spec[0].template[0].spec[0].service_account_name == "demo-one-console"
    error_message = "the pod runs as the module's service account"
  }
  assert {
    condition     = kubernetes_deployment.this.spec[0].template[0].spec[0].automount_service_account_token == true
    error_message = "the pod mounts the token"
  }
}

run "own_service_account_without_token_by_default" {
  command = plan
  variables {
    service_account = { name = "demo-one" }
  }
  assert {
    condition     = kubernetes_service_account.this[0].automount_service_account_token == false
    error_message = "no token unless asked for"
  }
  assert {
    condition     = kubernetes_deployment.this.spec[0].template[0].spec[0].automount_service_account_token == false
    error_message = "the pod mounts no token"
  }
}

run "managed_email_mapping_by_default" {
  command = plan
  assert {
    condition     = length(authentik_provider_oauth2.this.property_mappings) == 3 && contains(authentik_provider_oauth2.this.property_mappings, data.authentik_property_mapping_provider_scope.email.id)
    error_message = "openid, profile and Authentik's managed scope-email, as before"
  }
}

run "own_email_mapping_replaces_the_managed_one" {
  command = plan
  variables {
    email_scope_mapping_id = "custom-email-mapping"
  }
  assert {
    condition     = length(authentik_provider_oauth2.this.property_mappings) == 3 && contains(authentik_provider_oauth2.this.property_mappings, "custom-email-mapping")
    error_message = "the app's own email mapping takes the managed one's place"
  }
  assert {
    condition     = !contains(authentik_provider_oauth2.this.property_mappings, data.authentik_property_mapping_provider_scope.email.id)
    error_message = "the managed scope-email is not sent beside the app's own"
  }
}
