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
# Like etcd-tuning.tf, this patches kubeadm-managed manifests, so a kubeadm
# upgrade resets it and it must be re-applied afterwards. The pre-change manifest
# of each is kept next to it as a .bak.
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
import yaml

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

    with open(path + '.bak-leader-election', 'w') as f:
        f.write(before)
    with open(path, 'w') as f:
        f.write(after)
    print('%s: updated %s' % (name, ' '.join(sorted(FLAGS))))
"
      SCRIPT
    ]
  }

  triggers = local.leader_election_flags
}
