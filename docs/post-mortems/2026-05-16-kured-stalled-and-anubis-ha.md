# Post-Mortem: kured Reboots Silently Stalled for 6 Days + Anubis HA Lift

| Field | Value |
|-------|-------|
| **Date** | 2026-05-16 |
| **Duration** | 6 days of unbooted pending-reboot packages (2026-05-10 → 2026-05-16) |
| **Severity** | SEV3 — no user-facing impact; latent risk (kernel/libc CVEs queued, not landing) |
| **Affected Services** | None directly; OS-reboot pipeline halted on all 5 K8s nodes |
| **Status** | Root cause fixed (kured Helm value), defensive defaults added (Anubis HA, kured drain-timeout, CNPG 3 instances) |

## Summary

After unattended-upgrades was re-enabled on the K8s nodes on 2026-05-10,
kured was supposed to drive rolling node reboots within the Mon–Fri
02:00–06:00 London window. Instead, kured logged "Reboot not required"
every hour for six straight days while the `kured-sentinel-gate`
DaemonSet on every host happily reported "ALL CHECKS PASSED — creating
/var/run/gated-reboot-required". The gate WAS open. kured was looking
in the wrong place.

The kured Helm chart derives the sentinel hostPath from
`dirname(configuration.rebootSentinel)`. The stack set
`rebootSentinel = "/sentinel/gated-reboot-required"` — which pointed
the chart at hostPath `/sentinel/` (an empty auto-created directory).
The sentinel-gate writes to `/var/run/gated-reboot-required` on the
host. Two different host directories. kured silently skipped reboots
for six days.

Found on 2026-05-16 while auditing why "automatic upgrades aren't
happening" alongside the K8s version-upgrade Job-chain (PM
2026-05-11). Fixed in one commit; took the opportunity to also
eliminate three latent drain-time hazards (Anubis single-replica PDB
deadlock, kured unbounded drain timeout, CNPG-only-2-instances).

## Impact

- **User-facing**: None. Existing kernels, libc, and userspace kept running. CVEs queued in `/var/run/reboot-required.pkgs` on every node but were never exploited.
- **Backlog**: All 5 nodes accumulated `linux-image-*` + `libc6` queued for reboot. Largest gap was master at ~6 days. Workers also 5–6 days.
- **Detection gap**: kured exposes no Prometheus signal for "I checked but said no". The hourly "Reboot not required" line in stdout is the only trace, and nobody was tailing it. The architecture had two layers (sentinel-gate gate + kured sentinel check) but no verification that the two layers were looking at the same path.
- **Side discovery**: 8 Anubis instances would have stalled drain anyway via single-replica + `PDB minAvailable=1` (the same trap that stalled the manual K8s upgrade on 2026-05-11). Even if the kured path bug were fixed in isolation, Monday's first reboot would have hit the Anubis trap and idled forever (kured default `--drain-timeout=0` = unlimited).

## Timeline (UTC)

