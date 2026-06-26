# OS is the authorization boundary: agents defer to Unix/sudo, not a stricter in-policy rule

Supersedes the cross-user privacy *norm* that the devvm managed-settings policy
carried and that ADR-0011 leaned on ("never read another user's home /
`~/.claude`, off-limits even for an owner in-session"). ADR-0011's actual
subject — `usage top` telemetry and its emit design — is unchanged and still
current; only the privacy prohibition it referenced is superseded here.

## Context

The devvm managed-settings policy (`/etc/claude-code/managed-settings.json`,
`claudeMd`) carried two rules that were, in practice, *stricter than the OS*:
"you are not the admin, do not escalate privileges" and "never read another
user's home directory, credentials, tokens, or `~/.claude`." The OS told a
different story: `wizard` holds `(ALL) NOPASSWD: ALL` — full passwordless root.
The kernel had already granted total read access; the policy was layering an
artificial refusal on top of an authorization the OS already permits, and the
"not the admin" framing was factually wrong for a NOPASSWD-root user.

Two honest ways to resolve the inconsistency: tighten sudo to match the policy,
or loosen the policy to match the OS. The owner chose the latter on 2026-06-26,
for analytics/debugging across the shared box.

## Decision

- **Authorization follows the OS, not this policy.** Agents may access whatever
  their OS user can access — directly or via `sudo` where they hold sudo rights
  — and must not impose restrictions stricter than the OS. On this box that
  includes other users' home directories and `~/.claude` for users who hold
  broad sudo.
- **No separate prompt or carve-out** for OS-authorized access. The Unix
  permission model + sudoers is the single source of truth for who may read
  what. Other homes are `0750`-owned, so a cross-home read necessarily transits
  `sudo` and is therefore captured in the sudo/auth audit log.
- **Cluster/infra RBAC tiering is unchanged.** kubectl / Vault / infra access
  stays scoped to each user's RBAC tier; "defer to the OS" is about OS-level
  file access, not a licence to exceed cluster RBAC.
- **Scope is symmetric and multi-user.** The rule lives in the *shared*
  managed-settings, so every user's agents defer to that user's own sudo grant.
  Any user with broad sudo gets the same cross-home read capability over other
  users' files. Accepted by the owner with that understanding; emo's and
  ancamilea's `~/.claude` is now agent-readable by sudo-holders.
- **Takes effect in a fresh session.** managed-settings loads at session start;
  the session that made the change keeps running under the old policy.

## Consequences

- The privacy-preserving telemetry rationale in ADR-0011 (`usage top` as the
  "cross-user analytics without reading homes" answer) remains useful but is no
  longer the *only* sanctioned path; direct reads via `sudo` are now permitted.
- Larger blast radius: if an agent session running as a sudo-holder is
  prompt-injected or otherwise compromised, it can now read every user's secrets
  with no in-agent friction (sudo here is passwordless). The sudo/auth audit log
  is the remaining accountability control.
- Reversible: restore the prior `claudeMd` bullets (backup kept at
  `/etc/claude-code/managed-settings.json.bak-2026-06-26`) and start a fresh
  session.
