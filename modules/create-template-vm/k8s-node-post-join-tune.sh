#!/usr/bin/env bash
#
# Runs AFTER `kubeadm join` has written /var/lib/kubelet/config.yaml.
# Patches kubelet config in place (parallel image pulls, eviction
# thresholds, priority-based shutdown grace, container log rotation)
# and (on master) tightens controller-manager / apiserver flags.
#
# Embedded into the cloud-init snippet base64-encoded by main.tf so
# YAML whitespace doesn't touch the heredoc bodies inside.
set -euo pipefail

if [ ! -f /var/lib/kubelet/config.yaml ]; then
    echo "post-join-tune: /var/lib/kubelet/config.yaml not found — was kubeadm join run?" >&2
    exit 1
fi

# Parallel image pulls.
sed -i '/serializeImagePulls:/d' /var/lib/kubelet/config.yaml
sed -i '/maxParallelImagePulls:/d' /var/lib/kubelet/config.yaml
printf 'serializeImagePulls: false\nmaxParallelImagePulls: 50\n' >> /var/lib/kubelet/config.yaml

# Memory / disk eviction. Aggressive disk thresholds (15%/20%)
# prevent the 2026-03-13 containerd image-store corruption that took
# down k8s-node2.
sed -i '/systemReserved:/d; /kubeReserved:/d; /evictionHard:/,/^[^ ]/{ /evictionHard:/d; /^  /d }; /evictionSoft:/,/^[^ ]/{ /evictionSoft:/d; /^  /d }; /evictionSoftGracePeriod:/,/^[^ ]/{ /evictionSoftGracePeriod:/d; /^  /d }' /var/lib/kubelet/config.yaml

cat >> /var/lib/kubelet/config.yaml <<'KUBELET_PATCH'
systemReserved:
  memory: "512Mi"
  cpu: "200m"
kubeReserved:
  memory: "512Mi"
  cpu: "200m"
evictionHard:
  memory.available: "500Mi"
  nodefs.available: "15%"
  imagefs.available: "20%"
evictionSoft:
  memory.available: "1Gi"
  nodefs.available: "20%"
  imagefs.available: "25%"
evictionSoftGracePeriod:
  memory.available: "30s"
  nodefs.available: "60s"
  imagefs.available: "30s"
memorySwap:
  swapBehavior: "LimitedSwap"
KUBELET_PATCH

# Container log rotation + priority-based shutdown grace.
sed -i '/^shutdownGracePeriod:/d; /^shutdownGracePeriodCriticalPods:/d' /var/lib/kubelet/config.yaml
python3 - <<'KUBELET_FINAL'
import yaml
with open('/var/lib/kubelet/config.yaml') as f:
    cfg = yaml.safe_load(f)
cfg.pop('shutdownGracePeriod', None)
cfg.pop('shutdownGracePeriodCriticalPods', None)
cfg.pop('shutdownGracePeriodByPodPriority', None)
cfg['containerLogMaxSize'] = '10Mi'
cfg['containerLogMaxFiles'] = 3
# Per-tier grace CORRECTED from a live drill (2026-07-20). A full-node graceful
# drill measured a 9-min uncapped drain: kubelet does NOT short-circuit when a
# whole node drains -- it consumes close to each tier's full grace in sequence,
# so the tier caps ARE the drain time (the earlier per-pod delete tests, 4-26s,
# were misleading). The host VM down= (180s) is the binding ceiling, so the goal
# is to reach the DATABASE tier FAST and give it maximal grace within 180s:
#   apps (0/200k) 10s, edge/gpu (400k/600k) 15s  -> DB tier reached at ~50s
#   DB tier (800k) 90s                            -> DBs drain 50-140s (<180) OK
#   core (1M, traefik ~26s) 30s                   -> 140-170s (<180) OK
#   gpu-workload + system/node 15s                -> tail; force-killed at 180s
# Apps tolerate SIGKILL; databases do not -- this deliberately favours DBs.
cfg['shutdownGracePeriodByPodPriority'] = [
    {'priority': 0,          'shutdownGracePeriodSeconds': 10},
    {'priority': 200000,     'shutdownGracePeriodSeconds': 10},
    {'priority': 400000,     'shutdownGracePeriodSeconds': 15},
    {'priority': 600000,     'shutdownGracePeriodSeconds': 15},
    {'priority': 800000,     'shutdownGracePeriodSeconds': 90},
    {'priority': 1000000,    'shutdownGracePeriodSeconds': 30},
    {'priority': 1200000,    'shutdownGracePeriodSeconds': 15},
    {'priority': 2000000000, 'shutdownGracePeriodSeconds': 15},
    {'priority': 2000001000, 'shutdownGracePeriodSeconds': 15},
]
with open('/var/lib/kubelet/config.yaml', 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False)
KUBELET_FINAL

# Reload kubelet to pick up new config (it's already started by the
# preceding cloud-init runcmd line — restart, not start).
systemctl restart kubelet