| Time | Event |
|------|-------|
| **Mar 16 21:26** | kured-sentinel-gate DaemonSet introduced after the 26h overlayfs cascade outage. Original sentinel cool-down 30m. |
| **May 10 ~16:57** | Last successful kured pod restart picked up new Helm values. `rebootSentinel = "/sentinel/gated-reboot-required"`. Same commit re-enabled unattended-upgrades in cloud_init and stretched the sentinel cool-down 30m → 24h. |
| **May 10 ~17:00 → May 15 06:16** | unattended-upgrades on every node successfully installs kernel + libc patches, writes `/var/run/reboot-required`. |
| **May 10–15** | sentinel-gate Check 1–4 all pass every 5 min on every host. Touches `/var/run/gated-reboot-required`. Logs "ALL CHECKS PASSED". |
| **May 10–15** | kured polls `/sentinel/gated-reboot-required` (empty dir, file does not exist). Returns "Reboot not required" every hour. No reboots happen. |
| **May 11 20:40–21:00** | Separate K8s-version-upgrade incident (master upgraded to v1.34.7, workers stalled mid-rollout because the upgrade agent drained its own host). Manual recovery 5/11–5/12. **kured stall noticed but not investigated**: cluster healthy, K8sVersionSkew firing was tracked as the urgent issue. |
| **May 11 22:47 → May 12 00:01** | Manual worker drains hit the Anubis single-replica PDB trap (drain loops). Resolved by direct-deleting Anubis pods to bypass eviction API. This was the first signal that single-replica `minAvailable=1` patterns deadlock drains. |
| **May 16 10:56 UTC** | While auditing "what runs the upgrades" for the user, the kured + sentinel-gate log/path mismatch became visible. |
| **May 16 11:13 UTC** | `stacks/kured/main.tf`: `rebootSentinel = "/sentinel/..."` → `"/var/run/gated-reboot-required"`. Re-init, plan, apply. |
| **May 16 11:14 UTC** | kured DaemonSet rolls out the new spec. Volume hostPath becomes `/var/run`. kured pod can now see `/sentinel/reboot-required` (32B, from uu) AND `/sentinel/gated-reboot-required` (0B, from gate). Confirmed via `kubectl exec` listing. |
| **May 16 11:44 UTC** | Anubis HA module change deployed: `shared_store_url` variable → `store: { backend: valkey }` block appended to policy YAML, default replicas 2, PDB `maxUnavailable=1`, topology `DoNotSchedule`. Cyberchef applied as canary. Confirmed: Redis DB 5 starts receiving challenge state. |
| **May 16 11:48–11:53 UTC** | Remaining 7 Anubis stacks applied (DBs 6–12). 8/8 deployments at 2/2 Ready, replicas spread on different nodes. Smoke-tested 6 of 8 public URLs return 200. |
| **May 16 12:05 UTC** | kured `drainTimeout: "30m"` added + applied. pg-cluster bumped from 2 → 3 instances. |
| **May 16 12:11 UTC** | pg-cluster phase = "Cluster in healthy state", 3/3 ready. |

## Root Cause

The Helm chart `kured-5.11.0` computes:
```
{{- $sentinel_dir := dir .Values.configuration.rebootSentinel -}}
# template renders both volume mount and hostPath using $sentinel_dir
```

So `rebootSentinel` is doubly-purposed: it's both the **CLI arg path inside
the pod** AND the **hostPath on the node**. Setting it to `/sentinel/...`
caused:
- pod arg: `--reboot-sentinel=/sentinel/gated-reboot-required` (looks at `/sentinel/` inside the pod)
- hostPath: `/sentinel/` (auto-created empty directory by `type: Directory`)
- mountPath inside pod: `/sentinel/` (mapped from hostPath above)

Meanwhile the gate DaemonSet was configured with hostPath `/var/run` →
mountPath `/host/var-run`, and wrote `gated-reboot-required` to its local
`/host/var-run/` which became the host's `/var/run/gated-reboot-required`.

The two daemons never touched the same directory.

**Why this was hard to spot**:

1. Both layers logged success: sentinel-gate said "ALL CHECKS PASSED", kured said "Reboot not required". Neither claimed an error.
2. No Prometheus alert exists for "kured polled, gate is open, kured still didn't act". The Upgrade Gates alert group catches firing-alert-during-rollout, not silently-skipped-rollout.
3. The Helm chart's auto-derivation of hostPath from a config value is undocumented surprising behavior. The mental model is "rebootSentinel is just the in-pod path"; the hostPath co-mutation is invisible.

## Remediation

### Primary fix
- `stacks/kured/main.tf`: `rebootSentinel = "/var/run/gated-reboot-required"`. Both the chart-derived hostPath and the kured CLI arg now align with where the gate writes.

### Defensive companion changes (same session)

| Change | Purpose | Stack |
|---|---|---|
| `drainTimeout = "30m"` on kured | Fail closed instead of looping forever if a future PDB or finalizer stalls drain. Node stays Schedulable (no silent capacity loss). | `stacks/kured/main.tf` |
| Anubis: shared-state Valkey/Redis backend | Eliminate the single-replica drain deadlock + provide real HA. PDB changed `minAvailable=1` → `maxUnavailable=1`. Replicas 1 → 2 with `topologySpreadConstraint: DoNotSchedule`. | `modules/kubernetes/anubis_instance/main.tf` + 8 callers |
| pg-cluster: 2 → 3 instances | Failover during primary's node drain no longer depends on the lone replica being caught up. CNPG always has a fully-current candidate. | `stacks/dbaas/modules/dbaas/main.tf` |
| Orphan `mysql-standalone` PDB deleted | Helm-stamped leftover (selector required 4 labels, pod has 3 → matched 0 pods). Was dead code; deletion is safe. | `kubectl` (not TF-managed) |

