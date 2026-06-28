# k8s-upgrade compat-gate: classify "actionable" vs "held" blocks

**Date:** 2026-06-28
**Status:** design → implementation
**Stack:** `stacks/k8s-version-upgrade` (+ `stacks/monitoring` alert rules)

## Problem

The cluster is on k8s 1.35.6. The nightly `k8s-version-check` chain detects the
next minor (1.36.2), runs the preflight compat-gate, and the gate **refuses**
it — because no released kyverno/ESO supports k8s 1.36 yet, and gpu-operator is
deliberately pinned (its 26.3 bump needs a newer NVIDIA driver image + Ubuntu
release we're not ready for). The result, **every single night**:

- a **Failed** preflight Job (`block()` exits 1), and
- `k8s_upgrade_blocked=1` → the **K8sUpgradeBlocked** alert.

But this block is **not actionable** — there's nothing we can upgrade to clear
it; we can only wait for upstream (kyverno/ESO) and, separately, do the
gpu-operator/Ubuntu work. The gate is crying wolf: a "blocked, needs attention"
signal that's indistinguishable from a block we could actually fix.

## Goal

Make the gate **classify** each blocker and behave accordingly:

| Class | Definition | Behaviour |
|-------|-----------|-----------|
| **actionable** | the compat matrix has a newer version of the addon whose `max_k8s >= target`, and the running version is older — upgrading it would clear the block | **alert** (`k8s_upgrade_blocked=1` → K8sUpgradeBlocked), with the specific "upgrade X → Y" remediation in the nightly report |
| **waiting-upstream** | **no** matrix version of the addon supports the target yet (kyverno/ESO for 1.36) | **quiet** (`k8s_upgrade_held=1`, no alert) — nightly report only |
| **pinned** | a supporting version exists but the addon carries `"pinned": true` in the matrix (gpu-operator) | **quiet** (held) |

Removed-API and containerd blocks are always **actionable**. **Held wins:** if
*any* blocker is waiting-or-pinned, the whole target is **HELD** (quiet) —
acting on the actionable blockers wouldn't unblock it yet. The nightly report
still lists everything so the full eventual scope is visible.

Also (scope decision: "tidy the block path"): deliberate gate decisions
(actionable-block **and** held) now make the preflight Job **Complete cleanly**
(exit 0) instead of Failing. Chain progression is gated on the verdict, not the
exit code. Real failures (unhealthy nodes, kubeadm errors, crashes) still exit
1 → `K8sUpgradeChainJobFailed`.

## Design

### `compat-gate.py`
- New exit codes: `0` safe · `2` actionable-block · `3` gate-error (fail-safe) · **`4` held**.
- Each stdout reason line is tagged `[ACTIONABLE]` / `[WAITING]` / `[PINNED]`.
- `check_addons`: when an addon blocks, decide its class:
  - `pinned: true` in its matrix entry → `[PINNED]`.
  - else a higher matrix version with `max_k8s >= target` exists → `[ACTIONABLE]` (`upgrade X to >= V`).
  - else → `[WAITING]` (`no released X version supports k8s T yet`).
  - unreadable image / below-matrix → `[ACTIONABLE]` (fail-safe — a human must look).
- `check_removed_apis`, `check_containerd`: tag `[ACTIONABLE]`.
- `exit_code(reasons)`: `0` if none; `4` if any `held_reason` (WAITING/PINNED); else `2`.

### `upgrade-step.sh`
- New global `HALT_CHAIN=0`; `spawn_next()` returns early (no next Job) when set.
- Replace `block()` with `record_blocked()` / `record_held()` — push the gauge,
  set `HALT_CHAIN=1`, **do not exit**.
- `phase_preflight` gate handling routes on the gate's exit code:
  - `0` → push `blocked=0`+`held=0`, proceed.
  - `2`/`3` → `record_blocked`, `return 0` (Job Completes, K8sUpgradeBlocked fires).
  - `4` → `record_held`, `return 0` (Job Completes, **no alert**).
- Push the gauge **definitively once** per run (remove the pre-reset `blocked=0`
  at gate start) so a standing block doesn't flap 1→0→1 and re-notify.
- postflight also clears `held=0` alongside the existing gauge resets.

### `addon-compat.json`
- Add `"pinned": true` + `"pin_reason"` to the gpu-operator entry (its
  `26.3 → 1.36` row stays; `pinned` overrides classification to held). Document
  the `pinned` flag in `_comment`. Unpinning later = delete two keys.

### `stacks/monitoring` alert rules (`prometheus_chart_values.tpl`)
- `K8sUpgradeBlocked` (`k8s_upgrade_blocked == 1`): unchanged trigger, now
  actionable-only; reword annotation (reasons are in the nightly report, not a
  per-run chain Slack).
- `K8sUpgradeChainJobFailed`: **drop** the `unless on() (k8s_upgrade_blocked == 1)`
  clause — deliberate blocks no longer create Failed Jobs, so the alert again
  means a genuine wedge.
- **No alert** for `k8s_upgrade_held` (intentional — nothing to action; the
  nightly report surfaces it). Add a comment recording this.

### `nightly-report.py`
- Read `k8s_upgrade_held`. New `⏸️ HELD — <target> not yet upgradable` headline.
- Group reasons by tag: *Action needed* / *Waiting on upstream* / *Pinned (held by us)*
  (fallback bullets for untagged lines, so older reason strings still render).
- Fetch reasons when avail AND (blocked OR held).

## Net effect on 1.36 today
**HELD, quiet** — waiting on kyverno + ESO (upstream) + gpu-operator (pinned);
Calico listed as the lone actionable piece. No nightly Failed Job, no alert —
just the nightly report's ⏸️ line. Flips to actionable (→ alert) only once
kyverno/ESO ship support **and** gpu-operator is unpinned.

## Tests (TDD)
- `compat-gate`: waiting / actionable / pinned-is-held / mixed-held-wins,
  removed-API & containerd are actionable, exit_code mapping, + existing
  patch/safe cases stay green.
- `nightly-report`: held headline + grouped reasons; existing tests stay green.
- `upgrade-step.sh`: shellcheck; manual review of the HALT_CHAIN + gauge flow
  (bash, not unit-tested).

## Out of scope (separate follow-up)
Auto-refreshing the matrix when upstream ships 1.36 support (a periodic
addon-readiness probe). This change only *consumes* the matrix.
