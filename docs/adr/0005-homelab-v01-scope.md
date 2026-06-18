# homelab v0.1 scope: the infra inner-loop; everything allowed, tiers recorded

v0.1 ships only the highest-volume surface — the infra inner-loop: `work`
(worktree lifecycle), `tf` (terragrunt via `scripts/tg` + fmt/validate/
force-unlock), and `claim`/`release` (presence) — because it is ~29% of all mined
commands and where agents lose the most time and leak the most presence claims.

v0.1 enforces **no** homelab-level permission gating: everything is allowed,
relying on existing gates (harness permission mode, presence claims, plan
approval). But every verb records a `read|write` tier (visible in `manifest`), so
a PreToolUse classifier hook (auto-allow reads / prompt writes) can be added
later with zero restructuring.

## Considered options

- **Reads-first vertical slice** (top read verb per domain) — lower risk, broad
  value, but defers the toil that motivated the project.
- **One domain deep (k8s)** — cleanest template, narrow day-one value.

We chose the highest-volume-but-write-heavy infra loop deliberately, accepting
the extra complexity (worktree lifecycle, git-crypt flag injection, presence
coupling, branch-protection PR fallback) for the biggest immediate toil
reduction. k8s/node/secret/net/ci verb-groups are deferred to later versions.
