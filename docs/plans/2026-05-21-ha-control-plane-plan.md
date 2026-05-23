# HA Control Plane (3 masters) — Plan

**Date**: 2026-05-21 (locked + revised 2026-05-22 after challenger pass)
**Status**: Drafted, awaiting approval
**Pairs with**: `2026-05-21-ha-control-plane-design.md`
**Beads**: `code-n0ow`

## Goal

Migrate the single-master cluster to a 3-master HA control plane behind
a pfSense HAProxy VIP (`10.0.20.99:6443`), enabling autonomous k8s
upgrades without storm-cascade manual nursing.

## Topology — before / after

```
Before                            After
                                  ┌──────────────────────┐
                                  │ pfSense HAProxy      │
                                  │  10.0.20.99:6443     │
                                  │  TCP, /readyz health │
                                  └──┬───────┬───────┬───┘
┌───────────────┐                    │       │       │
│ k8s-master    │                    ▼       ▼       ▼
│ 10.0.20.100   │     ┌──────────────┐ ┌────────────┐ ┌────────────┐
│ apiserver+etcd│     │k8s-master    │ │k8s-master-2│ │k8s-master-3│
│ + workers join│     │10.0.20.100   │ │10.0.20.110 │ │10.0.20.111 │
│ directly      │     │(VMID 200)    │ │(VMID 205)  │ │(VMID 206)  │
└───────────────┘     │apiserver+etcd│ │apiserver+e.│ │apiserver+e.│
                      └──────────────┘ └────────────┘ └────────────┘
                          ▲                ▲                ▲
                          └────────────────┼────────────────┘
                                           │
                            etcd quorum (3 members, tolerates 1 down)
```

## Research decisions (locked — see design doc for full table)

| Decision | Value |
|---|---|
| LB strategy | pfSense HAProxy, TCP mode, HTTPS `/readyz` health check |
| VIP | `10.0.20.99` (FQDN `k8s-apiserver.viktorbarzin.lan`) |
| New master IPs | `10.0.20.110`, `10.0.20.111` |
| New master VMIDs | `205`, `206` |
| Master sizing | 8 vCPU, 32 GB RAM, 64 GB disk (matches existing) |
| VM provisioning | cloud-init via `create-template-vm` (template bumped v1.32 → v1.34 first; `k8s_join_command = ""` for masters) |
| etcd | stacked (kubeadm-managed) |
| Multi-master apiserver flags | rbac stack refactored to loop over master list (Phase 1.5) |
| controlPlaneEndpoint + cert SAN retrofit | Phase 0, before any new master joins |
| k8s-version-upgrade chain | extended to multi-master in Phase 7 |

## Callers / blast radius

| Surface | Path | Phase |
|---|---|---|
| Worker `/etc/kubernetes/kubelet.conf` × 4 | nodes 1-4 | 4.2 |
| `/home/wizard/code/infra/config` (root kubeconfig used by every `tg apply`) | repo root | 4.1 |
| `config.tfvars:115` (`kubernetes IN A 10.0.20.100` zone-file record) | repo root | 1.1 (delete) |
| `config.tfvars:231` (`k8s_join_command` for cloud-init template) | repo root | 4.1 (flip to VIP) |
| `stacks/rbac/modules/rbac/{apiserver-oidc,audit-policy,etcd-tuning}.tf` | `var.k8s_master_host` defaults | 1.5 (refactor to list) |
| `.woodpecker/{default,drift-detection,renew-tls,provision-user}.yml` (4 files × 2 refs each — kubeconfig `server:` AND `curl` lines) | repo root | 4.1 |
| `stacks/k8s-portal/.../files/src/routes/{download,setup/script}/+server.ts` (`CLUSTER_SERVER` const used to generate user kubeconfigs) | k8s-portal module | 4.1 |
| `stacks/k8s-version-upgrade/scripts/upgrade-step.sh` (hard-coded `k8s-master` in phase_master) | stack | 7.1 |
| `stacks/infra-maintenance/.../main.tf` lines 98 + 218 (`node_name = "k8s-master"` on etcd-backup + defrag-etcd CronJobs) | stack | 4.5 |
| `kured-sentinel-gate` bash loop | `stacks/kured/main.tf` | 5.1 |
| `docs/architecture/compute.md`, `.claude/skills/uptime-kuma/SKILL.md`, runbooks | docs | 6.3 |
| **No-op surfaces** (confirmed clean): Vault (uses `kubernetes.default.svc`), Cloudflared (no apiserver tunnel), in-cluster `kubernetes.default.svc` / `10.96.0.1`, etcd-backup CORRECTNESS (snapshot is cluster-wide), kubeadm-managed etcd peer certs (auto-generated on join) | | — |

