# K8s Node Auto-Upgrades

## Overview

OS-level package upgrades on the 5 K8s VMs (master + 4 workers) are driven by `unattended-upgrades` and rebooted by `kured`, with multiple safety gates layered on top to prevent the failure mode that caused the March 2026 26h cluster outage.

## Architecture

```
apt-daily.timer (random within window)
  │ apt-get update
  │
  ▼
apt-daily-upgrade.timer (random within window)
  │ unattended-upgrades runs
  │   - Allowed-Origins: -security, -updates, ESM
  │   - Package-Blacklist: containerd*, runc, calico-*, cni-plugins-*, docker-ce
  │   - apt-mark hold on kubelet, kubeadm, kubectl, containerd*, runc
  │   - Automatic-Reboot=false (kured handles reboots)
  │
  ▼ if kernel/glibc/systemd updated
/var/run/reboot-required appears on the host
  │
  ▼ (sentinel-gate DaemonSet polls every 5min)
kured-sentinel-gate checks:
  ├── 1. Host has /var/run/reboot-required
  ├── 2. ALL nodes Ready
  ├── 3. ALL calico-node pods Running
  └── 4. NO node Ready-transition in last 24h (soak window)
  │
  ▼ all pass
touch /var/run/gated-reboot-required
  │
  ▼ (kured polls every 1h within 02:00-06:00 London Mon-Fri window)
kured checks Prometheus before draining:
  │ http://prometheus-server.monitoring.svc.cluster.local:80/api/v1/alerts
  │ ANY firing alert (except ignore-list) blocks the drain
  │ Ignore-list: ^(Watchdog|RebootRequired|KuredNodeWasNotDrained|InfoInhibitor)$
  │
  ▼ no blockers
kured drains the node (priority-ordered, 310s budget)
kured runs /bin/systemctl reboot
  │
  ▼ node returns
kured uncordons + posts Slack notification (configuration.notifyUrl)
  │
  ▼ 24h cool-down begins (sentinel-gate Check 4)
```

## Components

### unattended-upgrades (in-guest)
- **Config**: `/etc/apt/apt.conf.d/52unattended-upgrades-k8s` + `/etc/apt/apt.conf.d/20auto-upgrades`
- **Source of truth**: `infra/modules/create-template-vm/cloud_init.yaml` (lines for `is_k8s_template`)
- **Day-2 push**: SSH-based — see "Restore / re-apply config" below

### kured (Helm release)
- **Stack**: `infra/stacks/kured/main.tf`
- **Helm chart**: `kured-5.11.0` (image `ghcr.io/kubereboot/kured:1.21.0`)
- **Window**: Mon-Fri 02:00-06:00 Europe/London, period=1h, concurrency=1
- **Sentinel**: `/sentinel/gated-reboot-required` (created by sentinel-gate DaemonSet)
- **Slack hook**: Vault `secret/kured` → `slack_kured_webhook`

### kured-sentinel-gate (DaemonSet)
- **Source**: `kubernetes_daemon_set_v1.kured_sentinel_gate` in `infra/stacks/kured/main.tf` (lines ~120-260)
- **Image**: `bitnami/kubectl:latest`
- **Loop period**: every 300s
- **Gate logic**: 4 checks — see Architecture diagram

### Upgrade Gates Prometheus alerts
- **Source**: `infra/stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl` group `Upgrade Gates`
- **10 alerts**: KubeAPIServerDown, KubeStateMetricsDown, PrometheusRuleEvaluationFailing, PVCStuckPending, RecentNodeReboot, MysqlStandaloneDown, ClusterPodReadyRatioDropped, NodeMemoryPressure, NodeDiskPressure, KubeQuotaAlmostFull
- **Effect**: kured `--prometheus-url` polls Prometheus before each drain — any non-ignored firing alert halts the rollout

## Common Operations

### Verify the system is healthy
```bash
# kured pods + sentinel-gate Running on all 5 nodes
kubectl -n kured get pods

# kured can reach Prometheus
kubectl -n kured exec ds/kured -- /usr/bin/kured --help | grep prometheus

# Upgrade Gates rules loaded + state
kubectl -n monitoring exec deploy/prometheus-server -c prometheus-server -- \
  wget -q -O- 'http://localhost:9090/api/v1/rules' | \
  jq -r '.data.groups[] | select(.name == "Upgrade Gates") | .rules[] | "  \(.name): \(.state)"'

# Per-node unattended-upgrades status
for n in k8s-master k8s-node1 k8s-node2 k8s-node3 k8s-node4; do
  echo "=== $n ==="
  ssh $n "systemctl is-active unattended-upgrades; apt list --upgradable 2>/dev/null | wc -l"
done
```

