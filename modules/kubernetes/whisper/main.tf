variable "tls_secret_name" {}
variable "tier" { type = string }

resource "kubernetes_namespace" "whisper" {
  metadata {
    name = "whisper"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.whisper.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "whisper" {
  metadata {
    name      = "whisper"
    namespace = kubernetes_namespace.whisper.metadata[0].name
    labels = {
      app  = "whisper"
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
        app = "whisper"
      }
    }
    template {
      metadata {
        labels = {
          app = "whisper"
        }
      }
      spec {
        node_selector = {
          "gpu" : "true"
        }
        toleration {
          key      = "nvidia.com/gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }

        container {
          name  = "whisper"
          image = "rhasspy/wyoming-whisper:latest"
          args  = ["--model", "small-int8", "--language", "en", "--beam-size", "1"]

          port {
            container_port = 10300
            protocol       = "TCP"
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
        }

        volume {
          name = "data"
          nfs {
            server = "10.0.10.15"
            path   = "/mnt/main/whisper"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "whisper" {
  metadata {
    name      = "whisper"
    namespace = kubernetes_namespace.whisper.metadata[0].name
    labels = {
      app = "whisper"
    }
  }

  spec {
    selector = {
      app = "whisper"
    }
    port {
      name        = "wyoming"
      port        = 10300
      target_port = 10300
      protocol    = "TCP"
    }
  }
}

# TCP passthrough from Traefik to whisper service
resource "kubernetes_manifest" "whisper_tcp_ingressroute" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRouteTCP"
    metadata = {
      name      = "whisper-tcp"
      namespace = "traefik"
    }
    spec = {
      entryPoints = ["whisper-tcp"]
      routes = [{
        match = "HostSNI(`*`)"
        services = [{
          name      = "whisper"
          namespace = "whisper"
          port      = 10300
        }]
      }]
    }
  }
}
