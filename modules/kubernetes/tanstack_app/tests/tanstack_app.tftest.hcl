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
    condition = [for e in kubernetes_deployment.this.spec[0].template[0].spec[0].container[0].env : "${e.name}=${e.value}" if contains(["PORT", "METRICS_PORT", "SIGNUP_MODE"], e.name)] == ["PORT=8080", "METRICS_PORT=9100", "SIGNUP_MODE=open"]
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
