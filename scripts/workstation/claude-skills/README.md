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
- **homelab-local, emo-PERSONALIZED** — `cluster-health` here is an
  **emo-specific variant**, not a copy of the canonical skill. It started as a
  copy of this repo's `.claude/skills/cluster-health/` but was rewritten on
  2026-06-26 to focus on ha-sofia + emo's Sofia devices (emo is the only entry
  in `SKILL_USERS`, a read-only power-user). The canonical admin skill
  (`.claude/skills/cluster-health/`) is the full 47-check version and is left
  untouched. **Do NOT `cp -a` the canonical copy over this one** — that would
  clobber the personalization. Maintain the two independently.

## Refreshing

Re-snapshot the upstream skills from a current install and commit the diff:

```sh
cp -a ~/.agents/skills/. scripts/workstation/claude-skills/
```

`cluster-health` is hand-maintained (emo variant) — it is **not** covered by the
`cp -a` above and must **not** be overwritten from `.claude/skills/`. Edit it in
place here when emo's needs change, then refresh his live copy (the provisioner's
`install_skills()` is if-absent, so it won't update an existing `~/.agents/skills`
copy — `cp` the new `SKILL.md` to `/home/emo/.agents/skills/cluster-health/` and
`chown emo:emo`, or remove emo's copy and re-run the reconcile).

Snapshot taken 2026-06-23 (upstream); `cluster-health` vendored 2026-06-26,
personalized for emo 2026-06-26.
