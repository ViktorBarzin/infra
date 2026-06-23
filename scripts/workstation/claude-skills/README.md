# claude-skills — vendored agent-skill snapshot

Point-in-time snapshot of the admin's (`wizard`) Claude Code agent skills, deployed
per-user by `install_skills()` in `../../t3-provision-users.sh` (scoped to the
`SKILL_USERS` allowlist). Each subdirectory is one skill (`SKILL.md` + any bundled
references). The provisioner copies a skill into `~/.agents/skills/<name>/` (owned by
the user) and symlinks `~/.claude/skills/<name> -> ../../.agents/skills/<name>` — the
layout the `skills` CLI's `-g` install produces; Claude Code reads `~/.claude/skills/`.

## Why vendored (not `npx skills add` at provision time)

Upstream drifted from this set: on `mattpocock/skills` master, `diagnose` →
`diagnosing-bugs` and `write-a-skill` → `writing-great-skills` were renamed, and
`caveman` + `zoom-out` are no longer published — so `npx skills` cannot reproduce this
exact set. Vendoring is also offline/deterministic and keeps GitHub-clone +
unpinned-CLI dependencies out of the hourly **root** reconcile.

## Sources

- `mattpocock/skills` (https://github.com/mattpocock/skills) — all except `find-skills`
- `vercel-labs/skills` (https://github.com/vercel-labs/skills) — `find-skills`

## Refreshing

Re-snapshot from a current install and commit the diff:

```sh
cp -a ~/.agents/skills/. scripts/workstation/claude-skills/
```

Snapshot taken 2026-06-23.
