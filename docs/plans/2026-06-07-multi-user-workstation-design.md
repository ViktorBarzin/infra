# Multi-User Workstation — Design

- **Date:** 2026-06-07
- **Status:** designed (grilled extensively); not yet implemented
- **Owner:** Viktor (wizard)
- **Builds on:** the t3code multi-user setup (`docs/plans/2026-06-01-t3-auto-provision-*`), the `k8s_users` multi-tenancy (`docs/architecture/multi-tenancy.md`), and the cloud-init VM-reproducibility decision (memory id=1575).
- **Glossary:** see `infra/CONTEXT.md` → "Workstation (multi-user devvm)" for the canonical terms used here (devvm, Workstation, RBAC tier, Workstation profile, Config inheritance, Config base, Infra visibility).

## Goal

Let any onboarded person get a fully-configured Claude Code **Workstation** on the devvm that **inherits Viktor's config live** (his edits propagate with no per-user sync), bounded by **their own permissions** (read infra code + RBAC-scoped cluster view, never secrets), provisioned by **one declarative roster + one idempotent script**, and **reproducible from git** so the VM can be rebuilt from a template.

## How we got here (so the rationale isn't re-litigated)

This was stress-tested down several branches before landing:

1. **Adopt a CDE?** Researched Coder / Gitpod-Ona / Eclipse Che / DevPod / OpenHands (2026-06-07). The category consolidated to "Coder or Che, or build it." Coder is architecturally a great fit but the **role model we need is Premium-gated** (groups + OIDC group→role sync + template ACLs are all paid), its agent UI is mid-transition (Tasks→Agents, Sept 2026), and it still needs custom glue. ~80% of the hard parts are already solved by our stack. → **Build on the existing stack** (ADR-0001).
2. **K8s ephemeral pods vs devvm OS users?** Ephemeral pods are maximally declarative but, at ~3-4 trusted users, re-platforming the agent + per-pod persistence is **overkill**; the devvm model already runs and config-push is *easier* on one host. → **devvm Linux users** (ADR-0002).
3. **Config inheritance — sync vs live?** A periodic sync/seed was rejected; the requirement is **live inheritance** ("I edit, everyone has it"). Realized via **each subsystem's native machine-wide layer + a per-user layer on top** (ADR-0003) — not OverlayFS (kernel disallows live lowerdir edits), not Nix (rebuild, not live), not bespoke symlink-only (clumsy per-item override).

## Core model

A person's **RBAC tier** drives one **Workstation profile**. **Inheritance**: `wizard` authors a **Config base** once; every child user (emo, anca, gheorghe) inherits it **live** through native machine-wide layers and may add their own on top. What differs per tier is **Infra visibility** and cluster scope — never the inherited config. Onboarding is **declarative**: a git roster + an idempotent provisioner.

## Components

### 1. Roster — the SINGLE source of truth (in git, full lifecycle)

A git-committed map keyed by **`os_user`**; it drives the **entire lifecycle** (onboard → reconcile → offboard). It carries the multiple identifiers a person actually has (verified live 2026-06-08 — they differ!):

```yaml
# infra/scripts/workstation/roster.yaml — THE source of truth
# os_user (key) → authentik_user (login local-part) · k8s_user (k8s_users key) · tier · namespaces
users:
  emo:       { authentik_user: emil.barzin, k8s_user: emo,  tier: power-user }
                  # NET-NEW cluster identity — emo is NOT in k8s_users today
  ancamilea: { authentik_user: ancaelena98, k8s_user: anca, tier: namespace-owner, namespaces: [plotting-book] }
                  # ALREADY a namespace-owner — preserve plotting-book; do NOT re-provision
# gheorghe:  { authentik_user: vabbit81,    k8s_user: vabbit81, tier: namespace-owner, namespaces: [vabbit81] }
                  # already a cluster namespace-owner; uncomment when he wants a devvm workstation
# wizard (admin) is the base author; not provisioned as a child.
```

