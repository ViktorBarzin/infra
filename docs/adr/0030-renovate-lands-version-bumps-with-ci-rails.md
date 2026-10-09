# ADR-0030: Renovate lands version bumps straight to master, with safety rails in CI and no agent

- Status: accepted
- Date: 2026-10-09
- Related: `docs/plans/2026-10-09-software-currency-design.md` (full design), `docs/architecture/automated-upgrades.md`, `docs/plans/2026-04-20-infra-audit-design.md` (finding F03)

## Context

On 2026-10-08 Muse flagged CVE-2026-88879 in Traefik. Traefik was on v3.7.1 while v3.7.14 existed, and the upgrade was done by hand the next day. Viktor asked whether our upgrade posture is enough, and said he wants the cluster always on the latest software.

What we found on 2026-10-09:

- Keel updates app images, mostly on `policy: patch`. Helm charts pinned in Terraform `helm_release` resources, which include Traefik, Vault, Prometheus and the cluster operators, had no automatic detection. 7 of the 28 had no version pin.
- The DIUN → n8n → service-upgrade-agent pipeline was meant to cover this. Its n8n filter keeps `status=update` (a new digest on an existing tag) and drops `status=new` (a new tag), so it never received a version bump. Its last upgrade commit was 2026-04-19.
- Vault was on 1.18.1 with about 25 Community CVE fixes missing, and Prometheus on v2.48.1 (December 2023). Both are reachable from the internet.

## Decision

1. **Renovate is the detector for every version pin Keel does not own**: all `helm_release` versions, image pins for `keel.sh/policy=never` workloads and Helm values, and the base images and dependencies of our own image repos that opt in with `renovate.json`.
2. **Renovate commits straight to master. There are no PRs and no agent in the loop.** It runs every 2 hours and lands at most one bump per run, one commit per chart or pin, because Woodpecker cancels a running pipeline when the next push arrives.
3. **Majors and the cluster operators land unattended.** Intermediate versions are stepped only where upstream requires it (Vault, Authentik, CNPG, Calico), through Renovate package rules.
4. **Safety rails live in the existing Woodpecker pipeline**, for commits authored by the Renovate bot: the shared upgrade-gate alert allowlist, a snapshot for stateful stacks, the apply, a health check, and on failure a `git revert` that also adds that exact version to Renovate's ignore list, plus a Slack page. There is no automatic data restore.
5. **Keel's default policy moves from `patch` to `major`** for unfenced workloads, in one change. The existing operator fences stay.
6. **The DIUN → n8n → agent pipeline is retired**, along with the service-upgrade agent files.
7. **Trivy Operator provides the CVE signal.** It alerts on fixable Critical/High findings on internet-reachable workloads and on secrets found in images. Everything else goes to a weekly section of `alert-digest`. Findings do not trigger upgrades directly, since Keel (hourly) and Renovate (every 2 hours) already pick up fixed versions.
8. **A Renovate liveness alert** fires when no run has succeeded for 8 hours. There is no separate versions-behind metric.
9. **Every automated upgrade must pass its component's checks before it counts as landed** (added the same day, after Viktor asked to "make sure each chart works after the upgrades, especially the db and gpu ones"). Each Renovate-owned component has a `verify` script, run as a Kubernetes Job; one without a script does not auto-land. Databases must show a healthy cluster, a successful write/read probe with their extensions, healthy dependent apps and a successful post-upgrade backup. The GPU stack must keep 100 GPU slots, run a CUDA test pod, answer one real inference on each GPU workload and keep DCGM metrics flowing. Keel app rollouts get a generic check plus the app's script where one exists, and failures page without rolling back.
10. **Database engines upgrade too, majors included**, in place after a dump and with no restore test first. MySQL tracks the latest innovation release. Immich's Postgres follows the tag in Immich's own release compose. The GPU node's kernel stays held; everything above it upgrades.
11. **CI gets Vault-admin rights** so Vault chart bumps apply through the same pipeline instead of being skipped.

## Alternatives considered

- **An agent lands each bump** (Renovate pushes a branch; the upgrade agent reads the changelog, snapshots, merges, verifies and bisects). Viktor preferred fewer moving parts. The parts of that flow that matter most (gate, snapshot, verify, revert) move into CI instead.
- **Pure Renovate automerge with CI apply as the only gate.** Rejected because it gives no pre-upgrade snapshot for Vault or databases and no revert on a failed rollout.
- **Fix DIUN as the trigger.** DIUN watches images only, so chart versions would still need a separate watcher.
- **Retire Keel and move all app images into Renovate.** This would bring changelog-aware landing to apps, at the cost of migrating 230+ workloads whose live tags Keel owns today. Deferred in favour of Keel on `major`.

## Consequences

- Version drift on the Helm-managed layer stops depending on someone noticing. The first runs clear a backlog of about 20 components over roughly 3 days.
- A failed bump costs one revert commit and one Slack page, and the next upstream release is tried automatically.
- Unattended majors can include CRD or schema migrations that `git revert` cannot undo. Recovery from those is the pre-upgrade snapshot, restored by hand. Viktor accepted this.
- Nextcloud will be moved across several majors at once by Keel, which Nextcloud's upgrader does not support. Viktor accepted that this may need a manual repair.
- A failed database major has no automatic way back; recovery is a manual restore from the pre-upgrade dump, which is not restore-tested first. MySQL innovation releases cannot be downgraded.
- A compromised CI job could change Vault's mounts and policies.
- Several checks need groundwork first: the GPU time-slicing config has to move to the right Helm key (a chart upgrade would otherwise likely drop GPU slots from 100 to 1), and MySQL, pg-cluster and ClickHouse need the metrics and backups the checks and snapshots read.
- Renovate needs a Forgejo bot account allowed to push to master, and its commits carry the audit trail (what changed and why) like any other commit.
