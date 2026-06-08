# Multi-User Workstation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement task-by-task. Steps use `- [ ]` for tracking. This is **infra** work — "verify" means an idempotent re-run + a smoke check with expected output (not pytest). Honor the Terraform-only rule for cluster changes; devvm host scripts are the accepted exception (versioned in `infra/scripts/`, deployed via the provisioner). Claim `host:devvm` before mutating the devvm; gate `t3-serve@<user>` restarts on user idle (memory id=3201). **INCREMENTALITY (don't break emo):** every phase is additive; the idempotent reconcile is **additive-only** — it NEVER removes an existing user's groups, NEVER replaces an existing `~/code` (skip-if-exists), and NEVER writes into an existing `~/.claude`/`~/.claude.json`. The emo cutover (Phase 5) is the ONLY destructive step — explicit, idle-gated, reversible, never auto-run. After each of Phases 1–4, **verify emo's live sessions, `~/.claude`/MCP, `~/code`, and groups are unchanged.**

**Goal:** A declarative roster + idempotent scripts that provision per-user Claude Code Workstations on the devvm, inheriting Viktor's config live via native machine-wide layers, scoped by RBAC tier, reproducible from git.

**Architecture:** Config base (machine-wide managed Claude config + system shell files + apt manifest) authored by wizard → all users inherit live. `roster.yaml` + `provision-users.sh` create constrained OS accounts + per-user OIDC kubeconfig (per tier) + per-user writable git-crypt-locked infra clone + `t3-serve@<u>`. Authentik `T3 Users` group gates the edge.

**Tech Stack:** Bash (idempotent host scripts), systemd template units + timer, Claude Code managed-settings, git-crypt, Authentik expression policy (Terraform), the existing `k8s_users` per-user Vault/RBAC.

**Design:** `infra/docs/plans/2026-06-07-multi-user-workstation-design.md`. **Glossary:** `infra/CONTEXT.md`.

---

## File structure

- Create: `infra/scripts/workstation/roster.yaml` — the source-of-truth roster
- Create: `infra/scripts/workstation/packages.txt` — declared host apt/global toolset
- Create: `infra/scripts/workstation/setup-devvm.sh` — host base: packages + managed Claude config + config-base clone (idempotent)
- Create: `infra/scripts/workstation/managed-settings.json` — the machine-wide Claude base (settings + `claudeMd`)
- Modify: `infra/scripts/t3-provision-users.sh` — read `roster.yaml`; create constrained accounts; per-tier groups + kubeconfig; repoint `~/code`
- Modify: `infra/scripts/t3-provision-users.sh` — also provision each non-admin's own writable git-crypt-locked clone at `~/code` (no separate mirror service)
- Modify: `infra/stacks/authentik/admin-services-restriction.tf` — add the `t3.viktorbarzin.me` → `T3 Users` branch
- Create: `infra/stacks/authentik/` group resource (or document the UI-created group) for `T3 Users`
- Docs: update `infra/docs/architecture/multi-tenancy.md` (add the Workstation section) + `.claude/reference/service-catalog.md` (t3code row) in the same commits

---

## Phase −1 — Prerequisites (do FIRST)

### Task −1.1: devvm capacity (P0 — verified 2026-06-08: 24 GB RAM, 0 swap, wizard ~20 sessions)

- [ ] **Step 1:** Add **swap** to the devvm (swapfile, e.g. 8–16 GB) — turns multi-user OOM-kill into graceful pressure. Verify `free -h` shows `Swap` > 0.
- [ ] **Step 2:** Document a per-user RAM budget + a **max-concurrent-active-users** ceiling; add memory/disk-pressure monitoring on the devvm. (Optionally bump RAM PVE-side — devvm is NOT TF-managed, id=1575.)
- [ ] **Step 3:** Fix the stale `infra/.claude/reference/proxmox-inventory.md` devvm RAM (says 8 GB; live = 24 GB). Commit `[ci skip]`.

### Task −1.2: tooling

