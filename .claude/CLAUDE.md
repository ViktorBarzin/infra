# Claude Code — Project Configuration

> **Shared knowledge**: Read `AGENTS.md` at repo root for architecture, patterns, rules, and operations. This file adds Claude-specific features on top.

## Claude-Specific Resources
- **Skills**: `.claude/skills/` (7 active). Archived runbooks: `.claude/skills/archived/`
- **Agents**: All agents are global (`~/.claude/agents/`, shared via dotfiles). Install Viktor's dotfiles for the full set.
  - **Infra specialists**: cluster-health-checker, dba, home-automation-engineer, network-engineer, observability-engineer, platform-engineer, security-engineer, sre
  - **Incident pipeline**: post-mortem → sev-triage → sev-historian → sev-report-writer
  - **DevOps**: devops-engineer, deploy-app, review-loop
- **Reference**: `.claude/reference/` — patterns.md, service-catalog.md, proxmox-inventory.md, github-api.md, authentik-state.md
- **GitHub API**: `curl` with tokens from tfvars (`gh` CLI blocked by sandbox)

## Critical Rule: Terraform Only

**ALL infrastructure changes MUST go through Terraform/Terragrunt.** Never use `kubectl apply/edit/patch/set`, `helm install/upgrade`, or any manual cluster mutation as the final state.

