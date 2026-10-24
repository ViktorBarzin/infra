# Let pods sit out a slow node boot instead of being evicted.
#
# WHY. The DefaultTolerationSeconds admission plugin gives every pod a
# toleration of 300s for node.kubernetes.io/not-ready and
# node.kubernetes.io/unreachable. When a node stays NotReady longer than that,
# the taint-eviction controller deletes its pods.
#
# On 2026-10-23 the R730 was hard reset at 06:14. The VMs started one by one
# from 06:18, and containerd took 3 to 7 minutes to start on each node because
# every VM reads the same `sdc` disk (playbooks/k8s-node-tuning.yml). Nodes went
# Ready between 06:23 and 06:38. The NoExecute taints landed at ~06:23:25,
# before the zone switched to PartialDisruption, so the built-in zone protection
# did not apply, and kube-controller-manager logged 159
# `taint_eviction.go "Deleting pod"` between 06:28:25 and 06:28:46. Those
# evictions set off Multi-Attach waits on the RWO volumes, and Vault, Postgres,
# DNS and Loki did not come back until 07:26-08:07.
#
# 1800s covers the slowest boot seen that day with room to spare.
#
# COST. A node that is genuinely dead keeps its pods for 30 minutes before they
# are rescheduled, against 5 today. Planned reboots are unaffected: kured drains
# a node before rebooting it.
#
# SCOPE. The admission plugin sets the toleration when a pod is created, so
# existing pods keep 300s until they are recreated. Pods that set their own
# tolerationSeconds (claude-breakglass sets 300) keep theirs.
#
# This patches the apiserver manifest AND records the flags in kubeadm-config
# apiServer.extraArgs, because `kubeadm upgrade` regenerates the manifest from
# kubeadm-config (see leader-election-tuning.tf for the 2026-09-16 upgrade that
# dropped flags set only in the manifests). The pre-change manifest is kept in
# /root/manifest-backups/, outside staticPodPath for the reason given there.
#
# Applying this restarts the apiserver once, about 30 to 60 seconds without the
# API. Workloads keep running. If the new apiserver does not come up healthy
# within 3 minutes, the script restores the backup and fails the apply.

