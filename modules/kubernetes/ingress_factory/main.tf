
variable "name" { type = string }
variable "service_name" {
  type    = string
  default = null # defaults to name
}
variable "host" {
  type    = string
  default = null
}
variable "namespace" { type = string }
variable "external_name" {
  type    = string
  default = null
}
variable "port" {
  default = "80"
}
variable "tls_secret_name" {}
variable "backend_protocol" {
  default = "HTTP"
}
variable "protected" {
  type    = bool
  default = false
}
variable "ingress_path" {
  type    = list(string)
  default = ["/"]
}
variable "max_body_size" {
  type    = string
  default = "50m"
}
variable "use_proxy_protocol" {
  type    = bool
  default = true
}
variable "proxy_timeout" {
  type    = number
  default = 60
}
variable "extra_annotations" {
  default = {}
}
variable "ssl_redirect" {
  default = true
  type    = bool
}
variable "allow_local_access_only" {
  default = false
  type    = bool
}
variable "root_domain" {
  default = "viktorbarzin.me"
  type    = string
}
variable "rybbit_site_id" {
  default = null
  type    = string
}


resource "kubernetes_service" "proxied-service" {
  count = var.external_name == null ? 0 : 1
  metadata {
    name      = var.name
    namespace = var.namespace
    labels = {
      "app" = var.name
    }
  }

  spec {
    type          = var.external_name != null ? "ExternalName" : "ClusterIP"
    external_name = var.name

    port {
      name        = "${var.name}-web"
      port        = var.port
      protocol    = "TCP"
      target_port = var.port
    }
  }
}

resource "kubernetes_ingress_v1" "proxied-ingress" {
  metadata {
    name      = var.name
    namespace = var.namespace
    annotations = merge({
      "kubernetes.io/ingress.class"                  = "nginx"
      "nginx.ingress.kubernetes.io/backend-protocol" = "${var.backend_protocol}"

      "nginx.ingress.kubernetes.io/auth-url" : var.protected ? "http://ak-outpost-authentik-embedded-outpost.authentik.svc.cluster.local:9000/outpost.goauthentik.io/auth/nginx" : null
      "nginx.ingress.kubernetes.io/auth-signin" : var.protected ? "https://authentik.viktorbarzin.me/outpost.goauthentik.io/start?rd=$scheme%3A%2F%2F$host$escaped_request_uri" : null
      "nginx.ingress.kubernetes.io/auth-snippet" : var.protected ? "proxy_set_header X-Forwarded-Host $http_host;" : null

      "nginx.ingress.kubernetes.io/proxy-body-size" : var.max_body_size
      "nginx.ingress.kubernetes.io/use-proxy-protocol" : var.use_proxy_protocol
      "nginx.ingress.kubernetes.io/proxy-connect-timeout" : var.proxy_timeout
      "nginx.ingress.kubernetes.io/proxy-send-timeout" : var.proxy_timeout
      "nginx.ingress.kubernetes.io/proxy-read-timeout" : var.proxy_timeout
      "nginx.ingress.kubernetes.io/proxy-buffering" : "on"

      "nginx.ingress.kubernetes.io/whitelist-source-range" : var.allow_local_access_only ? "192.168.1.0/24, 10.0.0.0/8" : "0.0.0.0/0"
      "nginx.ingress.kubernetes.io/ssl-redirect" : "${var.ssl_redirect}"

      # DDOS protection
      "nginx.ingress.kubernetes.io/limit-connections" : 100
      "nginx.ingress.kubernetes.io/limit-rps" : 5
      "nginx.ingress.kubernetes.io/limit-rpm" : 100
      "nginx.ingress.kubernetes.io/limit-burst-multiplier" : 50
      "nginx.ingress.kubernetes.io/limit-rate-after" : 100
      "nginx.ingress.kubernetes.io/configuration-snippet" = <<-EOF
        limit_req_status 429;
        limit_conn_status 429;
        ${var.rybbit_site_id != null ? <<-JS
          # Rybbit Analytics
          # Only modify HTML
          sub_filter_types text/html;
          sub_filter_once off;

          # Disable compression so sub_filter works
          proxy_set_header Accept-Encoding "";

          # Inject analytics before </head>
          sub_filter '</head>' '
          <script src="https://rybbit.viktorbarzin.me/api/script.js"
                data-site-id="${var.rybbit_site_id}"
                defer></script> 
          </head>';
        JS
      : ""
      }
      EOF

  }, var.extra_annotations)
}

spec {
  tls {
    hosts       = ["${var.name}.${var.root_domain}"] # TODO: refactor me to be easier to use
    secret_name = var.tls_secret_name
  }
  rule {
    host = "${var.host != null ? var.host : var.name}.${var.root_domain}"
    http {
      dynamic "path" {
        # for_each = { for pr in var.ingress_path : pr => pr }
        for_each = var.ingress_path

        content {
          path = path.value
          backend {
            service {

              name = var.service_name != null ? var.service_name : var.name
              port {
                number = var.port
              }
            }
          }
        }
      }
    }
  }
}
}

