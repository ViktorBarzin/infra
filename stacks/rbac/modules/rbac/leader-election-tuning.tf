# Slow the leader-election lease renewals on the two kubeadm static pods.
#
# WHY. kube-controller-manager and kube-scheduler both run with a bare
# `--leader-elect=true` and no timing flags, so they take client-go's defaults:
# lease duration 15s, renew deadline 10s, retry period 2s. The lease holder
# rewrites its Lease object every retry period, so the pair generate about
# 0.9 etcd writes/s to hold a lock. This control plane has one replica of each,
# so each lease is held against no contender.
#
# Those writes are not the problem on their own. The problem is what happens
# when a write is slow: measured 2026-09-06, the two pods had restarted 202 and
# 200 times, 289 of those in the preceding 30 days, and every restart was
#   Put .../leases/<name>?timeout=5s: context deadline exceeded
# followed by "leaderelection lost". WAL fsync p99 in the five-minute windows
# containing a scheduler restart was 3,438 ms against 197.9 ms elsewhere. A 10s
# renew deadline cannot survive a 3.4s fsync tail with a 2s retry period, so the
# process gives up and exits. See
# docs/research/2026-09-06-etcd-fsync-root-cause.md.
#
# New values, and why they are valid. client-go requires
# leaseDuration > renewDeadline > retryPeriod * 1.2:
#   60 > 45, and 45 > 15 * 1.2 = 18.
# The renew deadline goes from 10s to 45s, which is 13x the worst fsync tail
# observed, and the retry period from 2s to 15s cuts the lease writes by 7.5x.
#
# COST, stated plainly. A 60s lease duration means that after the process dies,
# the replacement waits up to 60s before it may acquire the lease, against up to
# 15s today. During that window no deployments, endpoints or node lifecycle
# reconcile, and no pods are scheduled. There is no second replica to fail over
# to either way, so this trades a slower recovery from a crash for far fewer
# crashes. On a multi-replica control plane the trade would be less clearly worth
# taking.
#
# This patches the kubeadm-managed manifests AND records the same three flags in
# the kubeadm-config ClusterConfiguration (controllerManager.extraArgs and
# scheduler.extraArgs), because the manifests alone do not survive an upgrade.
# Measured 2026-09-26: the v1.35.8 control-plane upgrade on 2026-09-16
# regenerated both manifests with a bare --leader-elect=true, nothing re-ran
# this resource, and kube-controller-manager went back to restarting 1 to 13
# times a day, against 0 to 1 a day while the tuning held (09-09 to 09-15).
# etcd-tuning.tf lost --listen-metrics-urls to the same upgrade for the same
# reason. The pre-change manifest of each is kept in /root/manifest-backups/.
#
# The backup directory sits OUTSIDE staticPodPath on purpose. The kubelet parses
# every file in /etc/kubernetes/manifests as a pod manifest whatever its
# extension, so a .bak written next to the original becomes a second definition
# of the same static pod. The first version of this file did that, and on
# 2026-09-08 the kubelet spent several minutes flipping kube-scheduler and
# kube-controller-manager between the tuned and untuned specs, restarting both
# each time, until the backups were moved to /root/manifest-backups. The flags
# were present in the manifest throughout, which is what made it confusing:
# the file was right and the running process was wrong. etcd-tuning.tf already
# keeps its backup under /root for the same reason.
#
# Applying this restarts each static pod, roughly 5 to 15 seconds apiece. The
# apiserver and etcd are untouched, so the datastore stays up throughout.

locals {
  leader_election_flags = {
    "leader-elect-lease-duration" = "60s"
    "leader-elect-renew-deadline" = "45s"
    "leader-elect-retry-period"   = "15s"
  }
}