## Edge cases

- **Phase 0 apiserver restart (~30s)** = same blast radius as today's k8s upgrade (tigera/cnpg/gpu-operator briefly crash). The LB doesn't help here because the new cert isn't yet trusted by clients. Accept the brief outage. Schedule during a low-activity window.
- **`kubeadm-certs` secret TTL = 2h** (NOT 24h as initially stated). Phase 2 + 3 must complete within the window, or re-upload between them.
- **pfSense haproxy bootstrap = reset-to-declared-state** on each run (lines 155-158 of the script). Adding master-2 means the apiserver pool is briefly torn down + rebuilt. TCP frontends bounce. Long-poll connections from kubelets break + reconnect. Expect ~2-5s of "kubectl: unable to connect" during pool rewrites.
- **TCP health check is too lax** for apiserver (listener up ≠ ready). Phase 1 uses HTTPS `GET /readyz` with `verify none` — catches NotReady (etcd unreachable, controller-manager flapping).
- **Worker kubelet.conf flip**: kubelet TLS bootstrap re-auths against new endpoint on restart. Expect 5-10s NotReady per node during the Phase 4.2 loop.
- **VIP cannot be the existing master IP**: confirmed `.99` is free (no grep matches, no MetalLB pool conflict — pool is .200-.220).
- **pfSense reboot windows**: pre-Phase-4 OK (clients still on direct IP), post-Phase-4 breaks everything. Don't migrate near a pfSense maintenance window.

## Phased plan

Reversible up to Phase 4. Phase 4+ reverse via the rollback section.

### Phase 0 — Retrofit existing cluster (~30 min, ~30s of apiserver outage)

- [ ] **0.1 Pre-flight**
  - [ ] Cluster healthy: `kubectl get nodes` (all Ready), `kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded` empty
  - [ ] Recent etcd backup valid: `ls -lh /srv/nfs/etcd-backup/ | tail -5`
  - [ ] Proxmox VM snapshot of `k8s-master`: `ssh root@192.168.1.127 qm snapshot 200 pre-ha-retrofit`
  - [ ] IPs free: `for ip in 99 110 111; do ping -c1 -W1 10.0.20.$ip && echo "BUSY $ip" || echo "free $ip"; done`
