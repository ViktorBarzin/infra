# Workstation Membership v2 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax. This is **infra** work: the engine tasks are real pytest TDD; the host/Authentik tasks "verify" via an idempotent re-run + a smoke check with expected output. Honor the Terraform-only rule for cluster/Authentik changes (`scripts/tg apply`); devvm host scripts are the accepted exception. Claim `host:devvm` before host mutations and `stack:authentik` before applying Authentik.

**Goal:** Make the Authentik `T3 Users` group membership the single source of truth for who gets a devvm workstation account, identified by email; retire `roster.yaml`.

**Architecture:** The provisioner reads `T3 Users` members from the Authentik API (read-only token) instead of `roster.yaml`. A pure engine derives the Linux `os_user` from each member's email (or an `os_user` Authentik attribute override) and produces the same desired-state shape v1 already applies. Workstation access stays fully decoupled from cluster RBAC (`k8s_users` untouched). wizard is special-cased as the admin/owner.

**Tech Stack:** Python (pure engine, pytest) + Bash (provisioner) + `jq`/`curl` (Authentik API) + Terraform (`stacks/authentik`: read-only token, drop HCL members).

**Design:** `infra/docs/plans/2026-06-09-workstation-authentik-membership-design.md`.

---

## File structure

- Modify: `infra/scripts/workstation/roster_engine.py` — add `derive_os_user()` + `roster_from_members()` (pure).
- Modify: `infra/scripts/workstation/test_roster_engine.py` — tests for the two new functions.
- Modify: `infra/scripts/t3-provision-users.sh` — source members from the Authentik API instead of `roster.yaml`.
- Modify: `infra/scripts/workstation/setup-devvm.sh` — drop the read-only Authentik token to `/etc/t3-serve/authentik-token`.
- Create: `infra/stacks/authentik/t3-provision-token.tf` — read-only service account + API token.
- Modify: `infra/stacks/authentik/t3-users.tf` — drop the HCL `users` list (membership becomes Authentik-managed).
- Delete: `infra/scripts/workstation/roster.yaml` (Task 7).
- Modify: `infra/.claude/reference/service-catalog.md`, `infra/docs/architecture/multi-tenancy.md` (Task 7).

---

## Task 1: Engine — `derive_os_user()`

**Files:** Modify `infra/scripts/workstation/roster_engine.py`; Test `infra/scripts/workstation/test_roster_engine.py`

- [ ] **Step 1: Write the failing tests** (append to `test_roster_engine.py`)

```python
# --- derive_os_user: email/attribute -> Linux username (v2) ---

def test_derive_os_user_sanitizes_email_local_part():
    assert eng.derive_os_user("emil.barzin@gmail.com", None) == "emil_barzin"


def test_derive_os_user_attribute_overrides():
    assert eng.derive_os_user("emil.barzin@gmail.com", "emo") == "emo"


def test_derive_os_user_lowercases_and_replaces_unsafe_runs():
    assert eng.derive_os_user("Weird.Name+tag@x.com", None) == "weird_name_tag"


def test_derive_os_user_truncates_to_32():
    long = ("a" * 40) + "@x.com"
    assert eng.derive_os_user(long, None) == "a" * 32


def test_derive_os_user_blank_attribute_is_ignored():
    assert eng.derive_os_user("emil.barzin@gmail.com", "") == "emil_barzin"
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd infra/scripts/workstation && python3 -m pytest test_roster_engine.py -k derive_os_user -q`
Expected: FAIL — `AttributeError: module 'roster_engine' has no attribute 'derive_os_user'`

- [ ] **Step 3: Implement** (add to `roster_engine.py`, after `RosterError`)

```python
import re

_MAX_USERNAME = 32


def derive_os_user(email: str, os_user_attr: str | None) -> str:
    """Linux username for a workstation member: the explicit `os_user` Authentik
    attribute if set, else the email local-part sanitized to a valid username
    (lowercase; runs of non [a-z0-9_-] -> '_'; stripped; <=32 chars)."""
    if os_user_attr:
        return os_user_attr
    local = email.split("@", 1)[0].lower()
    cleaned = re.sub(r"[^a-z0-9_-]+", "_", local).strip("_")
    return cleaned[:_MAX_USERNAME]
```