- **No exceptions for "quick fixes"** — even one-line changes must be in `.tf` files and applied via `scripts/tg apply`
- **Apply locally OR let CI do it — but ALWAYS commit.** You don't have to wait for CI: with apply access you MAY run the apply yourself (`scripts/tg apply <stack>` / `homelab tf apply <stack>`), but **from the main checkout, never a worktree** (git-crypt'd `*.tfvars` come through as ciphertext under the worktree filter-bypass, so a worktree apply reads garbage). **Every applied change MUST be committed and pushed to `master` the same session** — the repo is the source of truth, so applied-but-uncommitted HCL is drift that the next CI apply / daily drift-detection will try to revert. Order either way: apply locally then commit + push (CI's changed-stack apply then no-ops), or commit + push and let CI apply. Never apply an uncommitted edit; never leave a committed change unapplied.
- **kubectl is for read-only operations and temporary debugging only** (get, describe, logs, exec, port-forward)
- **If a resource isn't in Terraform yet**, evaluate whether it can be added before making manual changes. If manual change is unavoidable (e.g., emergency), document it immediately and create the Terraform resource in the same session
- **kubectl scale/patch during migrations is acceptable** as a transient step, but the final state must be in Terraform and applied via `scripts/tg apply`
- **Helm values live in Terraform** (templatefile or inline) — never `helm upgrade` directly

Violations cause state drift, which causes future applies to break or silently revert changes.

## Instructions
- **"remember X"**: store to the remote claude-memory store via the **`homelab memory` CLI**: `homelab memory store "content" --category facts --tags "tag1,tag2"` (also `recall "query"` / `update <id>` / `list` / `delete <id>`). For shared knowledge, also update the relevant CLAUDE.md / `AGENTS.md`. (Supersedes the old `memory-tool` CLI **and** the claude-memory MCP — both retired 2026-06-21; the homelab CLI hits the same remote HTTP API. Recall also runs automatically each turn via a UserPromptSubmit hook.)
- **Apply**: Authenticate via `vault login -method=oidc`, then use `scripts/tg` (preferred — handles state decrypt/encrypt) or `terragrunt` directly. `scripts/tg` adds `-auto-approve` for `--non-interactive` applies, and `-lock-timeout` (default `5m`, override via `TG_LOCK_TIMEOUT`) on every state-locking verb (`plan`/`apply`/`destroy`/`refresh`) so a contended state lock **waits** instead of failing instantly with `Error acquiring the state lock`.
- **New services need CI/CD** and **monitoring** (Prometheus/Uptime Kuma). CI = a GHA workflow on the repo's GitHub mirror (build + tests off-infra, ADR-0002); Woodpecker gets a deploy-only pipeline — never an in-cluster build.
- **New service**: Use `setup-project` skill for full workflow
- **Ingress**: `ingress_factory` module. **Auth** (`auth` string enum, default `"required"` — fail-closed). Pick by asking "what gates the app?":
  - `auth = "required"` — Authentik forward-auth gates every request. Use when the backend has **no built-in user auth** and Authentik is the only thing standing between strangers and the app (prowlarr, qbittorrent, netbox, phpipam, k8s-dashboard, any admin UI shipped without its own login).
  - `auth = "app"` — the backend handles its own user authentication (NextAuth, Django, OAuth, bearer-token API, etc.); Authentik would only break it. No middleware attached; the app's own login is the gate. Examples: immich, linkwarden, tandoor, freshrss, affine, actualbudget, audiobookshelf, novelapp. **Functionally identical to `"none"`** — the distinct name exists to record intent at the call site.
  - `auth = "public"` — Authentik anonymous binding via the dedicated `public` outpost (routes via `traefik-authentik-forward-auth-public` → `ak-outpost-public.authentik.svc:9000`). Strangers auto-bound to `guest`; logged-in users keep their identity in `X-authentik-username`. **Only works for top-level browser navigation** — CORS preflight rejects XHR/fetch and automation can't replay the cookie dance. Audit trail, not a gate.
  - `auth = "none"` — no Authentik, no own-auth claim. Use for Anubis-fronted content (Anubis is the gate), native-client APIs (Git, `/v2/`, WebDAV/CalDAV, CardDAV), webhook receivers, OAuth callbacks, and Authentik outposts themselves.
  - **Anti-exposure rule** (the reason `"app"` exists): only pick `"app"` or `"none"` AFTER you've verified the app has its own user auth (`"app"`) OR the endpoint is intentionally public (`"none"`). Default is `"required"` so accidental omission fails closed. **Convention**: when using `"app"` or `"none"`, add a comment line above the `auth = "..."` line stating what gates the app or why it's public. **Enforced by `scripts/tg`**: every `tg plan/apply/destroy/refresh` runs `scripts/check-ingress-auth-comments.py` against the current stack and aborts if any `auth = "app|none"` line lacks the preceding `# auth = "<tier>": ...` comment. Stack-scoped — untouched stacks aren't blocked until they're next edited.
  - **Anti-AI**: on by default when `auth = "none"` or `auth = "app"` (no Authentik to discourage bots); redundant on `"required"` and `"public"`.
  - **DNS**: `dns_type = "proxied"` (Cloudflare CDN) or `"non-proxied"` (direct A/AAAA). DNS records are auto-created — no need to edit `config.tfvars`. Smoke-test target: `echo.viktorbarzin.me` (auth=public, header-reflecting backend).
- **Anubis PoW challenge** (`modules/kubernetes/anubis_instance/`): per-site reverse proxy that issues a 30-day JWT cookie after a tiny PoW solve. Use for **public, content-bearing sites without app-level auth** (blog, docs, wikis, static landing pages). Pattern: declare `module "anubis" { source = "../../modules/kubernetes/anubis_instance"; name = "X"; namespace = ...; target_url = "http://<backend>.<ns>.svc.cluster.local" }`, then in `ingress_factory` set `service_name = module.anubis.service_name`, `port = module.anubis.service_port`, `anti_ai_scraping = false`. Shared ed25519 key in Vault `secret/viktor` -> `anubis_ed25519_key`; cookie scoped to `viktorbarzin.me` so one solve covers all Anubis-fronted subdomains. **DO NOT put Anubis in front of Git/API/WebDAV/CLI endpoints** — clients without JS can't solve PoW. **Replicas default to 1** because Anubis stores in-flight challenges in process memory; a challenge issued by pod A and solved against pod B errors with `store: key not found` (HTTP 500). Bumping replicas requires wiring a shared Redis store (TODO). For path-level carve-outs (e.g. wrongmove has `/` behind Anubis but `/api` direct, blog has `/net-diag.sh` direct), declare a second `ingress_factory` with `ingress_path = ["/<path>"]` pointing at the bare backend service. Active on: blog (except `/net-diag.sh`), www, kms, travel, f1, cc, json, pb (privatebin), home (homepage), wrongmove (UI only). See `.claude/reference/patterns.md` "Anti-AI Scraping" for full layering.
- **Docker images**: Always build for `linux/amd64`. SHA-tag rule is being phased out — see `docs/plans/2026-05-16-auto-upgrade-apps-{design,plan}.md`. New model: CI pushes `:latest` (optionally also `:<8-char-sha>` for traceability), Keel polls and triggers rollouts. Cache-staleness concern from the old rule is resolved at the nginx layer (URL-split — manifests pass through, blobs cached). Until Phase 1 of the migration completes (per the plan), follow the SHA-tag rule for new services to match existing pattern.
- **Image registry**: **Owned images now live on `ghcr.io/viktorbarzin/<name>`** (ADR-0002, built by GHA — see the CI/CD Architecture section). The **Forgejo container registry is FROZEN + emptied** (break-glass only — `docs/runbooks/forgejo-registry-breakglass.md`); nothing pushes to it. The rest of this bullet documents the **still-live forgejo-pull DNS/mirror machinery** (it remains in place for the break-glass path + because `registry-credentials` is still Kyverno-synced; the hairpin lessons apply to any internal-registry pull). Historical usage was `image: forgejo.viktorbarzin.me/viktor/<name>:<tag>` + `imagePullSecrets: [{name: registry-credentials}]`. **Kubelet pulls** are kept off the hairpin **at the resolver, with zero node-side DNS config**: pfSense Unbound carries a domain override forwarding the whole `viktorbarzin.me` zone to Technitium (added 2026-06-10, `docs/runbooks/pfsense-unbound.md`), whose split-horizon zone CNAMEs every ingress host (auto-synced hourly by `technitium-ingress-dns-sync`) to the zone apex whose A record tracks the **live** Traefik LB IP (canary: `viktorbarzin-apex-probe`, alerts ViktorBarzinApexDrift). Nodes are stock — link DNS `10.0.20.1 94.140.14.14` via `qm set --nameserver`, no `/etc/hosts` pins, no resolved drop-ins (two same-day interim approaches on 2026-06-10 were removed the same day). The containerd `hosts.toml` mirror (`[host."https://10.0.20.203"]`, `skip_verify = true`) still exists but is **vestigial** — it can NOT keep pulls internal on its own: Traefik routes by Host/SNI and 404s the mirror's bare-IP requests, and the registry's Bearer auth realm is the absolute `https://forgejo.viktorbarzin.me/v2/token` URL fetched outside the mirror — without internal DNS every fresh pull degrades to public DNS → hairpin → intermittent `dial tcp 176.12.22.76:443: i/o timeout` ImagePullBackOff (tuya-bridge 7.5h outage 2026-06-10, tripit 2026-06-09; see `docs/post-mortems/2026-06-10-tuya-bridge-forgejo-pull-hairpin.md`). **In-cluster pods are ordinary internal clients too** (since 2026-06-10 evening) — CoreDNS's dedicated `viktorbarzin.me:53` block (Corefile in `stacks/technitium/modules/technitium/main.tf`) forwards to the Technitium ClusterIP `10.96.0.53`, so pods get the same split-horizon answers as everyone else; forgejo stays pinned to Traefik's **ClusterIP** in that block (TF-interpolated from the live Service) so CI pushes survive a Technitium outage. This relies on a k8s-1.34 behavior verified 2026-06-10: **pods CAN reach the ETP=Local Traefik LB IP** (kube-proxy short-circuits in-cluster traffic to LB IPs via the cluster path) — re-verify after major k8s upgrades; canary = the uptime-kuma `[External]` fleet going red. (The block briefly forwarded to `8.8.8.8/1.1.1.1` earlier that day, which kept pods on the WAN IP and the broken TP-Link NAT loopback — 27 non-proxied `[External]` monitors dark; beads code-yh33.) **Was `.200` until 2026-06-01** — Traefik's 2026-05-30 move to its dedicated `.203` left the mirror pointing at the now-dead `.200:443`, silently breaking every *fresh* forgejo pull; a future LB renumber is now handled by DNS (apex record + drift probe) — only the vestigial hosts.toml literal would go stale. Mirror source lives in `modules/create-template-vm/k8s-node-containerd-setup.sh` (new nodes) and `scripts/setup-forgejo-containerd-mirror.sh` (existing nodes; also cleans up the legacy 2026-06-10 node-DNS customization). Push-side: viktor PAT in Vault `secret/ci/global/forgejo_push_token` (Forgejo container packages are scoped per-user; only the package owner can push, ci-pusher cannot write to viktor/*). Pull-side: cluster-puller PAT in Vault `secret/viktor/forgejo_pull_token`. Retention CronJob (`forgejo-cleanup` in `forgejo` ns, daily 04:00) keeps newest 10 versions + always `:latest` + any buildkit `*cache*` tag — **REVERTED to DRY_RUN 2026-06-10 after its first live run orphaned OCI index children** (multi-arch/attestation children are separate *untagged* sha256 versions that sort outside the newest-10 window while their parent index is kept; broke `kms-website:latest`+`:dfc83fb`, caught by the integrity probe, healed by re-tagging latest→a794d1a + deleting the corrupt version; see `docs/post-mortems/2026-06-10-forgejo-retention-orphaned-indexes.md`). Do NOT re-enable deletes until the keep-set resolves kept indexes' child digests (or skips untagged versions, or moves to Forgejo's native container-aware cleanup rules). The registry PVC remains at its 50Gi autoresize ceiling on the HDD (we did NOT move it to SSD, see beads code-oflt), so a container-aware retention is still needed. Integrity probed every 15min by `forgejo-integrity-probe` in `monitoring` ns (catalog walk + manifest HEAD on every blob). See `docs/plans/2026-05-07-forgejo-registry-consolidation-{design,plan}.md` for the migration history. Pull-through caches for upstream registries (DockerHub, GHCR, Quay, k8s.gcr, Kyverno) stay on the registry VM at `10.0.20.10` ports 5000/5010/5020/5030/5040 — the old port-5050 R/W private registry was decommissioned 2026-05-07.
- **LinuxServer.io containers**: `DOCKER_MODS` runs apt-get on every start — bake slow mods into a custom image (`RUN /docker-mods || true` then `ENV DOCKER_MODS=`). Set `NO_CHOWN=true` to skip recursive chown that hangs on NFS mounts.
- **Node memory changes**: When changing VM memory on any k8s node, update kubelet `systemReserved`, `kubeReserved`, and eviction thresholds accordingly. Config: `/var/lib/kubelet/config.yaml`. Template: `stacks/infra/main.tf`. Current values: systemReserved=512Mi, kubeReserved=512Mi, evictionHard=500Mi, evictionSoft=1Gi.
- **Node OS disk tuning** (in `stacks/infra/main.tf`): kubelet `imageGCHighThresholdPercent=70` (was 85), `imageGCLowThresholdPercent=60` (was 80), ext4 `commit=60` in fstab (was default 5s), journald `SystemMaxUse=200M` + `MaxRetentionSec=3day`.
- **Sealed Secrets**: User-managed secrets go in `sealed-*.yaml` files in the stack directory. Stacks pick them up via `kubernetes_manifest` + `fileset(path.module, "sealed-*.yaml")`. See AGENTS.md for full workflow.
- **CRITICAL — Update docs with every change**: When modifying infrastructure (Terraform, Vault, networking, storage, CI/CD, monitoring), you MUST update all affected documentation in the same commit. Check and update: `docs/architecture/*.md`, `docs/runbooks/*.md`, `.claude/CLAUDE.md`, `AGENTS.md`, `.claude/reference/service-catalog.md`. Stale docs cause incident response failures and onboarding confusion. If unsure which docs are affected, grep for the service/resource name across all doc files.

## Terraform State — Two-Tier Backend
- **Tier 0 (bootstrap)**: Local state, SOPS-encrypted in git. Stacks: `infra`, `platform`, `cnpg`, `vault`, `dbaas`, `external-secrets`. These must exist before PG is reachable.
- **Tier 1 (everything else)**: PostgreSQL backend (`pg`) on CNPG cluster at `pg-cluster-rw.dbaas.svc.cluster.local:5432/terraform_state`. Native `pg_advisory_lock` for concurrent safety. Each stack gets its own PG schema. **Lock contention is non-fatal**: `scripts/tg` passes `-lock-timeout` (default `5m`) so a contended lock waits rather than hard-failing — this was the #1 cause of infra CI failures (a Woodpecker-killed run's unreaped PG lock, a concurrent local apply, or the daily drift `plan`; Tier-1 stacks have no Vault advisory-lock skip to fall back on, unlike Tier-0).
- **Auth**: `scripts/tg` auto-fetches PG credentials from Vault (`database/static-creds/pg-terraform-state`). Humans use `vault login -method=oidc`, agents use K8s auth (role: `terraform-state`, namespace: `claude-agent`).
- **Tier 0 workflow** (unchanged): `git pull` → `scripts/tg plan` → `scripts/tg apply` → `git push`. State sync via SOPS is transparent.
- **Tier 1 workflow**: `vault login -method=oidc` → `scripts/tg plan` → `scripts/tg apply`. No git commit needed — PG is authoritative.
- **Tier detection**: Defined in `terragrunt.hcl` (`locals.tier0_stacks`), `scripts/tg`, and `scripts/state-sync`. All three share the same list.
- **Fallback**: If PG is down, Tier 0 local state can bring it back (`scripts/tg apply` in `dbaas` stack). Tier 1 ops are blocked until PG recovers.
- **Tier 0 details**: Decrypt priority: Vault Transit (primary) → age key fallback. Encrypt: both Vault Transit + age recipients. Scripts: `scripts/state-sync {encrypt|decrypt|commit} [stack]`.
- **Adding operator**: Generate age key (`age-keygen`), add pubkey to `.sops.yaml`, run `sops updatekeys` on Tier 0 `.enc` files. For Tier 1, only Vault access is needed.
- **Migration script**: `scripts/migrate-state-to-pg` (one-shot, idempotent) migrates Tier 1 stacks from local to PG.
- **Adopting existing resources**: use HCL `import {}` blocks (TF 1.5+), not `terraform import` CLI. Commit stanza → plan-to-zero → apply → delete stanza. Canonical reason: reviewable in PR, plan-safe, idempotent, tier-agnostic. Full rules + per-provider ID formats in `AGENTS.md` → "Adopting Existing Resources".

## Secrets Management — Vault KV
- **Vault is the sole source of truth** for secrets.
- **`secret/viktor`** — go-to path for ALL personal secrets (135 keys). Contains every API key, token, password, SSH key, and config from the old terraform.tfvars. Check here first: `vault kv get -field=KEY secret/viktor`.
- **Auth**: `vault login -method=oidc` (Authentik SSO) → `~/.vault-token` → read by Vault TF provider.
- **Vault stack self-reads**: `data "vault_kv_secret_v2" "vault"` reads its own OIDC creds from `secret/vault`.
- **ESO (External Secrets Operator)**: `stacks/external-secrets/` — chart **2.6.0 / app v2.6.0** (migrated 0.12.1→2.6.0 on 2026-06-22, one minor at a time; helm_release has `atomic=true`). **~104 ExternalSecrets across 73 files**, all on **API version `v1`** (migrated v1beta1→v1 on 2026-06-22 — there is NO v1beta1→v1 conversion webhook, so all CRs were rewritten to v1 on chart 0.16.2 before 0.17 removed v1beta1; see `docs/plans/2026-06-21-eso-0.12-to-2.x-migration-design.md`). Two ClusterSecretStores: `vault-kv` and `vault-database`. (2 pre-existing dead ESs — instagram-poster, payslip-ingest — fail "cannot find secret data" on missing Vault keys, unrelated.)
- **Plan-time pattern**: Former plan-time stacks use `data "kubernetes_secret"` to read ESO-created K8s Secrets at plan time (no Vault dependency). First-apply gotcha: must `terragrunt apply -target=kubernetes_manifest.external_secret` first, then full apply. `count` on resources using secret values fails — remove conditional counts.
- **14 hybrid stacks** still keep `data "vault_kv_secret_v2"` for plan-time needs (job commands, Helm templatefile, module inputs). Platform has 48 plan-time refs — no migration possible without restructuring modules.
- **Database rotation**: Vault DB engine rotates passwords every 7 days (604800s). MySQL: speedtest, wrongmove, codimd, nextcloud, shlink, grafana, phpipam. PostgreSQL: health, linkwarden, affine, woodpecker, claude_memory, crowdsec, technitium. Excluded: authentik (PgBouncer), root users. **Apps that read a rotated secret only at startup** (env var / initContainer, not a hot-reloaded mount) MUST carry a Reloader annotation (`secret.reloader.stakater.com/reload: <secret>`) or they keep the stale password and silently fail DB auth on each rotation until manually restarted — matrix's Synapse `inject-db-password` initContainer hit exactly this (found via Loki 2026-06-05, ~12.9k auth-fail lines/hr); matrix has since migrated to tuwunel (RocksDB, no Postgres) on 2026-06-08 and is no longer in the rotation list above. Technitium uses a password-sync CronJob (every 6h) to push rotated password to the Technitium app config via API, disable SQLite + MySQL logging, check PG plugin is loaded, configure PG query logging (90-day retention), and disable SQLite on secondary/tertiary instances.
- **K8s credentials**: Vault K8s secrets engine. Roles: `dashboard-admin`, `ci-deployer`, `openclaw`, `local-admin`. Use `vault write kubernetes/creds/ROLE kubernetes_namespace=NS`. Helper: `scripts/vault-kubeconfig`.
- **CI/CD (GHA + Woodpecker)**: Docker builds run on **GitHub Actions** (free on public repos). Woodpecker is **deploy-only** — receives image tag via API POST, runs `kubectl set image`. Woodpecker authenticates via K8s SA JWT → Vault K8s auth. Sync CronJob pushes `secret/ci/global` → Woodpecker API every 6h. Shell scripts in HCL heredocs: escape `$` → `$$`, `%{}` → `%%{}`.
- **Platform cannot depend on vault** (circular). Apply order: vault first, then platform. Platform has 48 vault refs, all in module inputs — no ESO migration possible.
- **Complex types** (maps/lists like `homepage_credentials`, `k8s_users`) stored as JSON strings in KV, decoded with `jsondecode()` in consuming stack `locals` blocks.
- **New stacks**: Add secret in Vault UI/CLI at `secret/<stack-name>`, add ExternalSecret + `data "kubernetes_secret"` for plan-time, `secret_key_ref` for env vars. Use `data "vault_kv_secret_v2"` only if `data "kubernetes_secret"` won't work (e.g., first-apply bootstrap).
- **Backup CronJob**: `vault-raft-backup` uses manually-created `vault-root-token` K8s Secret (independent of automation).
- **Bootstrap (fresh cluster)**: Comment out data source + OIDC → apply Helm → init+unseal → populate `secret/vault` → uncomment → re-apply.

## Resource Management Patterns
- **CPU**: All CPU limits removed cluster-wide (CFS throttling). Only set CPU requests based on actual usage.
- **Memory**: Set explicit `requests=limits` based on VPA upperBound. Target: upperBound x 1.2 for stable services, x 1.3 for GPU/volatile workloads.
- **Right-sizing**: VPA/Goldilocks was **REMOVED 2026-06-12** (etcd-load-reduction — 349 VPAs all ran `updateMode=Off`, costing ~800 etcd objects + continuous recommender writes + a pod-creation admission webhook for dashboard-only value). Right-size **on demand with `krr`** (Robusta, Dockerized from the devvm — no cluster install, no admission webhook, no eviction risk; reads Prometheus). Set container resources explicitly in TF from krr output.
- **LimitRange**: Tier-based defaults silently apply to pods with `resources: {}`. Always set explicit resources on containers needing more than defaults. Tier 3-edge and 4-aux now use Burstable QoS (request < limit) to reduce scheduler pressure.
- **Democratic-CSI sidecars**: Must set explicit resources (32-80Mi) in Helm values — 17 sidecars default to 256Mi each via LimitRange. `csiProxy` is a TOP-LEVEL chart key, not nested under controller/node.
- **ResourceQuota blocks rolling updates**: When quota is tight, scale to 0 then back to 1 instead of RollingUpdate. Or use Recreate strategy.
- **Kyverno ndots drift**: Kyverno injects dns_config on all pods. Every `kubernetes_deployment`, `kubernetes_stateful_set`, and `kubernetes_cron_job_v1` MUST include `lifecycle { ignore_changes = [spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1 }` (use `spec[0].job_template[0].spec[0].template[0].spec[0].dns_config` for CronJobs). The `# KYVERNO_LIFECYCLE_V1` marker is the canonical discoverability tag — grep for it to locate every site. A shared Terraform module was considered but `ignore_changes` only accepts static attribute paths (not module outputs, locals, or expressions), so the snippet convention is the only viable path. Full rationale and copy-paste snippets in `AGENTS.md` → "Kyverno Drift Suppression".
- **NVIDIA GPU operator resources**: dcgm-exporter and cuda-validator resources configurable via `dcgmExporter.resources` and `validator.resources` in nvidia values.yaml.
- **Pin database versions**: Disable Diun (image update monitoring) for MySQL, PostgreSQL, Redis.
- **Quarterly right-sizing**: Run `krr` (Dockerized, against Prometheus) for recommendations; compare to current requests and adjust in TF. (Goldilocks dashboard removed 2026-06-12.)

## CI/CD Architecture — GHA Builds → ghcr + Woodpecker Deploy

**Doctrine (ADR-0002, fleet-wide as of 2026-06-13): ALL image builds + CI
compute run OFF-infra.** Every owned image is built/linted/tested on GitHub
Actions (public repos: free; private: 2000 free min/mo) and pushed to
`ghcr.io/viktorbarzin/<name>`. **No in-cluster image builds or CI test runs
exist anywhere** — the in-cluster Woodpecker buildkit and the fallback-build
pattern were removed (clean cut). Woodpecker is **deploy-only** (plus infra
applies + maintenance crons). Canonical CI/CD reference:
`docs/architecture/ci-cd.md`; decision: `docs/adr/0002-all-image-builds-off-infra-gha-ghcr.md`.
**Watch what you trigger**: after a push that fires a build chain, follow it to
completion (GHA run → Woodpecker deploy → `rollout status`) and fix failures;
verify via live state, not the checkmark.

**The fleet pattern (every owned app):** Forgejo `viktor/<repo>` (canonical)
push-mirrors (`sync_on_commit`) → GitHub `ViktorBarzin/<repo>` → GHA
`.github/workflows/build.yml` (committed on Forgejo, mirrors over): `on: push:
branches:[master]` ONLY (feature branches mirror but build/deploy nothing — the
safety valve). The `build` job: lint/test → `svu` cuts the next `vX.Y.Z` tag to
CANONICAL Forgejo (GHA secret `FORGEJO_GIT_TOKEN` = write:repository PAT) + bakes
`VERSION` → `buildx` `linux/amd64` `provenance:false` (single-manifest, dodges
the orphaned-index-children class) → push `ghcr.io/viktorbarzin/<name>:<sha8>` +
`:latest` → `delete-package-versions` keep-10. The `deploy` job POSTs
`ci.viktorbarzin.me/api/repos/<id>/pipelines` (the GitHub-mirror's Woodpecker
registration, github-forge; GHA secret `WOODPECKER_TOKEN`) with `IMAGE_TAG` +
`IMAGE_NAME` → `.woodpecker/deploy.yml` (event:**manual** ONLY, so the raw
Forgejo→GitHub mirror pushes don't fire a tag-less deploy) runs `kubectl set
image deployment/<app> …` in-cluster (woodpecker-agent SA = cluster-admin, no
kubeconfig). Deployment image is `ignore_changes`/KEEL_IGNORE_IMAGE so the SHA
sticks vs `terragrunt apply`; CronJobs track `:latest` + `imagePullPolicy:
Always`. **Keel stays enrolled** as a redundant net (sees the SHA already
running → no-op). **Never** `set image`/`rollout restart` operator-managed
StatefulSets (memory id=740). Onboarding tool: `scripts/offinfra-onboard` +
`scripts/offinfra-templates/`; mirror + workflow commits via the Forgejo API over
the internal Traefik LB (`curl --resolve forgejo.viktorbarzin.me:443:10.0.20.203`).
Reference impls: tripit (the original pilot), f1-stream, job-hunter, tuya_bridge.

**Migrated apps (issues #13–#27):** f1-stream, job-hunter, tuya_bridge,
beadboard, nextcloud-todos, claude-agent-service, **claude-memory-mcp** (GHA →
ghcr, NOT DockerHub), kms-website, Freedify, instagram-poster, payslip-ingest,
broker-sync (image `wealthfolio-sync`), fire-planner, recruiter-responder,
x402-gateway — plus tripit. Earlier public-repo apps already on GHA (Website,
apple-health-data, audiblez-web, plotting-book, insta2spotify,
audiobook-search) now also land on ghcr.
- **PUBLIC ghcr packages:** beadboard, nextcloud-todos, claude-agent-service,
  claude-memory-mcp, kms-website, freedify, tuya_bridge, x402-gateway,
  chrome-service-novnc, android-emulator.
- **PRIVATE ghcr:** f1-stream, job-hunter, instagram-poster, payslip-ingest,
  wealthfolio-sync, fire-planner, recruiter-responder, tripit, infra-cli,
  infra-ci, k8s-portal. Pulled via the Kyverno-synced `ghcr-credentials` allowlist
  (`stacks/kyverno/modules/kyverno/ghcr-credentials.tf`; NOT cluster-wide; cred
  = Vault `secret/viktor/ghcr_pull_token`, a dedicated classic PAT scoped to
  `read:packages` (UI-minted 2026-06-15; no longer the admin `github_pat`
  alias). GitHub has no token-mint API, so rotation is manual: re-mint →
  `vault kv patch secret/viktor ghcr_pull_token=…` → targeted apply
  `module.kyverno.kubernetes_secret.ghcr_credentials` (reads Vault, dodges the
  git-crypt tls-secret-sync landmine), Kyverno re-syncs the allowlist).

**Infra-owned images (issues #29/#30)** build on GHA workflows IN the infra
repo's own `.github/workflows/` (added to the GitHub lineage via PR; the
github↔forgejo divergence was deliberately NOT reconciled):
`build-chrome-service-novnc.yml` + `build-android-emulator.yml` → public ghcr;
`build-cli.yml` → DockerHub `viktorbarzin/infra` (kept) + `ghcr.io/viktorbarzin/infra-cli`;
`build-infra-ci.yml` → `ghcr.io/viktorbarzin/infra-ci`; `build-k8s-portal.yml` →
PRIVATE `ghcr.io/viktorbarzin/k8s-portal` (Keel-deployed; the LAST in-cluster
Woodpecker build, migrated 2026-06-13 — completes "no local builds"). **infra-ci**
is the image the `.woodpecker/default.yml` apply step + `drift-detection.yml` run
in (proven by pipelines 165/166). chatterbox-tts is already built by tripit's GHA → ghcr.
The Woodpecker `build-ci-image.yml` + `build-cli.yml` pipelines were REMOVED;
infra-ci break-glass is a manual `.woodpecker/breakglass-infra-ci.yml` (ghcr
pull-and-save to the registry VM).

**Forgejo container registry: FROZEN + emptied** (issue #32 wiped all `viktor/*`
container packages). Break-glass-only now; nothing pushes. `forgejo-cleanup`
stays DRY_RUN. Pull-through caches on `10.0.20.10` are unchanged. Runbook:
`docs/runbooks/forgejo-registry-breakglass.md`.

**Woodpecker now runs only:** per-app `deploy.yml` (manual, `kubectl set
image`), `default.yml` (terragrunt apply), `renew-tls.yml` (certbot),
maintenance crons (drift-detection, provision-user, registry-config-sync,
pve-nfs-exports-sync, issue-automation, postmortem-todos), and the
manual `breakglass-infra-ci.yml`. **No build/test pipeline on any repo — do not
(re)introduce one.** (`.woodpecker/k8s-portal.yml`, the last in-cluster image
build, was removed 2026-06-13 — k8s-portal now builds on GHA → ghcr, see
Infra-owned images above.)

**Decommissioned (issue #31):** travel_blog (stack destroyed + dir removed), 6
dead builders' pipelines (terminal-lobby, webhook-handler, hmrc-sync,
trading-bot, travel-agent, trip-planner), and all `build-fallback.yml` files
(only Website had one).

**Woodpecker API**: numeric repo IDs (`/api/repos/<id>/pipelines`), NOT
owner/name (those return HTML). The deploy registration for each app is the
**GitHub mirror** repo (github-forge). Infra: Forgejo forge = repo 82, legacy
GitHub forge = repo 1.

**Woodpecker YAML gotchas**:
- Commands with `${VAR}:${VAR}` must be **quoted** — unquoted `:` triggers YAML map parsing when vars are empty
- Use `bitnami/kubectl:latest` (not pinned versions — entrypoint compatibility issues)
- Global secrets must have `manual` in their events list for API-triggered pipelines

**GitHub repo secrets** (per repo): `WOODPECKER_TOKEN` (POST deploy pipeline),
`FORGEJO_GIT_TOKEN` (write:repository PAT for the svu tag push). ghcr push uses
the workflow's built-in `GITHUB_TOKEN` (`packages: write`).

## Database Host

**`postgresql_host`** in `config.tfvars` is `pg-cluster-rw.dbaas.svc.cluster.local` (the CNPG primary). The legacy `postgresql.dbaas` service is a live compatibility alias (selector `cnpg.io/instanceRole=primary`, so it also reaches the primary — authentik's PgBouncer still points at it) — but use `pg-cluster-rw` for anything new. This variable is shared by ~12 stacks.

**CNPG tuning** (in `stacks/dbaas/modules/dbaas/main.tf`): `shared_buffers=512MB`, `work_mem=16MB`, `wal_compression=on`, `effective_cache_size=1536MB`, pod memory 2Gi.

## Networking & Resilience
- **Critical path services scaled to 3**: Traefik, Authentik, CrowdSec LAPI, PgBouncer, Cloudflared.
- **PDBs**: minAvailable=2 on Traefik and Authentik.
- **Fallback proxies**: basicAuth when Authentik is down, fail-open when poison-fountain is down.
- **CrowdSec enforcement is out-of-band** (no Traefik plugin/middleware — the dead Yaegi `crowdsec-bouncer-traefik-plugin` was removed on Traefik 3.7.5): banned IPs are dropped **in-kernel via nftables** by the `cs-firewall-bouncer` DaemonSet on **direct** hosts (drops in BOTH the `input` and `forward` hooks — Traefik is ETP=Local so client traffic is DNAT'd to the pod via `forward`; pulls ALL decisions incl. the ~31k CAPI blocklist), and **blocked at the Cloudflare edge** for **proxied** hosts (one `crowdsec_ban` Rules List + a zone WAF block rule, fed by the `crowdsec-cf-sync` CronJob in `rybbit` ns every 2 min — excludes CAPI). Zero per-request latency; **fails open** (LAPI down → no new bans, existing drops persist, legit traffic never blocked). Whitelist covers RFC1918 + tailnet + internal CIDRs. Full as-built: `docs/architecture/security.md`.
- **Rate limiting**: Return 429 (not 503). Per-service tuning via dedicated middleware + `skip_default_rate_limit` (default 10/s burst 50): Immich 1000/20000, ActualBudget 50/300 (app boot = ~70 parallel revalidations), authentik 100/1000 on `/`+`/static` (login SPA cold-loads ~70 flow chunks from `/static`; default burst 429'd them → blank login screen).
- **Retry middleware**: 2 attempts, 100ms — in default ingress chain.
- **Entrypoint transport timeouts** (`websecure` `respondingTimeouts`): `writeTimeout=0` (unlimited download duration), `readTimeout=3600s` (uploads ≤1h), `idleTimeout=600s`. These are **HARD total-duration caps**, not nginx-style per-read idle timeouts — a finite `writeTimeout` truncates *any* large download at that wall-clock mark (a prior `writeTimeout=60s` silently cut Immich videos at 60s). **Do NOT re-tighten `writeTimeout`**; keep `readTimeout` finite (slow-loris backstop) but ≥ longest expected upload. Full rationale: `docs/architecture/networking.md` → "Entrypoint Transport Timeouts".
- **HTTP/3 (QUIC)**: Enabled on Traefik. Works for **direct (non-proxied) apps** via the dedicated LB IP below (ETP=Local). Proxied apps get QUIC at the Cloudflare edge.
- **Traefik LB IP = `10.0.20.203`, `externalTrafficPolicy: Local`** (dedicated, NOT the shared `.200`). Moved off the shared `.200` on 2026-05-30 so direct/non-proxied apps preserve the **real client IP for CrowdSec** (ETP=Cluster SNAT'd them to the node IP) and so QUIC works. **The shared `10.0.20.200` keeps the other 10 LB services** (PG state-backend `postgresql-lb`, headscale, wireguard, coturn, xray, etc. — all ETP=Cluster; MetalLB forbids mixed ETP on a shared IP, hence Traefik's own IP). **cloudflared targets the in-cluster Traefik Service** (`https://traefik.traefik.svc.cluster.local:443`, remote/dashboard tunnel config — edit via CF Global API Key in `secret/platform`), so proxied apps are decoupled from the LB IP. pfSense WAN 443 (tcp+udp) NAT → alias `traefik_lb` (`.203`). Internal split-horizon apex `viktorbarzin.me A` → `.203`. Full runbook + post-mortem: `docs/plans/2026-05-30-traefik-dedicated-ip-etp-local-*`.
- **IPv6 ingress** = HE 6in4 tunnel (`2001:470:6e:43d::2`) → **standalone HAProxy on pfSense** (`/usr/local/etc/ipv6-haproxy.cfg`, NOT the HAProxy package) using `send-proxy-v2` → Traefik `.203` (web 443/80) + mail NodePorts `30125-30128` (25/465/587/993) — so **real IPv6 client IPs reach CrowdSec**. Traefik trusts PROXY-v2 **only from `10.0.20.1`** (`entryPoints.web/websecure.proxyProtocol.trustedIPs`); real IPv4 clients (own source IP) unaffected. **No QUIC over IPv6** (bridge is TCP/h2). Replaced socat 2026-05-30 (socat masked every v6 client as `10.0.20.1`). Boot/persistence: config.xml `<shellcmd>` → `ipv6_proxy.sh` (patches nginx off `[::]:443/:80` to free the tunnel IPv6, then `service ipv6proxy onestart`); `rc.d/ipv6proxy` manages HAProxy. Backends use **no health `check`** (a plain TCP check false-DOWNs the PROXY-expecting listeners). As-built: `docs/architecture/networking.md` → "IPv6 Ingress".
- **IPAM & DNS auto-registration**: pfSense Kea DHCP serves all 3 subnets (VLAN 10, VLAN 20, 192.168.1.x). Kea DDNS auto-registers every DHCP client in Technitium (RFC 2136, A+PTR). CronJob `phpipam-pfsense-import` (hourly) pulls Kea leases + ARP into phpIPAM via SSH (passive, no scanning). CronJob `phpipam-dns-sync` (15min) bidirectional sync phpIPAM ↔ Technitium. 42 MAC reservations for 192.168.1.x.

## Service-Specific Notes
| Service | Key Operational Knowledge |
|---------|--------------------------|
| Nextcloud | MaxRequestWorkers=150, needs 8Gi limit (Apache transient memory spikes, see commit eb94144), very generous startup probe |
| Immich | ML on SSD (CUDA), disable ModSecurity (breaks streaming), frequent upgrades. **`immich-machine-learning` MUST run with `MACHINE_LEARNING_MODEL_TTL > 0`** (set to `600` in `stacks/immich/main.tf`, env on the `immich-machine-learning` deployment). At `0`, no model ever unloads and onnxruntime's CUDA arena (OCR's dynamic input shapes inflate it to ~10 GB) is held forever on the **time-sliced T4 it shares with llama-swap/frigate/immich-server** — which has no VRAM isolation, so immich-ml starved llama-swap (qwen3-8b) and silently broke recruiter-responder triage for ~5 h on 2026-06-02 (post-mortem `docs/post-mortems/2026-06-02-immich-ml-ttl-gpu-oom-recruiter.md`). TTL>0 lets idle models (OCR, face — AND CLIP) free VRAM. The TTL is a single GLOBAL knob (no per-model pin), so CLIP would also unload after 600s idle; the `clip-keepalive` CronJob (`*/5 * * * *`, same stack) pings the CLIP textual encoder so smart-search stays warm without pinning the ad-hoc models. **Smart search has a SECOND warmth layer in Postgres** (don't conflate it with the ML model): the ~665MB vchord `clip_index` must stay resident in PG `shared_buffers`, else an ANN probe that lands on an evicted list pays a ~1.8s cold storage read vs ~4ms warm. The `postStart` hook prewarms it ONCE at pod start and `pg_prewarm.autoprewarm` only re-warms at *startup*, so the index decays out of cache over days under job buffer-pressure (observed ~33% resident after 9d uptime → slow context search, easily misattributed to the ML model). The `clip-index-prewarm` CronJob (`*/5`, same stack) re-runs `pg_prewarm('clip_index')` to pin it hot; `immich-search-probe` (`*/5`) measures live latency + residency → Pushgateway gauges (`immich_smart_search_db_seconds`, `immich_clip_index_cached_pct`) → alerts `ImmichSmartSearchSlow`/`ImmichClipIndexColdCache`/`ImmichSearchProbeStale` + cluster-health check #46 (`check_immich_search`). immich PG role is a superuser so the CronJobs can run `pg_prewarm`/`pg_buffercache`. **Video transcoding is GPU-accelerated**: `immich-server` is pinned to GPU node1 (nodeSelector `nvidia.com/gpu.present` + NoSchedule toleration + `gpu-workload` priority) with a time-sliced `nvidia.com/gpu=1` slice — the stock immich-server image's ffmpeg already ships h264/hevc_nvenc + NVDEC. Activated via `ffmpeg.accel=nvenc` + `accelDecode=true` in the **DB** system-config (`system_metadata` table, key `system-config`, JSONB — NOT Terraform; app config is DB-managed here like oauth/smtp). Direct DB edits need a pod **recreate** to reload (config is cached at boot; only API-driven changes broadcast a reload). **Streaming bitrate is capped** to keep 4K playback smooth on the contended HDD and over remote uplinks: `ffmpeg.maxBitrate=20000k` + `preset=medium` + `transcode=bitrate` (set 2026-06-01 — was uncapped `maxBitrate=0` + `ultrafast` + `targetResolution=original`, which produced 77–264 Mbps 4K transcodes that stuttered for every client, local and remote, since even a single stream needs ~10–13.5 MB/s off the shared `sdc` spindle). 4K resolution is preserved (`targetResolution=original`); originals are NEVER modified — only the `encoded-video/` streaming copy. To re-apply transcode settings to EXISTING videos (config changes only affect new/missing ones): delete the offenders' `asset_file` rows `WHERE type='encoded_video'` (derived/regenerable — never touches originals) then run videoConversion `force=false` (admin Jobs API → "Missing"); it regenerates them to the deterministic `<assetId>.mp4` path at concurrency 1 (gentle on sdc). See `docs/runbooks/immich-transcode-bitrate.md`. If Immich is ever reinstalled fresh (not restored), re-set these keys (accel, accelDecode, **maxBitrate=20000k, preset=medium, transcode=bitrate**). Thumbnails/previews live on SSD NFS (sdb) — do NOT move to block storage (HDD sdc = slower + the contended IO domain). **Background-job concurrency is capped to protect sdc** (DB-managed system-config, `system_metadata` key `system-config`, JSONB `job.*.concurrency`; re-set on fresh install): `thumbnailGeneration=2`, `metadataExtraction=2`, `library=2` — these jobs read ORIGINALS off the HDD library. Left uncapped (were 8/4/4) a library-wide job (e.g. Duplicate Detection on 2026-06-01) fans the ML/thumbnail backfill out into a read storm that saturates sdc and starves etcd → apiserver down. `sidecar`/`smartSearch`/`faceDetection` stay at Immich defaults (small `.xmp` / SSD previews). Apply via Job Settings UI or the `system-config` API; **direct DB edits need an `immich-server` pod recreate to reload** (config cached at boot). See `docs/post-mortems/2026-05-25-immich-anca-elements-io-storm.md`. |
| CrowdSec | Pin version, disable Metabase when not needed (CPU hog), LAPI scaled to 3, **DB on PostgreSQL** (migrated from MySQL), flush config: max_items=10000/max_age=7d/agents_autodelete=30d, DECISION_DURATION=168h in blocklist CronJob. **Enforcement is out-of-band, NOT a Traefik plugin** (the Yaegi `crowdsec-bouncer-traefik-plugin` was dead on Traefik 3.7.5 and removed): `cs-firewall-bouncer` DaemonSet drops in-kernel via nftables on direct hosts (bouncer key `firewall`, v0.0.34 binary fetched at runtime, hostNetwork+NET_ADMIN, `stacks/crowdsec/modules/crowdsec/firewall_bouncer.tf`); `crowdsec-cf-sync` CronJob blocks at the CF edge for proxied hosts (bouncer key `kvsync`, `stacks/rybbit/crowdsec_edge.tf`). Both fail open. See `docs/architecture/security.md` |
| Frigate | GPU stall detection in liveness probe (inference speed check), high CPU |
| Authentik | 3 server replicas + 2-replica embedded outpost (PG-backed sessions), PgBouncer in front of PostgreSQL, strip auth headers before forwarding. **`authentik.*` Helm values are INERT** (existingSecret skips chart env rendering) — tune via `server.env`/`worker.env` in `modules/authentik/values.yaml`. Single-screen login (password embedded in identification stage); all first-party OIDC apps use implicit consent (2026-06-10). `/static` ingress carve-out serves assets with immutable Cache-Control; `/`+`/static` use a dedicated `authentik-rate-limit` (100/1000) so the cold-load chunk burst isn't 429'd into a blank screen. **Reliability (2026-06-28): the chart key is `deploymentStrategy`, NOT `strategy`** — the old `strategy:` key was inert, so live ran the chart default 25%/25% and dropped a server pod out of rotation on every roll; now `maxSurge:1/maxUnavailable:0`. Readiness `failureThreshold:8` (~80s, was 30s): the DB-coupled `/-/health/ready/` returns 503 on a PG/pgbouncer blip, and with too-tight tolerance all 3 server pods left the Service at once → Traefik 502/504 (the episodic blank-screen + 30s-hang). gunicorn `max_requests=10000`/jitter=1000 decorrelates worker recycles from DB blips. Redis is GONE since 2026.2 (sessions+cache+channels on PostgreSQL, no external-cache option) — a short PG transient is now survived, but a TOTAL CNPG outage still takes authentik down. **Login latency (SLOW-1a, 2026-06-28):** server+worker run a CUSTOM OVERLAY image `ghcr.io/viktorbarzin/authentik-server:2026.2.4-patch1` (built by `.github/workflows/build-authentik.yml` from `stacks/authentik/Dockerfile`) narrowing the identification-stage `select_subclasses()` query (~1.4s→~14ms; bare upstream call LEFT-JOINs every source subtype). **Keel un-enrolled** for the ns → image pinned in `global.image` (repo+tag), **upgraded manually**: bump the Dockerfile `FROM` + the values tag together, GHA rebuilds, then apply. NOTE: an old client browser still can't run the SPA regardless — iPadOS ≤15 (Safari ≤15.6) renders the login blank (needs Safari 16+; no server-side fix; emo's iPad hit this). |
| Kyverno | failurePolicy=Ignore to prevent blocking cluster, pin chart version |
| MySQL Standalone | Raw `kubernetes_stateful_set_v1` pinned to `mysql:8.4.8` exactly (migrated from InnoDB Cluster 2026-04-16; **pinned to 8.4.8 on 2026-05-18** after Keel-driven `mysql:8.4` → 8.4.9 bump stalled the DD upgrade and required a full PVC-wipe + dump-restore — see `docs/runbooks/restore-mysql.md` and beads code-eme8/code-k40p). `skip-log-bin`, `innodb_flush_log_at_trx_commit=2`, `innodb_doublewrite=ON`. ConfigMap `mysql-standalone-cnf`. PVC `data-mysql-standalone-0` (5Gi initial → 30Gi via autoresizer, `proxmox-lvm-encrypted`). Service `mysql.dbaas` unchanged. Anti-affinity excludes k8s-node1. Bitnami charts deprecated (Broadcom Aug 2025) — use official images. |
| phpIPAM | IPAM — no active scanning. `pfsense-import` CronJob (hourly) pulls Kea leases + ARP via SSH. `dns-sync` CronJob (15min) bidirectional sync with Technitium. Kea DDNS on pfSense handles all 3 subnets. API app `claude` (ssl_token). |

## Monitoring & Alerting
- **Alert-on-change routing** (alert-noise-reduction 2026-06-12, `route` block in `prometheus_chart_values.tpl`): warning/info notify ONCE then stay quiet while firing (`repeat_interval: 8760h` ≈ off); criticals re-ping every 6h (was 1h); `send_resolved` on. Standing state is reviewed via the daily digest, not re-pings.
- **Daily alert digest**: CronJob `alert-digest` (monitoring ns, `alert_digest.tf` + `alert_digest.py`) posts the full current board grouped by severity + resolved-in-24h to `#alerts` at 08:00 Europe/London. Stock `python:3.12-alpine`, pure-stdlib (no pip/apk at runtime — avoids the status-page-pusher disk anti-pattern, id=559); reads Alertmanager v2 + Prometheus; reuses the Alertmanager Slack webhook via the `alert-digest` Secret. Safety net for alert-on-change.
- **Cascade inhibitions** (`inhibit_rules`): `NodeDown` AND `NodeConditionBad`/`NodeDiskPressure` suppress downstream pod-churn alerts (PodCrashLooping/PodImagePullBackOff/PodsStuckContainerCreating/ScrapeTargetDown/*ReplicasMismatch); `T3ProbeLegDown` suppresses `T3ProbeDropBurst` for the same `leg`; plus existing NFS/Traefik/Authentik/Power/Tuya/iDRAC cascades. No `equal` on the node rules (pod alerts carry no `node` label → cluster-wide, like NodeDown).
- **ScrapeTargetDown scrapes only Ready endpoints** (relabel `keep __meta_kubernetes_endpoint_ready=true` on both `kubernetes-service-endpoints` jobs) — completed CronJob pods lingering as NotReady EndpointSlice addresses no longer fire phantom "down" alerts (tts/tripit/beads, id=4895). Replaces the old "exclude completed CronJob pods" guidance; a Ready pod with a broken metrics endpoint still fires.
- Alertmanager is now scraped (`extraScrapeConfigs` job `alertmanager`) → `alertmanager_notifications_total`/`_alerts`/`_notifications_failed_total` available; it had no `prometheus.io/scrape` annotation so notification volume was previously unmeasurable.
- Every new service gets Prometheus scrape config + Uptime Kuma monitor. External monitors auto-created for Cloudflare-proxied services by `external-monitor-sync` CronJob (10min, uptime-kuma ns). Mechanism: `ingress_factory` auto-adds `uptime.viktorbarzin.me/external-monitor=true` whenever `dns_type != "none"` (see `modules/kubernetes/ingress_factory/main.tf`) — no manual action needed on new services. The `cloudflare_proxied_names` list in `config.tfvars` is a legacy fallback for the 17 hostnames not yet migrated to `ingress_factory` `dns_type`; don't check that list when debugging "is this monitored?" questions.
- **External monitoring**: `[External] <service>` monitors in Uptime Kuma test full external path (DNS → Cloudflare → Tunnel → Traefik). Divergence metric `external_internal_divergence_count` → alert `ExternalAccessDivergence` (15min). Config: `stacks/uptime-kuma/`, targets from `cloudflare_proxied_names` in `config.tfvars` (17 remaining centrally-managed hostnames; most DNS records now auto-created by `ingress_factory` `dns_type` param).
- Key alerts: OOMKill, pod replica mismatch, 4xx/5xx error rates, UPS battery, CPU temp, SSD writes, NFS responsiveness, ClusterMemoryRequestsHigh (>85%), ContainerNearOOM (>85% limit), PodUnschedulable, ExternalAccessDivergence, ImmichSmartSearchSlow (context-search latency / clip_index cache eviction), AuthentikRootRouter5xxHigh (all-3-server-pods-NotReady cascade → 502/503/504 on the authentik `/` router). **The Traefik scrape keeps `traefik_router_requests_total`** (per-router `code` label) — the drop-regex in the `traefik` scrape job drops only the high-cardinality `*_duration_seconds_bucket` histogram, NOT the request counter, so per-router 429/5xx is queryable + alertable.
- **E2E email monitoring**: CronJob `email-roundtrip-monitor` (every 20 min) sends test email via Brevo HTTP API to `smoke-test@viktorbarzin.me` (catch-all → `spam@`), verifies IMAP delivery, deletes test email, pushes metrics to Pushgateway + Uptime Kuma. Alerts: `EmailRoundtripFailing` (60m), `EmailRoundtripStale` (60m), `EmailRoundtripNeverRun` (60m). Outbound relay: Brevo EU (`smtp-relay.brevo.com:587`, 300/day free — migrated from Mailgun). Inbound external traffic enters via pfSense HAProxy on `10.0.20.1:{25,465,587,993}`, which forwards to k8s `mailserver-proxy` NodePort (30125-30128) with `send-proxy-v2`. Mailserver pod runs alt PROXY-speaking listeners (2525/4465/5587/10993) alongside stock PROXY-free ones (25/465/587/993) for intra-cluster clients. Real client IPs recovered from PROXY v2 header despite kube-proxy SNAT (replaces pre-2026-04-19 MetalLB `10.0.20.202` ETP:Local scheme; see bd code-yiu + `docs/runbooks/mailserver-pfsense-haproxy.md`). Vault: `brevo_api_key` in `secret/viktor` (probe + relay).
- **Authentik walling-off guard**: `blackbox-exporter` (monitoring ns, `stacks/monitoring/modules/monitoring/authentik_walloff_probe.tf`) probes each must-stay-public `auth = "none"` carve-out URL with `no_follow_redirects` and FAILS (`fail_if_header_matches` on `Location`) iff it 302s to Authentik. Catches a carve-out regressing (TF revert / deploy / `ingress_factory` `auth` default flipping back to `"required"`). Scrape job `blackbox-authentik-walloff` (1m) → alert `AuthentikWallingOffPublicPath` (`probe_failed_due_to_regex == 1`, for 10m, `lane=security` → posts to `#alerts` via the `slack-security` receiver, which keeps its `[SECURITY]` styling; the dedicated `#security` channel was abandoned 2026-06-25 — the shared webhook's app isn't a member of it). **To guard a new carve-out: add one line to `local.authentik_walloff_targets`** (a `service → URL` map; `valid_status_codes` includes 301/302 so legit redirects/404s stay green — only the Authentik `Location` fails the probe). `curl -sI '<url>'` must NOT show a Location to `authentik.viktorbarzin.me` before adding.

## Security Posture (Wave 1 — locked 2026-05-18)

Plan in `docs/architecture/security.md` + response playbook in `docs/runbooks/security-incident.md`. Beads epic: `code-8ywc`.

- **Identity allowlist for security rules**: ONLY `me@viktorbarzin.me`. NOT `viktor@viktorbarzin.me`, NOT `emo@viktorbarzin.me` (those don't exist). emo's identity scheme is unknown — ask before assuming.
- **Source-IP allowlist (K2, K9, V7, S1)**: `10.0.20.0/22`, `192.168.1.0/24` (Proxmox + Sofia LAN), K8s pod CIDR, K8s service CIDR, Headscale tailnet. **Policy: no public-IP access** — Vault, kube-apiserver, PVE sshd must transit LAN or Headscale. **One documented exception (2026-06-11): break-glass SSH** — PVE sshd on a WAN-exposed `:52222`, key-only, dedicated break-glass key only (`Match LocalPort`), rate-limited + fail2ban; intentionally cluster-independent so it survives an outage. As-built `docs/runbooks/breakglass-ssh.md`. (Replaced the 2026-05-30 port-knock design — circular Vault dep caused a lockout.)
- **Response model**: (I) Slack-only daily skim. All security alerts via Loki ruler → Alertmanager → the `slack-security` receiver, which posts to `#alerts` (it keeps its `[SECURITY/<sev>]` title styling so security-lane alerts stand out). Severity labels carried in the alert (critical/warning/info). No paging. The dedicated `#security` channel was abandoned 2026-06-25 — the shared `alertmanager_slack_api_url` webhook's Slack app isn't a member of it (a `#security` override 404s), so everything consolidated to `#alerts`.
- **Kyverno policies (wave 1)**: `deny-privileged-containers`, `deny-host-namespaces`, `restrict-sys-admin`, `require-trusted-registries` flip Audit→Enforce with the 31-namespace exclude list (memory id=1970). `failurePolicy: Ignore` preserved. Cosign `verify-images` deferred.
- **NetworkPolicy default-deny egress (wave 1)**: observe-then-enforce (γ approach) — Calico flow logs cluster-wide + GlobalNetworkPolicy log-only on tier 3+4, build empirical allowlist after 1 week, phased per-namespace enforce starting `recruiter-responder`. Tier 0/1/2 deferred. **The internal (ns-to-ns) half of each allowlist now derives faster from the east-west flow trail** (below): `SELECT DISTINCT dst_ns FROM edge WHERE src_ns='<ns>' AND action='allow'`. External egress is NOT in that table (empty-ns flows dropped) — those still come from the Calico flow-log W1.6 snapshot. Enforce-flips remain out of scope of the trail (observe-and-derive only; beads `code-8ywc`).
- **East-west flow trail (who-talks-to-whom, ADR-0014)**: Calico **Goldmane** (`goldmane.calico-system:7443`, gRPC/mTLS, ~60-min in-memory ring buffer — no etcd writes) + **Whisker** live UI (`whisker.viktorbarzin.me`, Authentik-gated) → **`goldmane-edge-aggregator`** streams Goldmane's `Flows.Stream` over mTLS and upserts the namespace-pair **edge set** (`edge(src_ns,dst_ns,action,first_seen,last_seen,flow_count)`, self-edges + public-internet flows dropped) into **CNPG DB `goldmane_edges`** → daily **`goldmane-edges-digest`** CronJob posts first-seen edges to `#alerts` (consolidated to `#alerts`; the `#security` channel was abandoned 2026-06-25 — the shared webhook's Slack app isn't a member of it, so a `#security` override 404s; see runbook). **CERT-REUSE GOTCHA**: the aggregator's mTLS client cert reuses the operator's Tigera-CA-signed `whisker-backend-key-pair` Secret (Goldmane verifies CA-chain only) — **re-apply `stacks/goldmane-edge-aggregator` if the operator rotates it** (symptom: no `last_seen` updates, `AggregatorDown`). Service identity = namespace, + `service-identity` label only in `monitoring`/`kube-system`/`dbaas`. Health: `AggregatorDown` + `DigestFailing` alerts + cluster-health #48. **WHISKER-WEDGE GOTCHA** (2026-06-28): the operator's `whisker` NetworkPolicy allows DNS egress only to kube-dns *pods*, but whisker-backend resolves goldmane via the kube-dns *ClusterIP* — Calico drops UDP DNS to a ClusterIP under a podSelector-only egress rule, so when whisker-backend's gRPC stream breaks and it re-resolves, it wedges and the UI goes **empty** (the aggregator, a separate pod, is unaffected). FIX = additive egress NP `whisker-allow-dns-clusterip` (`stacks/calico`, allows whisker→10.96.0.10/32:53); the `whisker-watchdog` CronJob is a backstop. Manual heal `kubectl -n calico-system delete pod -l k8s-app=whisker`. Runbook: `docs/runbooks/goldmane-flow-trail.md`. (Goldmane is OSS tech-preview — reversible operator-CR toggle in `stacks/calico/main.tf`.)
- **What's NOT in scope**: canary tokens (rejected — self-trigger risk with Viktor's normal `vault kv list secret/viktor` and `kubectl get secret -A` workflows), Falco/Tetragon (too noisy for Slack-only daily check), Cloudflare/GitHub audit polling (deferred to wave 2).

## Storage & Backup Architecture

### Storage Class Decision Rule (for new services)

Choose storage class based on workload type:

| Use **proxmox-lvm-encrypted** when | Use **proxmox-lvm** when | Use **NFS** (`nfs_volume` module) when |
|------------------------------------|--------------------------|----------------------------------------|
| **Any service storing sensitive data** | Non-sensitive app state (configs, caches) | Shared data across multiple pods (RWX) |
| Databases (user data, credentials) | Media indexes, search caches | Media libraries (music, ebooks, photos) |
| Auth/identity services | Monitoring data (Prometheus) | Backup destinations (cloud sync picks up from NFS) |
| Password managers, email, git repos | Tools with no user secrets | Large datasets (>10Gi) where snapshots matter |
| Health/financial data | | Data you want to browse/inspect from outside k8s |

**Default for sensitive data is proxmox-lvm-encrypted.** Use plain `proxmox-lvm` only for non-sensitive workloads. Use NFS when you need RWX, backup pipeline integration, or it's a large shared media library.

**NFS server:**
- **Proxmox host** (192.168.1.127): Sole NFS for all workloads. HDD at `/srv/nfs` (ext4 thin LV `pve/nfs-data`, 3 TB). SSD at `/srv/nfs-ssd` (ext4 LV `ssd/nfs-ssd-data`, 100GB). Exports use `async,insecure` options (`async` — safe with UPS + Vault Raft replication + databases on block storage; `insecure` — pfSense NATs source ports >1024 between VLANs).
- **Nextcloud as NFS browser**: Nextcloud (`nextcloud.viktorbarzin.me`) mounts the PVE NFS roots (`/srv/nfs`, `/srv/nfs-ssd`) inside the NC pod at `/mnt/pve-nfs` + `/mnt/pve-nfs-ssd`. Surfaced to users via two ACL patterns: (1) admin-only root browsers `PVE NFS Pool` + `PVE NFS-SSD Pool` (scoped to NC group `admin`); (2) per-archive mounts (e.g. `/anca-elements`) with `applicable_users` set to the owners. ACL is at the mount level via `occ files_external:applicable` — Files Access Control is NOT used (NC 30/31's workflow engine lacks FilePath / UserId checks). Manifest lives in `kubernetes_config_map_v1.nextcloud_external_storage_manifest` (`stacks/nextcloud/external_storage.tf`); a one-shot K8s Job applies it idempotently.
- **`nfs-truenas` StorageClass**: Historical name retained only because SC names are immutable on PVs (48 bound PVs reference it — renaming would require mass PV churn, not worth it). Now points to the Proxmox host (`nfs.csi.k8s.io` dynamic provisioning on `192.168.1.127:/srv/nfs`). TrueNAS (VM 9000, 10.0.10.15) operationally decommissioned 2026-04-13; VM still exists in stopped state on PVE pending user decision on deletion.

**Migration note**: CSI PV `volumeAttributes` are immutable — cannot update NFS server in place. New PV/PVC pairs required (convention: append `-host` to PV name).

**NFS CSI mount option requirements** (learned from [PM-2026-04-14]):
- **ALWAYS set `nfsvers=4`** in CSI mount options. NFSv3 is disabled on the PVE host (`vers3=n` in `/etc/nfs.conf`). Without this, mounts fail silently if kernel NFS client state is corrupt.
- **NEVER use `fsid=0`** in `/etc/exports` on `/srv/nfs`. `fsid=0` designates the NFSv4 pseudo-root, which breaks subdirectory path resolution for all CSI mounts. Only `fsid=1` (unique ID) is safe on `/srv/nfs-ssd`.
- **`/etc/exports` is git-managed** at `infra/scripts/pve-nfs-exports`. Deploy: `scp scripts/pve-nfs-exports root@192.168.1.127:/etc/exports && ssh root@192.168.1.127 exportfs -ra`
- **Critical services MUST NOT use NFS storage** — circular dependency risk. Alertmanager, Prometheus, and any monitoring that should alert about NFS must use `proxmox-lvm-encrypted`. Technitium DNS primary uses `proxmox-lvm-encrypted` (migrated 2026-04-14).
- **NFS PV template** (in `modules/kubernetes/nfs_volume/`): always include `mountOptions: ["nfsvers=4", "soft", "actimeo=5", "retrans=3", "timeo=30"]`

**proxmox-lvm PVC template** (Terraform):
```hcl
resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "<service>-data-proxmox"
    namespace = kubernetes_namespace.<ns>.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = { storage = "1Gi" }
    }
  }
  lifecycle {
    # pvc-autoresizer expands this PVC up to storage_limit; ignore drift on
    # requests.storage so the next TF apply doesn't try to shrink it back
    # (K8s rejects shrinks → apply fails). To bump the floor manually:
    # temporarily remove this block, apply the new size, re-add the block,
    # apply again.
    ignore_changes = [spec[0].resources[0].requests]
  }
}
```
- `wait_until_bound = false` is **required** (WaitForFirstConsumer binding)
- Deployment strategy **must be Recreate** (RWO volumes)
- Autoresizer annotations are **required** on all proxmox-lvm PVCs
- `lifecycle.ignore_changes` on `requests` is **required** to coexist with the autoresizer
- Every proxmox-lvm app **MUST** add a backup CronJob writing to NFS `/mnt/main/<app>-backup/`

**proxmox-lvm-encrypted PVC template** (Terraform) — use for all sensitive data:
```hcl
resource "kubernetes_persistent_volume_claim" "data_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "<service>-data-encrypted"
    namespace = kubernetes_namespace.<ns>.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = { storage = "1Gi" }
    }
  }
  lifecycle {
    # See data_proxmox above — required for autoresizer coexistence.
    ignore_changes = [spec[0].resources[0].requests]
  }
}
```
- Same rules as `proxmox-lvm` (wait_until_bound, Recreate strategy, autoresizer, backup CronJob, `lifecycle.ignore_changes`)
- Uses LUKS2 encryption with Argon2id key derivation via Proxmox CSI plugin
- Encryption passphrase stored in Vault KV (`secret/viktor/proxmox_csi_encryption_passphrase`), synced to K8s Secret `proxmox-csi-encryption` in `kube-system` via ExternalSecret
- Backup key at `/root/.luks-backup-key` on PVE host (chmod 600)
- CSI node plugin needs 1280Mi memory limit for LUKS operations (`node.plugin.resources` in Helm values)
- Convention: PVC names end in `-encrypted` (not `-proxmox`)

### 3-2-1 Backup Strategy
**Copy 1**: Live data on sdc thin pool (65 PVCs + VMs)
**Copy 2**: sda backup disk (`/mnt/backup`, 1.1TB ext4, VG `backup`)
**Copy 3**: Synology NAS offsite (two-tier: sda + NFS)

**PVE host scripts** (source: `infra/scripts/`; deployed manually via `scp` to `/usr/local/bin/<name>` — strip the `.sh`):
- `/usr/local/bin/nfs-mirror` — Daily 02:00. `rsync --delete /srv/nfs/<svc>/ → /mnt/backup/<svc>/` (sda leg 1), appends transferred paths to `/mnt/backup/.changed-files` for offsite Step 1. **EXCLUDES**: immich (too big — direct leg), frigate/temp (no backup), anca-elements (in Immich), and **(2026-06-01) ollama, prometheus-backup, audiblez, ebook2audiobook** — regenerable, live-only on sdc, kept off the space-constrained offsite. Does NOT mirror `/srv/nfs-ssd`.
- `/usr/local/bin/daily-backup` — Daily 05:00. Mounts LVM thin snapshots ro → rsyncs FILES to `/mnt/backup/pvc-data/<YYYY-WW>/<ns>/<pvc>/` with `--link-dest` versioning (4 weeks). Auto SQLite backup (magic number check, `?mode=ro`). Also backs up pfSense (config.xml + tar), PVE config. Prunes snapshots >7d. **Skip-list (2026-06-01)**: `nextcloud/nextcloud-data-proxmox` (orphaned pre-encryption PV).
- `/usr/local/bin/offsite-sync-backup` — Daily 06:00 (After=daily-backup). Step 1: sda → Synology `pve-backup/` (incremental via manifest; monthly full `rsync --delete` days 1–7). Step 2: NFS direct → Synology — **immich-only on BOTH `nfs/` and `nfs-ssd/` (2026-06-01)**; ollama/llamacpp on the SSD no longer ship offsite.
- `/usr/local/bin/lvm-pvc-snapshot` — Daily 03:00. Thin snapshots of all PVCs except dbaas+monitoring. 7-day retention. Instant restore: `lvm-pvc-snapshot restore <lv> <snap>`.
- `/usr/local/bin/vzdump-vms` — Daily 01:00. Live `vzdump --mode snapshot` of hand-managed VMs (the ones NOT in Terraform) → `/mnt/backup/vzdump/`, keep 3 per VMID. `VZDUMP_VMIDS` default `102` (devvm) — **the only VM imaged today** (its per-user home dirs + local-only git repos, incl. the no-remote monorepo root, are otherwise irreplaceable). devvm has the guest agent (`agent: 1`) so dumps are fs-consistent. Deliberately NOT in the incremental offsite manifest (would balloon Synology); the monthly offsite full pass (days 1-7) mirrors `/mnt/backup/vzdump/`. Pushgateway job `vzdump-backup`. Added 2026-06-09 (closed the silent "VMs never imaged" DR gap). Restore: `qmrestore /mnt/backup/vzdump/vzdump-qemu-<vmid>-<ts>.vma.zst <vmid>`.
- `nfs-change-tracker.service` — Continuous inotifywait on `/srv/nfs` + `/srv/nfs-ssd`. Logs changed file paths to `/mnt/backup/.nfs-changes.log`. Consumed by offsite-sync-backup for incremental rsync (completes in seconds instead of 30+ minutes).

**Synology layout** (`192.168.1.13:/volume1/Backup/Viki/`):
- `pve-backup/` — PVC file backups (`pvc-data/`), SQLite backups (`sqlite-backup/`), pfSense, PVE config (synced from sda)
- `nfs/` — mirrors `/srv/nfs` on Proxmox (inotify change-tracked rsync)
- `nfs-ssd/` — mirrors `/srv/nfs-ssd` on Proxmox (inotify change-tracked rsync)

**App-level CronJobs** (write to Proxmox host NFS, synced to Synology via inotify):
- MySQL (daily full + per-db), PostgreSQL (daily full + per-db), Vault (weekly), Vaultwarden (6h + integrity), Redis (weekly), etcd (weekly)
- **Per-database backups**: `postgresql-backup-per-db` (00:15, `pg_dump -Fc` → `/backup/per-db/<db>/`) and `mysql-backup-per-db` (00:45, `mysqldump` → `/backup/per-db/<db>/`). Enables single-database restore without affecting others.
- **Convention**: New proxmox-lvm apps MUST add a backup CronJob writing to `/mnt/main/<app>-backup/`

**Restore paths**:
- Single database: `pg_restore -d <db> --clean --if-exists` (PG) or `mysql <db> < dump.sql.gz` (MySQL) from per-db backup
- Accidental delete: `lvm-pvc-snapshot restore` (instant, 7 daily snapshots)
- Older data: Browse `/mnt/backup/pvc-data/<week>/<ns>/<pvc>/`, rsync back
- Database (full cluster): Restore from dump at `/srv/nfs/<db>-backup/` or Synology `nfs/<db>-backup/`
- pfsense: Upload config.xml via web UI, or extract tar for custom scripts
- Full disaster: Restore from Synology

## Known Issues
- **CrowdSec Helm upgrade times out**: `terragrunt apply` on platform stack causes CrowdSec Helm release to get stuck in `pending-upgrade`. Workaround: `helm rollback crowdsec <rev> -n crowdsec`. Root cause: likely ResourceQuota CPU at 302% preventing pods from passing readiness probes. Needs investigation.
- **OpenClaw config is writable**: OpenClaw writes to `openclaw.json` at runtime (doctor --fix, plugin auto-enable). Never use subPath ConfigMap mounts for it — use an init container to copy into a writable volume. Needs 2Gi memory + `NODE_OPTIONS=--max-old-space-size=1536`. **`mcp.servers` baked into the ConfigMap-loaded openclaw.json gets stripped by `doctor --fix`** — register MCP servers via `openclaw mcp set <name> <json>` in the container startup command instead (CLI-written entries persist across doctor runs). Current servers wired this way: `ha`, `context7`, `playwright` (sidecar at `localhost:3000/mcp`).
- **OpenClaw memory-core indexes `/workspace/memory/`, not `/home/node/.openclaw/memory/`**: `/home/node/.openclaw/memory/main.sqlite` is the index store, NOT a content source. Files written under `/home/node/.openclaw/memory/projects/<x>/*.md` will NOT be indexed. To populate memory-core, write Markdown under `/workspace/memory/projects/<source>/` and run `openclaw memory index --force`. This is what the daily `memory-sync` CronJob in `stacks/openclaw/` does for claude-memory → OpenClaw sync.
- **(Obsolete 2026-06-12) Goldilocks VPA**: VPA/Goldilocks was uninstalled (etcd-load-reduction); the old "Goldilocks may have added a limit that blocks the change" gotcha no longer applies. Use `krr` for right-sizing.

## User Preferences
- **Calendar**: Nextcloud at `nextcloud.viktorbarzin.me`
- **Home Assistant**: ha-london (default), ha-sofia. "ha"/"HA" = ha-london
- **Frontend**: Svelte for all new web apps
- **Tools**: Docker containers only — never `brew install` locally
- **Pod monitoring**: Never use `sleep` — spawn background subagent with `kubectl get pods -w`
