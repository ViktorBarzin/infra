# Terraform: adopting resources and the state backend

Moved verbatim from the repo's agent instruction files (`AGENTS.md`, `.claude/CLAUDE.md`) on 2026-09-22, when the two merged into one root `AGENTS.md`. Related as-built docs: `docs/architecture/overview.md`.

## Adopting Existing Resources — Use `import {}` Blocks, Not the CLI

When bringing a live cluster/Vault/Cloudflare resource under Terraform management, use an HCL `import {}` block (Terraform 1.5+). Do **NOT** use `terraform import` on the CLI for anything landing in this repo — the CLI path leaves no audit trail and makes multi-operator adoption fragile.

**Canonical workflow:**

1. Write the `resource` block that matches the live object.
2. In the same stack, add an `import {}` stanza naming the target and the provider-specific ID:
   ```hcl
   import {
     to = helm_release.kured
     id = "kured/kured"  # Helm ID format: <namespace>/<release-name>
   }

   resource "helm_release" "kured" {
     name       = "kured"
     namespace  = "kured"
     repository = "https://kubereboot.github.io/charts/"
     chart      = "kured"
     version    = "5.7.0"
     # ... values matching the live release
   }
   ```
3. `scripts/tg plan` — every change it proposes is real divergence between HCL and live state. Iterate on values until the plan is **0 changes**.
4. `scripts/tg apply` — the import runs alongside whatever zero-change apply you have. If your plan is 0 changes, this commits only the state-ownership transfer.
5. After the apply lands cleanly, **delete the `import {}` block** in a follow-up commit. The resource is now fully TF-owned and the stanza would be a no-op that clutters diffs.

**Why `import {}` and not `terraform import`:**

- Reviewable in PRs before any state mutation. The CLI path is an out-of-band action nobody sees.
- Plan-safe: the `import` plan step shows the exact object being adopted. Mistyped IDs or the wrong resource address are caught before apply, not after.
- Survives state backend changes (Tier 0 SOPS vs Tier 1 PG) transparently — both work identically from the operator's perspective because both use `scripts/tg`.
- Re-runnable: if the apply fails partway through, the `import {}` block is idempotent. The CLI path's state mutation is not.

**Finding the provider-specific ID:** each provider has its own convention.
| Resource | ID format | Example |
|---|---|---|
| `helm_release` | `<namespace>/<release-name>` | `kured/kured` |
| `kubernetes_manifest` | `{"apiVersion":"...","kind":"...","metadata":{"namespace":"...","name":"..."}}` | (pass as HCL object literal) |
| `kubernetes_<kind>_v1` | `<namespace>/<name>` for namespaced, `<name>` for cluster-scoped | `kube-system/coredns` |
| `authentik_provider_proxy` | provider UUID | `0eecac07-97c7-443c-...` |
| `cloudflare_record` | `<zone-id>/<record-id>` | `abc123/def456` |

## Terraform State — Two-Tier Backend
- **Tier 0 (bootstrap)**: Local state, SOPS-encrypted in git. Stacks: `infra`, `platform`, `cnpg`, `vault`, `dbaas`, `external-secrets`. These must exist before PG is reachable.
- **Tier 1 (everything else)**: PostgreSQL backend (`pg`) on CNPG cluster at `pg-cluster-rw.dbaas.svc.cluster.local:5432/terraform_state`. Native `pg_advisory_lock` for concurrent safety. Each stack gets its own PG schema. **Lock contention is non-fatal**: `scripts/tg` passes `-lock-timeout` (default `5m`) so a contended lock waits rather than hard-failing — this was the #1 cause of infra CI failures (a Woodpecker-killed run's unreaped PG lock, a concurrent local apply, or the daily drift `plan`; Tier-1 stacks have no Vault advisory-lock skip to fall back on, unlike Tier-0).
- **Auth**: `scripts/tg` auto-fetches PG credentials from Vault (`database/static-creds/pg-terraform-state`). Humans use `vault login -method=oidc`, agents use K8s auth (role: `terraform-state`, namespace: `claude-agent`).
- **Tier 0 workflow** (unchanged): `git pull` → `scripts/tg plan` → `scripts/tg apply` → `git push`. State sync via SOPS is transparent.
- **Tier 1 workflow**: `vault login -method=oidc` → `scripts/tg plan` → `scripts/tg apply`. No git commit needed — PG is authoritative.
- **Tier detection**: Defined in `terragrunt.hcl` (`locals.tier0_stacks`), `scripts/tg`, and `scripts/state-sync`. All three share the same list.
- **Fallback**: If PG is down, Tier 0 local state can bring it back (`scripts/tg apply` in `dbaas` stack). Tier 1 ops are blocked until PG recovers.
- **Tier 0 details**: Decrypt priority: Vault Transit (primary) → age key fallback. Encrypt: both Vault Transit + age recipients. Scripts: `scripts/state-sync {encrypt|decrypt|commit} [stack]`. **All 6 carry 2 age recipients and the public Vault address as of 2026-09-16, verified to decrypt with Vault unreachable.** Until that day 4 of them (`platform`, `cnpg`, `dbaas`, `external-secrets`) had ZERO age recipients and recorded `http://vault-active.vault.svc.cluster.local:8200` as their Transit address, which sops reuses verbatim in preference to `$VAULT_ADDR` — so they were decryptable **only from inside the cluster**, `dbaas` included, the stack the docs name as the recovery path when PG is down. Cause: the CI image had `python3` but not `py3-yaml`, so state-sync's `.sops.yaml` read raised, `2>/dev/null || echo ""` swallowed it, and `sops -e --age ""` wrote files with no age key group. Both halves fixed (`py3-yaml` in `ci/Dockerfile`; `encrypt_state` now REFUSES an empty recipient list). **Repairing such a file needs no cluster access** — rewrite the recorded `vault_address` to the public URL and sops decrypts, because the Transit key is reachable there; recipe in `docs/architecture/secrets.md` → "SOPS state decryption fails". A failed `decrypt` also no longer truncates the state it could not read, and `encrypt` refuses an empty or non-JSON source.
- **Adding operator**: Generate age key (`age-keygen`), add pubkey to `.sops.yaml`, run `sops updatekeys` on Tier 0 `.enc` files. For Tier 1, only Vault access is needed.
- **Migration script**: `scripts/migrate-state-to-pg` (one-shot, idempotent) migrates Tier 1 stacks from local to PG.
