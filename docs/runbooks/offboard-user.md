# Runbook: Offboard a User

Removing a user can span two surfaces — the **in-cluster** namespace-owner model
(Vault `k8s_users` / RBAC / namespace) and the **devvm Workstation** (roster /
OS account / t3 instance). Both are **staged**: a *reversible cut* (revoke access,
delete nothing) first, then an explicit, gated *destructive removal*. Do the
reversible cut immediately; only do the destructive step once you're sure.

> Architecture: `../architecture/multi-tenancy.md`. Workstation design:
> `../plans/2026-06-07-multi-user-workstation-design.md`.

---

## Part A — DevVM Workstation offboarding

Driven by removing the user's entry from `infra/scripts/workstation/roster.yaml`.
`roster_engine.py offboard_plan` computes the staged actions (reversible cut vs the
gated `userdel_archive`, which is **never** auto-applied).

### A1. Reversible cut (revoke access; delete nothing)

1. **Delete the user's entry** from `roster.yaml`; commit + push. *(Leaving the
   line COMMENTED rather than deleting it is fine and preferable — the engine
   treats commented and absent identically, and re-instating the user becomes one
   edit.)*
1b. **Drop them from the Authentik `T3 Users` group** —
   `stacks/authentik/t3-users.tf`, remove both their `data "authentik_user"`
   lookup and their entry in the group's `users` list; commit + push and CI
   applies the stack. Membership lives in HCL today, so the roster removal in
   step 1 does **not** revoke it: without this the user still passes the edge gate
   and only then meets dispatch's 403. Check their other groups while you are
   there (`GET /api/v3/core/users/?search=<login>` → `groups_obj`) — `T3 Users` is
   usually the only devvm door, but `Home Server Admins` reaches the web terminal
   at `terminal.viktorbarzin.me` and is not managed in this repo.
2. **Reconcile** (`sudo /usr/local/bin/t3-provision-users`, or wait for the hourly
   timer). This **regenerates** `/etc/ttyd-user-map` + `/etc/t3-serve/dispatch.json`
   *without* the user → `t3-dispatch` returns **403** for them. *(Automated.)*
   Two things to expect here: the provisioner reads the roster from
   `WORKSTATION_DIR`, i.e. **the admin's own working tree** — a pushed commit does
   nothing until that tree carries it, so sync the file (`git show
   origin/master:scripts/workstation/roster.yaml > …`) or the next hourly run puts
   the user straight back. And `t3-dispatch` re-reads its table on a **60-second
   tick**, so allow a minute: inside that window the removed user gets a **500**
   (their entry is still cached, and the session mint then fails), not a 403.
   Verified 2026-08-17 while cutting `ancamilea`.
3. **Disable their instance + lock login** *(manual today; Phase 7 will fold this into
   the reconcile):*
   ```bash
   sudo systemctl disable --now t3-serve@<os_user>.service
   sudo passwd -l <os_user>
   ```
4. **Revoke git + group access** *(manual)*:
   ```bash
   # legacy secret-bearing group, if they were ever in it
   sudo gpasswd -d <os_user> code-shared
   # drop write access to the infra repo
   curl -X DELETE -H "Authorization: token <admin_pat>" \
     https://forgejo.viktorbarzin.me/api/v1/repos/viktor/infra/collaborators/<forgejo_login>
   # if they were whitelisted for direct master push, remove them from the
   # branch-protection whitelists (PATCH with the remaining usernames)
   curl -X PATCH -H "Authorization: token <admin_pat>" -H 'Content-Type: application/json' \
     https://forgejo.viktorbarzin.me/api/v1/repos/viktor/infra/branch_protections/master \
     -d '{"push_whitelist_usernames":["viktor"],"merge_whitelist_usernames":["viktor"]}'
   # revoke their devvm git PAT (token name: devvm-infra-git; admin PAT may
   # manage other users' tokens — verified 2026-06-10; the CLI has no delete)
   curl -X DELETE -H "Authorization: token <admin_pat>" \
     https://forgejo.viktorbarzin.me/api/v1/users/<forgejo_login>/tokens/devvm-infra-git
   ```
   Note: their already-running sessions keep dropped groups until cycled — restart
   `t3-serve@<os_user>` to enforce immediately.
5. **Verify:** they can no longer reach `t3.viktorbarzin.me` (302 → Authentik, then
   denied once removed from the `T3 Users` group — Part C) and cannot log in. Nothing
   is deleted; re-adding the roster entry + reconcile fully restores them.

### A2. Destructive removal (explicit, gated — NEVER automatic)

Only after the reversible cut and a deliberate decision:
```bash
sudo tar czf /mnt/backup/offboard/<os_user>-$(date +%Y%m%d).tar.gz /home/<os_user>
sudo userdel -r <os_user>          # removes home + mail spool — IRREVERSIBLE
```
Rollback before this step: re-add the roster entry + reconcile. After it: restore
from the archive.

---

## Part B — In-cluster (namespace-owner) offboarding

1. **Reversible cut:** remove the user's Authentik group membership (edge/RBAC blocked)
   and their entry from the Vault `k8s_users` map (`secret/platform`).
2. **Apply:** `scripts/tg apply` the `vault` → `platform` → `woodpecker` stacks (drops the
   RBAC binding, Vault identity/policy, and per-user CI). Their OIDC kubeconfig stops
   authorizing immediately.
3. **Destructive (gated):** deleting their namespace(s) removes all their workloads +
   data — back up first (PVCs, DBs), then delete only on explicit decision.

---

## Part C — Authentik (both surfaces)

Remove the user from the relevant Authentik group(s) — `kubernetes-namespace-owners`
(cluster) and/or `T3 Users` (workstation edge gate). This is the edge revocation; do
it as part of the reversible cut so they're locked out at the front door.

---

## Order of operations

Reversible cut on **all** relevant surfaces first (Authentik group → roster removal +
reconcile → `k8s_users` removal + apply) → verify access is gone → only then the gated
destructive steps (`userdel -r`, namespace deletion), each after its own archive.
