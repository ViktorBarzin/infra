variable "tls_secret_name" {}
variable "name" {}
variable "tag" {
  default = "latest"
}
variable "tier" { type = string }
variable "sync_id" {
  type    = string
  default = null # If not passed, we won't run banksync
}
variable "budget_encryption_password" {
  type    = string
  default = null # If not passed, we won't run banksync ;known after initial installation
}

resource "kubernetes_deployment" "actualbudget" {
  metadata {
    name      = "actualbudget-${var.name}"
    namespace = "actualbudget"
    labels = {
      app  = "actualbudget-${var.name}"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "actualbudget-${var.name}"
      }
    }
    template {
      metadata {
        annotations = {
          "diun.enable"       = "false" # daily updates; pretty noisy
          "diun.include_tags" = "^${var.tag}$"
        }
        labels = {
          app = "actualbudget-${var.name}"
        }
      }
      spec {
        container {
          image = "actualbudget/actual-server:${var.tag}"
          name  = "actualbudget"

          port {
            container_port = 5006
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/actualbudget/${var.name}"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "actualbudget" {
  metadata {
    name      = "budget-${var.name}"
    namespace = "actualbudget"
    labels = {
      app = "actualbudget-${var.name}"
    }
  }

  spec {
    selector = {
      app = "actualbudget-${var.name}"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 5006
    }
  }
}

module "ingress" {
  source          = "../../ingress_factory"
  namespace       = "actualbudget"
  name            = "budget-${var.name}"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "nginx.ingress.kubernetes.io/proxy-body-size" : "0",
    "nginx.ingress.kubernetes.io/client-max-body-size" : "0"
  }
  rybbit_site_id = "3e6b6b68088a"
}


resource "random_string" "api-key" {
  length = 32
  lower  = true
}

resource "kubernetes_deployment" "actualbudget-http-api" {
  count = var.budget_encryption_password != null ? 1 : 0
  metadata {
    name      = "actualbudget-http-api-${var.name}"
    namespace = "actualbudget"
    labels = {
      app  = "actualbudget-http-api-${var.name}"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "RollingUpdate"
    }
    selector {
      match_labels = {
        app = "actualbudget-http-api-${var.name}"
      }
    }
    template {
      metadata {
        labels = {
          app = "actualbudget-http-api-${var.name}"
        }
      }
      spec {
        container {
          image = "jhonderson/actual-http-api:latest"
          name  = "actualbudget"

          port {
            container_port = 5007
          }
          env {
            name  = "ACTUAL_SERVER_URL"
            value = "https://budget-${var.name}.viktorbarzin.me"
          }
          env {
            name  = "ACTUAL_SERVER_PASSWORD"
            value = var.budget_encryption_password
          }
          env {
            name  = "API_KEY"
            value = random_string.api-key.result
          }

        }
      }
    }
  }
}

resource "kubernetes_service" "actualbudget-http-api" {
  metadata {
    name      = "budget-http-api-${var.name}"
    namespace = "actualbudget"
    labels = {
      app = "actualbudget-http-api-${var.name}"
    }
  }

  spec {
    selector = {
      app = "actualbudget-http-api-${var.name}"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 5007
    }
  }
}

resource "kubernetes_cron_job_v1" "bank-sync" {
  count = var.sync_id != null && var.budget_encryption_password != null ? 1 : 0
  metadata {
    name      = "bank-sync-${var.name}"
    namespace = "actualbudget"
  }
  spec {
    concurrency_policy            = "Replace"
    failed_jobs_history_limit     = 5
    schedule                      = "0 0 * * *" # Daily
    starting_deadline_seconds     = 10
    successful_jobs_history_limit = 10
    job_template {
      metadata {}
      spec {
        backoff_limit              = 3
        ttl_seconds_after_finished = 10
        template {
          metadata {}
          spec {
            container {
              name  = "bank-sync"
              image = "curlimages/curl"
              command = ["/bin/sh", "-c", <<-EOT
              # set -eux # Shows credentials so use only when debugging
              curl -X POST --location 'http://budget-http-api-${var.name}/v1/budgets/${var.sync_id}/accounts/banksync' --header 'accept: application/json' --header 'budget-encryption-password: ${var.budget_encryption_password}' --header 'x-api-key: ${random_string.api-key.result}'
              EOT
              ]
            }
          }
        }
      }
    }
  }
}
