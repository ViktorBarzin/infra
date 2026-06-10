#!/usr/bin/env bash
#
# K8s node containerd + kubelet bootstrap. Runs once via cloud-init runcmd.
# Embedded into the cloud-init snippet base64-encoded by main.tf so YAML
# whitespace handling never touches the heredoc bodies — TOML / Python
# blocks below land in /etc/containerd/config.toml etc. with their leading
# whitespace intact.
#
# Layout:
#   1. /etc/containerd/config.toml — config_path + mirror dirs + GC tuning
#   2. /etc/containerd/certs.d/*/hosts.toml — per-registry mirror configs
#   3. /var/lib/kubelet/config.yaml — eviction + shutdown grace + log rotation
#   4. /etc/systemd/logind.conf.d + kubelet.service.d — graceful shutdown
#   5. (master-only) /etc/kubernetes/manifests — apiserver + controller flags
set -euo pipefail

# 1. config_path — match BOTH quote styles. containerd v1 writes `""`,
# containerd v2.x writes `''`. Without the v2 match, hosts.toml mirror
# config is silently ignored — observed 2026-05-26 on k8s-node4
# (containerd v2.2.4) and reproduced on k8s-node5 v1 boot.
sed -i "s|config_path = \"\"|config_path = \"/etc/containerd/certs.d\"|g" /etc/containerd/config.toml
sed -i "s|config_path = ''|config_path = \"/etc/containerd/certs.d\"|g" /etc/containerd/config.toml

# 2. Per-registry hosts.toml — pull-through caches on docker-registry VM
# (10.0.20.10) for high-traffic registries, Traefik LB (10.0.20.200) for
# forgejo. Low-traffic registries (registry.k8s.io, reg.kyverno.io) skip
# the cache and pull direct because past pull-through cache attempts
# truncated downloads and broke VPA certgen + Kyverno image pulls.

mkdir -p /etc/containerd/certs.d/docker.io
cat > /etc/containerd/certs.d/docker.io/hosts.toml <<'DOCKERIO'
server = "https://registry-1.docker.io"

[host."http://10.0.20.10:5000"]
  capabilities = ["pull", "resolve"]

[host."https://registry-1.docker.io"]
  capabilities = ["pull", "resolve"]
DOCKERIO

mkdir -p /etc/containerd/certs.d/ghcr.io
cat > /etc/containerd/certs.d/ghcr.io/hosts.toml <<'GHCR'
server = "https://ghcr.io"

[host."http://10.0.20.10:5010"]
  capabilities = ["pull", "resolve"]

[host."https://ghcr.io"]
  capabilities = ["pull", "resolve"]
GHCR

# Forgejo OCI registry: prefer in-cluster Traefik LB (10.0.20.203) to
# avoid hairpin NAT. Traefik serves the *.viktorbarzin.me wildcard so
# SNI verification succeeds. If the mirror is unreachable, fall back to
# public DNS resolution (needs the global DNS fallback set up below).
mkdir -p /etc/containerd/certs.d/forgejo.viktorbarzin.me
cat > /etc/containerd/certs.d/forgejo.viktorbarzin.me/hosts.toml <<'FORGEJO'
server = "https://forgejo.viktorbarzin.me"