- [ ] **Step 4: Run to verify they pass**

Run: `python3 -m pytest test_roster_engine.py -k derive_os_user -q`
Expected: PASS (5 passed)

- [ ] **Step 5: Commit**

```bash
cd /home/wizard/code/infra
git add scripts/workstation/roster_engine.py scripts/workstation/test_roster_engine.py
git commit -m "workstation: engine derive_os_user (email/attribute -> Linux username)"
```

---

## Task 2: Engine — `roster_from_members()`

Builds a `Roster` (the v1 type `derive_desired_state` already consumes) from the Authentik member list, so the existing tested derivation is reused unchanged.

**Files:** Modify `roster_engine.py`; Test `test_roster_engine.py`

- [ ] **Step 1: Write the failing tests**

```python
# --- roster_from_members: Authentik members -> Roster (v2) ---

MEMBERS = [
    {"email": "vbarzin@gmail.com", "os_user": "wizard"},
    {"email": "emil.barzin@gmail.com", "os_user": "emo"},
    {"email": "ancaelena98@gmail.com", "os_user": "ancamilea"},
]
ADMINS = {"vbarzin@gmail.com"}


def test_roster_from_members_maps_identity_fields():
    r = eng.roster_from_members(MEMBERS, ADMINS)
    u = r.users["emo"]
    assert u.os_user == "emo"
    assert u.authentik_user == "emil.barzin"      # email local-part = t3-dispatch key
    assert u.k8s_user == "emil.barzin@gmail.com"  # email = identity
    assert u.tier == "power-user"                  # non-admin


def test_roster_from_members_admin_by_email():
    r = eng.roster_from_members(MEMBERS, ADMINS)
    assert r.users["wizard"].tier == "admin"


def test_roster_from_members_derives_os_user_when_no_override():
    r = eng.roster_from_members([{"email": "jane.doe@x.com", "os_user": None}], set())
    assert "jane_doe" in r.users
    assert r.users["jane_doe"].tier == "power-user"


def test_roster_from_members_raises_on_os_user_collision():
    members = [{"email": "a@x.com", "os_user": "dup"}, {"email": "b@y.com", "os_user": "dup"}]
    with pytest.raises(eng.RosterError, match="collision"):
        eng.roster_from_members(members, set())


def test_roster_from_members_reuses_derive_desired_state():
    r = eng.roster_from_members(MEMBERS, ADMINS)
    ds = eng.derive_desired_state(r, {"wizard": 3773, "emo": 3774, "ancamilea": 3775})
    assert ds.dispatch["emil.barzin"] == {"os_user": "emo", "port": 3774}
    assert ds.accounts["wizard"].groups == ("code-shared", "docker", "sudo")
    assert ds.accounts["emo"].groups == ()
```

- [ ] **Step 2: Run to verify they fail**

Run: `python3 -m pytest test_roster_engine.py -k roster_from_members -q`
Expected: FAIL — `AttributeError: ... 'roster_from_members'`

- [ ] **Step 3: Implement** (add to `roster_engine.py`)

```python
def roster_from_members(members: list[dict], admin_emails: set[str]) -> Roster:
    """Build a Roster from Authentik `T3 Users` members. Each member dict has
    `email` and optional `os_user`. tier = admin iff the email is in admin_emails,
    else power-user (a non-admin workstation: no groups, locked clone). Raises on
    an os_user collision (two emails resolving to the same Linux username)."""
    users: dict[str, User] = {}
    for m in members:
        email = m["email"]
        os_user = derive_os_user(email, m.get("os_user"))
        if os_user in users:
            raise RosterError(
                f"os_user collision: {email!r} and {users[os_user].k8s_user!r} "
                f"both resolve to {os_user!r} (set an os_user attribute to disambiguate)"
            )
        tier = "admin" if email in admin_emails else "power-user"
        users[os_user] = User(
            os_user=os_user,
            authentik_user=email.split("@", 1)[0],
            k8s_user=email,
            tier=tier,
            namespaces=(),
        )
    return Roster(users)
```

