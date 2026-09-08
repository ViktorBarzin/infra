# Post-Mortem: MetalLB ServiceL2Status Stuck Immutable → PG LB VIP Flap → Woodpecker CI Tier 1 Applies Broken

| Field | Value |
|-------|-------|
| **Date** | 2026-05-16 (mitigated) / 2026-05-26 (closed) |
| **Duration** | ~5 days of degraded CI (2026-04-21 first observed → 2026-05-16 mitigated). Symptom-only; no human-visible service downtime. |
| **Severity** | SEV3 — Woodpecker CI default.yml apply step failed on Tier 1 (PG-backend) stacks. Drift-detection ran silently broken. Manual `scripts/tg apply` continued to work. No data loss, no app downtime. |
| **Affected Services** | Woodpecker CI pipelines applying any of the 28+ Tier 1 stacks (monitoring, crowdsec, authentik, headscale, etc.). PostgreSQL backend itself was healthy. |
| **Issue** | Beads `code-aoxk` (closed 2026-05-26). |
| **Status** | Closed |

## Summary

Woodpecker CI surfaced as `ERROR: Cannot read PG credentials from Vault. Run: vault login -method=oidc` from `scripts/tg` whenever a pipeline tried to apply a Tier 1 stack. The error was misleading on two counts:

1. **Vault was healthy.** A direct `vault read database/static-creds/pg-terraform-state` from inside a Woodpecker pipeline pod (using K8s SA JWT → `auth/kubernetes/login role=ci`) succeeded every time when run in isolation.
2. **The "Cannot read PG credentials" message in `scripts/tg` was a catch-all** that fired for *any* Terraform/Terragrunt failure during PG state-lock acquire-release, including TCP RSTs against the PG LoadBalancer VIP.

Actual root cause: the MetalLB `ServiceL2Status` CR for the `postgresql-lb` service (`dbaas` namespace, VIP `10.0.20.200`) had a stuck `status.node` field that the controller treated as immutable. The L2 speaker kept failing to update it with `Invalid value: "k8s-nodeX": Value is immutable`, so the leader-elected announcer flapped between k8s-node3 and k8s-node4 every few seconds. Each flap dropped open TCP connections (RST). Terraform's state-lock acquire → operation → release sequence straddled flaps and failed mid-operation. `scripts/tg` surfaced this as the misleading "Cannot read PG credentials" message.

Manual `scripts/tg apply` from the DevVM kept working because the developer's session happened to land on whichever node currently held the VIP and complete fast enough to not straddle a flap. CI pipelines, being slower (full stack walk), reliably straddled at least one flap.

## Impact

- **CI degradation**: Tier 1 stack changes pushed to master were NOT auto-applied. Required manual `scripts/tg apply` from DevVM after every push touching one of 28+ stacks.
- **Drift-detection broken**: The daily `drift-detection.yml` Woodpecker pipeline silently failed on every Tier 1 stack — meaning unannounced manual changes to those stacks could have persisted undetected for the duration.
- **No user-facing outage**: PG cluster itself, all apps that use PG, and all in-cluster traffic to `10.0.20.200` worked normally. Only the very specific `acquire-state-lock → run operation → release-state-lock` round-trip pattern from CI was unreliable.

## Timeline (UTC)

