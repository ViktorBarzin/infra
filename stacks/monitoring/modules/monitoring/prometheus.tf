

resource "kubernetes_persistent_volume_claim" "prometheus_server_pvc" {
  metadata {
    name      = "prometheus-data-proxmox"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    annotations = {
      # threshold = free-space % below which autoresizer expands.
      # 10% means "expand when 90% used" (the conventional knob).
      # WAS 90% — that's "expand when 10% used", which would
      # autoresize this volume from 200Gi → 500Gi in 6 cycles.
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "10%"
      "resize.topolvm.io/storage_limit" = "500Gi"
    }
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = {
        storage = "200Gi"
      }
    }
  }
  lifecycle {
    # The autoresizer expands requests.storage up to storage_limit and
    # PVCs can't shrink. Without this ignore_changes, every TF apply
    # tries to revert the live size back to 200Gi, hits the
    # K8s shrink-forbidden rule, and forces a destroy+recreate that
    # leaves the PVC stuck in Terminating until the pod releases it.
    # (Root cause of the prometheus-data-proxmox + technitium-primary-config-encrypted
    # Terminating-but-in-use incident on 2026-05-10.)
    ignore_changes = [spec[0].resources[0].requests]
  }
}

module "nfs_prometheus_backup_host" {
  source             = "../../../../modules/kubernetes/nfs_volume"
  name               = "monitoring-prometheus-backup-host"
  namespace          = kubernetes_namespace.monitoring.metadata[0].name
  nfs_server         = "192.168.1.127"
  nfs_path           = "/srv/nfs/prometheus-backup"
  storage_class_name = "nfs-pve"
}

resource "helm_release" "prometheus" {
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = true
  name             = "prometheus"

  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus"
  # version    = "15.0.2"
  version = "25.8.2"

  # wait=false: do NOT block the apply on the slow Recreate + WAL-replay roll.
  # Blocking held an ~15-min in-flight `helm upgrade` that Woodpecker's
  # cancel-on-new-push SIGKILLed mid-flight, wedging the release in
  # `pending-upgrade` (#6073 — recurred 4x on 2026-07-26) and taking the later
  # stacks in the same CI run down with it (immich never applied). With
  # wait=false helm writes the manifests and returns in ~1-2s; the pod still
  # rolls async (expected ~1-2min prometheus blip, memory #8956) and a failed
  # roll is caught by PrometheusDown + cluster_healthcheck #18, not by a blocked
  # apply. The helm-unstick CronJob (helm_unstick.tf) mops up any residual wedge.
  wait    = false
  timeout = 900 # ceiling for the (now non-blocking) rollout
  # force_update disabled 2026-04-23: caused Helm to try replacing the bound
  # pushgateway PVC (added in rev 188, see commit e51c104), which is immutable.
  # Re-enable temporarily only when a StatefulSet volumeClaimTemplate change needs --force.
  force_update = false

  values = [templatefile("${path.module}/prometheus_chart_values.tpl", { alertmanager_mail_pass = var.alertmanager_account_password, alertmanager_slack_api_url = var.alertmanager_slack_api_url, tuya_api_key = var.tiny_tuya_service_secret, haos_api_token = var.haos_api_token, authentik_walloff_targets = local.authentik_walloff_targets })]
}

# Keel opt-out for this Deployment lives ENTIRELY in the annotation — see the
# long note on `server.deploymentAnnotations` in prometheus_chart_values.tpl.
# Keel reads the annotation, and since 2026-08-17 the Kyverno exclude rule
# selects on that same annotation too (stacks/kyverno/.../keel-annotations.tf).
#
# There was a `kubernetes_labels.prometheus_server_keel_optout` here until
# 2026-08-17, stamping a matching keel.sh/policy LABEL for the exclude to
# select on. Removed: a keel.sh/* label is drift against any stack declaring a
# `labels` map on the workload, and it bought nothing the annotation does not.