[host."https://10.0.20.203"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
FORGEJO

# /etc/hosts pin — REQUIRED in addition to the hosts.toml mirror. The
# mirror alone cannot make forgejo pulls hairpin-proof for two reasons
# (2026-06-10 tuya-bridge outage, third incident of this class):
#   a) Traefik routes by Host/SNI and 404s the mirror's bare-IP requests,
#      so containerd always falls back to `server` (public DNS → hairpin).
#   b) The registry's Bearer auth realm is the absolute URL
#      https://forgejo.viktorbarzin.me/v2/token, which containerd fetches
#      verbatim — that leg never goes through the mirror at all.
# Pinning the name to Traefik's LB fixes resolve + token + blob legs with
# correct SNI and a valid cert. If Traefik's LB IP ever changes, update
# this pin together with the hosts.toml IP above.
grep -q forgejo-internal-pin /etc/hosts || \
  echo '10.0.20.203 forgejo.viktorbarzin.me # forgejo-internal-pin (managed: setup-forgejo-containerd-mirror.sh)' >> /etc/hosts

# quay.io + registry.k8s.io: include mirror configs that match node4's
# layout (no real pull-through cache today, server line is the direct
# upstream). Keeping these present makes the per-node config uniform and
# lets us flip a cache on later by editing only the [host."..."] block.
mkdir -p /etc/containerd/certs.d/quay.io
cat > /etc/containerd/certs.d/quay.io/hosts.toml <<'QUAY'
server = "https://quay.io"

[host."http://10.0.20.10:5020"]
  capabilities = ["pull", "resolve"]
QUAY

mkdir -p /etc/containerd/certs.d/registry.k8s.io
cat > /etc/containerd/certs.d/registry.k8s.io/hosts.toml <<'K8SREG'
server = "https://registry.k8s.io"

[host."http://10.0.20.10:5030"]
  capabilities = ["pull", "resolve"]
K8SREG

# 3. containerd tuning: parallel pulls + selective GC overrides.
# containerd v2's `config default` ALREADY emits `[plugins.'io.containerd.gc.v1.scheduler']`,
# `[plugins.'io.containerd.runtime.v2.task']`, and `[plugins.'io.containerd.metadata.v1.bolt']`
# sections — declaring them again fails with `toml: table … already exists`
# (observed on node6 boot 2026-05-26). Patch values in place instead.
sed -i 's/.*max_concurrent_downloads = 3/max_concurrent_downloads = 20/g' /etc/containerd/config.toml
# pause_threshold: 0.5 → 0.02 (run GC more aggressively when images dirty %)
sed -i "s/^[[:space:]]*pause_threshold = .*/  pause_threshold = 0.02/" /etc/containerd/config.toml
# schedule_delay: 0s/1ms → 30 min (longer cool-down between GC runs)
sed -i "s/^[[:space:]]*schedule_delay = .*/  schedule_delay = '1800s'/" /etc/containerd/config.toml
# exit_timeout: 0s → 5m (more aggressive container cleanup)
sed -i "s/^[[:space:]]*exit_timeout = .*/  exit_timeout = '5m'/" /etc/containerd/config.toml

# 4. (kubelet tuning intentionally NOT here — /var/lib/kubelet/config.yaml
# only exists AFTER kubeadm join. That work runs in
# k8s-node-post-join-tune.sh, invoked as a separate cloud-init runcmd
# step after the join completes.)

# 5. logind + kubelet systemd unit — total kubelet shutdown 310s, so
# logind InhibitDelay > that and kubelet TimeoutStopSec > that.
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/kubelet-shutdown.conf <<'LOGIND_CONF'
[Login]
InhibitDelayMaxSec=480
LOGIND_CONF
systemctl restart systemd-logind

mkdir -p /etc/systemd/system/kubelet.service.d
cat > /etc/systemd/system/kubelet.service.d/20-shutdown.conf <<'KUBELET_SHUTDOWN'
[Service]
TimeoutStopSec=420s
KUBELET_SHUTDOWN
systemctl daemon-reload

# 6. (master-only) faster pod eviction + attach-detach reconcile.
if [ -f /etc/kubernetes/manifests/kube-controller-manager.yaml ]; then
    python3 - <<'CM_PATCH'
import yaml
with open('/etc/kubernetes/manifests/kube-controller-manager.yaml') as f:
    m = yaml.safe_load(f)
args = m['spec']['containers'][0]['command']
for flag in ['--attach-detach-reconcile-sync-period=15s']:
    key = flag.split('=')[0]
    args = [a for a in args if not a.startswith(key)]
    args.append(flag)
m['spec']['containers'][0]['command'] = args
with open('/etc/kubernetes/manifests/kube-controller-manager.yaml', 'w') as f:
    yaml.dump(m, f, default_flow_style=False)
CM_PATCH
    python3 - <<'AS_PATCH'
import yaml
with open('/etc/kubernetes/manifests/kube-apiserver.yaml') as f:
    m = yaml.safe_load(f)
args = m['spec']['containers'][0]['command']
for flag in ['--default-unreachable-toleration-seconds=60', '--default-not-ready-toleration-seconds=60']:
    key = flag.split('=')[0]
    args = [a for a in args if not a.startswith(key)]
    args.append(flag)
m['spec']['containers'][0]['command'] = args
with open('/etc/kubernetes/manifests/kube-apiserver.yaml', 'w') as f:
    yaml.dump(m, f, default_flow_style=False)
AS_PATCH
fi
