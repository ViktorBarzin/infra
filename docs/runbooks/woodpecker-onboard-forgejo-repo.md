# Runbook: Onboarding a new Forgejo repo to Woodpecker

Last updated: 2026-05-07

## Programmatic (preferred)

```bash
infra/scripts/woodpecker-register-forgejo-repo.sh viktor/<repo-name>
```

The script:
1. Pulls the `viktor` (Forgejo-OAuth'd) user's `hash` from the
   Woodpecker PG `users` table.
2. Mints a session JWT (HS256, signed with that hash) — Woodpecker
   per-user session JWTs have payload
   `{"type":"user","user-id":"<id>"}` and the signing key is the
   user's `hash` column. (Confirmed against a known-good admin
   token: same payload shape, signature reproducible from the user's
   stored hash via `openssl dgst -sha256 -hmac "$HASH"`.)
3. Looks up the Forgejo repo id and POSTs to
   `https://ci.viktorbarzin.me/api/repos?forge_remote_id=<id>` as
   that user. Woodpecker server creates the per-repo webhook +
   per-repo signing key on the Forgejo side automatically (uses
   the user's stored Forgejo OAuth `access_token` to do so — that's
   why this only works with viktor's user, not the GitHub admin's).

Pre-requisites:
- `vault login -method=oidc` with read access to
  `database/static-creds/pg-woodpecker`.
- `kubectl` cluster access (the script spawns a 5-min psql pod in
  the `woodpecker` namespace to query the DB).
- A Forgejo PAT in `secret/viktor/forgejo_admin_token` (or pass
  `FORGEJO_TOKEN=…` env), used to look up the repo's numeric ID.
- The `viktor` Woodpecker user must already exist (i.e., they've
  logged in via Forgejo OAuth at least once on the Web UI).
  If user_id=2 / forge_id=2 doesn't exist in `users`, the OAuth
  bootstrap is unavoidable — but it only needs to happen once for
  the lifetime of the Woodpecker DB.

## Why the GitHub admin token can't do this

The earlier 500 from `POST /api/repos?forge_remote_id=N` was
because my admin session token authenticates as `ViktorBarzin`
(GitHub user, forge_id=1). Woodpecker tries to call Forgejo as
that user (using their stored Forgejo OAuth token) — which doesn't
exist for the GitHub user, hence the lookup error. There's no way
around this without acting as the Forgejo user.

## Why the previous "JWT for the webhook" approach didn't work

I tried generating a webhook JWT signed with `WOODPECKER_AGENT_SECRET`
(the global agent secret) and registering it directly on Forgejo.
That fails because the webhook JWT verification path runs through a
DB-backed `keyfunc` — Woodpecker stores a per-repo signing key when
the repo is activated, and rejects any JWT signed with a different
key. POST /api/repos is what creates that per-repo key.

## After registration

Pipelines fire automatically on push. The `WOODPECKER_FORGE_TIMEOUT`
default of 3s was too tight for our cluster (Forgejo response time
spikes to 1-2s under load) — bumped to 30s in
`infra/stacks/woodpecker/values.yaml` 2026-05-07. Without that bump,
config-loader hits the deadline and every pipeline errors with
`could not load config from forge: context deadline exceeded`.

## When the v3.13 → v3.14 server upgrade matters

`v3.14.0` doesn't fix this on its own — the timeout default is the
same. Set `WOODPECKER_FORGE_TIMEOUT` regardless of version. The
v3.14 upgrade was useful for unrelated forge-API changes (smarter
config-loader, fewer redundant calls per trigger).

## Troubleshooting

- Pipeline status `error` with `could not load config from forge`:
  bump `WOODPECKER_FORGE_TIMEOUT`. 30s is plenty.
- Pipeline status `error` with `secret "registry-password" not found`:
  the repo's `.woodpecker.yml` still references registry-private
  credentials. Drop the `registry.viktorbarzin.me` block — Forgejo
  is the only registry now.
- Pipeline status `failure` with `"/vault": not found` (or any
  other COPY of a binary): the gitignored binary wasn't pushed to
  Forgejo. Switch the Dockerfile to `curl … && unzip` from the
  HashiCorp/upstream release URL. See `claude-agent-service/Dockerfile`
  commit bab6dd2 for the pattern.
