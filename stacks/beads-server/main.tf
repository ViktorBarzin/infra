variable "tls_secret_name" {
  type      = string
  sensitive = true
}

# Temporary default until GHA pipeline publishes the first 8-char SHA tag.
variable "beadboard_image_tag" {
  type    = string
  default = "latest"
}

resource "kubernetes_namespace" "beads" {
  metadata {
    name = "beads-server"
    labels = {
      tier = local.tiers.aux
    }
  }
}

resource "kubernetes_persistent_volume_claim" "dolt_data" {
  wait_until_bound = false
  metadata {
    name      = "dolt-data"
    namespace = kubernetes_namespace.beads.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "10Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = { storage = "2Gi" }
    }
  }
}

resource "kubernetes_config_map" "dolt_init" {
  metadata {
    name      = "dolt-init"
    namespace = kubernetes_namespace.beads.metadata[0].name
  }
  data = {
    "01-create-beads-user.sql" = <<-EOT
      CREATE USER IF NOT EXISTS 'beads'@'%' IDENTIFIED BY '';
      GRANT ALL PRIVILEGES ON *.* TO 'beads'@'%' WITH GRANT OPTION;
    EOT
  }
}

resource "kubernetes_deployment" "dolt" {
  metadata {
    name      = "dolt"
    namespace = kubernetes_namespace.beads.metadata[0].name
    labels = {
      app  = "dolt"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "dolt"
      }
    }
    template {
      metadata {
        labels = {
          app = "dolt"
        }
      }
      spec {
        container {
          name  = "dolt"
          image = "dolthub/dolt-sql-server:latest"

          port {
            name           = "mysql"
            container_port = 3306
          }

          env {
            name  = "DOLT_ROOT_HOST"
            value = "%"
          }

          volume_mount {
            name       = "dolt-data"
            mount_path = "/var/lib/dolt"
          }
          volume_mount {
            name       = "init-scripts"
            mount_path = "/docker-entrypoint-initdb.d"
            read_only  = true
          }

          startup_probe {
            tcp_socket {
              port = 3306
            }
            failure_threshold = 30
            period_seconds    = 2
          }
          liveness_probe {
            tcp_socket {
              port = 3306
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }
          readiness_probe {
            tcp_socket {
              port = 3306
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          resources {
            requests = {
              memory = "256Mi"
              cpu    = "50m"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }

        volume {
          name = "dolt-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.dolt_data.metadata[0].name
          }
        }
        volume {
          name = "init-scripts"
          config_map {
            name = kubernetes_config_map.dolt_init.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config
    ]
  }
}

resource "kubernetes_service" "dolt" {
  metadata {
    name      = "dolt"
    namespace = kubernetes_namespace.beads.metadata[0].name
    labels = {
      app = "dolt"
    }
    annotations = {
      "metallb.universe.tf/loadBalancerIPs" = "10.0.20.200"
      "metallb.io/allow-shared-ip"          = "shared"
    }
  }
  spec {
    type                    = "LoadBalancer"
    external_traffic_policy = "Cluster"
    selector = {
      app = "dolt"
    }
    port {
      name        = "mysql"
      port        = 3306
      target_port = 3306
    }
  }
}

# ── Dolt Workbench (web UI) ──

resource "kubernetes_config_map" "workbench_store" {
  metadata {
    name      = "workbench-store"
    namespace = kubernetes_namespace.beads.metadata[0].name
  }
  data = {
    "store.json" = jsonencode([{
      name             = "beads"
      connectionUrl    = "mysql://beads@dolt.beads-server.svc.cluster.local:3306/code"
      hideDoltFeatures = false
      useSSL           = false
      type             = "Mysql"
    }])
  }
}

resource "kubernetes_deployment" "workbench" {
  metadata {
    name      = "dolt-workbench"
    namespace = kubernetes_namespace.beads.metadata[0].name
    labels = {
      app  = "dolt-workbench"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "dolt-workbench"
      }
    }
    template {
      metadata {
        labels = {
          app = "dolt-workbench"
        }
      }
      spec {
        init_container {
          name  = "seed-config"
          image = "dolthub/dolt-workbench:latest"
          command = ["sh", "-c", <<-EOT
            # Seed connection store
            cp /config/store.json /store/store.json
            # Copy static JS to writable volume and patch GraphQL URL
            cp -r /app/web/.next/static/* /static/
            for f in /static/chunks/pages/_app-*.js; do
              sed -i 's|http://localhost:9002/graphql|/graphql|g' "$f"
            done
            echo "Patched GraphQL URL and store path"
          EOT
          ]
          volume_mount {
            name       = "store-config"
            mount_path = "/config"
            read_only  = true
          }
          volume_mount {
            name       = "store"
            mount_path = "/store"
          }
          volume_mount {
            name       = "static-patched"
            mount_path = "/static"
          }
        }

        container {
          name  = "workbench"
          image = "dolthub/dolt-workbench:latest"
          command = ["sh", "-c", <<-EOT
            # Patch GraphQL server to listen on 0.0.0.0 (IPv4) — Node 18+ defaults to IPv6
            sed -i 's|app.listen(9002)|app.listen(9002,"0.0.0.0")|g' /app/graphql-server/dist/main.js
            # Start PM2, then auto-connect to Dolt after GraphQL is ready
            pm2-runtime /app/process.yml &
            PM2_PID=$!
            # Wait for GraphQL server to be ready, then auto-connect
            for i in $(seq 1 30); do
              if node -e "fetch('http://127.0.0.1:9002/graphql',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({query:'{storedConnections{name}}'})}).then(r=>{if(r.ok)process.exit(0);process.exit(1)}).catch(()=>process.exit(1))" 2>/dev/null; then
                node -e "fetch('http://127.0.0.1:9002/graphql',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({query:'mutation{addDatabaseConnection(connectionUrl:\"mysql://beads@dolt.beads-server.svc.cluster.local:3306/code\",name:\"beads\",hideDoltFeatures:false,useSSL:false,type:Mysql){currentDatabase}}'})}).then(r=>r.text()).then(t=>{console.log('Auto-connect:',t);process.exit(0)}).catch(e=>{console.error(e);process.exit(1)})" 2>&1
                break
              fi
              sleep 1
            done &
            wait $PM2_PID
          EOT
          ]

          port {
            name           = "http"
            container_port = 3000
          }
          port {
            name           = "graphql"
            container_port = 9002
          }

          env {
            name  = "NODE_OPTIONS"
            value = "--dns-result-order=ipv4first"
          }
          env {
            name  = "GRAPHQLAPI_URL"
            value = "http://localhost:9002/graphql"
          }

          volume_mount {
            name       = "store"
            mount_path = "/app/graphql-server/store"
          }
          volume_mount {
            name       = "static-patched"
            mount_path = "/app/web/.next/static"
          }

          startup_probe {
            http_get {
              path = "/"
              port = 3000
            }
            failure_threshold = 30
            period_seconds    = 2
          }
          liveness_probe {
            http_get {
              path = "/"
              port = 3000
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }
          readiness_probe {
            http_get {
              path = "/"
              port = 3000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          resources {
            requests = {
              memory = "128Mi"
              cpu    = "10m"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }

        volume {
          name = "store-config"
          config_map {
            name = kubernetes_config_map.workbench_store.metadata[0].name
          }
        }
        volume {
          name = "store"
          empty_dir {}
        }
        volume {
          name = "static-patched"
          empty_dir {}
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config
    ]
  }
}

resource "kubernetes_service" "workbench" {
  metadata {
    name      = "dolt-workbench"
    namespace = kubernetes_namespace.beads.metadata[0].name
    labels = {
      app = "dolt-workbench"
    }
  }
  spec {
    selector = {
      app = "dolt-workbench"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 3000
    }
    port {
      name        = "graphql"
      port        = 9002
      target_port = 9002
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.beads.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

module "ingress" {
  source           = "../../modules/kubernetes/ingress_factory"
  dns_type         = "proxied"
  namespace        = kubernetes_namespace.beads.metadata[0].name
  name             = "dolt-workbench"
  tls_secret_name  = var.tls_secret_name
  protected        = false
  exclude_crowdsec = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Dolt Workbench"
    "gethomepage.dev/description"  = "Beads task database UI"
    "gethomepage.dev/icon"         = "dolt.png"
    "gethomepage.dev/group"        = "Core Platform"
    "gethomepage.dev/pod-selector" = ""
  }
}

# GraphQL API ingress — the frontend JS hardcodes localhost:9002/graphql,
# but we rewrite the browser request to hit the same hostname on /graphql
# routed to port 9002.
resource "kubernetes_ingress_v1" "graphql" {
  metadata {
    name      = "dolt-workbench-graphql"
    namespace = kubernetes_namespace.beads.metadata[0].name
    annotations = {
      # No Authentik — browser fetch() can't follow 302 redirects on POST.
      # Main page (/) is still protected. GraphQL has no sensitive data beyond task list.
    }
  }
  spec {
    ingress_class_name = "traefik"
    tls {
      hosts       = ["dolt-workbench.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "dolt-workbench.viktorbarzin.me"
      http {
        path {
          path      = "/graphql"
          path_type = "Exact"
          backend {
            service {
              name = kubernetes_service.workbench.metadata[0].name
              port {
                number = 9002
              }
            }
          }
        }
      }
    }
  }
}

# ── BeadBoard (task visualization dashboard) ──

resource "kubernetes_config_map" "beadboard_config" {
  metadata {
    name      = "beadboard-beads-config"
    namespace = kubernetes_namespace.beads.metadata[0].name
  }
  data = {
    "metadata.json" = jsonencode({
      database         = "dolt"
      backend          = "dolt"
      dolt_mode        = "server"
      dolt_server_host = "dolt.beads-server.svc.cluster.local"
      dolt_server_port = 3306
      dolt_server_user = "root"
      dolt_database    = "code"
      project_id       = "a8f8bae7-ce65-4145-a5db-a13d11d297da"
    })
    "dolt-server.port" = "3306"
  }
}

# Pulls the claude-agent-service bearer token from Vault so BeadBoard can
# dispatch agent jobs via the in-cluster HTTP API.
resource "kubernetes_manifest" "beadboard_agent_service_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "beadboard-agent-service"
      namespace = kubernetes_namespace.beads.metadata[0].name
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "beadboard-agent-service"
      }
      data = [
        {
          secretKey = "api_bearer_token"
          remoteRef = {
            key      = "claude-agent-service"
            property = "api_bearer_token"
          }
        },
      ]
    }
  }
}

resource "kubernetes_deployment" "beadboard" {
  metadata {
    name      = "beadboard"
    namespace = kubernetes_namespace.beads.metadata[0].name
    labels = {
      app  = "beadboard"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "beadboard"
      }
    }
    template {
      metadata {
        labels = {
          app = "beadboard"
        }
      }
      spec {
        image_pull_secrets {
          name = "registry-credentials"
        }

        init_container {
          name    = "seed-beads-config"
          image   = "busybox:1.36"
          command = ["sh", "-c", "cp /config/* /beads/ && mkdir -p /beads/templates /beads/archetypes"]
          volume_mount {
            name       = "beads-config"
            mount_path = "/config"
            read_only  = true
          }
          volume_mount {
            name       = "beads-writable"
            mount_path = "/beads"
          }
        }

        container {
          name  = "beadboard"
          image = "registry.viktorbarzin.me:5050/beadboard:${var.beadboard_image_tag}"

          port {
            name           = "http"
            container_port = 3000
          }

          env {
            name  = "CLAUDE_AGENT_SERVICE_URL"
            value = "http://claude-agent-service.claude-agent.svc.cluster.local:8080"
          }

          env {
            name = "CLAUDE_AGENT_BEARER_TOKEN"
            value_from {
              secret_key_ref {
                name = "beadboard-agent-service"
                key  = "api_bearer_token"
              }
            }
          }

          volume_mount {
            name       = "beads-writable"
            mount_path = "/app/.beads"
          }

          startup_probe {
            http_get {
              path = "/"
              port = 3000
            }
            failure_threshold = 30
            period_seconds    = 2
          }
          liveness_probe {
            http_get {
              path = "/"
              port = 3000
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }
          readiness_probe {
            http_get {
              path = "/"
              port = 3000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          resources {
            requests = {
              memory = "256Mi"
              cpu    = "50m"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }

        volume {
          name = "beads-config"
          config_map {
            name = kubernetes_config_map.beadboard_config.metadata[0].name
          }
        }
        volume {
          name = "beads-writable"
          empty_dir {}
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config
    ]
  }
}

resource "kubernetes_service" "beadboard" {
  metadata {
    name      = "beadboard"
    namespace = kubernetes_namespace.beads.metadata[0].name
    labels = {
      app = "beadboard"
    }
  }
  spec {
    selector = {
      app = "beadboard"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 3000
    }
  }
}

module "beadboard_ingress" {
  source           = "../../modules/kubernetes/ingress_factory"
  dns_type         = "proxied"
  namespace        = kubernetes_namespace.beads.metadata[0].name
  name             = "beadboard"
  tls_secret_name  = var.tls_secret_name
  protected        = true
  exclude_crowdsec = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "BeadBoard"
    "gethomepage.dev/description"  = "Agent task visualization dashboard"
    "gethomepage.dev/icon"         = "mdi-chart-gantt"
    "gethomepage.dev/group"        = "Core Platform"
    "gethomepage.dev/pod-selector" = ""
  }
}