resource "null_resource" "leader_election_tuning" {
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
import os
import yaml

BACKUP_DIR = '/root/manifest-backups'

FLAGS = {
    '--leader-elect-lease-duration': '60s',
    '--leader-elect-renew-deadline': '45s',
    '--leader-elect-retry-period': '15s',
}

for name in ('kube-controller-manager', 'kube-scheduler'):
    path = '/etc/kubernetes/manifests/%s.yaml' % name

    with open(path) as f:
        before = f.read()
    doc = yaml.safe_load(before)

    container = doc['spec']['containers'][0]
    args = container['command']

    # Only touch a component that is actually electing a leader. Rewriting the
    # timing flags on a component with --leader-elect=false would be dead config.
    if '--leader-elect=true' not in args:
        print('%s: not leader-electing, skipped' % name)
        continue

    kept = [a for a in args if a.split('=')[0] not in FLAGS]
    container['command'] = kept + ['%s=%s' % kv for kv in sorted(FLAGS.items())]

    # The kubelet restarts a static pod whenever the file changes, so write
    # nothing when the flags are already right. Without this guard every apply
    # of the rbac stack would bounce both controllers for no reason.
    after = yaml.dump(doc, default_flow_style=False)
    if before == after:
        print('%s: already tuned, not rewriting' % name)
        continue

    os.makedirs(BACKUP_DIR, exist_ok=True)
    with open(os.path.join(BACKUP_DIR, '%s.yaml.bak-leader-election' % name), 'w') as f:
        f.write(before)

    # Write to a temp file in the same directory and rename, so the kubelet
    # cannot observe a half-written manifest. Its file source polls every 20s
    # and will read a partial YAML document if it catches one.
    tmp = path + '.tmp-leader-election'
    with open(tmp, 'w') as f:
        f.write(after)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
    print('%s: updated %s' % (name, ' '.join(sorted(FLAGS))))
"
      SCRIPT
      ,
      # Record the same flags in kubeadm-config so the NEXT `kubeadm upgrade`
      # regenerates both manifests with them. Same shape as the etcd reconcile
      # in etcd-tuning.tf: wait for the apiserver first, change nothing when the
      # flags are already there, and warn rather than fail, because a failure
      # here loses durability across the next upgrade, not the fix applied
      # above. The file names differ from etcd-tuning.tf's so the two steps
      # never share a scratch file.
      <<-SCRIPT
      set -u
      KC="sudo kubectl --kubeconfig /etc/kubernetes/admin.conf"

      for i in $(seq 1 60); do
        if curl -sk https://localhost:6443/livez 2>/dev/null | grep -q '^ok'; then break; fi
        sleep 2
      done

      CC=$($KC -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' 2>/dev/null || true)
      if [ -z "$CC" ]; then
        echo "WARN: RECONCILE DID NOT RUN. Could not read kubeadm-config after waiting 120s for the apiserver."
        echo "WARN: the leader-election tuning will NOT survive the next kubeadm upgrade. Re-apply the rbac stack once the control plane is healthy."
      else
        printf '%s' "$CC" > /tmp/kubeadm-cc-leader.yaml
        sudo python3 -c "
import sys
import yaml

FLAGS = {
    'leader-elect-lease-duration': '60s',
    'leader-elect-renew-deadline': '45s',
    'leader-elect-retry-period': '15s',
}

cc = yaml.safe_load(open('/tmp/kubeadm-cc-leader.yaml'))
changed = False
for component in ('controllerManager', 'scheduler'):
    section = cc.get(component) or {}
    args = section.get('extraArgs') or []
    have = dict((a['name'], a['value']) for a in args)
    if all(have.get(k) == v for k, v in FLAGS.items()):
        continue
    changed = True
    section['extraArgs'] = [a for a in args if a['name'] not in FLAGS] + [
        {'name': k, 'value': v} for k, v in sorted(FLAGS.items())]
    cc[component] = section

# Exit 10 means nothing to do, so the shell below can tell it from a failure.
if not changed:
    print('kubeadm-config already carries the leader-election flags (no drift)')
    sys.exit(10)
with open('/tmp/kubeadm-cc-leader-new.yaml', 'w') as f:
    yaml.safe_dump(cc, f, default_flow_style=False, sort_keys=False)
print('kubeadm-config rewritten with the leader-election flags')
"
        RC=$?
        if [ "$RC" -eq 10 ]; then
          :
        elif [ "$RC" -eq 0 ] && sudo kubeadm init phase upload-config kubeadm --config /tmp/kubeadm-cc-leader-new.yaml; then
          echo "kubeadm-config reconciled: the leader-election tuning survives the next control-plane upgrade"
        else
          echo "WARN: kubeadm-config reconcile failed; re-apply this stack after the next kubeadm upgrade"
        fi
        sudo rm -f /tmp/kubeadm-cc-leader.yaml /tmp/kubeadm-cc-leader-new.yaml
      fi
      SCRIPT
    ]
  }

  # Both this and etcd_tuning read, modify and re-upload the same kubeadm-config
  # ConfigMap. Run concurrently, the second upload would silently drop the
  # first one's change.
  depends_on = [null_resource.etcd_tuning]

  # kubeadm_config_reconcile was added with the kubeadm-config step on
  # 2026-09-26. Changing it re-runs both steps once: the manifests get back the
  # flags the 09-16 upgrade dropped, and kubeadm-config learns them.
  triggers = merge(local.leader_election_flags, {
    kubeadm_config_reconcile = "v1"
  })
}