locals {
  apiserver_eviction_flags = {
    "default-not-ready-toleration-seconds"   = "1800"
    "default-unreachable-toleration-seconds" = "1800"
  }

  # Edits the manifest as text, so the rest of the file keeps kubeadm's
  # formatting and the line-based edits in apiserver-oidc.tf keep working. Each
  # flag is replaced in place when present with another value, and otherwise
  # inserted after --authorization-mode with the same indent. Exit 10 means
  # nothing to change.
  apiserver_eviction_manifest_py = <<-PY
    import os, sys
    path, backup = sys.argv[1], sys.argv[2]
    flags = dict(a.split('=', 1) for a in sys.argv[3:])
    before = open(path).read()
    lines = before.splitlines(True)
    seen = set()
    for i, ln in enumerate(lines):
        s = ln.strip()
        for k, v in flags.items():
            if s.startswith('- --%s=' % k):
                seen.add(k)
                indent = ln[:len(ln) - len(ln.lstrip())]
                lines[i] = '%s- --%s=%s\n' % (indent, k, v)
    missing = [k for k in sorted(flags) if k not in seen]
    if missing:
        for i, ln in enumerate(lines):
            if ln.strip().startswith('- --authorization-mode='):
                indent = ln[:len(ln) - len(ln.lstrip())]
                lines[i + 1:i + 1] = ['%s- --%s=%s\n' % (indent, k, flags[k]) for k in missing]
                break
        else:
            sys.stderr.write('ANCHOR-NOT-FOUND: --authorization-mode\n')
            sys.exit(3)
    after = ''.join(lines)
    if after == before:
        print('kube-apiserver: eviction tolerations already set, not rewriting')
        sys.exit(10)
    os.makedirs(os.path.dirname(backup), exist_ok=True)
    with open(backup, 'w') as f:
        f.write(before)
    # Write to a temp file and rename, so the kubelet never reads a half-written
    # manifest.
    tmp = path + '.tmp-eviction'
    with open(tmp, 'w') as f:
        f.write(after)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
    print('kube-apiserver: set %s' % ' '.join(sorted(flags)))
  PY

  # Same shape as the reconcile in leader-election-tuning.tf, for
  # apiServer.extraArgs. Exit 10 means kubeadm-config already has the flags.
  apiserver_eviction_kubeadm_py = <<-PY
    import sys, yaml
    src, dst = sys.argv[1], sys.argv[2]
    flags = dict(a.split('=', 1) for a in sys.argv[3:])
    cc = yaml.safe_load(open(src))
    section = cc.get('apiServer') or {}
    args = section.get('extraArgs') or []
    have = dict((a['name'], a['value']) for a in args)
    if all(have.get(k) == v for k, v in flags.items()):
        print('kubeadm-config already carries the eviction tolerations (no drift)')
        sys.exit(10)
    section['extraArgs'] = [a for a in args if a['name'] not in flags] + [
        {'name': k, 'value': v} for k, v in sorted(flags.items())]
    cc['apiServer'] = section
    with open(dst, 'w') as f:
        yaml.safe_dump(cc, f, default_flow_style=False, sort_keys=False)
    print('kubeadm-config rewritten with the eviction tolerations')
  PY

  apiserver_eviction_flag_args = join(" ", [for k, v in local.apiserver_eviction_flags : "${k}=${v}"])

  apiserver_eviction_remote_script = <<-SH
    set -u
    MANIFEST=/etc/kubernetes/manifests/kube-apiserver.yaml
    BACKUP=/root/manifest-backups/kube-apiserver.yaml.bak-eviction-tuning.$(date +%s)
    FLAGS="${local.apiserver_eviction_flag_args}"

    livez() { curl -sk https://localhost:6443/livez 2>/dev/null | grep -q '^ok'; }

    # True once the RUNNING apiserver carries every flag and answers /livez.
    # Checking /livez alone would pass against the old process, which keeps
    # answering until the kubelet notices the new manifest (up to ~20s).
    running_with_flags() {
      ARGS=$(ps -eo args | grep '^kube-apiserver ' || true)
      for kv in $FLAGS; do
        echo "$ARGS" | grep -q -- "--$kv" || return 1
      done
      livez
    }

    # 1. Manifest.
    echo '${base64encode(local.apiserver_eviction_manifest_py)}' | base64 -d > /tmp/apiserver-eviction-manifest.py
    sudo python3 /tmp/apiserver-eviction-manifest.py "$MANIFEST" "$BACKUP" $FLAGS
    RC=$?
    rm -f /tmp/apiserver-eviction-manifest.py
    if [ "$RC" -ne 0 ] && [ "$RC" -ne 10 ]; then
      echo "ERROR: could not edit $MANIFEST (exit $RC); nothing changed"
      exit 1
    fi

    # 2. Health gate with rollback, when the manifest changed.
    if [ "$RC" -eq 0 ]; then
      echo "Waiting for kube-apiserver to restart with the new flags ..."
      ok=0
      for i in $(seq 1 90); do
        sleep 2
        if running_with_flags; then ok=1; break; fi
      done
      if [ "$ok" != "1" ]; then
        echo "kube-apiserver not healthy with the new flags after 180s, rolling back to $BACKUP"
        sudo cp "$BACKUP" "$MANIFEST"
        for i in $(seq 1 90); do sleep 2; if livez; then break; fi; done
        echo "rolled back to the previous manifest"
        exit 1
      fi
      echo "kube-apiserver healthy with $FLAGS"
    fi

    # 3. kubeadm-config, so the next `kubeadm upgrade` keeps the flags. Warn
    #    rather than fail: a failure here loses the flags at the next upgrade,
    #    not the change applied above.
    for i in $(seq 1 60); do if livez; then break; fi; sleep 2; done
    KC="sudo kubectl --kubeconfig /etc/kubernetes/admin.conf"
    CC=$($KC -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' 2>/dev/null || true)
    if [ -z "$CC" ]; then
      echo "WARN: could not read kubeadm-config; the eviction tolerations will NOT survive the next kubeadm upgrade. Re-apply the rbac stack."
      exit 0
    fi
    printf '%s' "$CC" > /tmp/kubeadm-cc-eviction.yaml
    echo '${base64encode(local.apiserver_eviction_kubeadm_py)}' | base64 -d > /tmp/apiserver-eviction-kubeadm.py
    sudo python3 /tmp/apiserver-eviction-kubeadm.py /tmp/kubeadm-cc-eviction.yaml /tmp/kubeadm-cc-eviction-new.yaml $FLAGS
    RC=$?
    if [ "$RC" -eq 10 ]; then
      :
    elif [ "$RC" -eq 0 ] && sudo kubeadm init phase upload-config kubeadm --config /tmp/kubeadm-cc-eviction-new.yaml; then
      echo "kubeadm-config reconciled: the eviction tolerations survive the next control-plane upgrade"
    else
      echo "WARN: kubeadm-config reconcile failed; re-apply this stack after the next kubeadm upgrade"
    fi
    sudo rm -f /tmp/kubeadm-cc-eviction.yaml /tmp/kubeadm-cc-eviction-new.yaml /tmp/apiserver-eviction-kubeadm.py
  SH
}

resource "null_resource" "apiserver_eviction_tuning" {
  connection {
    type        = "ssh"
    user        = "wizard"
    host        = var.k8s_master_host
    private_key = var.ssh_private_key
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${base64encode(local.apiserver_eviction_remote_script)}' | base64 -d | bash",
    ]
  }

  # leader_election_tuning and apiserver_oidc_config also read, modify and
  # re-upload kubeadm-config. Run concurrently, one upload would drop the
  # other's change.
  depends_on = [null_resource.leader_election_tuning, null_resource.apiserver_oidc_config]

  # Only the flag values. An edit to the script alone does not restart the
  # apiserver on a routine CI apply.
  triggers = local.apiserver_eviction_flags
}