- [ ] **Step 4: Run the whole suite**

Run: `python3 -m pytest test_roster_engine.py -q && ruff check roster_engine.py test_roster_engine.py`
Expected: PASS (all, incl. the v1 tests) + ruff clean

- [ ] **Step 5: Commit**

```bash
git add scripts/workstation/roster_engine.py scripts/workstation/test_roster_engine.py
git commit -m "workstation: engine roster_from_members (Authentik members -> Roster, reuses derive)"
```

---

## Task 3: Read-only Authentik token (Terraform)

**Files:** Create `infra/stacks/authentik/t3-provision-token.tf`

- [ ] **Step 1: Write the resources** (service account + API token + view permissions)

```hcl
# Read-only service account whose token the devvm provisioner uses to list
# "T3 Users" members. View-only: it can read users + groups, nothing else.
resource "authentik_user" "t3_provision" {
  username = "t3-provision-bot"
  name     = "T3 Provision (read-only)"
  type     = "service_account"
  path     = "service-accounts"
}

resource "authentik_token" "t3_provision" {
  identifier   = "t3-provision-readonly"
  user         = authentik_user.t3_provision.id
  intent       = "api"
  description  = "devvm t3-provision-users: read T3 Users membership"
  retrieve_key = true
}

# Global view permissions for the service account (users + groups read only).
resource "authentik_rbac_permission_user" "t3_provision_view_user" {
  user       = authentik_user.t3_provision.id
  permission = "authentik_core.view_user"
}

resource "authentik_rbac_permission_user" "t3_provision_view_group" {
  user       = authentik_user.t3_provision.id
  permission = "authentik_core.view_group"
}

output "t3_provision_token" {
  value     = authentik_token.t3_provision.key
  sensitive = true
}
```

- [ ] **Step 2: Apply** (claim first)

```bash
~/code/scripts/presence claim stack:authentik --purpose "v2: read-only t3-provision token"
export VAULT_ADDR=https://vault.viktorbarzin.me && vault login -method=oidc
cd /home/wizard/code/infra/stacks/authentik && ../../scripts/tg apply -target=authentik_user.t3_provision -target=authentik_token.t3_provision -target=authentik_rbac_permission_user.t3_provision_view_user -target=authentik_rbac_permission_user.t3_provision_view_group --non-interactive
```
Expected: 4 added. (If the `authentik_rbac_permission_user` resource/permission codename differs in the installed provider, run `../../scripts/tg console` / check the provider docs and adjust the codename; verify in Step 3.)

- [ ] **Step 3: Store the token in Vault + verify it is read-only**

```bash
TOK=$(../../scripts/tg output -raw t3_provision_token)
vault kv patch secret/authentik t3_provision_token="$TOK"
# verify: can LIST T3 Users members...
curl -sk -H "Authorization: Bearer $TOK" "https://authentik.viktorbarzin.me/api/v3/core/users/?groups_by_name=T3%20Users" | jq -r '.results[].email'
# ...but CANNOT write (expect 403):
curl -sk -o /dev/null -w '%{http_code}\n' -X PATCH -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d '{"name":"x"}' "https://authentik.viktorbarzin.me/api/v3/core/users/14/"
```
Expected: the three emails listed; the PATCH returns `403`.

- [ ] **Step 4: Commit**

```bash
git add stacks/authentik/t3-provision-token.tf
git commit -m "workstation: read-only Authentik token for the t3-provision membership query"
```

---

## Task 4: setup-devvm.sh — stage the token for the root provisioner

**Files:** Modify `infra/scripts/workstation/setup-devvm.sh`