### Verified post-fix

- `kubectl -n kured exec deploy/kured -- ls /sentinel/` lists both `reboot-required` and `gated-reboot-required` on every node.
- 8 Anubis Deployments at 2/2 Ready; pods spread across different nodes (verified via `kubectl get pods -o wide`).
- Redis DBs 5, 7, 8, 10 receiving challenge state from real public traffic post-apply (Palo Alto Networks scanner hit blog).
- pg-cluster 3/3 healthy, phase = "Cluster in healthy state".
- kured args show `--drain-timeout=30m`.

## Lessons

1. **Auto-derivation in Helm charts is invisible drift surface.** The chart's
   habit of deriving hostPath from a CLI-arg-shaped value is the kind of
   "convenient default" that hides during normal review. Mitigation:
   pin `hostFilePath` explicitly in `configuration` so the host path is
   declared, not derived. (Did not do this in the fix because the
   single-config approach is now correct; flagging as future improvement.)

2. **"Silently skipped" needs a Prometheus signal.** The Upgrade Gates
   alerts cover "rollout in progress + something went wrong". They don't
   cover "we haven't rolled in 7 days when we should have". Suggested:
   add `KuredRebootBacklog` — fires when `kured_reboot_required ==
   1` (kured exposes this) for more than 24h continuously. The kured
   chart already serves `/metrics`; just needs a rule. (Deferred.)

3. **Single-replica `PDB: minAvailable=1` is a deadlock pattern.** It
   reads as "protect this pod" but actually means "block all voluntary
   disruption forever". Manifested in 9 places (8 Anubis + mysql-standalone
   with broken selector). The Anubis fix is now in place via shared-store
   replicas=2; the `mysql-standalone` selector was already broken so it
   matched 0 pods (and was deleted as cruft). Worth auditing the cluster
   periodically for any new pattern of the same shape.

4. **k8s-node1 containerd source drift** (Ubuntu archive's `containerd`
   vs Docker's `containerd.io`) is benign but should be documented.
   Audited during this session: not a blocker for kured because both
   variants are in the Package-Blacklist and both are apt-held. The
   version skew with master (1.6.22 vs 1.7.24/1.7.27) is what the
   K8s version-upgrade Stage 3 "containerd bump" exists to fix.

5. **CNPG drain handling at 2 replicas is fragile.** Switchover works
   but the lone replica must be caught up; in practice this means
   on a busy cluster, a primary-node drain could stall for tens of
   seconds while CNPG promotes. 3 instances eliminates this. Worth
   considering for every long-running multi-instance stateful workload.

## Detection / Prevention Followups

- [ ] `KuredRebootBacklog` Prometheus alert. Spec: `kured_reboot_required == 1 and (time() - timestamp(kured_reboot_required)) > 86400`.
- [ ] Add a `hostFilePath` value to the kured Helm release for explicit declaration (current setup is correct but undocumented).
- [ ] Audit periodically for new single-replica + `minAvailable=1` PDB patterns (could be a Kyverno warn policy).
- [ ] Phase 4: clean up the InnoDB Cluster CR + remaining `mysql-cluster-pdb` once the bitnami legacy is fully decommissioned.

## File pointers

| What | Where | Commit |
|---|---|---|
| kured sentinel path fix | `infra/stacks/kured/main.tf` | c17d87e1 |
| Anubis HA (module + 8 callers) | `infra/modules/kubernetes/anubis_instance/` + 8 `stacks/<app>/main.tf` | 6e920f96 |
| kured drainTimeout + CNPG 3-replica | `infra/stacks/kured/main.tf` + `infra/stacks/dbaas/modules/dbaas/main.tf` | a726e963 |
| K8s version-upgrade Job-chain (related context) | `infra/stacks/k8s-version-upgrade/` | 01bc16d5 (5/11) |
| Architecture doc | `infra/docs/architecture/automated-upgrades.md` | (updated 5/11) |
| Runbook | `infra/docs/runbooks/k8s-version-upgrade.md` | (updated 5/11) |
| Deprecated agent prompt (self-preemption history) | `infra/.claude/agents/k8s-version-upgrade.deprecated.md` | 01bc16d5 |