| Time | Event |
|------|-------|
| 2026-04-21 | First broken CI pipelines (#411, #412, #413). Drift-detection failures noticed. `code-aoxk` filed. Initial hypothesis: Vault auth/role mismatch. |
| 2026-04-22 — 2026-05-15 | Multiple investigation attempts. Verified Vault K8s `auth/kubernetes/role/ci` has correct policies (`terraform-state`, `ci`). Verified `database/static-creds/pg-terraform-state` exists, rotates on schedule, credentials valid. Could not reproduce the failure in isolated `vault read` from Woodpecker pods. |
| 2026-05-16 (~12:14 UTC) | `pg-cluster-3` came up (third CNPG replica); endpoint set churn likely triggered MetalLB L2 announcer to attempt to update the existing `ServiceL2Status` CR (was `l2-rgt9d`). Update was rejected as immutable. Speaker kept retrying. VIP flapped. |
| 2026-05-16 | RCA breakthrough: noticed `kubectl logs -n metallb-system -l component=speaker` was full of `Invalid value: "k8s-node…": Value is immutable` on the postgresql-lb ServiceL2Status. Correlated with `kubectl get servicel2status` returning multiple stale entries for the same service. |
| 2026-05-16 | **Mitigation**: `kubectl delete servicel2status.metallb.io l2-rgt9d -n metallb-system`. Speaker recreated the CR cleanly (became `l2-zj9ss`). Flap stopped. PG connections stable. Manual CI re-runs of `monitoring` stack apply succeeded immediately. |
| 2026-05-17 | Audit: acceptance criteria 1 + 2 met implicitly. #3 (post-mortem) remained pending. Beads task reverted from `in_progress` → `open`. |
| 2026-05-25 | Node2 SCSI LUN remap → encrypted PVC emergency_ro → containerd boltdb corruption outage. Unrelated, but pulled Woodpecker server off node2. Subsequent server pod restart on k8s-node4. |
| 2026-05-26 | Verification: from a live Woodpecker pipeline pod (`wp-01kshph6pa0w6ch0zf5x9bfqgr`), `vault write auth/kubernetes/login role=ci jwt=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)` succeeded. `vault read database/static-creds/pg-terraform-state` returned valid creds (`username=terraform_state`, last_vault_rotation 2026-05-21, TTL 58h). Live `default.yml` pipeline confirmed applying Tier 1 stacks: dbaas, authentik, crowdsec, monitoring, nvidia, cloudflared, kyverno, metallb — all `OK`. `postgresql-lb` ServiceL2Status currently single allocation (`l2-sv9vv` on k8s-node3, no flap). Beads task closed. |

## Root Cause

`metallb-speaker` reconciler in the deployed MetalLB version treats `ServiceL2Status.status.node` as immutable after first set. When the L2 announcer's leader-election picks a different node to announce a given VIP (which happens on speaker pod restart, node loss, endpoint set churn, or pod-anti-affinity reshuffles), the reconciler fails to patch the existing CR and gets stuck in a retry loop. Without manual deletion, the reconciler will not progress.

Why it manifested as Vault credential errors:

1. CI's `scripts/tg` pre-flight runs `vault read database/static-creds/pg-terraform-state` (line 83 in current code) to get PG credentials. That call succeeds.
2. CI then runs `terragrunt apply` against the Tier 1 stack. Terragrunt connects to `10.0.20.200:5432` for state-lock acquire (via `pg_advisory_lock`). The TCP connection lands on whichever node MetalLB last announced the VIP from.
3. Mid-operation, MetalLB tries to re-announce from a different node, sends gratuitous ARPs, and the upstream switch updates its MAC table. Open TCP sessions on the previous announcer's node are immediately RST.
4. Terragrunt's state-lock release (or any subsequent PG operation) fails with broken pipe / connection refused.
5. `scripts/tg` interpreted the wrapper-level failure as "PG creds bad" because that's the most common failure mode it handles. The actual error from terragrunt was buried in `2>/dev/null` suppression (since fixed — see Fix #1 below).

## Detection

We did not have any of:
- A direct alert for "MetalLB ServiceL2Status reconciler errors".
- An alert for "PG LB VIP node changed N times in M minutes".
- An end-to-end probe for the CI state-lock pattern (terragrunt against `10.0.20.200`).

Detection mechanism was a human reading `kubectl logs -n metallb-system` for unrelated reasons. Took 25 days from first observed symptom to RCA.

## Fixes & Mitigations

### 1. Surface real error from `scripts/tg` (DONE)

The original `scripts/tg` swallowed the real `vault read` / terragrunt error behind `2>/dev/null` and printed a static "Cannot read PG credentials from Vault" message. Fixed in the script:

```sh
# scripts/tg lines 79-89 (current)
if ! command -v vault >/dev/null 2>&1; then
  echo "ERROR: vault CLI not found on PATH. Install it or use an image that includes it (ci/Dockerfile)." >&2
  exit 1
fi
VAULT_OUT=$(vault read -format=json database/static-creds/pg-terraform-state 2>&1) || {
  echo "ERROR: Cannot read PG credentials from Vault. Vault output follows:" >&2
  echo "$VAULT_OUT" >&2
  echo "" >&2
  echo "Hint: humans run 'vault login -method=oidc'; CI auths via K8s SA (role=ci)." >&2
  exit 1
}
```

Comment in the code explicitly references this incident.

### 2. Stuck-CR cleanup procedure (DOCUMENTED)

Reproduction check for future sessions (also in `code-aoxk` beads notes):

```sh
kubectl logs -n metallb-system -l component=speaker --tail=200 | grep -iE 'Invalid value.*immutable'
# If matches found → same root cause. Delete the stuck CR:
kubectl get servicel2status -n metallb-system
kubectl delete servicel2status.metallb.io <name> -n metallb-system
```

Speaker recreates the CR cleanly within seconds.

### 3. Long-term MetalLB controller fix (DEFERRED)

The underlying bug — speaker not recreating the CR when the immutable field needs to change — is upstream MetalLB behaviour. Two paths possible:

- **Upgrade MetalLB** to a version where this is fixed (needs research — check changelogs).
- **File upstream issue / patch** with reproducer.

Not done as part of this post-mortem; tracked separately. Risk acceptance: until then, the manual `delete servicel2status` workaround is the playbook, and is fast (<10s).

### 4. Alerting (DEFERRED)

Suggested but not implemented:
- Prometheus alert on `metallb_speaker_reconcile_errors_total{kind="ServiceL2Status"}` rate.
- Synthetic probe: a CronJob that does `pg_advisory_lock` + release against the PG VIP every 5min from CI namespace, alert if it ever fails.

Tracked as future hardening (no beads task yet — only worth filing if recurrence happens).

## Lessons

1. **`2>/dev/null` is a time-bomb.** It hid the real error for weeks. Fix #1 already lands the principle; audit other places in `scripts/` for the same anti-pattern next time we touch them.
2. **CRD `status.*` immutability is non-obvious failure mode.** When debugging weird LB / VIP / endpoint behaviour, always grep speaker logs for `immutable`, `cannot update`, and reconciler errors. Add to cluster-health checks.
3. **Misleading wrapper errors cost weeks.** `scripts/tg` claimed "Cannot read PG credentials" — that's what the operator believed. The actual `vault read` step worked. The real failure was three steps later in a completely different subsystem. When a wrapper script makes a definitive claim about which subsystem failed, distrust it; reproduce the subsystem in isolation before chasing the claim.
4. **CNPG primary changes / endpoint churn can trigger L2 announcer flap.** The trigger (within the timeline) was likely the `pg-cluster-3` pod coming up. Worth flagging for any future CNPG topology changes.

## References

- Beads: `code-aoxk` — closed 2026-05-26.
- `scripts/tg` lines 65-95 — current pre-flight with explicit error surfacing.
- `kubectl get servicel2status -A` — current state, single allocation per service.
- This file: `infra/docs/post-mortems/2026-05-16-metallb-l2-immutable-pg-vip-flap.md`.
