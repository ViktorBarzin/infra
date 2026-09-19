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
# This patches the kubeadm-managed static pod manifest AND records the same
# value in the kubeadm-config ClusterConfiguration, because the manifest alone
# does not survive an upgrade.
#
# Measured 2026-09-19: the v1.35.8 control-plane upgrade on 2026-09-16 rewrote
# etcd.yaml and `up{job="etcd"}` went 1 -> 0 that evening, staying down for
# three days. --snapshot-count=50000 came back and --listen-metrics-urls did
# not, and the reason is which of the two kubeadm knows about. snapshot-count
# is in kubeadm-config under etcd.local.extraArgs, so kubeadm re-emits it every
# time it regenerates the manifest; listen-metrics-urls was only ever written
# into the file on disk, so kubeadm reset it to its own default of
# 127.0.0.1:2381 and Prometheus, which scrapes the node IP, got connection
# refused. Putting it in extraArgs alongside snapshot-count is what makes it
# durable; the manifest edit below is what makes it take effect now without
# waiting for the next upgrade.
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
      ,
      # Reconcile kubeadm-config so the NEXT `kubeadm upgrade` regenerates
      # etcd.yaml with the node IP still in --listen-metrics-urls. Writing only
      # the manifest above is what let the 2026-09-16 upgrade silently take
      # etcd metrics away for three days. Stdlib-only: the master is guaranteed
      # python3 but not pyyaml. Idempotent, and it leaves every other field of
      # the ClusterConfiguration verbatim. Best-effort: a failure here loses
      # durability across the next upgrade, not the fix applied above, so it
      # warns rather than failing the apply.
      <<-SCRIPT
      set -u
      KC="sudo kubectl --kubeconfig /etc/kubernetes/admin.conf"
      CC=$($KC -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' 2>/dev/null || true)
      if [ -z "$CC" ]; then
        echo "WARN: could not read kubeadm-config; etcd metrics will not survive the next kubeadm upgrade"
      elif printf '%s' "$CC" | grep -q 'name: listen-metrics-urls'; then
        echo "kubeadm-config already carries listen-metrics-urls (no drift)"
      else
        printf '%s' "$CC" > /tmp/kubeadm-cc.yaml
        if sudo python3 -c "
import sys

WANT_NAME = 'listen-metrics-urls'
WANT_VAL  = 'http://127.0.0.1:2381,http://${var.k8s_master_host}:2381'

lines = open('/tmp/kubeadm-cc.yaml').read().split('\n')
out, i, n, done = [], 0, len(lines), False
while i < n:
    ln = lines[i]
    out.append(ln)
    # Anchor on the snapshot-count entry, which lives in etcd.local.extraArgs
    # and is the one arg known to survive an upgrade. Appending immediately
    # after it puts the new entry in the same list at the same indent without
    # having to parse the document structure.
    if (not done) and ln.strip() == '- name: snapshot-count':
        indent = ln[:len(ln) - len(ln.lstrip())]
        if i + 1 < n and lines[i + 1].strip().startswith('value:'):
            out.append(lines[i + 1]); i += 1
        out.append(indent + '- name: ' + WANT_NAME)
        out.append(indent + '  value: ' + WANT_VAL)
        done = True
    i += 1
if not done:
    sys.stderr.write('ANCHOR-NOT-FOUND: no etcd.local.extraArgs snapshot-count entry\n')
    sys.exit(3)
open('/tmp/kubeadm-cc-new.yaml', 'w').write('\n'.join(out))
print('kubeadm-config rewritten with ' + WANT_NAME)
" && sudo kubeadm init phase upload-config kubeadm --config /tmp/kubeadm-cc-new.yaml; then
          echo "kubeadm-config reconciled: etcd metrics survive the next control-plane upgrade"
        else
          echo "WARN: kubeadm-config reconcile failed; re-apply this stack after the next kubeadm upgrade"
        fi
        rm -f /tmp/kubeadm-cc.yaml /tmp/kubeadm-cc-new.yaml
      fi
      SCRIPT
    ]
  }

  # Re-run if the configuration changes
  triggers = {
    snapshot_count     = "50000"
    listen_metrics_url = "http://127.0.0.1:2381,http://${var.k8s_master_host}:2381"
    # Bumped when the kubeadm-config reconcile step was added (2026-09-19) so
    # the new step actually runs against a master that already has the right
    # manifest — the other two triggers were unchanged by that work.
    kubeadm_config_reconcile = "v1"
  }
}