- [ ] **0.2 Patch `kubeadm-config` ConfigMap via kubeadm (NOT kubectl apply)**
  - [ ] On master: `sudo kubeadm config print init-defaults --component-configs=KubeletConfiguration > /tmp/kubeadm-new.yaml`
  - [ ] Hand-edit /tmp/kubeadm-new.yaml: take the existing CM as base, add `controlPlaneEndpoint: 10.0.20.99:6443` under ClusterConfiguration, add `apiServer.certSANs: [10.0.20.99, k8s-apiserver.viktorbarzin.lan]`
  - [ ] Apply via kubeadm (kubeadm-owned, future `kubeadm upgrade apply` won't overwrite): `sudo kubeadm init phase upload-config kubeadm --config /tmp/kubeadm-new.yaml`
  - [ ] Verify: `kubectl -n kube-system get cm kubeadm-config -o yaml | grep -E 'controlPlaneEndpoint|certSANs'`
- [ ] **0.3 Regen apiserver cert**
  - [ ] On master: `sudo mkdir -p /tmp/apiserver-backup && sudo mv /etc/kubernetes/pki/apiserver.{crt,key} /tmp/apiserver-backup/`
  - [ ] `sudo kubeadm init phase certs apiserver` (reads patched kubeadm-config)
  - [ ] Verify: `sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep -A2 'Subject Alternative'` — expect `IP Address:10.0.20.99` PLUS existing SANs (kubeadm adds, doesn't replace)
- [ ] **0.4 Restart kube-apiserver static pod**
  - [ ] On master: `sudo kubectl -n kube-system delete pod kube-apiserver-k8s-master --force --grace-period=0`
  - [ ] Wait: `kubectl wait --for=condition=Ready pod/kube-apiserver-k8s-master -n kube-system --timeout=180s`
  - [ ] Verify: `kubectl get nodes` works (apiserver alive on direct IP)
- [ ] **0.5 Panic-mode rollback procedure (DOCUMENTED ONLY — only run if 0.4 fails)**
  - [ ] `sudo cp /tmp/apiserver-backup/apiserver.{crt,key} /etc/kubernetes/pki/`
  - [ ] `sudo systemctl restart kubelet` (forces static pod re-read)
  - [ ] Wait for apiserver Ready; revert kubeadm-config edits via the file backup
- [ ] **0.6 Verify operators recovered from brief outage**
  - [ ] `kubectl get pods -n calico-system -l app=tigera-operator -o wide` — Running, restart count incremented by 1 max
  - [ ] `kubectl get pods -n gpu-operator -o wide` — same
  - [ ] `kubectl get pods -n cnpg-system -o wide` — same

### Phase 1 — pfSense HAProxy + DNS (~30 min)

- [ ] **1.1 Reserve VIP `10.0.20.99` + DNS**
  - [ ] Add Virtual IP on pfSense (Firewall → Virtual IPs → IP Alias on VLAN20, `10.0.20.99/24`)
  - [ ] Add `k8s-apiserver-vip → 10.0.20.99` host alias (Firewall → Aliases → Hosts)
  - [ ] phpIPAM: register `10.0.20.99` under section "K8s cluster"
  - [ ] Add DNS A record `k8s-apiserver IN A 10.0.20.99` to `config.tfvars` (and **delete** stale `kubernetes IN A 10.0.20.100` on line 115)
  - [ ] `scripts/tg apply -target=module.technitium` — confirm zone reload
- [ ] **1.2 Extend `infra/scripts/pfsense-haproxy-bootstrap.php` for apiserver pool with HTTPS health check**
  - [ ] Add `build_pool_https()` helper variant (or add `$use_https_readyz` param to existing `build_pool()`) that emits `check_type='HTTP'`, `monitor_uri='/readyz'`, `httpchk_method='GET'`, `ssl='yes'`, `sslverify='no'`
  - [ ] Add `'apiserver_nodes'` to `$POOL_NAMES`; `'apiserver_proxy_6443'` to `$FRONTEND_NAMES`
  - [ ] `build_pool_https('apiserver_nodes', '6443', [['k8s-master', '10.0.20.100']])`
  - [ ] `build_frontend('apiserver_proxy_6443', 'K8s apiserver VIP', '10.0.20.99', '6443', 'apiserver_nodes')`
- [ ] **1.3 Deploy + validate**
  - [ ] `scp infra/scripts/pfsense-haproxy-bootstrap.php admin@10.0.20.1:/tmp/ && ssh admin@10.0.20.1 'php /tmp/pfsense-haproxy-bootstrap.php'`
  - [ ] `ssh admin@10.0.20.1 'sockstat -l | grep 10.0.20.99:6443'` — expect haproxy listening
  - [ ] `ssh admin@10.0.20.1 "echo 'show servers state' | socat /tmp/haproxy.socket stdio" | grep apiserver` — backend UP (op_state=2)
- [ ] **1.4 Smoke via VIP**
  - [ ] From devvm: `curl --cacert /etc/kubernetes/pki/ca.crt https://10.0.20.99:6443/readyz` — expect `ok`
  - [ ] Build a transient kubeconfig pointing at VIP, run `kubectl get nodes` — succeeds
  - [ ] **If TLS validation fails: STOP — Phase 0 cert regen didn't include VIP**, rollback Phase 1 and retry Phase 0

### Phase 1.5 — Refactor rbac stack for multi-master (~45 min)

- [ ] **1.5.1 Refactor `stacks/rbac/modules/rbac/{apiserver-oidc,audit-policy,etcd-tuning}.tf`**
  - [ ] Replace `var.k8s_master_host = "10.0.20.100"` with `var.k8s_master_hosts = list(string)` (default `["10.0.20.100"]`)
  - [ ] Wrap each `null_resource` / `provisioner "remote-exec"` block in `for_each = toset(var.k8s_master_hosts)` so the same sed runs on every master
  - [ ] In `stacks/rbac/main.tf` set `k8s_master_hosts = ["10.0.20.100"]` (still single-master in this phase — variable is forward-looking, no behaviour change yet)
- [ ] **1.5.2 `scripts/tg apply` rbac stack** — confirm zero diff against today (no-op refactor)
- [ ] **1.5.3 Verify** — sanity: `ssh wizard@k8s-master 'sudo grep oidc-issuer-url /etc/kubernetes/manifests/kube-apiserver.yaml | wc -l'` — expect `1`. Cluster healthy.

### Phase 2 — Cloud-init template bump + master-2 (~75 min)

- [ ] **2.0 Bump cloud-init template (one-time)**
  - [ ] Edit `infra/modules/create-template-vm/cloud_init.yaml`:
    - line 49: apt source `pkgs.k8s.io/core:/stable:/v1.32/deb/` → `pkgs.k8s.io/core:/stable:/v1.34/deb/`
    - line 135: wrap `${k8s_join_command}` in a conditional via cloud-init `if:` template logic, or simpler: add `${k8s_join_command_or_noop}` and let the module pass `""` for masters and the real worker join command for workers (default)
  - [ ] Update `infra/modules/create-template-vm/main.tf` to add `variable "k8s_join_command" { default = "" }` and a conditional in the templatefile to skip the runcmd line when empty
  - [ ] Rebuild the template: `scripts/tg apply -target=module.k8s_template` (or whatever the existing template-build target name is in `stacks/infra/main.tf`)
  - [ ] Verify new template registered in Proxmox at the same template_id
- [ ] **2.1 Add master-2 VM to Terraform**
  - [ ] In `stacks/infra/main.tf`: add `module "k8s-master-2"` using `create-vm` from the (now-v1.34) k8s template, with master sizing (8 vCPU / 32GB / 64GB), VMID 205, IP `10.0.20.110`, unique MAC, `vmbr1/vlan 20`, `use_cloud_init = true`, and explicitly pass `k8s_join_command = ""` (so first-boot does NOT auto-join as worker)
  - [ ] `scripts/tg apply -target=module.k8s-master-2`
  - [ ] Verify VM booted: `ssh wizard@k8s-master-2.viktorbarzin.lan uname -a` (expect Ubuntu 26.04 LTS, kernel 7.0.x)
- [ ] **2.2 Prep master-2 for kubeadm join**
  - [ ] Confirm versions: `ssh wizard@k8s-master-2.viktorbarzin.lan 'kubeadm version; containerd --version'` — expect kubeadm v1.34.x, containerd 2.2.2+
  - [ ] DNS resolves: `getent hosts k8s-master-2.viktorbarzin.lan`
- [ ] **2.3 Upload certs on existing master**
  - [ ] `sudo kubeadm init phase upload-certs --upload-certs` → records `--certificate-key <KEY>`
  - [ ] **2h TTL** — Phase 2 + 3 must complete within window or re-upload
- [ ] **2.4 Generate join command**
  - [ ] `sudo kubeadm token create --print-join-command` → `kubeadm join 10.0.20.99:6443 --token <T> --discovery-token-ca-cert-hash sha256:<H>`
  - [ ] Append `--control-plane --certificate-key <KEY>`
- [ ] **2.5 Run join on master-2**
  - [ ] `ssh wizard@k8s-master-2.viktorbarzin.lan` → run sudo join command from 2.4
  - [ ] Wait for "This node has joined the cluster"
- [ ] **2.6 Update rbac stack to include master-2 (propagates OIDC/audit/etcd tuning to it)**
  - [ ] Edit `stacks/rbac/main.tf`: `k8s_master_hosts = ["10.0.20.100", "10.0.20.110"]`
  - [ ] `scripts/tg apply` rbac stack
  - [ ] Verify: `ssh wizard@k8s-master-2 'sudo grep -c oidc-issuer-url /etc/kubernetes/manifests/kube-apiserver.yaml'` — expect `1`
- [ ] **2.7 Smoke**
  - [ ] `kubectl get nodes` — 6 nodes, master-2 Ready control-plane
  - [ ] `kubectl -n kube-system get pods -o wide | grep k8s-master-2` — 4 static pods Running
  - [ ] etcd member list shows 2 members
  - [ ] `kubectl --server=https://10.0.20.110:6443 get nodes` — direct probe works
- [ ] **2.8 Add master-2 to LB pool**
  - [ ] Edit `pfsense-haproxy-bootstrap.php`: pool now `[['k8s-master', '10.0.20.100'], ['k8s-master-2', '10.0.20.110']]`
  - [ ] Deploy + verify both backends UP

### Phase 3 — master-3 (~45 min) — same pattern as Phase 2

- [ ] **3.1 Add `module.k8s-master-3` to Terraform** (VMID 206, IP `10.0.20.111`, same template, `k8s_join_command = ""`)
- [ ] **3.2 Prep verify**
- [ ] **3.3 Re-upload certs if >2h since Phase 2.3, refresh `--certificate-key`**
- [ ] **3.4 Generate fresh join command**
- [ ] **3.5 Run join on master-3**
- [ ] **3.6 Update rbac stack: `k8s_master_hosts = [".100", ".110", ".111"]`, apply, verify master-3 has OIDC flag**
- [ ] **3.7 Smoke (7 nodes, 3 control-plane, etcd quorum 3/3)**
- [ ] **3.8 Add master-3 to LB pool — all three backends UP**

### Phase 4 — Cut over clients and workers to VIP (~45 min)

- [ ] **4.1 Update in-repo kubeconfig consumers (single commit)**
  - [ ] `/home/wizard/code/infra/config` — flip `server:` to `https://10.0.20.99:6443`
  - [ ] `config.tfvars:231` — `k8s_join_command` to `kubeadm join 10.0.20.99:6443 ...`
  - [ ] `stacks/rbac/modules/rbac/apiserver-oidc.tf` — variable `default = "10.0.20.99"` (or whatever the multi-master refactor needs)
  - [ ] `.woodpecker/default.yml` — flip server: AND curl URL
  - [ ] `.woodpecker/drift-detection.yml` — flip server: AND curl URL
  - [ ] `.woodpecker/renew-tls.yml` — flip curl URL (line 18)
  - [ ] `.woodpecker/provision-user.yml` — flip curl URL (line 41)
  - [ ] `stacks/k8s-portal/modules/k8s-portal/files/src/routes/download/+server.ts` — `CLUSTER_SERVER` const
  - [ ] `stacks/k8s-portal/modules/k8s-portal/files/src/routes/setup/script/+server.ts` — same
  - [ ] Final sweep: `cd /home/wizard/code/infra && grep -rn '10.0.20.100:6443' --include='*.tf' --include='*.yml' --include='*.yaml' --include='*.ts' --include='*.php' --include='*.sh'` — handle anything remaining
  - [ ] `scripts/tg apply` for rbac + k8s-portal (and any other stacks touched)
  - [ ] Commit + push (single conventional commit referencing `code-n0ow`)
- [ ] **4.2 Worker `kubelet.conf` flip (one at a time, with 5-10s expected NotReady)**
  ```bash
  for n in k8s-node1 k8s-node2 k8s-node3 k8s-node4; do
    echo "=== $n ==="
    ssh wizard@$n.viktorbarzin.lan "sudo sed -i.bak 's|server: https://10.0.20.100:6443|server: https://10.0.20.99:6443|' /etc/kubernetes/kubelet.conf"
    ssh wizard@$n.viktorbarzin.lan "sudo systemctl restart kubelet"
    kubectl wait --for=condition=Ready node/$n --timeout=180s
    echo "$n Ready"
    sleep 15
  done
  ```
- [ ] **4.3 Existing master's `kubelet.conf`** — same sed + restart on `k8s-master`
- [ ] **4.4 Verify master-2 + master-3 kubelet.conf already at VIP** (cloud-init join used VIP via controlPlaneEndpoint)
- [ ] **4.5 Verify everything**
  - [ ] `kubectl get nodes` — all 7 Ready
  - [ ] `kubectl --kubeconfig ~/.kube/config config view --minify -o jsonpath='{.clusters[0].cluster.server}'` → `https://10.0.20.99:6443`
  - [ ] Worker loop: `for n in k8s-{master,node1,node2,node3,node4,master-2,master-3}; do ssh wizard@$n.viktorbarzin.lan "sudo grep server: /etc/kubernetes/kubelet.conf"; done` — all show VIP
  - [ ] Trigger a no-op Woodpecker pipeline (commit a typo fix in a runbook) — verify the kubeconfig path through the new VIP

### Phase 4.5 — Fix etcd-backup CronJob node pinning (~15 min)

- [ ] **4.5.1 Edit `stacks/infra-maintenance/modules/infra-maintenance/main.tf`**
  - [ ] backup-etcd (line 98): replace `node_name = "k8s-master"` with `nodeSelector { "node-role.kubernetes.io/control-plane" = "" }` + the corresponding toleration block
  - [ ] defrag-etcd (line 218): same change
- [ ] **4.5.2 `scripts/tg apply` infra-maintenance**
- [ ] **4.5.3 Verify backup runs** — trigger a manual job-from-cronjob, confirm it lands on one of the 3 masters and produces a valid snapshot

### Phase 5 — kured-sentinel-gate quorum check (~15 min)

- [ ] **5.1 Edit `infra/stacks/kured/main.tf`** (insert into the bash heredoc in the sentinel-gate ConfigMap, between all-nodes-Ready and calico-Ready checks)
  ```bash
  # Check 3b: control-plane quorum safety (HA invariant)
  CP_READY=$(kubectl get nodes -l node-role.kubernetes.io/control-plane= --no-headers | grep ' Ready ' | wc -l | tr -d ' ')
  if [ "$CP_READY" -lt 2 ]; then
    echo "  BLOCKED: Only $CP_READY control-plane node(s) Ready (need ≥2 for HA)"
    rm -f /host/var-run/gated-reboot-required
    sleep 300
    continue
  fi
  echo "  Control-plane quorum safe ($CP_READY Ready)"
  ```
- [ ] **5.2 `scripts/tg apply` kured**
- [ ] **5.3 Verify**
  - [ ] `kubectl -n kured logs ds/kured-sentinel-gate | tail -50` — expect "Control-plane quorum safe (3 Ready)" line
  - [ ] Negative test: cordon `k8s-master-2`, wait for the gate to re-evaluate, confirm block message. Restore.

### Phase 6 — E2E validation (~30 min)

- [ ] **6.1 Failover test**
  - [ ] `kubectl drain k8s-master --delete-emptydir-data --ignore-daemonsets`
  - [ ] `ssh wizard@k8s-master.viktorbarzin.lan sudo reboot`
  - [ ] During the 50-90s reboot: tight loop `while true; do kubectl get nodes -o name | wc -l; sleep 2; done` from devvm — line count never drops to 0 (LB transparent)
  - [ ] After boot: `kubectl uncordon k8s-master`, verify apiserver static pod re-registers in LB pool (op_state=2)
- [ ] **6.2 All-masters apiserver flag parity**
  - [ ] `for h in k8s-master k8s-master-2 k8s-master-3; do echo "=== $h ==="; ssh wizard@$h.viktorbarzin.lan 'sudo grep -E "oidc-issuer-url|audit-policy|auto-compaction-retention|snapshot-count" /etc/kubernetes/manifests/{kube-apiserver,etcd}.yaml | sort'; done`
  - [ ] Expect identical flag set across all 3 masters
- [ ] **6.3 Update documentation**
  - [ ] Add `docs/architecture/control-plane.md` — HA topology, etcd member list, LB config location
  - [ ] Update `.claude/reference/proxmox-inventory.md` — add VMIDs 205, 206
  - [ ] Add `docs/runbooks/control-plane-add-remove-master.md`
  - [ ] Update `docs/runbooks/restore-etcd.md` to cover 3-member quorum restore (was single-master only)
  - [ ] Cross-link `docs/runbooks/mailserver-pfsense-haproxy.md` with the new apiserver_proxy_6443 pool

### Phase 7 — Extend k8s-version-upgrade chain to multi-master (~60 min)

- [ ] **7.1 Edit `stacks/k8s-version-upgrade/scripts/upgrade-step.sh`**
  - [ ] phase_master: discover masters dynamically — `MASTERS=$($KUBECTL get nodes -l node-role.kubernetes.io/control-plane= -o name | sed 's|node/||')`
  - [ ] Wrap drain → `update_k8s.sh` → uncordon → wait-ready in a `for m in $MASTERS; do ... done` loop
  - [ ] Between masters: quorum check — `READY=$($KUBECTL get nodes -l node-role.kubernetes.io/control-plane= --no-headers | grep ' Ready ' | wc -l); [ $READY -ge 2 ] || { slack "ABORT quorum lost"; exit 1; }`
  - [ ] Update line 9 + 17 comment block to reflect multi-master phase
  - [ ] Update line 326-340 containerd-bump section to loop over masters
- [ ] **7.2 Edit `phase_preflight` and the master phase pin**
  - [ ] Line 209-210 (scheduling_block): allow any control-plane node to be the target
  - [ ] Line 285 (`kubeadm upgrade plan` check): run against the first master in the list, not specifically `k8s-master`
- [ ] **7.3 `scripts/tg apply` k8s-version-upgrade**
- [ ] **7.4 Dry-run test**
  - [ ] `kubectl -n k8s-upgrade create job --from=cronjob/k8s-version-check ha-validation-$(date +%s)` (no actual upgrade pending — chain should noop the upgrade phase but exercise the discovery loop)
  - [ ] Verify logs show 3 masters discovered in correct order
- [ ] **7.5 (Real test on next patch release)** — when 1.34.8 ships:
  - [ ] Watch the chain execute drain → upgrade → uncordon across all 3 masters in turn
  - [ ] Confirm no manual intervention needed

### Phase 8 — Close out

- [ ] **8.1 Update beads** — `bd close code-n0ow` once all 6 acceptance criteria met (see below)

## Rollback plan

### Before Phase 4 (no clients flipped)

- **Phase 0**: restore apiserver cert/key from `/tmp/apiserver-backup/`, edit kubeadm-config back, restart kubelet on master.
- **Phase 1**: remove `apiserver_proxy_6443` + `apiserver_nodes` from `pfsense-haproxy-bootstrap.php`, re-run; revert DNS A record in config.tfvars.
- **Phase 1.5**: revert rbac stack to single `k8s_master_host` var; apply.
- **Phase 2/3**: on failed master `sudo kubeadm reset --force`; from a surviving master `etcdctl member remove <id>`; `tg destroy -target=module.k8s-master-N`.

### After Phase 4 (clients flipped)

- Revert all the Phase 4.1 file changes (single revert commit).
- Reverse the kubelet.conf sed loop (VIP → direct IP) on all 7 nodes.
- Phase 0 controlPlaneEndpoint can stay — harmless even on full rollback.

### Worst case (etcd corruption / multi-master split-brain)

- Restore from latest etcd snapshot via `etcdctl snapshot restore` to a single master.
- Rebuild master VM from the Proxmox snapshot taken in Phase 0.1.
- Cluster back to single-master.

## Acceptance criteria (beads `code-n0ow`)

- [ ] 1. Design doc + plan doc written ✓ (this commit)
- [ ] 2. Plan approved by user
- [ ] 3. 3 masters online, etcd quorum healthy, apiserver LB working
- [ ] 4. k8s upgrade chain runs end-to-end across **all 3 masters** without manual intervention (Phase 7)
- [ ] 5. kured-sentinel-gate respects quorum (Phase 5)
- [ ] 6. etcd backup runs from any control-plane node (Phase 4.5)

## Open questions

None — all locked via 2026-05-22 decision pass + challenger amendment pass.
