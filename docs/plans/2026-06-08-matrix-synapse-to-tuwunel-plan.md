# Matrix: Synapse → tuwunel migration — Plan (executed)

**Date:** 2026-06-08 · **Companion:** `2026-06-08-matrix-synapse-to-tuwunel-design.md`

## Executed steps

1. **Vault** — generated a 32-byte `registration_token`, stored at
   `secret/matrix`.
2. **`stacks/matrix` rewrite** — replaced Synapse with tuwunel: removed the
   `matrix-db-creds` ExternalSecret, both init-containers (`install-psycopg2`,
   `inject-db-password`), the `extra-packages` volume, and the Reloader
   annotation; added the `matrix-secrets` ExternalSecret (vault-kv `dataFrom`),
   the `TUWUNEL_*` env, `securityContext` 1000, and the tuwunel image. Encrypted
   PVC, Service (`80→8008`), and ingress (`auth="none"`, proxied) unchanged.
   - The image is in the deployment's `ignore_changes` (KEEL_IGNORE_IMAGE); it
     was **temporarily un-ignored** for this base-image swap, then re-added at
     step 4 so Keel resumes tag management.
   - `tg init -reconfigure` was required first (Tier-1 PG-backend creds rotate
     weekly → "Backend configuration block has changed").
3. **Apply** — `Plan: 1 to add, 2 to change, 1 to destroy`. tuwunel 1.7.1 came up
   1/1, created a fresh RocksDB on the encrypted PVC (no permission errors —
   fsGroup worked).
4. **Verify** — all `200`: `/_tuwunel/server_version`, `.well-known/matrix/
   {client,server}`, `/_matrix/client/versions`, `/_matrix/federation/v1/version`.
   Registered `@viktor:matrix.viktorbarzin.me` (first user → admin) via the token
   flow; `whoami` confirmed. Creds stored at `secret/matrix`
   (`admin_user`, `admin_password`).
5. **Lock down** — `TUWUNEL_ALLOW_REGISTRATION=false` + re-added image
   `ignore_changes`; applied. Registration now returns `403 M_FORBIDDEN`.
6. **Cleanup** —
   - `stacks/vault`: removed the `pg_matrix` static role + its `allowed_roles`
     entry (targeted apply — the full plan also wanted an **unrelated** OIDC
     `tune`-TTL change, deliberately NOT applied; see residual items).
   - Dropped the orphaned `matrix` Postgres DB (16 MB) + `matrix` role on the
     CNPG primary (`pg-cluster-2`).
   - Docs updated: `.claude/CLAUDE.md` (PG-rotation list), `service-catalog.md`,
     `upgrade-config.json` (removed synapse image-rename + matrix PG entry),
     `authentication.md` + `authentik-state.md` (Matrix OIDC → orphaned).

## Rollback

Fresh start was confirmed, so there is no Synapse data to preserve. To revert the
*service*: restore the Synapse `main.tf` from git, re-add the `pg_matrix` Vault
role, and restore the `matrix` Postgres DB from the daily per-db dump
(`/backup/per-db/matrix/`). The reused encrypted PVC still holds Synapse's old
`homeserver.yaml` / signing key / media at the volume root alongside the new
RocksDB dir.

## Residual / follow-up items (flagged to user)

- **Authentik Matrix OAuth2 app — REMOVED 2026-06-08** (user-confirmed). It was
  UI-managed (NOT in the authentik TF stack), so it was deleted via the Authentik
  API: application `matrix` + OAuth2 provider `pk=6`. tuwunel uses native password
  auth, so nothing consumed it.
- **Pre-existing drift in `stacks/vault`**: `vault_jwt_auth_backend.oidc` shows a
  `tune` diff (explicit `768h` default/max lease TTLs being dropped). This
  predates this migration and was **not** applied. Resolve separately.
- **Synapse leftover files** remain on the encrypted PVC volume root (unused by
  tuwunel). Can be `rm`'d after confidence in the new server.