- [ ] **Step 1:** Install `kubelogin` (`kubectl-oidc_login`) on the devvm and add it to `packages.txt` — the per-user OIDC kubeconfig (Task 2.2) needs it; it is NOT installed today.

---

## Phase 0 — Roster + config base in git (no host changes)

### Task 0.1: Create the roster

**Files:** Create `infra/scripts/workstation/roster.yaml`

- [ ] **Step 1:** Write the roster with the current three children (wizard is the base author, not listed):

```yaml
# THE single source of truth for the devvm Workstation lifecycle (onboard → offboard).
# os_user (key) → authentik_user · k8s_user · tier · namespaces. Identifiers differ per person (verified 2026-06-08).
users:
  emo:       { authentik_user: emil.barzin, k8s_user: emo,  tier: power-user }            # NET-NEW cluster identity (not in k8s_users today)
  ancamilea: { authentik_user: ancaelena98, k8s_user: anca, tier: namespace-owner, namespaces: [plotting-book] }  # ALREADY provisioned — preserve, don't re-create
# gheorghe:  { authentik_user: vabbit81,    k8s_user: vabbit81, tier: namespace-owner, namespaces: [vabbit81] }    # already a cluster ns-owner; uncomment for a devvm workstation
```
(`os_user` is the pinned key — no email→username derivation. Note the three distinct IDs per person.)

- [ ] **Step 2: Verify** it parses: `python3 -c "import yaml,sys; print(yaml.safe_load(open('infra/scripts/workstation/roster.yaml')))"` → Expected: a dict with `users.emo.tier == power-user`.
- [ ] **Step 3: Commit:** `git add infra/scripts/workstation/roster.yaml && git commit -m "workstation: add roster source-of-truth [ci skip]"`

### Task 0.2: Declare the host toolset

**Files:** Create `infra/scripts/workstation/packages.txt`

- [ ] **Step 1:** List the shared tools (one per line, comments allowed): `git`, `zsh`, `tmux`, `ripgrep`, `jq`, `python3`, `nodejs`, `kubectl`, `vault`, `podman` (rootless). Claude Code is installed via npm global in `setup-devvm.sh` (Task 1.2), not apt.
- [ ] **Step 2: Verify:** `grep -vE '^\s*(#|$)' infra/scripts/workstation/packages.txt` lists the expected packages.
- [ ] **Step 3: Commit:** `git add infra/scripts/workstation/packages.txt && git commit -m "workstation: declare host package manifest [ci skip]"`

### Task 0.3: Build the Config base (secret-free, curated — it doesn't exist yet)

**Files:** chezmoi dotfiles repo (`github.com/ViktorBarzin/dot_files`, `dot_claude/`) + `infra/scripts/workstation/managed-settings.json`

- [ ] **Step 1:** Create/refresh the **Config base** = the secret-free curated set the managed layer + `/etc/skel` deploy from: skills/agents/rules/commands/hooks/`CLAUDE.md` + shell (`zshrc`/`profile.d`) + the `start-claude.sh` launcher (`cd "$HOME/code"`). Sanitize OUT all secrets (`.credentials.json`, `~/.claude.json`, `settings.json` `env`); resolve any `~/.agents/skills` symlinks to real files.
- [ ] **Step 2:** Reconcile launcher ownership: the current `start-claude.sh` is deployed by the SEPARATE `viktor/terminal-lobby` repo (its own `deploy.sh`). Decide whether the workstation base or terminal-lobby owns it — not both (avoid two competing launchers).
- [ ] **Step 3: Verify:** secret-scan the base (`grep -rEi 'sk-ant|oat01|BEGIN .*PRIVATE|api[_-]?key|password'` → only docs/placeholders) + no dangling symlinks.
- [ ] **Step 4: Commit/push** the refreshed dotfiles repo.

---

## Phase 1 — Config base + machine-wide inheritance (additive; verify wizard+emo inherit)

### Task 1.1: Pin the exact Claude managed-skills mechanism (discovery spike)

