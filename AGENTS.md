# Infrastructure Repository — AI Agent Instructions

## Critical Rules (MUST FOLLOW)
- **NEVER restart NFS on the Proxmox host** — causes cluster-wide mount failures across all pods
- **NEVER commit secrets** — triple-check before every commit
- **`[ci skip]` in commit messages** when changes were already applied locally (admins only)

## Critical Rule: Terraform Only

**ALL infrastructure changes MUST go through Terraform/Terragrunt.** Never use `kubectl apply/edit/patch/set`, `helm install/upgrade`, or any manual cluster mutation as the final state.

- **No exceptions for "quick fixes"** — even one-line changes must be in `.tf` files and applied via `scripts/tg apply`
- **Apply locally OR let CI do it — but ALWAYS commit.** You don't have to wait for CI: with apply access you MAY run the apply yourself (`scripts/tg apply <stack>` / `homelab tf apply <stack>`), but **from the main checkout, never a worktree** (git-crypt'd `*.tfvars` come through as ciphertext under the worktree filter-bypass, so a worktree apply reads garbage). **Every applied change MUST be committed and pushed to `master` the same session** — the repo is the source of truth, so applied-but-uncommitted HCL is drift that the next CI apply / daily drift-detection will try to revert. Order either way: apply locally then commit + push (CI's changed-stack apply then no-ops), or commit + push and let CI apply. Never apply an uncommitted edit; never leave a committed change unapplied.
- **kubectl is for read-only operations and temporary debugging only** (get, describe, logs, exec, port-forward)
- **If a resource isn't in Terraform yet**, evaluate whether it can be added before making manual changes. If manual change is unavoidable (e.g., emergency), document it immediately and create the Terraform resource in the same session
- **kubectl scale/patch during migrations is acceptable** as a transient step, but the final state must be in Terraform and applied via `scripts/tg apply`
- **Helm values live in Terraform** (templatefile or inline) — never `helm upgrade` directly

Violations cause state drift, which causes future applies to break or silently revert changes.

## Critical Rule: the devvm goes through Ansible

The cluster's counterpart. **Machine-wide changes to the devvm (10.0.10.10) are
edits to `playbooks/devvm.yml`, not commands typed on the box** — packages,
`/usr/local/bin` binaries, systemd units, `/etc` config, resource limits, apt
sources.

```sh
ansible-playbook -i playbooks/inventory.ini playbooks/devvm.yml --check --diff  # always first
ansible-playbook -i playbooks/inventory.ini playbooks/devvm.yml                 # apply
```

A `--check` run against the live box should be a no-op; anything else is drift,
and it means either the box carries something undeclared or a committed change
has not been applied.

Routed elsewhere by design: accounts, groups, clones and kubeconfigs come from
`roster.yaml` via `t3-provision-users.sh` (hourly; infra#88 ports that half),
which also restores each user's credential files from Vault and applies
dotfiles on a rebuilt box (`docs/runbooks/devvm-credentials.md`), and
Terminal Lobby's own files ship in its Debian package.

## Execution
- **Apply**: Authenticate via `vault login -method=oidc`, then **`homelab tf plan|validate|apply <stack>`** (always the full form — bare `homelab tf` prints `unknown command: "tf"`, which reads as "the verb does not exist"). It wraps `scripts/tg`, which handles state decrypt/encrypt. **Do not run bare `terragrunt`/`terraform`.** On a Tier-1 stack a bare terragrunt dies in "Initializing the backend" with `pq: password authentication failed for user "<your-os-user>"`, because `PG_CONN_STR` is set only by `scripts/tg`. **That error is not a permission-tier limit** — reading it as one led to abandoning local verification for CI and hand-rolling the offline check with plain `terraform init`, 15 times over a month. `scripts/tg` adds `-auto-approve` for `--non-interactive` applies, and `-lock-timeout` (default `5m`, override via `TG_LOCK_TIMEOUT`) on every state-locking verb (`plan`/`apply`/`destroy`/`refresh`) so a contended state lock **waits** instead of failing instantly with `Error acquiring the state lock`.
- **Before changing a stack**: read the relevant `docs/{architecture,runbooks,plans,post-mortems}/` files first; they are the starting state. A mismatch between the docs and the live cluster is itself a finding, so report it.

## Instructions
- **"remember X"**: use the `homelab memory` CLI. The rule and the usage discipline live in your own AGENTS.md — not restated here, so the two cannot drift apart. Infra-specific addition: for knowledge that belongs to the repo rather than to a session, also update the relevant CLAUDE.md / `AGENTS.md`.
- **New services need CI/CD** and **monitoring** (Prometheus/Uptime Kuma). CI per ADR-0002, see Architecture below.
- **New service**: a new first-party TanStack Start app is one `modules/kubernetes/tanstack_app` call; steps in `docs/agents/new-app.md`.
- **Adopting existing resources**: use HCL `import {}` blocks (TF 1.5+), not `terraform import` CLI. Commit stanza → plan-to-zero → apply → delete stanza. Canonical reason: reviewable in PR, plan-safe, idempotent, tier-agnostic. Full rules + per-provider ID formats in `docs/agents/terraform.md` → "Adopting Existing Resources".
- **Sealed Secrets**: User-managed secrets go in `sealed-*.yaml` files in the stack directory. Stacks pick them up via `kubernetes_manifest` + `fileset(path.module, "sealed-*.yaml")`. See `docs/agents/secrets.md` for full workflow.
- **CRITICAL — Update docs with every change**: When modifying infrastructure (Terraform, Vault, networking, storage, CI/CD, monitoring), you MUST update all affected documentation in the same commit. Check and update: `docs/architecture/*.md`, `docs/runbooks/*.md`, `docs/agents/*.md`, `AGENTS.md`, `.claude/reference/service-catalog.md`. Stale docs cause incident response failures and onboarding confusion. If unsure which docs are affected, grep for the service/resource name across all doc files.

## Cloud-owned objects (scope rule)

Cloud (Forgejo `viktor/cloud`) keeps each Project's desired state in its own database and applies it with its own reconciler, one OpenTofu state per Project (ADR-0003 in the cloud repo, approved by Viktor 2026-11-12). **These belong to Cloud's database, not this repo:**
- every object in a `p-*` namespace, and the namespaces themselves;
- Postgres roles and databases that are members of `cloud_projects` (this repo owns only `cloud_projects`, `cloud_provisioner`, `cloud_state` and the `cloud_state` and `cloud` databases);
- the OAuth2 providers, applications, `cloud-*` groups and policy bindings that `svc-cloud-reconciler` creates in Authentik;
- Vault `secret/cloud/<namespace>/*` (this repo writes only `secret/cloud/system`).

Do not import, recreate or "fix" them from Terraform, and keep the nightly drift plan blind to them: no stack may manage them, so they never appear in a plan. Name no new homelab namespace `p-*`. What this repo does own for Cloud is listed in `.claude/reference/service-catalog.md` (row `cloud`); details in `docs/agents/terraform.md`.

## Secrets Management — Vault KV
- **Vault is the sole source of truth** for secrets.
- **`secret/viktor`** — go-to path for ALL personal secrets (135 keys). Contains every API key, token, password, SSH key, and config from the old terraform.tfvars. Check here first: `vault kv get -field=KEY secret/viktor`.
- **Auth**: `vault login -method=oidc` (Authentik SSO) → `~/.vault-token` → read by Vault TF provider.
- **App DB passwords** are Vault static roles that rotate on Tuesday 10:00-10:45 UTC; the `db-rotation-watcher` CronJob force-syncs their `vault-database` ExternalSecrets within seconds, and ESO's 15m poll is the fallback. A new role takes a free slot: `docs/runbooks/db-credential-rotation.md`.

## Architecture
Terragrunt-based homelab managing a Kubernetes cluster (6 nodes, v1.35) on Proxmox VMs.
- **100+ stacks**, each in `stacks/<service>/` with its own Terraform state
- **Core platform**: `stacks/platform/` is now an empty shell — all modules have been extracted to independent stacks under `stacks/`
- **Public domain**: `viktorbarzin.me` (Cloudflare) | **Internal**: `viktorbarzin.lan` (Technitium DNS)
- **Onboarding portal**: `https://k8s-portal.viktorbarzin.me` — self-service kubectl setup + docs
- **CI/CD**: Woodpecker CI — PRs run plan, merges to master auto-apply all stacks
- **CI compute is external (ADR-0002, 2026-06-12)**: builds, tests, lint, and release jobs run on GitHub Actions hosted runners via each repo's GitHub mirror — never on cluster nodes. In-cluster pipelines exist only for steps that need cluster access (Woodpecker `kubectl set image` deploys, terragrunt applies, certbot). Never add an in-cluster build or test pipeline to any repo; the fallback-build pattern was deliberately removed. After pushing anything that fires a build chain, watch it end-to-end (GHA run → Woodpecker deploy → rollout) before calling the change done — verify live state, not the checkmark.

## Key Paths
- `stacks/<service>/main.tf` — service definition
- `modules/kubernetes/ingress_factory/` — standard ingress: auth, rate limiting, anti-AI, Cloudflare DNS. Pick `dns_type` from `docs/agents/ingress.md`; `"none"` on a `.me` host is NOT private.
- `modules/kubernetes/nfs_volume/` — NFS volume module (CSI-backed, soft mount)
- `config.tfvars` — non-secret configuration (plaintext)
- `scripts/cluster_healthcheck.sh` — 50-check cluster health script (nodes, workloads, monitoring, certs, backups, external reachability, Slack #alerts traffic)

## Shared Variables (never hardcode)
`var.nfs_server` (192.168.1.127), `var.redis_host`, `var.postgresql_host`, `var.mysql_host`, `var.ollama_host`, `var.mail_host`

## Claude-Specific Resources
- **Skills**: `.claude/skills/` (cluster-health, home-assistant).
- **Agents**: `.claude/agents/` (10 files).
  - **Incident pipeline**: post-mortem → sev-triage → sev-historian → sev-report-writer
  - **Other**: issue-responder, postmortem-todo-resolver, source-fixer (tv sources: Channels the tv Watcher reports down, F1 Live, and dormant sites the daily probe finds answering again), tv-feedback-fixer (approved User reports on viktor/tv), payslip-extractor
- **Reference**: `.claude/reference/` — patterns.md, service-catalog.md, proxmox-inventory.md, github-api.md, authentik-state.md

## Contributor Onboarding
Non-admin users (emo, Anca): access, the git-for-non-git-users model and the PR fallback are in `docs/agents/contributor-onboarding.md`.

If a command's output ends with a `[devvm-io-guard] Stopped ...` note, the
devvm disk was saturated and the guard stopped that scan to protect etcd,
which shares the disk. Don't re-run it as is: narrow the path, or use the
tool the note names. A `BLOCKED by scan-guard` message is the same rule
applied before the command runs. Details: `docs/architecture/devvm-io-guard.md`.

## Common Operations
- **`homelab` CLI** (`/usr/local/bin/homelab`, source `cli/`): unified infra-ops verbs — run `homelab manifest` to discover the surface (each verb tagged read/write). Infra loop: `homelab tf plan|fmt|apply <stack>` (wraps `scripts/tg`; `apply` auto-claims presence + releases on exit, warns out-of-band), `homelab claim|release <kind>:<name>`, `homelab work start|land|clean <topic>` (worktree lifecycle; `land` gates on verification, `--verify-cmd`/`--no-verify`). Full docs: `cli/README.md`.
- **Fix crashed pods**: Run healthcheck first. Safe to delete evicted/failed pods and CrashLoopBackOff pods with >10 restarts.
- **OOMKilled**: Check `kubectl describe limitrange tier-defaults -n <ns>`. Increase `resources.limits.memory` in the stack's main.tf.

## Detailed Reference
See `.claude/reference/patterns.md` for: NFS volume code examples, iSCSI details, Kyverno governance tables, anti-AI scraping layers, Terragrunt architecture, node rebuild procedure.

Moved out of this file on 2026-09-22, verbatim (read the one your task touches):
- `docs/agents/service-notes.md` — Service-Specific Notes (per-service operational knowledge)
- `docs/agents/monitoring.md` — Monitoring & Alerting
- `docs/agents/networking.md` — Networking & Resilience (CrowdSec enforcement, Traefik, HTTP/3, IPv6)
- `docs/agents/security.md` — Security Posture
- `docs/agents/storage-backup.md` — storage classes, NFS rules, PVC templates, 3-2-1 backups
- `docs/agents/ci-cd.md` — CI/CD Architecture (GHA → ghcr, Woodpecker deploy)
- `docs/agents/ingress.md` — `ingress_factory` auth and DNS tiers, Anubis, Sablier scale-to-zero
- `docs/agents/kyverno-drift.md` — the `# KYVERNO_LIFECYCLE_V1` block every pod-owning resource needs, plus the MetalLB, Reloader and legacy template-annotation markers
- `docs/agents/terraform.md` — two-tier state backend, adopting resources with `import {}`
- `docs/agents/secrets.md` — ESO, plan-time secrets, DB rotation, Sealed Secrets
- `docs/agents/databases.md` — CNPG host and tuning, Redis endpoints
- `docs/agents/resources.md` — resource requests and limits, tier LimitRanges
- `docs/agents/images.md` — image builds, registries, pull-through caches
- `docs/agents/nodes.md` — node kubelet and OS disk tuning
- `docs/agents/infrastructure.md` — hosts, nodes, GPU scheduling, SMTP
- `docs/agents/known-issues.md` — Known Issues
- `docs/agents/homelab-cli.md` — the `homelab` verb catalogue
- `docs/agents/new-app.md` — a new first-party app on the ADR-0001 stack: `modules/kubernetes/tanstack_app` plus the dbaas and vault map entries
- Repowise (sunset 2026-11-10, as-built record): `docs/architecture/repowise.md`. Automated service upgrades: `docs/architecture/automated-upgrades.md`

## User Preferences
- **Calendar**: Nextcloud at `nextcloud.viktorbarzin.me`
- **New apps**: TanStack Start (React) on Bun with Drizzle on the shared Postgres and Authentik accounts, per `~/code/app-kit/docs/adr/0001-default-app-stack.md` (2026-10-16). The setup guide is `~/code/app-kit/docs/stack.md`, and the org policy points every agent at it. Existing SvelteKit apps keep their stack. emo builds his own apps too: `docs/agents/new-app.md`, "An app owned by a non-admin"