- [ ] **Step 1: Add a token-staging step** (after step 6, before the final `log "OK"`). The hourly provisioner runs as root with no Vault token, so `setup-devvm.sh` (run by wizard, who can read Vault) drops it to a root-only file.

```bash
# 8) stage the read-only Authentik token for the root provisioner's membership query.
if command -v vault >/dev/null; then
  export VAULT_ADDR="${VAULT_ADDR:-https://vault.viktorbarzin.me}"
  if tok="$(vault kv get -field=t3_provision_token secret/authentik 2>/dev/null)"; then
    install -m 0600 /dev/stdin /etc/t3-serve/authentik-token <<<"$tok"
    log "staged /etc/t3-serve/authentik-token (read-only Authentik API)"
  else
    log "WARN: t3_provision_token not in Vault -> Authentik membership query will be skipped"
  fi
fi
```

- [ ] **Step 2: Run + verify**

Run: `sudo bash /home/wizard/code/infra/scripts/workstation/setup-devvm.sh 2>&1 | grep -E 'authentik-token|OK'` then `sudo stat -c '%a %U' /etc/t3-serve/authentik-token`
Expected: "staged ... authentik-token" + `OK`; perms `600 root`.

- [ ] **Step 3: Commit**

```bash
git add scripts/workstation/setup-devvm.sh
git commit -m "workstation: setup-devvm.sh stages the read-only Authentik token (root-only)"
```

---

## Task 5: Provisioner — source members from Authentik (replace roster.yaml)

**Files:** Modify `infra/scripts/t3-provision-users.sh`

- [ ] **Step 1: Add a members-fetch + swap the engine call.** Replace the roster-read/derive block. Fetch members from Authentik (best-effort); build the members JSON `[{email, os_user}]`; pass to the engine via a new `--members-json` mode on `derive`.

First extend the engine CLI (`roster_engine.py` `_main`): add `derive-members` that reads a members JSON + ports JSON + admin emails and emits the same desired-state JSON.

```python
# in _main(), add a subparser:
    pm = sub.add_parser("derive-members", help="desired state from an Authentik member list")
    pm.add_argument("--members-json", required=True)
    pm.add_argument("--ports-json", required=True)
    pm.add_argument("--admin-emails", default="", help="comma-separated admin emails")
    # ...in the dispatch:
    if args.cmd == "derive-members":
        with open(args.members_json, encoding="utf-8") as fh:
            members = json.load(fh)
        with open(args.ports_json, encoding="utf-8") as fh:
            ports = json.load(fh)
        admins = {e for e in args.admin_emails.split(",") if e}
        ds = derive_desired_state(roster_from_members(members, admins), ports)
        json.dump(_desired_state_to_dict(ds), sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0
```

In `t3-provision-users.sh`, replace the `ROSTER`/validate/derive section with:

```bash
AUTHENTIK_URL="${AUTHENTIK_URL:-https://authentik.viktorbarzin.me}"
TOKEN_FILE="${TOKEN_FILE:-/etc/t3-serve/authentik-token}"
T3_GROUP="${T3_GROUP:-T3 Users}"
ADMIN_EMAILS="${WORKSTATION_ADMIN_EMAILS:-vbarzin@gmail.com}"

members_file="$(mktemp)"; trap 'rm -f "$ports_file" "$members_file" "${desired_file:-}"' EXIT
if [[ -r "$TOKEN_FILE" ]]; then
  tok="$(cat "$TOKEN_FILE")"
  if curl -sf -H "Authorization: Bearer $tok" --get \
        --data-urlencode "groups_by_name=$T3_GROUP" \
        "$AUTHENTIK_URL/api/v3/core/users/" \
      | jq -c '[.results[] | select(.is_active) | {email: .email, os_user: (.attributes.os_user // null)}]' \
      > "$members_file" && [[ -s "$members_file" ]]; then
    :
  else
    log "WARN: Authentik membership query failed -> no membership change this run"; echo '[]' > "$members_file"
    SKIP_RECONCILE=1
  fi
else
  log "WARN: $TOKEN_FILE absent -> no membership change this run"; echo '[]' > "$members_file"; SKIP_RECONCILE=1
fi

if [[ "${SKIP_RECONCILE:-0}" == 1 ]]; then log "reconcile skipped (no Authentik membership)"; exit 0; fi

desired_file="$(mktemp)"
python3 "$ENGINE" derive-members --members-json "$members_file" --ports-json "$ports_file" --admin-emails "$ADMIN_EMAILS" > "$desired_file"
jq -e . "$desired_file" >/dev/null || { echo "[t3-provision] derive-members produced invalid JSON" >&2; exit 1; }
```

