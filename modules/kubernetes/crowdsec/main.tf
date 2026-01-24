variable "tls_secret_name" {}
variable "homepage_username" {}
variable "homepage_password" {}
variable "db_password" {}
variable "enroll_key" {}
variable "crowdsec_dash_api_key" { type = string }          # used for web dash
variable "crowdsec_dash_machine_id" { type = string }       # used for web dash
variable "crowdsec_dash_machine_password" { type = string } # used for web dash
variable "tier" { type = string }

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.crowdsec.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "crowdsec" {
  metadata {
    name = "crowdsec"
    labels = {
      tier = var.tier
    }
  }
}

resource "kubernetes_config_map" "crowdsec_custom_scenarios" {
  metadata {
    name      = "crowdsec-custom-scenarios"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "crowdsec"
    }
  }

  data = {
    "http-403-abuse.yaml" = <<-YAML
      type: leaky
      name: crowdsecurity/http-403-abuse
      description: "Detect IPs triggering too many HTTP 403s in NGINX ingress logs"
      filter: "evt.Meta.log_type == 'http_access-log' && evt.Parsed.status == '403'"
      groupby: "evt.Meta.source_ip"
      leakspeed: "2s"
      capacity: 10
      blackhole: 5m
      labels:
        service: http
        behavior: abusive_403
        remediation: true
    YAML
    "http-429-abuse.yaml" : <<-YAML
      type: leaky
      name: crowdsecurity/http-429-abuse
      description: "Detect IPs repeatedly triggering rate-limit (HTTP 429)"
      filter: "evt.Meta.log_type == 'http_access-log' && evt.Parsed.status == '429'"
      groupby: "evt.Meta.source_ip"
      leakspeed: "10s"
      capacity: 5
      blackhole: 1m
      labels:
        service: http
        behavior: rate_limit_abuse
        remediation: true
      YAML
  }
}

# Whitelist for trusted IPs that should never be blocked
resource "kubernetes_config_map" "crowdsec_whitelist" {
  metadata {
    name      = "crowdsec-whitelist"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "crowdsec"
    }
  }

  data = {
    "whitelist.yaml" = <<-YAML
      name: crowdsecurity/whitelist-trusted-ips
      description: "Whitelist for trusted IPs that should never be blocked"
      whitelist:
        reason: "Trusted IP - never block"
        ip:
          - "176.12.22.76"
    YAML
  }
}


resource "helm_release" "crowdsec" {
  namespace        = kubernetes_namespace.crowdsec.metadata[0].name
  create_namespace = true
  name             = "crowdsec"
  atomic           = true
  version          = "0.21.0"

  repository = "https://crowdsecurity.github.io/helm-charts"
  chart      = "crowdsec"

  values  = [templatefile("${path.module}/values.yaml", { homepage_username = var.homepage_username, homepage_password = var.homepage_password, DB_PASSWORD = var.db_password, ENROLL_KEY = var.enroll_key })]
  timeout = 3600
}


# Deployment for my custom dashboard that helps me unblock myself when I blocklist myself
resource "kubernetes_deployment" "crowdsec-web" {
  metadata {
    name      = "crowdsec-web"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
    labels = {
      app                             = "crowdsec_web"
      "kubernetes.io/cluster-service" = "true"
      tier                            = var.tier
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "RollingUpdate"
    }
    selector {
      match_labels = {
        app = "crowdsec_web"
      }
    }
    template {
      metadata {
        labels = {
          app                             = "crowdsec_web"
          "kubernetes.io/cluster-service" = "true"
        }
      }
      spec {
        container {
          name  = "crowdsec-web"
          image = "viktorbarzin/crowdsec_web"
          env {
            name  = "CS_API_URL"
            value = "http://crowdsec-service.crowdsec.svc.cluster.local:8080/v1"
          }
          env {
            name  = "CS_API_KEY"
            value = var.crowdsec_dash_api_key
          }
          env {
            name  = "CS_MACHINE_ID"
            value = var.crowdsec_dash_machine_id
          }
          env {
            name  = "CS_MACHINE_PASSWORD"
            value = var.crowdsec_dash_machine_password
          }
          port {
            name           = "http"
            container_port = 8000
            protocol       = "TCP"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "crowdsec-web" {
  metadata {
    name      = "crowdsec-web"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
    labels = {
      "app" = "crowdsec_web"
    }
  }

  spec {
    selector = {
      app = "crowdsec_web"
    }
    port {
      port        = "80"
      target_port = "8000"
    }
  }
}
module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.crowdsec.metadata[0].name
  name            = "crowdsec-web"
  protected       = true
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    # "crowdsec.io/bouncer-mode" : "bypass"
    "nginx.ingress.kubernetes.io/server-snippet" : <<-EOF
      # --- Disable CrowdSec for this host ---
      set $crowdsec_bypass 1;
      access_by_lua_block {
        -- Skip calling CrowdSec for this server
        if ngx.var.crowdsec_bypass == "1" then
          return
        end
      }
    EOF
  }
  rybbit_site_id = "d09137795ccc"
}

