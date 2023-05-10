# Module to run some infra-specific things like updating the public ip


resource "kubernetes_cron_job_v1" "update-public-ip" {
  metadata {
    name      = "update-public-ip"
    namespace = "default"
  }
  spec {
    schedule           = "* * * * *"
    concurrency_policy = "Forbid"
    job_template {
      metadata {
        name = "update-public-ip"
      }
      spec {
        template {
          metadata {
            name = "update-public-ip"
          }
          spec {
            priority_class_name = "system-cluster-critical"
            container {
              name  = "update-public-ip"
              image = "viktorbarzin/infra"
              command = ["./infra_cli"]
              args    = ["-use-case", "update-public-ip"]
            }
            restart_policy       = "Never"
            # service_account_name = "descheduler-sa"
            # volume {
            #   name = "policy-volume"
            #   config_map {
            #     name = "policy-configmap"
            #   }
            # }
          }
        }
      }
    }
  }
}
