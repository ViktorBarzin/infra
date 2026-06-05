# Ghost-disk auto-reconcile (beads code-dfjn — the prevention half).
#
# proxmox-csi hot-plugs each PVC as a virtio-scsi disk via the Proxmox API.
# A failed detach (query-pci QMP timeout on a disk-heavy VM) leaves a "ghost":
# a scsiN entry in the VM config with NO matching k8s VolumeAttachment. Ghosts
# are invisible to the NodeVolumeLimits scheduler (it counts VAs, not real scsi
# disks), so the node gets oversubscribed until query-pci wedges — the doom loop.
#
# This CronJob closes the loop: every 15 min it compares each worker VM's real
# scsi disks (Proxmox API) against k8s VolumeAttachments, and safely detaches any
# ghost (`PUT .../config delete=scsiN` — frees the LUN slot, retains the LV, same
# as `qm set --delete scsiN`). Detection mirrors cluster-health check #47.
#
# SAFETY: only acts on `vm-9999-pvc-*` scsi entries with NO VolumeAttachment for
# that PV on that node; re-confirms after a 60s sleep (so an in-flight attach is
# never caught); caps detaches per run. Uses the scoped CSI API token (VM.Config.Disk),
# NOT root SSH. Detach is non-destructive to data (the LV is retained).

locals {
  ghost_reconcile_ns = "proxmox-csi"
}

resource "kubernetes_secret" "ghost_reconcile_pve" {
  metadata {
    name      = "csi-ghost-reconcile-pve"
    namespace = local.ghost_reconcile_ns
  }
  data = {
    token_id     = data.vault_kv_secret_v2.secrets.data["proxmox_csi_token_id"]
    token_secret = data.vault_kv_secret_v2.secrets.data["proxmox_csi_token_secret"]
  }
  depends_on = [module.proxmox-csi]
}

resource "kubernetes_service_account" "ghost_reconcile" {
  metadata {
    name      = "csi-ghost-reconcile"
    namespace = local.ghost_reconcile_ns
  }
  depends_on = [module.proxmox-csi]
}

resource "kubernetes_cluster_role" "ghost_reconcile" {
  metadata { name = "csi-ghost-reconcile" }
  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["volumeattachments"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_cluster_role_binding" "ghost_reconcile" {
  metadata { name = "csi-ghost-reconcile" }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.ghost_reconcile.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.ghost_reconcile.metadata[0].name
    namespace = local.ghost_reconcile_ns
  }
}