(Keep steps 4-6 of the existing script — accounts/groups/clone/kubeconfig, .env/enable, regen map/dispatch — unchanged; they consume `$desired_file`.)

- [ ] **Step 2: shellcheck + DRY_RUN** (with the staged token present)

Run: `cd /home/wizard/code/infra/scripts && shellcheck -S warning t3-provision-users.sh && sudo DRY_RUN=1 bash t3-provision-users.sh 2>&1 | grep -iE 'clone|kubeconfig|reconcile|WARN'`
Expected: shellcheck clean; dry-run lists the current members, no account creations (all exist), "reconcile complete (DRY-RUN)".

- [ ] **Step 3: Real run + verify it reproduces current state**

Run: `sudo jq -S . /etc/t3-serve/dispatch.json > /tmp/d1; sudo DRY_RUN=0 bash t3-provision-users.sh >/dev/null 2>&1; sudo jq -S . /etc/t3-serve/dispatch.json > /tmp/d2; diff /tmp/d1 /tmp/d2 && echo SAME; id -nG emo`
Expected: `SAME` (dispatch content unchanged); emo groups unchanged. Redeploy: `sudo install -m0755 t3-provision-users.sh /usr/local/bin/t3-provision-users`.

- [ ] **Step 4: Commit**

```bash
git add scripts/t3-provision-users.sh scripts/workstation/roster_engine.py scripts/workstation/test_roster_engine.py
git commit -m "workstation: provisioner sources members from Authentik T3 Users (replaces roster.yaml)"
```

---

## Task 6: Authentik — Authentik-managed membership + legacy os_user attributes

**Files:** Modify `infra/stacks/authentik/t3-users.tf`; set user attributes via API.

