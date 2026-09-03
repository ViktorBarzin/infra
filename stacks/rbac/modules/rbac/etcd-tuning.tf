# Tune etcd on k8s-master, and expose its metrics port to Prometheus.
#
# 1. snapshot-count 10000 (default) -> 50000 to reduce WAL snapshot frequency.
#    etcd writes ~37.5 GB/day; less frequent snapshots reduce this by ~30-40%.
#
# 2. listen-metrics-urls gains the node IP alongside loopback (code-at4f,
#    2026-09-03). kubeadm binds it to 127.0.0.1:2381 only, so nothing outside
#    the master could scrape it and Prometheus had no etcd disk metrics at all:
#    `count(etcd_disk_wal_fsync_duration_seconds_count)` returned no series,
#    and the only etcd_* metrics in Prometheus were etcd_request_duration_*,
#    which the APISERVER emits about its own calls rather than etcd about its
#    disk. That matters more since 2026-09-03, when the decision to keep etcd
#    on the shared HDD was explicitly risk-accepted (bead code-oflt): the
#    compensating control is measurement, and wal_fsync / backend_commit p99
#    are the two numbers that show the spindle hurting.
#
#    Scope of the exposure: :2381 serves /metrics and /health only. It is not
#    the client API, which stays on https://127.0.0.1:2379 with mTLS and is
#    deliberately NOT widened here. The port is reachable only from the
#    10.0.20.0/24 management network.
#
# This patches the kubeadm-managed static pod manifest. Note: kubeadm upgrades
# will reset this, so re-apply after any kubeadm upgrade.
#
# Applying this RESTARTS the etcd static pod on a single-node control plane, so
# the apiserver briefly loses its datastore. Rollback is a file copy: the
# pre-change manifest is kept at /root/etcd.yaml.bak-code-at4f-2026-09-03.

resource "null_resource" "etcd_tuning" {
  connection {
    type        = "ssh"
    user        = "wizard"
    host        = var.k8s_master_host
    private_key = var.ssh_private_key
  }

  provisioner "remote-exec" {
    inline = [
      <<-SCRIPT
      sudo python3 -c "
import yaml

path = '/etc/kubernetes/manifests/etcd.yaml'
METRICS_URLS = 'http://127.0.0.1:2381,http://${var.k8s_master_host}:2381'

with open(path) as f:
    doc = yaml.safe_load(f)

container = doc['spec']['containers'][0]
args = container['command']

# Update or add --snapshot-count=50000
new_args = [a for a in args if not a.startswith('--snapshot-count=')]
new_args.append('--snapshot-count=50000')

# Update or add --listen-metrics-urls. Loopback stays first so anything on the
# host that already reads it keeps working; the node IP is what Prometheus
# scrapes. Metrics and health only, never the client API.
new_args = [a for a in new_args if not a.startswith('--listen-metrics-urls=')]
new_args.append('--listen-metrics-urls=' + METRICS_URLS)

# Update or add --quota-backend-bytes (256MB, default is 2GB which is fine)
# Keep default for now

container['command'] = new_args

# The kubelet restarts the static pod only when the file actually changes, so
# write nothing when the desired args are already in place. Without this an
# apply would bounce etcd every time the rbac stack runs, which on a
# single-node control plane means a datastore blip for no reason.
with open(path) as f:
    before = f.read()
after = yaml.dump(doc, default_flow_style=False)
if before == after:
    print('etcd manifest already correct, not rewriting')
else:
    with open(path, 'w') as f:
        f.write(after)
    print('etcd manifest updated: --snapshot-count=50000, --listen-metrics-urls=' + METRICS_URLS)
"
      SCRIPT
    ]
  }

  # Re-run if the configuration changes
  triggers = {
    snapshot_count     = "50000"
    listen_metrics_url = "http://127.0.0.1:2381,http://${var.k8s_master_host}:2381"
  }
}
