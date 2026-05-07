# Runbook: Onboarding a new Forgejo repo to Woodpecker

Last updated: 2026-05-07

When you create a new repo on `forgejo.viktorbarzin.me`, Woodpecker
does NOT auto-discover it via the cluster's existing OAuth session.
The `forgejo` user inside Woodpecker (Forgejo-OAuth'd) needs to:

1. Open `https://ci.viktorbarzin.me/` in a browser.
2. Log in via Forgejo OAuth (the "Sign in with Forgejo" button).
3. Click "Add Repository" — your new repo should appear.
4. Click the toggle to activate it. Woodpecker will:
   - Add a webhook on the Forgejo repo (push, PR, release events).
   - Register the repo's `forge_remote_id` in its DB so subsequent
     hooks deserialize correctly.
5. Push a commit (or hit "Run pipeline" in Woodpecker UI) — first
   build fires.

## Why API-only doesn't work

The webhook URL contains a JWT signed with a per-server key that's
stored in the DB and only accessible at OAuth-flow time. POST'ing
`/api/repos` as the admin (`ViktorBarzin` GitHub user) returns 500
because the lookup queries forge-side OAuth state for THAT user,
which doesn't exist for the Forgejo `viktor` user. We confirmed:

- Direct `POST /api/repos?forge_remote_id=N` → HTTP 500 server-side.
- Generating a JWT with the agent secret → "token is unverifiable"
  on hook delivery (the signing key is repo-specific, not the
  global agent secret).

There's no admin endpoint that side-steps the OAuth flow.

## Bootstrap when UI access isn't available

If you absolutely need to bootstrap a new image without UI access
(e.g., during an outage), the workaround is:

1. Build locally:
   ```bash
   docker build -t forgejo.viktorbarzin.me/viktor/<name>:<tag> /path/to/source
   docker push forgejo.viktorbarzin.me/viktor/<name>:<tag>
   ```
2. Or pull from another already-built source and retag:
   ```bash
   docker pull viktorbarzin/<name>:<tag>          # DockerHub
   docker tag  viktorbarzin/<name>:<tag>     forgejo.viktorbarzin.me/viktor/<name>:<tag>
   docker push forgejo.viktorbarzin.me/viktor/<name>:<tag>
   ```
3. Flip the cluster `image=` reference and restart deployments.

Document the bootstrap in the relevant stack so future maintainers
know the image was put there by hand. After Woodpecker UI onboarding,
the next pipeline run replaces the bootstrap image with a CI-built one.

## Repos onboarded in flight 2026-05-07

These were created during the forgejo-registry-consolidation but the
UI step above hasn't been done yet — their `.woodpecker.yml` /
`.woodpecker/build.yml` exists on Forgejo but no pipeline fires:

- `viktor/broker-sync` — image bootstrapped via DockerHub (see
  `infra/stacks/wealthfolio/main.tf` comment).
- `viktor/fire-planner` — image bootstrapped via local docker build.
- `viktor/hmrc-sync`
- `viktor/freedify`
- `viktor/claude-agent-service`
- `viktor/beadboard` — image bootstrapped via local docker build.
- `viktor/claude-memory-mcp`

Walk through each in the Woodpecker UI to enable. Pipelines for
already-onboarded repos (payslip-ingest, job-hunter, infra) fired
correctly after the v3.13 → v3.14 upgrade.
