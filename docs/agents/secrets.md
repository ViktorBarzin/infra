# Secrets

Moved verbatim from the repo's agent instruction files (`AGENTS.md`, `.claude/CLAUDE.md`) on 2026-09-22, when the two merged into one root `AGENTS.md`. Related as-built docs: `docs/architecture/secrets.md`.

## Secrets Management — Vault KV
- **Vault stack self-reads**: `data "vault_kv_secret_v2" "vault"` reads its own OIDC creds from `secret/vault`.
- **ESO (External Secrets Operator)**: `stacks/external-secrets/` — chart **2.6.0 / app v2.6.0** (migrated 0.12.1→2.6.0 on 2026-06-22, one minor at a time; helm_release has `atomic=true`). **~104 ExternalSecrets across 73 files**, all on **API version `v1`** (migrated v1beta1→v1 on 2026-06-22 — there is NO v1beta1→v1 conversion webhook, so all CRs were rewritten to v1 on chart 0.16.2 before 0.17 removed v1beta1; see `docs/plans/2026-06-21-eso-0.12-to-2.x-migration-design.md`). Two ClusterSecretStores: `vault-kv` and `vault-database`. **refreshInterval is split by store on purpose (2026-09-03):** `vault-kv` ExternalSecrets refresh at `1h`, `vault-database` ones stay at `15m`. Every Vault database role here is a STATIC role rotating weekly, and the old password dies the instant it rotates, so the app is broken until ESO polls and Reloader restarts it — measured at 4-7 min of CI downtime per rotation for woodpecker at 15m (infra#45), which an hourly refresh would stretch toward 60. Raise a `vault-database` one only with a per-stack force-sync CronJob like woodpecker's. (1 pre-existing dead ES — `instagram-poster-secrets` — fails "cannot find secret data" on a missing Vault key, unrelated. `payslip-ingest-secrets` was in that state too and is **no longer**: verified `SecretSynced True` with all 6 keys on 2026-08-16, so re-check before citing an ES as dead.)
- **Plan-time pattern**: Former plan-time stacks use `data "kubernetes_secret"` to read ESO-created K8s Secrets at plan time (no Vault dependency). First-apply gotcha: must `terragrunt apply -target=kubernetes_manifest.external_secret` first, then full apply. `count` on resources using secret values fails — remove conditional counts.
- **14 hybrid stacks** still keep `data "vault_kv_secret_v2"` for plan-time needs (job commands, Helm templatefile, module inputs). Platform has 48 plan-time refs — no migration possible without restructuring modules.
- **Database rotation**: Vault DB engine rotates passwords every 7 days (604800s). MySQL: speedtest, wrongmove, codimd, nextcloud, shlink, grafana, phpipam. PostgreSQL: health, linkwarden, affine, woodpecker, claude_memory, crowdsec, technitium, paperless_ngx. Excluded: authentik (PgBouncer), root users. **Apps that read a rotated secret only at startup** (env var / initContainer, not a hot-reloaded mount) MUST carry a Reloader annotation (`secret.reloader.stakater.com/reload: <secret>`) or they keep the stale password and silently fail DB auth on each rotation until manually restarted — matrix's Synapse `inject-db-password` initContainer hit exactly this (found via Loki 2026-06-05, ~12.9k auth-fail lines/hr); matrix has since migrated to tuwunel (RocksDB, no Postgres) on 2026-06-08 and is no longer in the rotation list above. Technitium uses a password-sync CronJob (every 6h) to push rotated password to the Technitium app config via API, disable SQLite + MySQL logging, check PG plugin is loaded, configure PG query logging (90-day retention), and disable SQLite on secondary/tertiary instances.
- **K8s credentials**: Vault K8s secrets engine. Roles: `dashboard-admin`, `ci-deployer`, `openclaw`, `local-admin`. Use `vault write kubernetes/creds/ROLE kubernetes_namespace=NS`. Helper: `scripts/vault-kubeconfig`.
- **CI/CD (GHA + Woodpecker)**: Docker builds run on **GitHub Actions** (free on public repos). Woodpecker is **deploy-only** — receives image tag via API POST, runs `kubectl set image`. Woodpecker authenticates via K8s SA JWT → Vault K8s auth. Sync CronJob pushes `secret/ci/global` → Woodpecker API every 6h. Shell scripts in HCL heredocs: escape `$` → `$$`, `%{}` → `%%{}`.
- **Platform cannot depend on vault** (circular). Apply order: vault first, then platform. Platform has 48 vault refs, all in module inputs — no ESO migration possible.
- **Complex types** (maps/lists like `homepage_credentials`, `k8s_users`) stored as JSON strings in KV, decoded with `jsondecode()` in consuming stack `locals` blocks.
- **New stacks**: Add secret in Vault UI/CLI at `secret/<stack-name>`, add ExternalSecret + `data "kubernetes_secret"` for plan-time, `secret_key_ref` for env vars. Use `data "vault_kv_secret_v2"` only if `data "kubernetes_secret"` won't work (e.g., first-apply bootstrap).
- **Backup CronJob**: `vault-raft-backup` uses manually-created `vault-root-token` K8s Secret (independent of automation).
- **Bootstrap (fresh cluster)**: Comment out data source + OIDC → apply Helm → init+unseal → populate `secret/vault` → uncomment → re-apply.

## Sealed Secrets (User-Managed Secrets)
For secrets that users manage themselves (no SOPS/git-crypt access needed):
1. **Create**: `kubectl create secret generic <name> --from-literal=key=value -n <ns> --dry-run=client -o yaml | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets -o yaml > sealed-<name>.yaml`
2. **Commit**: Place `sealed-*.yaml` files in the stack directory (`stacks/<service>/`)
3. **Terraform picks them up** automatically via `fileset` + `for_each`:
   ```hcl
   resource "kubernetes_manifest" "sealed_secrets" {
     for_each = fileset(path.module, "sealed-*.yaml")
     manifest = yamldecode(file("${path.module}/${each.value}"))
   }
   ```
4. **Deploy**: Push → CI runs `terragrunt apply` → controller decrypts into real K8s Secrets
- Only the in-cluster controller has the private key. `kubeseal` uses the public key — safe to distribute.
- Naming convention: files MUST match `sealed-*.yaml` glob pattern.
- The `kubernetes_manifest` block is safe to add even with zero sealed-*.yaml files (empty for_each).
