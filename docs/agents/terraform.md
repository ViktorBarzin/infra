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
| `cloudflare_dns_record` (provider v5; `cloudflare_record` on v4) | `<zone-id>/<record-id>` | `abc123/def456` |
| `cloudflare_zone_setting` | `<zone-id>/<setting-id>` | `abc123/http3` |

## Objects Terraform must not own: Cloud's Projects

Cloud's reconciler (Forgejo `viktor/cloud`, ADR-0003 there, approved by Viktor on 2026-11-12) creates and destroys Projects on this cluster with its own OpenTofu, one state per Project in the `cloud_state` database, never in `terraform_state`. Its objects are owned by Cloud's database:

| Where | Cloud-owned | Owned by this repo |
|---|---|---|
| Kubernetes | `p-*` namespaces and everything in them, including the RoleBinding to `cloud-reconciler-project` | `stacks/cloud`: namespace `cloud`, the console and reconciler Deployments, their service accounts, the ClusterRoles, the admission policies, Calico tier `cloud` and its policy. `stacks/kyverno`: the rule that keeps `tls-secret` and `registry-credentials` out of Project namespaces |
| Postgres (`pg-cluster-v18`) | `p_*` Project roles (members of `cloud_projects`) and their databases | `stacks/dbaas`: `cloud_projects`, `cloud_provisioner`, `cloud_state`, databases `cloud_state` and `cloud`, the pg_hba rules |
| Authentik | nothing: the reconciler holds no Authentik credential; the console holds the `tanstack_app` module's reader and approver tokens, which this repo creates | `stacks/authentik/cloud-apps.tf`: the shared OAuth2 provider and application `cloud-apps` that every private App signs in through, its binding, and `secret/cloud/system`. `stacks/cloud`: the console's application `cloud`, its groups Cloud Users and Cloud Operators, and the CLI's client `cloud-cli` |
| Vault | `secret/cloud/<namespace>/*` | `stacks/vault/cloud.tf`, and `secret/cloud/system` from `stacks/authentik` |

Rules: never write an `import {}` block, a data source loop or a resource for a Cloud-owned object; never delete one by hand to "clean up drift" (Cloud would recreate it, or a Project would break). No state holds them, so no plan proposes changes to them; keep it that way. **Authentik:** Cloud creates no Authentik object (M2 contract, Addendum v2 point 7). Every private App's oauth2-proxy signs in through `cloud-apps`, bound to a policy that admits every active account except `guest` and service accounts, and admits only the App's email allowlist. The access guard (`stacks/authentik/app-access-guard.tf`) lists `cloud-apps` in `app_access_exempt` for that reason. A cluster-wide audit that lists live objects must skip the `cloud.viktorbarzin.me/managed=true` namespaces. No homelab namespace may be named `p-*`, because the reconciler's admission policy treats that prefix as Cloud's.

Apply order for the Cloud pieces from a fresh start: `dbaas` (roles must exist before Vault's static roles rotate them), then `vault` (static roles, policies, and CI's write grant on `secret/cloud/system`), then `authentik` and `cloud`. Before the first `cloud` apply with the console (M4), seed `secret/cloud-console` (`docs/runbooks/cloud.md`).

## Terraform State — Two-Tier Backend
- **Tier 0 (bootstrap)**: Local state, SOPS-encrypted in git. Stacks: `infra`, `platform`, `cnpg`, `vault`, `dbaas`, `external-secrets`. These must exist before PG is reachable.
- **Tier 1 (everything else)**: PostgreSQL backend (`pg`) on CNPG cluster at `pg-cluster-rw.dbaas.svc.cluster.local:5432/terraform_state`. Native `pg_advisory_lock` for concurrent safety. Each stack gets its own PG schema. **Lock contention is non-fatal**: `scripts/tg` passes `-lock-timeout` (default `5m`) so a contended lock waits rather than hard-failing — this was the #1 cause of infra CI failures (a Woodpecker-killed run's unreaped PG lock, a concurrent local apply, or the daily drift `plan`; Tier-1 stacks have no Vault advisory-lock skip to fall back on, unlike Tier-0).
- **Auth**: `scripts/tg` auto-fetches PG credentials from Vault (`database/static-creds/pg-terraform-state`). Humans use `vault login -method=oidc`, agents use K8s auth (role: `terraform-state`, namespace: `claude-agent`).
- **Tier 0 workflow** (unchanged): `git pull` → `scripts/tg plan` → `scripts/tg apply` → `git push`. State sync via SOPS is transparent.
- **Tier 1 workflow**: `vault login -method=oidc` → `scripts/tg plan` → `scripts/tg apply`. No git commit needed — PG is authoritative.
- **Tier detection**: Defined in `terragrunt.hcl` (`locals.tier0_stacks`), `scripts/tg`, and `scripts/state-sync`. All three share the same list.
- **Fallback**: If PG is down, Tier 0 local state can bring it back (`scripts/tg apply` in `dbaas` stack). Tier 1 ops are blocked until PG recovers.
- **Tier 0 details**: Decrypt priority: Vault Transit (primary) → age key fallback. Encrypt: both Vault Transit + age recipients. Scripts: `scripts/state-sync {encrypt|decrypt|commit} [stack]`. **All 6 carry 2 age recipients and the public Vault address as of 2026-09-16, verified to decrypt with Vault unreachable.** Until that day 4 of them (`platform`, `cnpg`, `dbaas`, `external-secrets`) had ZERO age recipients and recorded `http://vault-active.vault.svc.cluster.local:8200` as their Transit address, which sops reuses verbatim in preference to `$VAULT_ADDR` — so they were decryptable **only from inside the cluster**, `dbaas` included, the stack the docs name as the recovery path when PG is down. Cause: the CI image had `python3` but not `py3-yaml`, so state-sync's `.sops.yaml` read raised, `2>/dev/null || echo ""` swallowed it, and `sops -e --age ""` wrote files with no age key group. Both halves fixed (`py3-yaml` in `ci/Dockerfile`; `encrypt_state` now REFUSES an empty recipient list). **Repairing such a file needs no cluster access** — rewrite the recorded `vault_address` to the public URL and sops decrypts, because the Transit key is reachable there; recipe in `docs/architecture/secrets.md` → "SOPS state decryption fails". A failed `decrypt` also no longer truncates the state it could not read, and `encrypt` refuses an empty or non-JSON source.
- **Adding operator**: Generate age key (`age-keygen`, from the `age` apt package on the devvm), add pubkey to `.sops.yaml`, run `sops updatekeys` on Tier 0 `.enc` files. For Tier 1, only Vault access is needed.
- **Migration script**: `scripts/migrate-state-to-pg` (one-shot, idempotent) migrates Tier 1 stacks from local to PG.
