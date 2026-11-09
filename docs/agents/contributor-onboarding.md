# Contributor onboarding

Moved from the root `AGENTS.md` on 2026-11-09 so it loads only when needed.

## Getting access
1. Get Authentik account + Headscale VPN access (ask Viktor)
2. Clone repo — `AGENTS.md` is auto-loaded by Codex
3. Create branch → edit → push → open PR
4. Viktor reviews → CI applies → Slack notification
5. Portal: `https://k8s-portal.viktorbarzin.me/onboarding` for full guide

### Non-admin workstation users — the AGENT does the git work

Non-admin devvm users (power-user / namespace-owner tiers) may not know git at
all. Their infra clone arrives preconfigured: git identity, a `forgejo` remote
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
(`git push forgejo HEAD:master`, or the PR fallback below if not whitelisted).
Locked (git-crypt) clones can use plain `git worktree add`. Trivial
single-commit fixes may be committed directly on a clean `master`. Full
lifecycle: your own AGENTS.md.

To land a finished change from such a clone:

1. Land it per the worktree paragraph above.
2. Leave the clone on clean `master` so auto-refresh keeps working.

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