### Halt rollout in an emergency
```bash
# Option 1: scale kured to 0 (most decisive)
kubectl -n kured scale ds kured --replicas=0
# When ready: kubectl -n kured scale ds kured --replicas=5

# Option 2: silence the gate via Alertmanager (allows kured to retry once silence expires)
# Use Alertmanager UI at https://prometheus.viktorbarzin.me/alertmanager/
```

### Force halt by adding a custom blocker alert
- Add a PrometheusRule expression that's always-1 (e.g. `vector(1)`) to the `Upgrade Gates` group temporarily.
- Apply, wait for sync (~120s), kured will block on the next poll.
- Remove when ready.

### Pause apt upgrades on a single node
```bash
ssh <node> sudo systemctl stop unattended-upgrades
ssh <node> sudo systemctl disable unattended-upgrades
# Re-enable when ready:
ssh <node> sudo systemctl enable --now unattended-upgrades
```

### Restore / re-apply unattended-upgrades config to existing nodes
Cloud-init only runs on first boot. To bring existing nodes into compliance with the IaC:

```bash
# Per node — installs uu, drops apt config, holds k8s/runtime packages, enables service
for n in k8s-master k8s-node1 k8s-node2 k8s-node3 k8s-node4; do
  ssh $n sudo bash -s <<'EOF'
set -e
systemctl unmask unattended-upgrades 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades update-notifier-common
cat > /etc/apt/apt.conf.d/52unattended-upgrades-k8s <<'CONF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}:${distro_codename}-updates";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {
    "^containerd(\.io)?$";
    "^runc$";
    "^cri-tools$";
    "^kubernetes-cni$";
    "^calico-.*";
    "^cni-plugins-.*";
    "^docker-ce$";
};
Unattended-Upgrade::DevRelease "false";
Unattended-Upgrade::Automatic-Reboot "false";
CONF
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF
apt-mark hold kubelet kubeadm kubectl
apt-mark hold containerd containerd.io runc 2>/dev/null || true
systemctl enable --now unattended-upgrades
EOF
done
```

### Roll back a bad apt upgrade
1. Identify the package(s) that broke things from `/var/log/apt/history.log` on the affected node.
2. Hold them: `sudo apt-mark hold <pkg>`.
3. Downgrade: `sudo apt-get install -y --allow-downgrades <pkg>=<previous-version>` (find versions via `apt-cache madison <pkg>`).
4. Reboot the node manually if the package needs it.
5. Add the package to the `Unattended-Upgrade::Package-Blacklist` in `cloud_init.yaml` AND drop the holds via the SSH push above so future apt runs skip it.

### kured halted — investigate which alert is blocking
```bash
# Show kured logs — it logs "blocking alerts" when halting
kubectl -n kured logs ds/kured --tail=100 | grep -i alert

# List currently firing alerts (any of these blocks kured):
kubectl -n monitoring exec deploy/prometheus-server -c prometheus-server -- \
  wget -q -O- 'http://localhost:9090/api/v1/alerts' | \
  jq -r '.data.alerts[] | select(.state == "firing") | "  \(.labels.alertname) (\(.labels.severity // "info"))"' | sort -u
```

The alert is either:
- One of the 10 `Upgrade Gates` (genuine cluster-health issue — fix it),
- A pre-existing alert (any of the ~211 in the library — investigate),
- Or `RecentNodeReboot` — expected for 24h after each node reboot. This is the soak window.

### Verify the 24h soak is enforcing
```bash
# Sentinel-gate logs Check 4 outcome
kubectl -n kured logs ds/kured-sentinel-gate --tail=20 | grep -E "soak|cool-down|24"

# kured won't drain another node until the most recent Ready-transition is >24h ago.
# If you need to override (e.g. emergency security patch), shorten the cool-down by
# editing infra/stacks/kured/main.tf (sentinel script: 86400 → smaller) and applying.
```

## Past Incidents

- **2026-03-16 SEV-1**: Kured + Containerd Cascade Outage (26h). See `docs/post-mortems/2026-03-16-kured-containerd-cascade-outage.html`. Root cause: unattended-upgrades pushed a kernel update → kured rebooted nodes → containerd's overlayfs snapshotter corrupted → image pulls failed → calico broke → cascading outage. Remediations now baked into this system: 24h soak, Prometheus halt-on-alert, Package-Blacklist for runtime components, sentinel-gate health checks.

## File Pointers

| What | Where |
|------|-------|
| kured Helm + sentinel-gate | `infra/stacks/kured/main.tf` |
| Upgrade Gates alerts | `infra/stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl` (group "Upgrade Gates") |
| Cloud-init for new nodes | `infra/modules/create-template-vm/cloud_init.yaml` |
| Slack webhook | Vault `secret/kured` → `slack_kured_webhook` |
| Post-mortem | `infra/docs/post-mortems/2026-03-16-kured-containerd-cascade-outage.html` |
| Architecture doc | `infra/docs/architecture/automated-upgrades.md` (OS section) |
