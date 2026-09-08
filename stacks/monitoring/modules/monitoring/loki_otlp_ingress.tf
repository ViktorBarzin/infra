# Loki's native OTLP log endpoint, for Claude Code's built-in OpenTelemetry
# export (docs/adr/0025-claude-session-telemetry.md). Claude sessions on the
# devvm POST OTLP/HTTP to /otlp/v1/logs, which Loki 3.x serves directly — no
# collector and no Alloy receiver in between.
#
# Separate from loki-write-ingress (the .lan host rpi-sofia's promtail uses)
# for a TLS reason. The wildcard certificate covers *.viktorbarzin.me only, so
# a .lan host fails hostname verification; promtail and curl work around that
# with insecure_skip_verify and -k. Claude's exporter runs inside the Claude
# process, where the only lever is NODE_TLS_REJECT_UNAUTHORIZED — which would
# also stop verifying its calls to the Anthropic API. Using a hostname the
# certificate already covers avoids the problem rather than suppressing it.
module "loki-otlp-ingress" {
  source = "../../../../modules/kubernetes/ingress_factory"
  # auth = "none": an OTLP exporter is not a browser and holds no Authentik SSO
  # cookie; forward-auth would 302 every push. The allow_local_access_only IP
  # allowlist (LAN/VPN CIDRs) is the gate, as for loki-write-ingress.
  auth                    = "none"
  namespace               = kubernetes_namespace.monitoring.metadata[0].name
  name                    = "loki-otlp"
  service_name            = "loki"
  root_domain             = "viktorbarzin.me"
  tls_secret_name         = var.tls_secret_name
  allow_local_access_only = true
  ssl_redirect            = false
  port                    = 3100
  ingress_path            = ["/otlp"]
  # See prometheus-otlp-ingress: a .me host defaults to dns_type = "none",
  # which is not private since the wildcard consolidation (ADR-0021).
  # "internal" publishes the internal Traefik LB address, so the name resolves
  # anywhere but routes only from the LAN/VPN.
  dns_type = "internal"
  # Internal-only, so an external Uptime Kuma monitor would be permanently red.
  external_monitor = false
  # Every active Claude session flushes on the same export interval, so log
  # export arrives in bursts. The default rate limit is sized for browsers.
  skip_default_rate_limit = true
  extra_annotations = {
    "gethomepage.dev/description" = "Loki OTLP log ingest for Claude Code telemetry (LAN only)"
    "gethomepage.dev/icon"        = "loki.png"
  }
}
