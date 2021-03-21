variable "tls_secret_name" {}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "kafka"
  tls_secret_name = var.tls_secret_name
}

resource "helm_release" "kafka" {
  namespace        = "kafka"
  create_namespace = true
  name             = "kafka"

  repository = "https://charts.bitnami.com/bitnami"
  chart      = "kafka"

  values = [templatefile("${path.module}/kafka_chart_values.tpl", {})]
}

resource "kubernetes_deployment" "kafka-ui" {
  metadata {
    name      = "kafka-ui"
    namespace = "kafka"
    labels = {
      run = "kafka-ui"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        run = "kafka-ui"
      }
    }
    template {
      metadata {
        labels = {
          run = "kafka-ui"
        }
      }
      spec {
        container {
          image = "provectuslabs/kafka-ui:latest"
          name  = "kafka-ui"
          resources {
            limits = {
              cpu    = "0.5"
              memory = "512Mi"
            }
            requests = {
              cpu    = "250m"
              memory = "50Mi"
            }
          }
          port {
            container_port = 8080
          }
          env {
            name  = "KAFKA_CLUSTERS_0_NAME"
            value = "local"
          }
          env {
            name  = "KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS"
            value = "kafka:9092"
          }
          env {
            name  = "KAFKA_CLUSTERS_0_ZOOKEEPER"
            value = "kafka-zookeeper:2181"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "kafka-ui" {
  metadata {
    name      = "kafka-ui"
    namespace = "kafka"
    labels = {
      "run" = "kafka-ui"
    }
    # annotations = {
    #   "prometheus.io/scrape" = "true"
    #   "prometheus.io/path"   = "/metrics"
    #   "prometheus.io/port"   = "9113"
    # }
  }

  spec {
    selector = {
      run = "kafka-ui"
    }
    port {
      name        = "http"
      port        = "80"
      target_port = "8080"
    }
    # port {
    #   name        = "prometheus"
    #   port        = "9113"
    #   target_port = "9113"
    # }
  }
}

resource "kubernetes_ingress" "kafka-ui" {
  metadata {
    name      = "kafka-ui-ingress"
    namespace = "kafka"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
    }
  }

  spec {
    tls {
      hosts       = ["kafka.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "kafka.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service_name = "kafka-ui"
            service_port = "80"
          }
        }
      }
    }
  }
}
