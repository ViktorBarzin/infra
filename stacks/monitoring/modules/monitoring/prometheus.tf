

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
  source     = "../../../../modules/kubernetes/nfs_volume"
  name       = "monitoring-prometheus-backup-host"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/prometheus-backup"
}

resource "helm_release" "prometheus" {
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = true
  name             = "prometheus"

  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus"
  # version    = "15.0.2"
  version = "25.8.2"

  timeout = 900 # 15 min — Recreate strategy + iSCSI reattach is slow
  # force_update disabled 2026-04-23: caused Helm to try replacing the bound
  # pushgateway PVC (added in rev 188, see commit e51c104), which is immutable.
  # Re-enable temporarily only when a StatefulSet volumeClaimTemplate change needs --force.
  force_update = false

  values = [templatefile("${path.module}/prometheus_chart_values.tpl", { alertmanager_mail_pass = var.alertmanager_account_password, alertmanager_slack_api_url = var.alertmanager_slack_api_url, tuya_api_key = var.tiny_tuya_service_secret, haos_api_token = var.haos_api_token, authentik_walloff_targets = local.authentik_walloff_targets })]
}

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
}