**Why:** the managed `settings.json` + `claudeMd` paths are confirmed (`/etc/claude-code/managed-settings.json`), but the exact **managed skills** deployment path needs confirming on the installed Claude Code version before we rely on it for skill inheritance.

- [ ] **Step 1:** On the devvm, check the installed version: `claude --version`.
- [ ] **Step 2:** Confirm the managed location is read: create a throwaway `/etc/claude-code/managed-settings.json` with a benign `claudeMd` string, start a fresh `claude` session as a NON-wizard test user, and confirm the injected guidance appears. Expected: the `claudeMd` text is present in context.
- [ ] **Step 3:** Determine the managed-skills path (managed-settings `skills`/skill-source key, or a managed skills dir) **AND how the bespoke `~/.claude/rules/*.md` + `agents/` are delivered machine-wide** — the managed layer covers settings/skills/`claudeMd`, NOT an arbitrary `rules/` dir, so rules land either (a) folded into the managed `claudeMd`, or (b) a per-user symlink to the shared Config base (replacing today's live `~/.claude/rules → /home/wizard/.claude/rules` symlink). Record the verified mechanism in the design doc's §4 + a memory.
- [ ] **Step 3b — Plan-B (go/no-go):** if managed *skills* aren't supported on the installed Claude Code version, FALL BACK to per-user symlinks of `~/.claude/{skills,agents,rules}` → the shared Config base. The verified `settingSources:[user,…]` (2026-06-08) means both t3 and `claude` read the per-user `user` layer, so symlinks are a complete fallback. Make this an explicit branch, not a silent assumption.
- [ ] **Step 4: Commit** the design-doc update: `git commit -am "workstation: pin verified managed-skills mechanism [ci skip]"`

### Task 1.2: `setup-devvm.sh` — host base (idempotent)

**Files:** Create `infra/scripts/workstation/setup-devvm.sh`, `infra/scripts/workstation/managed-settings.json`

- [ ] **Step 1:** Write `managed-settings.json` — the machine-wide Claude base: the `claudeMd` org guidance + any enforced hooks/permissions, **no secrets** (per-user memory keys etc. stay per-user).
- [ ] **Step 2:** Write `setup-devvm.sh` (run as root, idempotent): (a) `apt-get install -y $(grep -vE '^\s*(#|$)' packages.txt)`; (b) `npm install -g @anthropic-ai/claude-code` if missing; (c) `install -m 0644 managed-settings.json /etc/claude-code/managed-settings.json`; (d) materialize managed skills from the config-base checkout per the Task 1.1 mechanism; (e) lay down `/etc/profile.d/00-workstation.sh` + `/etc/zsh/zshrc.d/` base shell config + seed `/etc/skel` — **incl. a `start-claude.sh` that `cd "$HOME/code"` and a `.tmux.conf` with `default-command "$HOME/start-claude.sh"`, so a new account auto-launches Claude in ITS OWN clone (never a hardcoded `/home/wizard/code`)**; (f) clone/refresh the config-base repo to a shared path.
- [ ] **Step 3: Verify (inheritance):** as `emo` (idle-gated if a session is live), `sudo -u emo -i claude` shows wizard's managed `claudeMd` + a base skill in `/skills`, with no per-emo copy. Expected: base skill present.
- [ ] **Step 4: Verify (idempotent):** re-run `setup-devvm.sh`; Expected: exit 0, no changes on second run.
- [ ] **Step 5: Commit:** `git add infra/scripts/workstation/setup-devvm.sh infra/scripts/workstation/managed-settings.json && git commit -m "workstation: host base + machine-wide Claude config inheritance"`

---

## Phase 2 — Provisioner (additive; create constrained accounts from roster)

### Task 2.1: Extend `t3-provision-users.sh` to read the roster + create accounts

**Files:** Modify `infra/scripts/t3-provision-users.sh`

- [ ] **Step 1:** Add a roster-read + per-entry loop. For each `os_user`: if the account is **absent**, `useradd -m -s /bin/zsh "$os_user"` + `passwd -l "$os_user"` (SSO/t3 only) + `chmod 700 ~`. `set_tier_groups` is **ADD-ONLY** — it `gpasswd -a`'s the tier's groups (admin → `sudo,docker,code-shared`; power-user/namespace-owner → none beyond their own) but **NEVER removes** a group from an existing account (so a routine reconcile can't strip emo's current `code-shared`/`docker` — removal is the Phase-5 cutover only). Do **not** `passwd -l` or re-`chmod` an already-existing account.
- [ ] **Step 2 (SSoT — derive, don't append):** **Regenerate** `/etc/ttyd-user-map` + `/etc/t3-serve/dispatch.json` from the roster each run (so a removed roster entry DISAPPEARS — this is what makes offboarding's reversible-cut work), allocate sticky ports, `systemctl enable --now t3-serve@<os_user>`. Reconcile the `T3 Users` Authentik group membership from the roster. **Validate** each entry's `tier` against the live `k8s_users` role and **abort with a clear error on mismatch** (workstation tier and cluster tier must not silently diverge).
- [ ] **Step 3: Verify (idempotent + non-breaking):** run as root; Expected: emo + ancamilea instances `active`, dispatch.json unchanged, **AND** `id emo` still shows `code-shared`+`docker` (NOT stripped), emo's `~/code` symlink intact, his live sessions unaffected.
- [ ] **Step 4: Verify (constrained account):** `id emo` shows no `sudo`/`docker`/`code-shared`; `sudo -n -u emo true` fails (no sudo).
- [ ] **Step 5: Commit:** `git add infra/scripts/t3-provision-users.sh && git commit -m "workstation: roster-driven account creation + per-tier groups"`

### Task 2.2: Per-user identity-scoped kubeconfig + Vault helper

**Files:** Modify `infra/scripts/t3-provision-users.sh` (add `install_user_identity`)

- [ ] **Step 1:** For each non-admin, write `~$os_user/.kube/config` as a **per-user OIDC kubeconfig** (`kubelogin`/`oidc-login`) bound to THEIR email — the apiserver accepts Authentik OIDC for the `kubernetes` audience (verified 2026-06-08; the dashboard SA-token pattern is for the dashboard UI, NOT kubectl). Tier → a ClusterRole bound to their OIDC `User`: namespace-owner → admin in their own namespace via the existing `oidc-ns-owner-*` bindings (for anca that's the EXISTING `plotting-book` — assert, don't re-provision); power-user → a **NEW `oidc-power-user-readonly`** ClusterRole (get/list/watch cluster-wide, **NO `secrets`**), NOT the existing `oidc-power-user` (read+write+Secrets). Owned by the user, `0600`. **Install only if `~/.kube/config` is absent;** else back up to `.bak-<ts>` and skip (never clobber).
- [ ] **Step 2:** Drop a `~/.zshrc.d/vault.sh` that sets `VAULT_ADDR=https://vault.viktorbarzin.me` and documents `vault login -method=oidc` (their own identity). Do NOT seed wizard's token.
- [ ] **Step 3: Verify (OIDC works, then scoping):** FIRST smoke-test the OIDC path — a non-admin `kubectl` via kubelogin actually authenticates (it's currently unexercised by any human; if it fails like the dashboard audience did, fall back to a per-user SA-token kubeconfig). THEN: as emo, `kubectl get pods -A` works (read) but `kubectl get secret -A` is forbidden and `kubectl delete` anything is forbidden; as ancamilea, only `plotting-book` is visible.
- [ ] **Step 4: Commit:** `git add infra/scripts/t3-provision-users.sh && git commit -m "workstation: per-user identity-scoped kubeconfig + vault helper"`

*(Prereq: add a **NEW `oidc-power-user-readonly`** ClusterRole + email binding to `stacks/rbac` via `scripts/tg apply` — do NOT reuse the existing `oidc-power-user` (read+write+Secrets, currently unbound). emo also needs a NEW `k8s_users` entry as `power-user` (net-new); anca/gheorghe already exist — assert, don't re-create. Terraform-managed, separate commit.)*

### Task 2.3: Inject per-user MCP + auth secrets (new users only; never clobber)

**Files:** Modify `infra/scripts/t3-provision-users.sh` (add `install_user_secrets`)

- [ ] **Step 1:** For each non-admin **without** an existing `~/.claude.json` (NEW users only — NEVER touch an existing one): write `~/.claude.json` with `playwright-shared` (localhost), `ha` (shared `ha_sofia_mcp_url` from Vault `secret/openclaw`) if HA-eligible, and `claude_memory` using a **shared/simple key (per-user memory isolation is DEFERRED — not a risk now)**. Seed `~/.claude/.credentials.json` with the shared Claude token (Vault) **or** leave absent for interactive login. **Drop the beads Dolt credential** into `~/code/.beads/` (`.beads-credential-key`, from Vault, or set `DOLT_REMOTE_PASSWORD`) so `bd` authenticates — it's git-ignored, so a fresh clone lacks it. All `0600`, owned by the user. Per-user `playwright-mcp` systemd unit on its own port (existing pattern, id=4015).
- [ ] **Step 2 (DEFERRED — not now):** Per-user memory isolation is NOT built (Viktor, 2026-06-08): a new user shares/omits memory for now. When wanted, it needs a service-side `_key_to_user` map edit + redeploy (claude-memory-mcp, GHA repo 78) **and** a Vault key — not just a Vault write (id=413/4181).
- [ ] **Step 3: Verify (new user gets isolated auth):** as the test user, `claude mcp list` shows their servers `Connected`; `memory_recall` returns THEIR namespace, not Viktor's.
- [ ] **Step 4: Verify (emo untouched):** `~emo/.claude.json`, `~emo/.claude/.credentials.json`, `~emo/.claude/settings.json` are **byte-identical** to before the run (`sha256sum` before/after); `claude mcp list` as emo still shows ha/claude_memory/playwright `Connected`.
- [ ] **Step 5: Commit:** `git add infra/scripts/t3-provision-users.sh && git commit -m "workstation: per-user MCP + auth injection (new users only, if-absent)"`

---

## Phase 3 — Per-user writable locked infra clone (code view; changes ungated)

### Task 3.1: Provision each non-admin's own writable git-crypt-locked `~/code`

**Files:** Modify `infra/scripts/t3-provision-users.sh` (add `install_infra_clone`)

- [ ] **Step 1:** For each non-admin, **only if `~$os_user/code` does not exist at all** (no symlink, no directory — NEVER touch an existing `~/code`, so emo's symlink stays intact), clone the same repo wizard uses, as that user: `REPO=$(git -C /home/wizard/code config --get remote.origin.url); sudo -u "$os_user" git clone "$REPO" ~/code`. Then in the clone set `git config filter.git-crypt.smudge cat; filter.git-crypt.clean cat; filter.git-crypt.required false` and `git checkout master`. **No git-crypt key is installed** → secret files stay ciphertext, code/docs are plaintext (memory id=3665/3666). Owned by the user, writable.
- [ ] **Step 2:** Leave it writable with a normal `origin` remote (Forgejo) — no read-only mount, no PR gate; they may edit/commit/push freely. (Optional: `git config push.default current` so a bare `git push` targets their own branch.)
- [ ] **Step 3: Verify (locked + writable):** as emo, `head -c 9 ~/code/infra/terraform.tfvars` shows the `GITCRYPT` magic (ciphertext); `cat ~/code/CLAUDE.md` is plaintext; `echo x >> ~/code/README.md && git -C ~/code commit -am wip` **succeeds** (writable, ungated).
- [ ] **Step 4: Verify (apply-gated, not repo-gated):** as emo, `cd ~/code/infra && scripts/tg apply <a-stack>` **fails** (no write Vault token / cluster RBAC); `vault login -method=oidc` as emo cannot obtain vault-admin. Pushing to Forgejo does NOT trigger an apply (id=4355). So his edits can't take effect without an admin apply.
- [ ] **Step 5: Commit:** `git add infra/scripts/t3-provision-users.sh && git commit -m "workstation: per-user writable git-crypt-locked infra clone"`

---

## Phase 4 — Eligibility gate (Authentik group + edge)

### Task 4.1: Create the `T3 Users` group + edge restriction

**Files:** Modify `infra/stacks/authentik/admin-services-restriction.tf`; add the group resource

- [ ] **Step 1:** Add `resource "authentik_group" "t3_users" { name = "T3 Users" }` (pattern: `stacks/authentik/guest.tf:53`). Add emo/ancamilea (and wizard) as members.
- [ ] **Step 2:** In the expression policy, add a dedicated branch BEFORE the final return: `if host == "t3.viktorbarzin.me": return ak_is_group_member(request.user, name="T3 Users")`.
- [ ] **Step 3: Apply:** `vault login -method=oidc` then `scripts/tg apply` in `stacks/authentik` (claim `stack:authentik` first).
- [ ] **Step 4: Verify (gate):** `curl -sI` an unauthenticated request to `t3.viktorbarzin.me` → 302 to Authentik; a member login → reaches their instance; a logged-in NON-member → denied. Confirm the `authentik-walloff` probe stays green for any public carve-outs.
- [ ] **Step 5: Commit:** `git add infra/stacks/authentik/*.tf && git commit -m "workstation: gate t3.viktorbarzin.me to T3 Users group"`

---

## Phase 5 — Migrate existing users (idle-gated, low-disruption)

### Task 5.1: Cut emo over to his own writable locked clone (opt-in, reversible)

**Files:** none (host state; an explicit one-time action — NOT the routine reconcile)

- [ ] **Step 1: Prereqs.** Confirm emo inherits config (Phase 1) + has his scoped kubeconfig (Phase 2). (Phase 3 deliberately SKIPPED emo — his clone is created *here*.)
- [ ] **Step 2: Record rollback state.** Save `readlink -f ~emo/code` (symlink target), `id emo` (groups), a copy of `/home/emo/start-claude.sh`, and the `~/.claude/{rules,skills/file-issue}` symlink targets. This is the instant-rollback snapshot.
- [ ] **Step 3: Idle-gate + go-ahead.** Confirm emo's sessions are keystroke-idle ≥20 min (id=3201); if ambiguous, ASK. Opt-in — never auto-run by the reconcile.
- [ ] **Step 4: Cutover.** (a) `mv ~emo/code ~emo/code.symlink.bak`; provision his own writable locked clone at `~emo/code` (Phase-3 `install_infra_clone`, run explicitly for emo). (b) **Repoint his launcher (REQUIRED):** back up `/home/emo/start-claude.sh`, then change its `cd /home/wizard/code` → `cd "$HOME/code"`. The hardcoded `cd` is the *actual* mechanism landing him in wizard's tree — the symlink swap alone is insufficient. (c) Remove the now-redundant `~/.claude/rules` and `~/.claude/skills/file-issue` symlinks into wizard's home (managed layer / shared base delivers them now). (d) `gpasswd -d emo code-shared`.
- [ ] **Step 5: Verify.** As emo: `cat ~/code/CLAUDE.md` works (his clone); `head -c 9 ~/code/infra/terraform.tfvars` shows `GITCRYPT` ciphertext (locked); he can still `git -C ~/code commit` (ungated) but can no longer read wizard's unlocked secrets nor `scripts/tg apply`. emo's live t3 session still works (only a WS blip if `t3-serve@emo` was restarted).
- [ ] **Step 6: Rollback (seconds, if anything's off):** restore the `~emo/code` symlink (`rm -rf ~emo/code && ln -sfn <saved-target> ~emo/code`), restore `start-claude.sh` from its backup, recreate the `~/.claude/{rules,skills/file-issue}` symlinks, and `gpasswd -a emo code-shared` → emo back to his exact prior state. Otherwise record the cutover in a memory.

### Task 5.2: Confirm ancamilea + a fresh test user end-to-end

- [ ] **Step 1:** Confirm ancamilea logs into `t3.viktorbarzin.me` → her instance, inherits config, own-namespace kubectl only.
- [ ] **Step 2:** Add a throwaway roster entry, run `provision-users.sh`, confirm the account+instance appear and login works; then remove it + `userdel` and confirm clean teardown.

---

## Phase 6 — Template-readiness (design-for-now; convert when wanted)

### Task 6.1: Verify reproducibility from git (no cloud-init yet)

- [ ] **Step 1:** On a scratch VM (or a container), clone the infra repo and run `setup-devvm.sh` + `provision-users.sh`; confirm the toolset + managed config + users reproduce.
- [ ] **Step 2 (promote out of deferred — do in the main rollout):** Add per-user home data to the 3-2-1 backup set NOW: at minimum `~/.t3` (pairings + 30-day sessions) + `~/.claude` (mutable state), ideally all of `/home`. A devvm rebuild otherwise silently loses every user's pairings + session state.
- [ ] **Step 3 (deferred):** When the template is wanted, wrap `setup-devvm.sh` + `provision-users.sh` in cloud-init (the `modules/create-template-vm` pattern, memory id=1575) and snapshot the devvm as a Proxmox template. File a beads task; do not build now.

---

## Phase 7 — Offboarding (deprovision; staged, gated)

Removing a user = delete their `roster.yaml` entry, then:

### Task 7.1: Reversible cut (driven by roster removal)

- [ ] **Step 1:** On reconcile after the entry is gone: `systemctl disable --now t3-serve@<u>`; regenerate `/etc/ttyd-user-map` + `dispatch.json` (user absent → dispatcher 403s); remove them from the `T3 Users` Authentik group (edge-blocked); `passwd -l <u>`. **Verify:** they can no longer reach `t3.viktorbarzin.me` (302→login, then denied) and can't log in. Nothing deleted yet.
- [ ] **Step 2 (cluster revoke):** remove their `k8s_users` entry + `scripts/tg apply` (drops their RBAC binding; OIDC kubeconfig stops authorizing); revoke any individually-held token/memory key.

### Task 7.2: Destructive removal (explicit, separate, NEVER auto)

- [ ] **Step 1:** Archive `~<u>` → backup: `tar czf /mnt/backup/offboard/<u>-<ts>.tar.gz /home/<u>`.
- [ ] **Step 2:** `userdel -r <u>` (removes home + spool). **Irreversible — requires explicit go-ahead.**
- [ ] **Step 3: Rollback:** before 7.2, re-add the roster entry + reconcile restores everything; after 7.2, restore from the archive.
- [ ] **Step 4:** Write + commit `infra/docs/runbooks/offboard-user.md` (the `multi-tenancy.md` link to it is currently a dead end).

---

## Self-review

- **Spec coverage:** prerequisites/capacity + kubelogin (Ph−1), roster SSoT + config-base build (Ph0), config inheritance (Ph1), provisioning + per-tier OIDC kubectl + SSoT-derive/validate + secrets/auth + beads-cred (Ph2), infra code access via writable locked clone (Ph3), Authentik gate (Ph4), incremental non-breaking migration (Ph5), reproducibility/template + per-user backups (Ph6), **offboarding / full lifecycle (Ph7)** — all mapped. Per-user **memory isolation DEFERRED** (not a risk now).
- **Open verification carried as a task, not a placeholder:** the exact managed-skills path (Task 1.1) is a discovery spike with a concrete acceptance check.
- **Terraform-only respected:** the only cluster changes (Authentik group/policy, the power-user ClusterRole) go through `scripts/tg apply`; devvm host scripts are the accepted exception.
- **Docs:** multi-tenancy.md + service-catalog.md updates folded into the relevant commits (per the update-docs rule).