**Single source of truth (SSoT):** the roster is authoritative; everything else is **derived or validated against it** — never hand-maintained in parallel:
- `/etc/ttyd-user-map` + `/etc/t3-serve/dispatch.json` are **regenerated** from the roster each reconcile (not appended).
- The Authentik **`T3 Users`** group membership is reconciled from the roster (a member ⇔ a roster entry).
- The reconcile **validates** `roster.tier` against the live `k8s_users` role and **fails loud on mismatch** (e.g. roster says `power-user` but `k8s_users` says `namespace-owner`) — so the workstation tier and the cluster tier can't silently diverge. `k8s_user`/`namespaces` are reconciled into `k8s_users` (or asserted to match for pre-existing users).

`os_user` is the pinned key (no email→username derivation — avoids the `ancaelena98`-vs-`ancamilea` trap). Onboard = add an entry + reconcile; **offboard = remove the entry** (see "User lifecycle").

### 2. Eligibility gate (Authentik group, edge-enforced)

A `T3 Users` Authentik group gates `t3.viktorbarzin.me` at the edge via a one-branch addition to the existing `stacks/authentik/admin-services-restriction.tf` expression policy (`if host == "t3.viktorbarzin.me": return ak_is_group_member(request.user, name="T3 Users")`). Non-members 302→login, never reach the box. Verified earlier: `X-authentik-groups` already reaches the dispatcher (it's in the forward-auth middleware `authResponseHeaders`), so a dispatcher-side second check is possible but the edge gate is the primary.

### 3. Provisioning (idempotent script + roster)

Extend the existing root reconcile (`infra/scripts/t3-provision-users.sh`) to read `roster.yaml` and, per entry, converge:
- `useradd` the OS account if missing — **constrained** per tier (see §6);
- assign per-tier groups;
- drop the per-user identity-scoped kubeconfig + Vault helper;
- append the `<authentik_user>=<os_user>` line to `/etc/ttyd-user-map`;
- `systemctl enable --now t3-serve@<os_user>`;
- provision a writable git-crypt-locked clone at `~/code` for non-admins **only if absent** (§5; never replaces an existing `~/code`).

Run via the existing systemd timer (OnBoot + periodic) for self-healing, plus on-demand after a roster edit. Account creation is the one new privileged step; it lives only in this root reconcile.

### 4. Config inheritance (native machine-wide layers — ADR-0003)

`wizard` authors the **Config base** (a git checkout of the dotfiles/config-base repo on the devvm). It materializes into the OS's native machine-wide layers, which every user inherits live:

**Verified 2026-06-08:** t3 is itself built on `@anthropic-ai/claude-agent-sdk` and opts into `settingSources: [user, project, local]`; the SDK also reads `/etc/claude-code/managed-settings.json` independently. So the managed layer + `~/.claude` reach **both** surfaces — the t3 web UI *and* a terminal `claude`. Two caveats: it's **Claude-specific** (a t3 user who picks Codex/OpenCode won't inherit Claude config), and `rules/` loads via the per-user `user` source (so Task 1.1's "managed-`claudeMd` vs per-user symlink" question stays real).

| What inherits | Layer (machine-wide) | Native mechanism (live) | Notes |
|---|---|---|---|
| **Org guidance** (enforced) | `/etc/claude-code/managed-settings.json` → `claudeMd` | top precedence, every session, non-overridable | NO secrets; **spike-confirmed on claude 2.1.168** |
| **Skills / rules / agents / commands** | per-user `~/.claude/{skills,rules,…}` **symlinks** → Config base | loaded from the `user` source; symlink ⇒ base edits are live | there is **NO** managed-skills key — symlinks ARE the mechanism (the proven emo pattern) |
| Shell (zsh/aliases/env) | `/etc/profile.d/*.sh`, `/etc/skel` | sourced at login; skel seeds new homes | `~/.zshrc` layers on top |
| Tools/binaries | system-wide `/usr/local` + apt manifest | one host → shared `/usr` | `pip install --user` in `~` |

`wizard` edits the base → commit → every child inherits on next prompt/login. **No copy, no mirror, no drift** (this replaces today's hand-mirrored per-user setup — the documented emo-drift pain, memory id=3205/4015). Per-user *mutable* state (`~/.claude.json`, `.credentials.json`, `projects/`, history) is never shared — local only. *(Resolved 2026-06-08, spike GO: skills/rules/agents are delivered via per-user `~/.claude/*` symlinks to the base — seeded in `/etc/skel/.claude/` (a symlink there is copied **as a symlink** by `useradd -m`) and reinforced by the provisioner; the managed `claudeMd` carries enforced org guidance. Base = wizard's chezmoi-versioned `~/.claude` (override via `WORKSTATION_CONFIG_BASE`). This replaces the old `start-claude.sh: cd /home/wizard/code` hack — config now comes from the managed layer + symlinks regardless of CWD, so a new user's launcher just `cd ~/code`.)* **Secret leak found+fixed 2026-06-08:** `~/.claude/settings.json` was `0664`, exposing `MEMORY_API_KEY` to every devvm user → `0600` (the chezmoi source is non-private, so it needs a `private_` prefix + the key templated out to persist).

### 5. Infra access (per-user writable locked clone — changes NOT gated)

Each non-admin gets their **own writable**, git-crypt-**locked** clone of the monorepo at `~/code`:
- A **keyless** clone (`filter.git-crypt.smudge=cat`): all code/docs are plaintext; the git-crypt'd secret files (`infra/secrets/`, `infra/terraform.tfvars`) stay `\0GITCRYPT\0` ciphertext blobs. They read the code, never the secrets (the repo is public anyway; only git-crypt'd files are sensitive).
- **Writable + ungated:** they edit, commit, and `git push` to Forgejo **freely** — no read-only mount, no PR gate. Safe because **pushing infra master does NOT auto-apply** (infra is applied *manually* via `scripts/tg apply`; memory id=4355). Per-user clones also remove the old shared-tree commit-entanglement hazard.
- **The real boundary is apply-time, not the repo:** a non-admin can change code but cannot make it take effect — `scripts/tg apply` needs a write-capable Vault token (`vault login -method=oidc` → vault-admin) + cluster RBAC their tier lacks.
- **Trade vs the earlier live mirror:** the infra repo's own `CLAUDE.md`/code now updates via `git pull` (standard dev flow), not instantly. The high-value live inheritance — Viktor's skills/prompts/rules/global `CLAUDE.md` — is **unaffected** (it flows through the machine-wide managed layer in §4, not the repo).

### 6. Permission model

| Tier | OS account | sudo / docker | code-shared + git-crypt | infra repo | kubectl (own OIDC, per tier) | Vault (own OIDC) |
|---|---|---|---|---|---|---|
| **admin** (Viktor) | wizard | ✅ / ✅ | ✅ (unlocked) | unlocked R/W tree; can `tg apply` | cluster-admin | vault-admin |
| **power-user** (Emo) | emo | ❌ / ❌ | ❌ | own **writable locked** clone (push free; no secrets; can't apply) | **cluster-wide read-only, no Secrets** | scoped read |
| **namespace-owner** (Anca) | ancamilea | ❌ / ❌ | ❌ | own **writable locked** clone (push free; no secrets; can't apply) | **admin in own namespace** (full R/W in-ns) + namespace/node LIST only | own-namespace paths |

Layers: Authentik group (eligibility) → OS account `0700` home + per-tier groups (no sudo/docker for non-admins; rootless podman if containers needed) → **per-user OIDC kubeconfig + Vault** so each session acts as *its own* identity, never Viktor's. **kubectl is enabled per tier** — the provisioner installs each user's kubeconfig at the scope above (admin = cluster-admin; power-user = cluster-wide read-only, no Secrets; namespace-owner = admin in their own namespace), reusing the existing `k8s_users` / dashboard-SA machinery (memory id=4042). **Changing infra is never gated at the repo; it's gated at apply** — only admin can `scripts/tg apply` (write Vault + cluster RBAC). Per-user creds live in each `0700` home; wizard's `~/.vault-token` (`0600`) is unreadable to others.

**Cluster-RBAC reality (verified 2026-06-08) — two corrections + identity facts:**
- **power-user role:** the existing `oidc-power-user` ClusterRole grants cluster-wide **read+write+Secrets** and is currently *unbound* — NOT the read-only-no-Secrets tier ADR-0005 wants. So power-user needs a **NEW** `oidc-power-user-readonly` ClusterRole (get/list/watch on non-secret resources cluster-wide, NO `secrets`), bound to emo's OIDC email. Do not reuse the existing role.
- **kubeconfig is OIDC, not SA-token:** the apiserver carries live `--oidc-*` flags for the `kubernetes` audience and accepts Authentik OIDC; the "apiserver rejects OIDC" note in `dashboard-sa.tf` is dashboard-audience-specific (the multi-issuer `authentication-config` isn't live). Install `kubelogin`, smoke-test the OIDC path first, and fall back to the per-user SA-token (dashboard) pattern only if it fails.
- **identity reality:** emo has **no `k8s_users` entry** today → power-user is a NET-NEW grant; anca is already namespace-owner of `plotting-book` and gheorghe (`vabbit81`) of `vabbit81` — preserve, don't re-provision.

**Shared-host caveat:** a multi-user host is a softer boundary than pods — it relies on standard Linux hardening. Appropriate because these are trusted people. If a user must ever be *untrusted*, that's the signal to revisit K8s pods. Note: non-admins' Claude/t3 runs `--dangerously-skip-permissions` (autonomous tool execution as their uid) — bounded by the `0700` home + no-sudo/no-docker sandbox, but a conscious accepted trade.

### 7. Secrets & auth (per-user, injected — never in the Config base)

The Config base / machine-wide managed layer is **secret-free**. Everything carrying a token/auth is **per-user**, in the user's own `0600` files, and **never machine-wide** — per the Google-Workspace-MCP precedent (id=4553: *"do NOT move a secret-bearing MCP server into machine-wide config"*; one user literally can't read another's `~/.claude.json`).

| Auth / token | Lives in (per-user, `0600`) | New-user provisioning (from Vault) |
|---|---|---|
| **Claude OAuth** | `~/.claude/.credentials.json` + isolated Vault backup | own Enterprise SSO login; Claude refreshes locally and `claude-auth-sync@<user>.timer` validates/backs up/recovers `claudeAiOauth` at `secret/workstation/claude-users/<os_user>`; shared token injection is forbidden |
| **`claude_memory` MCP** | `~/.claude.json` mcpServers + `MEMORY_API_KEY` in `settings.json` env | **DEFERRED — not a risk now (Viktor, 2026-06-08).** Per-user memory isolation needs a service-side `_key_to_user` map edit + redeploy (claude-memory-mcp, GHA repo 78), not just a Vault write — NOT built now. For now a new user gets a simple key or omits memory; revisit if isolation becomes a concern. |
| **`ha` MCP** (token-in-URL) | `~/.claude.json` | shared `ha_sofia_mcp_url` from Vault `secret/openclaw` (one HA instance; shared secret, per-user file) — only if HA-eligible |
| **`playwright` MCP** | per-user systemd unit (own port) + localhost entry | existing per-user playwright pattern (id=4015); non-secret |
| **`context7`** | plugin-provided | non-secret (plugins layer) |

The root provisioner READS these from Vault and writes them into a **new** user's home — **if-absent, never clobbering** an existing user's working config. Minting a new per-user memory key needs an admin Vault write (`vault login -method=oidc`; the agent token can't write KV — id=4181) → an admin onboarding step. **emo's existing MCP/auth is untouched** (additive-only): `managed-settings.json` carries NO `env` secrets, so his `MEMORY_API_KEY` and his `~/.claude.json` MCP servers keep working exactly as today.

**beads (`bd`) credential — gap found 2026-06-08:** a per-user infra clone does NOT include the Dolt credential (`.beads-credential-key` is git-ignored), so the provisioner must drop it (or set `DOLT_REMOTE_PASSWORD`) into the user's `~/code/.beads/` — else `bd` resolves the central server (`10.0.20.200:3306`) but fails auth. `bd` does **not** depend on `code-shared` (it's server-mode against the central Dolt), so the emo cutover doesn't break `bd` *if* his credential is provisioned.

## Capacity & prerequisites

**The devvm is the binding constraint — address before onboarding active users.** Verified 2026-06-08: devvm has **24 GB RAM** (the `proxmox-inventory.md` "8 GB" is STALE → fix that doc), ~8 GB free, **0 swap**; wizard alone already runs ~20 sessions (~10 GB RSS). Each interactive Claude session is ~300–700 MB; each user adds one persistent `t3-serve` daemon (~430 MB). 3–5 active users × several sessions would exhaust RAM → with **0 swap the failure mode is OOM-kill of live sessions** (everyone's), not graceful slowdown — also a `~/.claude.json` corruption trigger (id=2320/2321: multi-session writes + disk pressure).

**Prerequisites (do FIRST):** (1) **add swap** to the devvm (OOM-kill → graceful pressure); (2) optionally bump RAM (PVE-side — devvm is NOT TF-managed, id=1575); (3) set a per-user RAM budget + a **max-concurrent-active-users** ceiling; (4) memory/disk-pressure monitoring on the devvm. CPU (16 cores, ~7%) and disk (`/` ~28 GB free) are fine for now.

## User lifecycle (onboard → reconcile → offboard) — the roster drives all of it

The roster is the SSoT for the **whole** lifecycle, not just creation:

- **Onboard:** add a roster entry (the reconcile also adds them to the `T3 Users` Authentik group). The reconcile creates the constrained account, seeds config inheritance, provisions the per-user OIDC kubeconfig + locked clone + MCP/auth (+ the `bd` Dolt credential), starts `t3-serve@<u>`.
- **Reconcile (routine, additive-only):** converges *missing* state UP; never strips an existing user (the don't-break-emo guarantee). Safe to run anytime.
- **Offboard (REMOVE the roster entry):** the destructive half — gated + staged, NOT the routine timer:
  1. **Reversible cut (on roster removal):** stop+disable `t3-serve@<u>`; drop the user from `/etc/ttyd-user-map` + `dispatch.json` (regenerated → 403 at the dispatcher); remove from the `T3 Users` Authentik group (edge-blocked); `passwd -l <u>`. Access fully cut; nothing deleted.
  2. **Cluster revoke:** remove their `k8s_users` entry + apply (drops RBAC binding + kubeconfig validity) + revoke shared-token / memory creds.
  3. **Destructive (explicit, separate, never auto):** archive `~<u>` (tar → backup), then `userdel -r`. Irreversible — requires explicit go-ahead.
- Write `docs/runbooks/offboard-user.md` (the link in `multi-tenancy.md` currently dead-ends). Rollback of step 1/2 = re-add the roster entry + reconcile.

## Incrementality & migration (don't break emo)

emo has a **working** setup that must not break: his `t3-serve@emo` (port 3774) + ~4 concurrent live Claude sessions (id=2320); his own `~/.claude` + `~/.claude.json` (MCP servers incl. `ha` token-in-URL and his `MEMORY_API_KEY`); his `~/code` symlink into wizard's tree; `code-shared` + `docker` membership; tmux/playwright units. Hard guarantees:

- **The idempotent reconcile is ADDITIVE-ONLY.** It creates *missing* accounts/config/instances and *adds* a user's tier-appropriate access, but it **never removes** an existing user's groups, **never replaces** an existing `~/code` (skip-if-exists), and **never writes into** an existing `~/.claude` / `~/.claude.json`. Running `provision-users.sh` at any time is therefore a no-op on emo's existing state — safe to run repeatedly.
- **Every destructive/tightening step is SEPARATE, explicit, idle-gated, and reversible** — never part of the routine reconcile.
- **Phases 0–4 are additive and verified non-breaking.** After each, confirm emo's live sessions, his `~/.claude`/MCP, his `~/code`, and his groups are unchanged.

Rollout order:
1. **Config base + machine-wide managed layer** → wizard + emo *inherit* wizard's skills/prompts. Additive: the managed layer only ADDS; it must not set keys/hooks that override emo's working `~/.claude` / `MEMORY_API_KEY` / MCP servers. **Verify emo's existing sessions + MCP still work.**
2. **Roster + provisioner** alongside the current `/etc/ttyd-user-map` (idempotent; ancamilea already provisioned; emo's instance untouched).
3. **Per-user writable locked clones** provisioned **only for users without an existing `~/code`** — emo's symlink is left intact (skip-if-exists).
4. **Per-tier kubeconfig** installed **only if absent** (existing `~/.kube/config` backed up, never clobbered) — emo's current kube access untouched.
5. **emo cutover — the ONLY step that changes emo; opt-in + reversible, never auto-run:** (a) record rollback state (`readlink ~emo/code`, `id emo`, copy of `start-claude.sh`); (b) idle-gate (id=3201); (c) replace his `~/code` symlink with his own writable locked clone, **point his `start-claude.sh` at `cd ~/code`** (today it hardcodes `cd /home/wizard/code` — *that* is the actual reason his Claude lands in wizard's unlocked tree, so swapping the symlink alone is NOT enough), drop the now-redundant `~/.claude/{rules,skills/file-issue}` symlinks into wizard's home (the managed layer / shared base delivers them now), and `gpasswd -d emo code-shared`. He keeps full edit/commit/push (ungated); loses only secret-read + apply. **Rollback (seconds):** restore the symlink + `start-claude.sh` + the `~/.claude` symlinks + `gpasswd -a emo code-shared`. A `t3-serve@emo` restart only blips his WebSocket (id=3308). Requires explicit go-ahead.
6. **Authentik `T3 Users` group + edge gate** last (once instances exist), so no one is locked out mid-migration.

New users (gheorghe; and ancamilea's enhancement) are born into the new model — no migration needed.

## Template-readiness ("VM as a template" — future)

Design principle: **every bit of devvm setup is an idempotent git script** — nothing lives only as hand-typed host state. Three scripts in `infra/scripts/workstation/`: `setup-devvm.sh` (package manifest + managed config + config-base clone), `provision-users.sh` (roster loop), and the roster + manifest data files. When the template is wanted: the devvm becomes a cloud-init Proxmox template (the estate's existing reproducibility pattern, id=1575) that clones the infra repo + runs both scripts → identical devvm. Per-user **home data** is the only non-template state → add `/home` to the 3-2-1 backup set, or users re-clone + re-pair on a fresh box.

## Key decisions (ADR candidates)

- **ADR-0001 — Build on the existing stack, not a CDE.** Coder/Che/etc. researched; the role model is Premium-gated or the platform lacks the agent layer, and the homelab scale doesn't justify it. Hard to reverse, surprising ("why not Coder?"), real trade-off.
- **ADR-0002 — devvm Linux users, not K8s ephemeral pods.** Re-platforming is overkill at this scale; config-push is easier on one host.
- **ADR-0003 — Config inheritance via native machine-wide layers + per-user override.** Rejected: periodic sync, OverlayFS (no live lowerdir edits), Nix (rebuild not live).
- **ADR-0004 — Infra access via per-user writable git-crypt-locked clones (changes ungated).** Each non-admin gets their own writable, keyless (locked) clone — read + edit + push freely, no PR gate. Safe because infra apply is manual + admin-only (push ≠ apply, id=4355) and the clone can't decrypt secrets. Rejected: the shared read-only mirror (gated changes) and the shared unlocked tree (secret leak + commit entanglement). Trade: repo-local CLAUDE.md updates via pull, not live (global config inheritance stays live via §4).
  - **AMENDED 2026-06-10 — the "push ≠ apply" premise was WRONG.** The Forgejo→Woodpecker webhook on `viktor/infra` fires `.woodpecker/default.yml` on `push` to `master` (`require_approval: forks` only), which terragrunt-applies changed stacks — so an ungated master push IS a deploy. Enforcement added instead of dropping the ADR: Forgejo **branch protection on `master`** (push + merge whitelists = `viktor`, deploy keys allowed). Non-admins keep free branch pushes + PRs; only admin merges land on master. "No PR gate" is thereby reversed for non-admins; the rest of the ADR (per-user locked clones) stands. As-built: `../architecture/multi-tenancy.md` → "Contribute access".
  - **AMENDED AGAIN 2026-06-10 (later) — allow-then-audit.** Viktor granted emo (`ebarzin`) direct master push ("he's allowed to make any change; what matters is tracking what changed and why"). The PR gate is dropped FOR WHITELISTED USERS; tracking is enforced instead: agent-written commit messages must carry the user's plain-language intent (the WHY), a `notify-nonadmin-push` Slack step in `.woodpecker/default.yml` surfaces every non-admin master push, `[ci skip]` is forbidden for non-admins, and force-push stays disabled (append-only history). Accepted consequence: emo's pushes auto-apply changed stacks via CI. Branch protection + the PR fallback remain for non-whitelisted users.
- **ADR-0005 — Power-user = cluster-wide read-only (no Secrets), via a NEW dedicated ClusterRole.** Re-widens cross-tenant READ for the trusted power-user tier only — but via a NEW `oidc-power-user-readonly` ClusterRole (get/list/watch, NO `secrets`), NOT the existing `oidc-power-user` (which grants read+write+Secrets and is unbound). Bound to the user's OIDC identity (kubelogin) — the apiserver accepts Authentik OIDC for the `kubernetes` audience; the dashboard's SA-token pattern is for the dashboard UI only.
- **ADR-0006 — The roster is the single source of truth for the FULL lifecycle.** `roster.yaml` drives onboard *and* offboard; `/etc/ttyd-user-map`, `dispatch.json`, and Authentik `T3 Users` membership are *derived* from it, and tier is *validated* against `k8s_users` (fail-loud on mismatch). Rejected: hand-maintaining the four membership lists in parallel (guaranteed drift). Offboarding is first-class + staged (reversible cut → cluster revoke → gated `userdel`), not an afterthought.
- **ADR-0007 — Add swap + a capacity budget to the devvm before onboarding active users.** A shared 24 GB / **0-swap** host OOM-kills live sessions under multi-user load (wizard alone runs ~20). Swap + a max-concurrent ceiling are prerequisites, not follow-ups.

## Out of scope / deferred

- Zero-touch auto-provision on first Authentik login (admin runs the provisioner / the timer converges — simpler at this scale).
- K8s per-user pods (revisit only if a user must be untrusted, or scale grows large).
- The actual cloud-init template conversion (design for it now; do it when wanted).
- **Per-user memory isolation** (own namespace / service-side `_key_to_user` map + redeploy) — **deferred; not a risk now** (Viktor, 2026-06-08). Revisit if memory cross-read becomes a concern.

## Verification (acceptance)

- A new roster entry + `provision-users.sh` → the user can log into `t3.viktorbarzin.me` and lands in a configured Workstation with Viktor's skills/prompts.
- wizard edits a skill/CLAUDE.md in the base → a child's next prompt sees it (no pull).
- A child's `kubectl`/`vault` is bounded by their tier (kubectl enabled per tier: power-user = cluster-wide read-only; namespace-owner = read/write in own ns only); a non-admin cannot read git-crypt secrets nor escalate.
- A non-admin can edit + commit + push their infra clone **freely**, but cannot `scripts/tg apply` (no write Vault / cluster RBAC) — changes don't take effect until an admin applies.
- Re-running the provisioner is idempotent (no changes on a converged host).
- `provision-users.sh` + `setup-devvm.sh` reproduce the setup on a fresh host from git.
