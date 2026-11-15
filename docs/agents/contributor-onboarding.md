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

Changes to viktor/infra land as **pull requests from your own fork**
(enforced-identity plan, 2026-11-15). CI applies every push to master with
cluster-admin rights, so a write to viktor/infra is admin: only Viktor and the
bots `infra-agent` and `renovate-bot` push there (`stacks/forgejo-acl`), and
everyone else reads it. Before this, whitelisted users (emo) pushed straight to
master. Force-push is disabled for everyone, so master history is append-only.

Each non-admin clone has two Forgejo remotes, wired by the provisioner:
`forgejo` is viktor/infra, which `master` tracks and which is refreshed hourly;
`fork` is `<your-forgejo-user>/infra`, forked with your own PAT, and it is the
push default. Woodpecker runs a fork's pull request only after Viktor approves
it, and Viktor merges it.

**Feature-sized work is worktree-first** (org rule, 2026-06-10): develop in an
isolated worktree (`.worktrees/<topic>`, branch `<os-user>/<topic>` off
`forgejo/master`) so concurrent agent sessions never collide in the clone.
Locked (git-crypt) clones can use plain `git worktree add`. Full lifecycle:
your own AGENTS.md.

To land a finished change:

1. Merge the latest `forgejo/master` into the branch and push it to the fork:
   `git push fork HEAD:<os-user>/<short-topic>`.
2. Open the pull request with your own PAT (`write:repository` suffices; the
   PAT also carries `write:issue` for `file-issue` and `write:user` for
   `cloud new`, which creates a repo you own). `head` names the fork owner:

```bash
TOK=$(sed -E 's#https://[^:]+:([^@]+)@.*#\1#' ~/.git-credentials)
ME=$(sed -E 's#https://([^:]+):.*#\1#' ~/.git-credentials)
curl -X POST -H "Authorization: token $TOK" -H 'Content-Type: application/json' \
  https://forgejo.viktorbarzin.me/api/v1/repos/viktor/infra/pulls \
  -d "{\"title\":\"<title>\",\"head\":\"$ME:<os-user>/<short-topic>\",\"base\":\"master\",\"body\":\"<what + why>\"}"
```

3. Leave the clone on clean `master` so the hourly refresh keeps working.
