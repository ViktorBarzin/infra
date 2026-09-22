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
has not been applied. Validated end to end on 2026-08-29 against a VM cloned
from Proxmox template 1000: playbook, then `apt install terminal-lobby`, then
all six services up and all eight verification probes passing.

Routed elsewhere by design: accounts, groups, clones and kubeconfigs come from
`roster.yaml` via `t3-provision-users.sh` (hourly; infra#88 ports that half),
and Terminal Lobby's own files ship in its Debian package.

## Execution
- **Apply**: Authenticate via `vault login -method=oidc`, then **`homelab tf plan|validate|apply <stack>`** (always the full form — bare `homelab tf` prints `unknown command: "tf"`, which reads as "the verb does not exist"). It wraps `scripts/tg`, which handles state decrypt/encrypt. **Do not run bare `terragrunt`/`terraform`.** On a Tier-1 stack a bare terragrunt dies in "Initializing the backend" with `pq: password authentication failed for user "<your-os-user>"`, because `PG_CONN_STR` is set only by `scripts/tg`. **That error is not a permission-tier limit** — reading it as one led to abandoning local verification for CI and hand-rolling the offline check with plain `terraform init`, 15 times over a month. `scripts/tg` adds `-auto-approve` for `--non-interactive` applies, and `-lock-timeout` (default `5m`, override via `TG_LOCK_TIMEOUT`) on every state-locking verb (`plan`/`apply`/`destroy`/`refresh`) so a contended state lock **waits** instead of failing instantly with `Error acquiring the state lock`.
- **Health check**: `bash scripts/cluster_healthcheck.sh --quiet`

## Instructions
- **"remember X"**: use the `homelab memory` CLI. The rule and the usage discipline live in your own AGENTS.md — not restated here, so the two cannot drift apart. Infra-specific addition: for knowledge that belongs to the repo rather than to a session, also update the relevant CLAUDE.md / `AGENTS.md`.
- **New services need CI/CD** and **monitoring** (Prometheus/Uptime Kuma). CI = a GHA workflow on the repo's GitHub mirror (build + tests off-infra, ADR-0002); Woodpecker gets a deploy-only pipeline — never an in-cluster build.
- **New service**: Use `setup-project` skill for full workflow
- **Adopting existing resources**: use HCL `import {}` blocks (TF 1.5+), not `terraform import` CLI. Commit stanza → plan-to-zero → apply → delete stanza. Canonical reason: reviewable in PR, plan-safe, idempotent, tier-agnostic. Full rules + per-provider ID formats in `docs/agents/terraform.md` → "Adopting Existing Resources".
- **Sealed Secrets**: User-managed secrets go in `sealed-*.yaml` files in the stack directory. Stacks pick them up via `kubernetes_manifest` + `fileset(path.module, "sealed-*.yaml")`. See `docs/agents/secrets.md` for full workflow.
- **CRITICAL — Update docs with every change**: When modifying infrastructure (Terraform, Vault, networking, storage, CI/CD, monitoring), you MUST update all affected documentation in the same commit. Check and update: `docs/architecture/*.md`, `docs/runbooks/*.md`, `docs/agents/*.md`, `AGENTS.md`, `.claude/reference/service-catalog.md`. Stale docs cause incident response failures and onboarding confusion. If unsure which docs are affected, grep for the service/resource name across all doc files.

## Secrets Management — Vault KV
- **Vault is the sole source of truth** for secrets.
- **`secret/viktor`** — go-to path for ALL personal secrets (135 keys). Contains every API key, token, password, SSH key, and config from the old terraform.tfvars. Check here first: `vault kv get -field=KEY secret/viktor`.
- **Auth**: `vault login -method=oidc` (Authentik SSO) → `~/.vault-token` → read by Vault TF provider.

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
- `modules/kubernetes/ingress_factory/` — standardized ingress with auth, rate limiting, anti-AI, and auto Cloudflare DNS (`dns_type = "proxied"` — no per-name record, rides the zone-wide `*` wildcard CNAME per ADR-0021 (apex `"@"` carve-out excepted); `"non-proxied"` — explicit A/AAAA to the WAN IP, shadows the wildcard; `"internal"` — a public A record carrying the internal Traefik LB IP for household-only services, shadows the wildcard so the name stays dark; pair with the `home-lans-only` ipAllowList middleware, never with `"proxied"`. Since the wildcard, `dns_type = "none"` on a `.me` host is NOT private — recordless names resolve through the tunnel; internal-only ingresses must use `"internal"` or `.lan`)
- `modules/kubernetes/nfs_volume/` — NFS volume module (CSI-backed, soft mount)
- `config.tfvars` — non-secret configuration (plaintext)
- `scripts/cluster_healthcheck.sh` — 50-check cluster health script (nodes, workloads, monitoring, certs, backups, external reachability, Slack #alerts traffic)

## Shared Variables (never hardcode)
`var.nfs_server` (192.168.1.127), `var.redis_host`, `var.postgresql_host`, `var.mysql_host`, `var.ollama_host`, `var.mail_host`

## Claude-Specific Resources
- **Skills**: `.claude/skills/` (11 active). Archived runbooks: `.claude/skills/archived/`
- **Agents**: `.claude/agents/` (10 files; `k8s-version-upgrade` is deprecated).
  - **Incident pipeline**: post-mortem → sev-triage → sev-historian → sev-report-writer
  - **Other**: service-upgrade, issue-responder, postmortem-todo-resolver, f1-source-fixer, payslip-extractor
- **Reference**: `.claude/reference/` — patterns.md, service-catalog.md, proxmox-inventory.md, github-api.md, authentik-state.md

## Contributor Onboarding
1. Get Authentik account + Headscale VPN access (ask Viktor)
2. Clone repo — `AGENTS.md` is auto-loaded by Codex
3. Create branch → edit → push → open PR
4. Viktor reviews → CI applies → Slack notification
5. Portal: `https://k8s-portal.viktorbarzin.me/onboarding` for full guide

### Non-admin workstation users — the AGENT does the git work

Non-admin devvm users (power-user / namespace-owner tiers) may not know git at
all. Their agent handles every version-control step silently — never ask them
to commit, push, pull, or open a PR, and never surface git jargon at them.
Their infra clone arrives preconfigured: git identity, a `forgejo` remote
authenticated via `~/.git-credentials`, and `master` tracking `forgejo/master`
(auto-freshened hourly and at session launch, fast-forward only).

Two per-user layouts exist (`code_layout` in
`scripts/workstation/roster.yaml`): `single` (the default) — `~/code` IS the
locked infra clone — and `workspace` — `~/code` is a plain directory of
per-project clones: the infra clone at `~/code/infra`, plus each roster
`repos` entry (e.g. `~/code/tripit`) cloned from Forgejo `viktor/<name>` with
the user's own PAT. The reconcile auto-migrates a single-layout `~/code` when
a user is flipped to `workspace`, and keeps every clone fresh either way.

The model is **allow-then-audit** (Viktor, 2026-06-10): whitelisted users (emo)
push straight to `master` — no PR gate — and the record of *what changed and
why* is what matters. Force-push is disabled for everyone, so master history
is append-only.

**Feature-sized work is worktree-first** (org rule, 2026-06-10): develop in an
isolated worktree (`.worktrees/<topic>`, branch `<os-user>/<topic>` off
`forgejo/master`) so concurrent agent sessions never collide in the clone, then
land by merging latest master into the branch and pushing it
(`git push forgejo HEAD:master`, or the PR fallback below if not whitelisted) —
the audit-trail rules below apply to the branch's commit messages all the same.
Locked (git-crypt) clones can use plain `git worktree add`. Trivial
single-commit fixes may be committed directly on a clean `master`. Full
lifecycle: your own AGENTS.md.

To land a finished change from such a clone:

1. **The commit message is the audit trail** — this matters
   more than the change itself:
   - subject: what changed, specific ("ha-sofia: lower fan curve bias to -5")
   - body: WHY, in plain words — paraphrase the user's actual request and any
     reasoning ("Emil asked for quieter fans in the evening; curve was
     overshooting after the 2026-06-08 redesign")
2. Land it per the worktree paragraph above.
3. **Never use `[ci skip]`** as a non-admin — it hides the change from the
   Slack audit feed; a no-op CI apply on a docs-only commit is harmless.
4. Leave the clone on clean `master` so auto-refresh keeps working.
5. Tell the user in plain language what happened. Stack changes are
   auto-applied by CI on push — or, with apply access, applied locally yourself
   (`scripts/tg apply`, from the main checkout, not a worktree); either path is
   fine, but the change must always be committed here, never applied
   uncommitted. Verify the live result with the user's read-only kubectl before
   saying "it's live".

If a push to `master` is rejected by branch protection (user not on the
whitelist — e.g. new users before Viktor grants it), fall back to a
`<os-user>/<short-topic>` branch + PR with the user's own PAT
(`write:repository` suffices — verified 2026-06-10):

```bash
TOK=$(sed -E 's#https://[^:]+:([^@]+)@.*#\1#' ~/.git-credentials)
curl -X POST -H "Authorization: token $TOK" -H 'Content-Type: application/json' \
  https://forgejo.viktorbarzin.me/api/v1/repos/viktor/infra/pulls \
  -d '{"title":"<title>","head":"<os-user>/<short-topic>","base":"master","body":"<what + why>"}'
```

## Common Operations
- **`homelab` CLI** (`/usr/local/bin/homelab`, source `cli/`): unified infra-ops verbs — run `homelab manifest` to discover the surface (each verb tagged read/write). Infra loop: `homelab tf plan|fmt|apply <stack>` (wraps `scripts/tg`; `apply` auto-claims presence + releases on exit, warns out-of-band), `homelab claim|release <kind>:<name>`, `homelab work start|land|clean <topic>` (worktree lifecycle; `land` gates on verification, `--verify-cmd`/`--no-verify`). Full docs: `cli/README.md`.
- **Fix crashed pods**: Run healthcheck first. Safe to delete evicted/failed pods and CrashLoopBackOff pods with >10 restarts.
- **OOMKilled**: Check `kubectl describe limitrange tier-defaults -n <ns>`. Increase `resources.limits.memory` in the stack's main.tf.

## Detailed Reference
See `.claude/reference/patterns.md` for: NFS volume code examples, iSCSI details, Kyverno governance tables, anti-AI scraping layers, Terragrunt architecture, node rebuild procedure, archived troubleshooting runbooks index.

Moved out of this file on 2026-09-22, verbatim (read the one your task touches):
- `docs/agents/service-notes.md` — Service-Specific Notes (per-service operational knowledge)
- `docs/agents/monitoring.md` — Monitoring & Alerting
- `docs/agents/networking.md` — Networking & Resilience (CrowdSec enforcement, Traefik, HTTP/3, IPv6)
- `docs/agents/security.md` — Security Posture
- `docs/agents/storage-backup.md` — storage classes, NFS rules, PVC templates, 3-2-1 backups
- `docs/agents/ci-cd.md` — CI/CD Architecture (GHA → ghcr, Woodpecker deploy)
- `docs/agents/ingress.md` — `ingress_factory` auth and DNS tiers, Anubis, Sablier scale-to-zero
- `docs/agents/kyverno-drift.md` — the `# KYVERNO_LIFECYCLE_V1` block every pod-owning resource needs, plus the Keel, MetalLB and Reloader markers
- `docs/agents/terraform.md` — two-tier state backend, adopting resources with `import {}`
- `docs/agents/secrets.md` — ESO, plan-time secrets, DB rotation, Sealed Secrets
- `docs/agents/databases.md` — CNPG host and tuning, Redis endpoints
- `docs/agents/resources.md` — resource requests and limits, tier LimitRanges
- `docs/agents/images.md` — image builds, registries, pull-through caches
- `docs/agents/nodes.md` — node kubelet and OS disk tuning
- `docs/agents/infrastructure.md` — hosts, nodes, GPU scheduling, SMTP
- `docs/agents/known-issues.md` — Known Issues
- `docs/agents/homelab-cli.md` — the `homelab` verb catalogue
- Repowise: `docs/architecture/repowise.md`. Automated service upgrades: `docs/architecture/automated-upgrades.md`

## User Preferences
- **Calendar**: Nextcloud at `nextcloud.viktorbarzin.me`
- **Home Assistant**: ha-london (default), ha-sofia. "ha"/"HA" = ha-london
- **Frontend**: Svelte for all new web apps
- **Tools**: Docker containers only — never `brew install` locally
