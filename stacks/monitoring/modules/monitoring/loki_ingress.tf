# Loki write/push endpoint for EXTERNAL hosts (currently rpi-sofia's promtail).
#
# Loki runs SingleBinary with the gateway disabled and auth_enabled=false, so it
# is ClusterIP-only (svc "loki":3100) and unreachable from off-cluster. An
# external log shipper like the Sofia Raspberry Pi cannot POST to
# /loki/api/v1/push without this ingress.
#
# auth = "none": promtail ships logs programmatically (no browser, no Authentik
# SSO cookie dance). The allow_local_access_only middleware (192.168.0.0/16 +
# 10.0.0.0/8) gates the endpoint to LAN/VPN only — the correct model for a
# LAN-only Pi, mirroring the idrac-redfish-exporter ingress in this module.
module "loki-write-ingress" {
  source                  = "../../../../modules/kubernetes/ingress_factory"
  auth                    = "none"
  namespace               = kubernetes_namespace.monitoring.metadata[0].name
  name                    = "loki"
  root_domain             = "viktorbarzin.lan"
  tls_secret_name         = var.tls_secret_name
  allow_local_access_only = true
  ssl_redirect            = false
  port                    = 3100
}