resource "kubernetes_config_map" "ghost_reconcile_script" {
  metadata {
    name      = "csi-ghost-reconcile-script"
    namespace = local.ghost_reconcile_ns
  }
  data = {
    "reconcile.py" = <<-PY
      import json, os, ssl, sys, time, urllib.request, urllib.parse

      DRY = os.environ.get("DRY_RUN", "false") == "true"
      CAP = int(os.environ.get("MAX_DETACH", "5"))
      PVE = os.environ["PVE_URL"].rstrip("/")
      PVE_TOK = os.environ["PVE_TOKEN_ID"] + "=" + os.environ["PVE_TOKEN_SECRET"]
      PG = os.environ.get("PUSHGATEWAY", "")
      NODES = {201:"k8s-node1",202:"k8s-node2",203:"k8s-node3",204:"k8s-node4",205:"k8s-node5",206:"k8s-node6"}

      _ktok = open("/var/run/secrets/kubernetes.io/serviceaccount/token").read().strip()
      _kctx = ssl.create_default_context(cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
      _kctx.check_hostname = False  # reach the API by injected ClusterIP (cluster DNS may not resolve in this pod); CA chain still verified
      _kapi = "https://%s:%s" % (os.environ["KUBERNETES_SERVICE_HOST"], os.environ.get("KUBERNETES_SERVICE_PORT", "443"))
      _pctx = ssl.create_default_context(); _pctx.check_hostname = False; _pctx.verify_mode = ssl.CERT_NONE

      def k8s(path):
          r = urllib.request.Request(_kapi + path, headers={"Authorization": "Bearer " + _ktok})
          return json.load(urllib.request.urlopen(r, context=_kctx, timeout=20))

      def pve(path, method="GET", data=None):
          body = urllib.parse.urlencode(data).encode() if data else None
          r = urllib.request.Request(PVE + path, data=body, method=method, headers={"Authorization": "PVEAPIToken=" + PVE_TOK})
          return json.load(urllib.request.urlopen(r, context=_pctx, timeout=20))

      def attached():
          out = set()
          for v in k8s("/apis/storage.k8s.io/v1/volumeattachments").get("items", []):
              sp = v.get("spec", {})
              if sp.get("attacher") != "csi.proxmox.sinextra.dev": continue
              if not v.get("status", {}).get("attached"): continue
              pv = (sp.get("source", {}) or {}).get("persistentVolumeName", "")
              if pv: out.add((sp.get("nodeName", ""), pv.replace("pvc-", "")))
          return out

      def find_ghosts(att):
          g = []
          for vmid, node in NODES.items():
              cfg = pve("/nodes/pve/qemu/%d/config" % vmid).get("data", {})
              for key, val in cfg.items():
                  if not (key.startswith("scsi") and key[4:].isdigit()): continue
                  s = str(val)
                  if "vm-9999-pvc-" not in s: continue
                  uuid = s.split("vm-9999-pvc-")[1].split(",")[0]
                  if (node, uuid) not in att:
                      g.append((vmid, node, key, uuid))
          return g

      att = attached()
      ghosts = find_ghosts(att)
      print("[reconcile] attached_VAs=%d ghosts=%d dry=%s" % (len(att), len(ghosts), DRY), flush=True)
      for vmid, node, scsi, uuid in ghosts:
          print("  ghost: VM%d/%s %s -> pvc-%s" % (vmid, node, scsi, uuid), flush=True)

      detached = 0
      if ghosts:
          time.sleep(60)  # re-confirm: never act on an in-flight attach
          att2 = attached()
          confirmed = [x for x in ghosts if (x[1], x[3]) not in att2]
          print("[reconcile] confirmed after 60s recheck: %d" % len(confirmed), flush=True)
          for vmid, node, scsi, uuid in confirmed:
              if detached >= CAP:
                  print("[reconcile] hit per-run cap %d, stopping" % CAP, flush=True); break
              if DRY:
                  print("  DRY would detach VM%d %s (pvc-%s)" % (vmid, scsi, uuid), flush=True); continue
              try:
                  pve("/nodes/pve/qemu/%d/config" % vmid, method="PUT", data={"delete": scsi})
                  print("  DETACHED VM%d %s (pvc-%s)" % (vmid, scsi, uuid), flush=True); detached += 1
              except Exception as e:
                  print("  FAILED detach VM%d %s: %s" % (vmid, scsi, e), flush=True)
      else:
          print("[reconcile] no ghosts — all nodes reconciled", flush=True)

      if PG:
          try:
              body = "csi_ghosts_detected %d\ncsi_ghosts_detached %d\ncsi_ghost_reconcile_last_run %d\n" % (len(ghosts), detached, int(time.time()))
              urllib.request.urlopen(urllib.request.Request(PG.rstrip("/") + "/metrics/job/csi-ghost-reconcile", data=body.encode(), method="PUT"), timeout=10)
          except Exception as e:
              print("[reconcile] metric push failed: %s" % e, flush=True)
    PY
  }
  depends_on = [module.proxmox-csi]
}

resource "kubernetes_cron_job_v1" "ghost_reconcile" {
  metadata {
    name      = "csi-ghost-reconcile"
    namespace = local.ghost_reconcile_ns
  }
  spec {
    schedule                      = "*/15 * * * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        active_deadline_seconds    = 300
        ttl_seconds_after_finished = 600
        template {
          metadata {}
          spec {
            service_account_name = kubernetes_service_account.ghost_reconcile.metadata[0].name
            restart_policy       = "Never"
            container {
              name              = "reconcile"
              image             = "python:3.13-alpine"
              image_pull_policy = "IfNotPresent"
              command           = ["python3", "/script/reconcile.py"]
              env {
                name  = "PVE_URL"
                value = "https://192.168.1.127:8006/api2/json"
              }
              env {
                name  = "DRY_RUN"
                value = "false"
              }
              env {
                name  = "MAX_DETACH"
                value = "5"
              }
              env {
                name  = "PUSHGATEWAY"
                value = "http://prometheus-prometheus-pushgateway.monitoring.svc.cluster.local:9091"
              }
              env {
                name = "PVE_TOKEN_ID"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret.ghost_reconcile_pve.metadata[0].name
                    key  = "token_id"
                  }
                }
              }
              env {
                name = "PVE_TOKEN_SECRET"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret.ghost_reconcile_pve.metadata[0].name
                    key  = "token_secret"
                  }
                }
              }
              volume_mount {
                name       = "script"
                mount_path = "/script"
              }
              resources {
                requests = { cpu = "10m", memory = "64Mi" }
                limits   = { memory = "128Mi" }
              }
            }
            volume {
              name = "script"
              config_map {
                name         = kubernetes_config_map.ghost_reconcile_script.metadata[0].name
                default_mode = "0555"
              }
            }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }
  depends_on = [module.proxmox-csi]
}
