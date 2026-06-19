# homelab ci/deploy verbs: API-based watch, internal-LB dialer, work-land integration

v0.4 adds `ci`/`deploy` — the biggest *reasoning* sink in agent sessions (watching
a build/deploy to completion), proven during the session that built it (hours
spent hand-rolling Woodpecker API polling, DB-schema reverse-engineering, and
retrigger logic for a single CI incident).

## Decisions

- **API, not DB.** The verbs query the Woodpecker REST API (version-stable),
  not its Postgres schema (which drifts across upgrades — column renames bit us
  mid-incident). Reached via the internal Traefik LB by dialing `10.0.20.203`
  while keeping SNI/Host = `ci.viktorbarzin.me` so the cert verifies (the Go
  equivalent of the house `curl --resolve` pattern). Token from
  `WOODPECKER_TOKEN` or Vault `secret/ci/global`; repo id resolved from the cwd
  git remote via `/api/repos/lookup/<owner>/<repo>`.
- **Retries are mandatory.** The Woodpecker API intermittently returns empty/5xx
  under load (it flapped through the whole build session); `getJSON` retries
  empties with backoff so `ci watch` is reliable exactly when it's needed.
- **`work land` now waits for CI.** After pushing, `work land` calls `ci watch`
  on the landed commit and fails if the pipeline does — closing the gap ADR-0005
  deferred. `--no-ci-watch` opts out.
- **`deploy wait` encodes the "rollout status lies" rule:** it first waits for
  the deployment image to reference the expected sha, *then* blocks on rollout
  status (kubectl-based; reuses the k8s helpers).
- **`ci logs` deferred to v0.4.1.** Woodpecker's per-pipeline detail/log
  endpoints were the least reliable this session (often empty); `status`/`watch`
  rely on the list endpoint that works. A DB-backed `ci logs` is a possible
  follow-up if the API path stays flaky.