# Local-only Prometheus query-API ingress for ha-sofia REST sensors (added
# 2026-06-05). ha-sofia (external HAOS) reads R730 iDRAC SNMP metrics
# (r730_idrac_coolingDeviceReading, etc.) by querying Prometheus directly via
# this host instead of hitting the slow on-demand Redfish exporter. Distinct
# host (prometheus-query.viktorbarzin.lan) + resource name to avoid colliding
# with the chart-created `prometheus-server` ingress (prometheus.viktorbarzin.me).
# Path-scoped to /api/v1/query so ONLY the read-only instant-query endpoint is
# reachable on the LAN — not the UI, admin, or federation endpoints.
module "prometheus-query-ingress" {
  source = "../../../../modules/kubernetes/ingress_factory"
  # auth = "none": ha-sofia REST sensor queries the Prometheus HTTP API
  # programmatically (no browser, no SSO cookie); the allow_local_access_only
  # IP allowlist (LAN subnets) is the gate. Authentik OIDC would 302 every call.
  auth                    = "none"
  namespace               = kubernetes_namespace.monitoring.metadata[0].name
  name                    = "prometheus-query"
  service_name            = "prometheus-server"
  root_domain             = "viktorbarzin.lan"
  tls_secret_name         = var.tls_secret_name
  allow_local_access_only = true
  ssl_redirect            = false
  port                    = 80
  ingress_path            = ["/api/v1/query"]
  extra_annotations = {
    "gethomepage.dev/description" = "Prometheus query API"
    "gethomepage.dev/icon"        = "prometheus.png"
  }
}

# OTLP metric ingest for Claude Code's native telemetry
# (docs/adr/0025-claude-session-telemetry.md). Claude sessions on the devvm
# export claude_code.* metrics over OTLP/HTTP to
# /api/v1/otlp/v1/metrics, enabled by the otlp-write-receiver feature flag in
# prometheus_chart_values.tpl.
#
# A SEPARATE ingress rather than another path on prometheus-query: that one is
# documented as read-only and named for it, and this one accepts writes.
#
# The host is .me, not .lan, for a TLS reason rather than a routing one. The
# wildcard certificate covers *.viktorbarzin.me only, so a .lan host fails
# hostname verification — which the existing LAN clients work around with
# insecure_skip_verify. Claude's exporter is inside the Claude process, and the
# only way to relax verification there is NODE_TLS_REJECT_UNAUTHORIZED, which
# would also stop verifying its calls to the Anthropic API. A hostname the
# certificate already covers avoids the problem instead of suppressing it.
module "prometheus-otlp-ingress" {
  source = "../../../../modules/kubernetes/ingress_factory"
  # auth = "none": an OTLP exporter is not a browser and holds no SSO cookie;
  # Authentik would 302 every push. The LAN allowlist is the gate, exactly as
  # for prometheus-query above.
  auth                    = "none"
  namespace               = kubernetes_namespace.monitoring.metadata[0].name
  name                    = "prometheus-otlp"
  service_name            = "prometheus-server"
  root_domain             = "viktorbarzin.me"
  tls_secret_name         = var.tls_secret_name
  allow_local_access_only = true
  ssl_redirect            = false
  port                    = 80
  ingress_path            = ["/api/v1/otlp"]
  # A .me host defaults to dns_type = "none", which since the wildcard
  # consolidation (ADR-0021) is NOT private — every recordless name resolves
  # through the tunnel and reaches Traefik. "internal" publishes the internal
  # Traefik LB address instead, so the name resolves anywhere but only routes
  # from the LAN/VPN. The IP allowlist above is the actual gate; this keeps a
  # write endpoint off the public path entirely.
  dns_type = "internal"
  # Internal-only, so no Uptime Kuma external monitor — one would probe from
  # outside and be permanently red.
  external_monitor = false
  # Telemetry arrives in bursts at each export interval, from every active
  # session at once. The default rate limit is sized for browsers.
  skip_default_rate_limit = true
  extra_annotations = {
    "gethomepage.dev/description" = "Prometheus OTLP metric ingest for Claude Code telemetry (LAN only)"
    "gethomepage.dev/icon"        = "prometheus.png"
  }
}