- [ ] **Step 1: Set the legacy os_user attributes** (the 3 existing accounts don't derive from their emails). Read-merge-write so existing attributes are preserved (Authentik PATCH replaces the `attributes` dict).

```bash
export VAULT_ADDR=https://vault.viktorbarzin.me
TOK=$(vault kv get -field=tf_api_token secret/authentik)
A=https://authentik.viktorbarzin.me/api/v3
set_os_user() {  # $1=username  $2=os_user
  local pk attrs
  pk=$(curl -sk -H "Authorization: Bearer $TOK" "$A/core/users/?username=$1" | jq '.results[0].pk')
  attrs=$(curl -sk -H "Authorization: Bearer $TOK" "$A/core/users/$pk/" | jq -c --arg o "$2" '.attributes + {os_user:$o}')
  curl -sk -X PATCH -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
    -d "{\"attributes\":$attrs}" "$A/core/users/$pk/" | jq -r '.username + " os_user=" + .attributes.os_user'
}
set_os_user "vbarzin@gmail.com" wizard
set_os_user "emil.barzin@gmail.com" emo
set_os_user "ancaelena98@gmail.com" ancamilea
```
Expected: three lines confirming `os_user=` each.

- [ ] **Step 2: Drop the HCL `users` list** so membership is Authentik-managed. Edit `t3-users.tf`: remove the `users = [...]` argument from `resource "authentik_group" "t3_users"` (keep the `data "authentik_user"` lookups removed too if now unused). Leave the group resource (name only).

```hcl
resource "authentik_group" "t3_users" {
  name = "T3 Users"
  # Membership is managed in Authentik (UI/API), not Terraform — the devvm
  # provisioner reconciles workstation accounts from this group's members.
}
```

- [ ] **Step 3: Apply + verify members unchanged**

```bash
cd /home/wizard/code/infra/stacks/authentik && ../../scripts/tg apply -target=authentik_group.t3_users --non-interactive
curl -sk -H "Authorization: Bearer $TOK" "$A/core/groups/?search=T3%20Users" | jq -r '.results[0].users_obj[].username'
```
Expected: apply shows the group updated (no member change / the `users` field no longer managed); the 3 members still listed.

- [ ] **Step 4: Commit**

```bash
git add stacks/authentik/t3-users.tf
git commit -m "workstation: T3 Users membership is Authentik-managed (drop HCL member list)"
```

---

## Task 7: Retire roster.yaml + update docs

**Files:** Delete `infra/scripts/workstation/roster.yaml`; modify `service-catalog.md`, `multi-tenancy.md`.

- [ ] **Step 1: Confirm nothing reads roster.yaml anymore**

Run: `grep -rn 'roster.yaml\|roster_engine.*roster\b' /home/wizard/code/infra/scripts /home/wizard/code/infra/docs | grep -v 'load_roster\|test_\|design.md\|-plan.md'`
Expected: no live references in the provisioner (the engine keeps `load_roster` for tests, that's fine).

- [ ] **Step 2: Delete it + update the service-catalog t3code row** — change "Source of truth = roster.yaml" to "Source of truth = the Authentik `T3 Users` group (members → accounts via the read-only API token); `os_user` from the email or a per-user `os_user` attribute". Update the multi-tenancy Workstation section's "single source of truth" line likewise.

```bash
git rm scripts/workstation/roster.yaml
# (edit service-catalog.md + multi-tenancy.md per above)
```

- [ ] **Step 3: Commit**

```bash
git add scripts/workstation/roster.yaml .claude/reference/service-catalog.md docs/architecture/multi-tenancy.md
git commit -m "workstation: retire roster.yaml — Authentik T3 Users group is the membership SSoT"
```

---

## Task 8: End-to-end smoke (add + remove a throwaway member)

- [ ] **Step 1: Add a throwaway test member** to `T3 Users` in Authentik (a test user, or temporarily add an existing one), set no `os_user` attribute. Run `sudo /usr/local/bin/t3-provision-users` and confirm an account `<derived>` is created (`id <derived>`), with a locked `~/code` (secret file shows `GITCRYPT`) and `~/.kube/config`.
- [ ] **Step 2: Remove the test member** from the group; run the reconcile; confirm they drop out of `/etc/ttyd-user-map` + `dispatch.json` (the reversible cut). Leave `userdel` to the gated offboarding runbook.
- [ ] **Step 3: Verify the 3 real users are intact** — `id emo` (groups unchanged), emo/ancamilea/wizard still in `dispatch.json`, their `t3-serve@` active, emo's locked clone + ancamilea's intact.

---

## Self-review

- **Spec coverage:** Authentik-as-SSoT (Tasks 5,6) · email identity + os_user derive/override (Tasks 1,6) · provisioner reads the API (Task 5) · read-only token for the root timer (Tasks 3,4) · roster.yaml retires (Task 7) · k8s_users/cluster untouched (no task touches it) · wizard special-cased (admin_emails, Task 2). All covered.
- **Type consistency:** `derive_os_user(email, os_user_attr)` and `roster_from_members(members, admin_emails)` used consistently; `members` dicts are `{email, os_user}`; reuses the existing `User`/`Roster`/`derive_desired_state`/`DesiredState`.
- **apiserver-OIDC:** out of scope here (kubectl auth method only) — flagged in the design; the generic kubeconfig task is unchanged from v1.
- **Open risk:** the `authentik_rbac_permission_user` resource name / permission codenames may differ in the installed provider version (Task 3) — Step 3 verifies read-works/write-403 and says to adjust if needed.
