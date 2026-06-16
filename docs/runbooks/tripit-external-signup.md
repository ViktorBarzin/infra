# Runbook — TripIt external user self-signup (email + passkey)

Implements ADR-0020 (tripit repo): people outside the homelab self-register to
TripIt with **email + a passkey** (no password), are auto-tagged into the
**`TripIt External`** Authentik group, and are fenced to `tripit.viktorbarzin.me`
only. Audience: people Viktor knows; open public registration.

> **Safety model.** Containment is two-layered. (1) **Forward-auth apps** — the
> branch in `stacks/authentik/admin-services-restriction.tf` admits `TripIt
> External` to `tripit.viktorbarzin.me` and denies every other `auth="required"`
> host. (2) **OIDC apps** — the branch does NOT cover OIDC (it bypasses
> forward-auth); External users are contained because every sensitive OIDC app
> already requires a trusted group they do not hold (audit below). The no-lockout
> guarantee is that the group is created **empty**, so the new branch matches
> zero existing users on day one.

## OIDC app authorization audit (2026-06-15, read-only)

A parentless `TripIt External` user holds NONE of these groups, so:

| OIDC app | Requires | External user |
|---|---|---|
| Immich, Grafana, Linkwarden, Cloudflare Access | `Home Server Admins` | DENIED ✓ |
| Forgejo | `Task Submitters` / `Forgejo Users` | DENIED ✓ |
| Headscale | `Headscale Users` | DENIED ✓ |
| wrongmove | `Wrongmove Users` | DENIED ✓ |
| **Vault** | **was OPEN** → bound to `Allow Login Users` in Step 3 | DENIED after Step 3 |
| Kubernetes, Kubernetes Dashboard | OPEN | harmless — apiserver rejects OIDC tokens (idle) |
| TripIt App, Public | OPEN | by design (TripIt's own provider / guest) |

Vault's JWT `default` role grants only Vault's built-in `default` policy (token
self-management, cubbyhole — **no** secret access), so the pre-fix exposure was a
near-powerless token; Step 3 closes it anyway.

---

## Pre-flight gates (STOP if any fails)

1. **`TripIt External` is net-new / empty** (no-lockout precondition):
   ```
   kubectl -n authentik exec -i deploy/goauthentik-server -- ak shell <<'PY'
   from authentik.core.models import Group
   g = Group.objects.filter(name="TripIt External").first()
   print("exists:", bool(g), "members:", g.users.count() if g else 0)
   PY
   ```
   Expect `exists: False`. If it exists with members → STOP.
2. **Authentik image pin matches live (B5)** — the policy edit auto-applies the
   whole `authentik` stack; a stale pin re-triggers the 2026-06-10 downgrade
   boot-storm:
   ```
   kubectl -n authentik get deploy -o custom-columns=N:.metadata.name,IMG:.spec.template.spec.containers[0].image
   ```
   Every `goauthentik`/`ak-outpost` image tag MUST equal
   `stacks/authentik/modules/authentik/values.yaml` `global.image.tag`
   (currently `2026.2.4`). If they differ → refresh the pin first.

---

## Step 1 — Terraform (group + fence branch)

Already written on this branch:
- `stacks/authentik/tripit-external.tf` — the empty, parentless group.
- `stacks/authentik/admin-services-restriction.tf` — the prepended fence branch.

**Local plan gate (B4 — CI auto-applies on push with `-auto-approve`, so there is
NO human plan review in the apply path; do it here):**
```
vault login -method=oidc
cd stacks/authentik && ../../scripts/tg plan
```
Confirm the plan is **exactly**:
- `+ authentik_group.tripit_external` (create)
- `~ authentik_policy_expression.admin_services_restriction` (update in place — the
  `expression` body gains ONLY the new branch; every other line byte-identical)
- **`Plan: 1 to add, 1 to change, 0 to destroy.`**

ABORT if the plan shows any destroy/replace, any `authentik_provider_*` /
`authentik_outpost` / `authentik_flow*` / `helm_release`, or any other expression
change.

**Apply** (presence-claim courtesy, then push = apply; land human-watched, B5):
```
~/code/scripts/presence claim stack:authentik --purpose "ADR-0020 TripIt External group + fence branch"
# push the branch to master (this triggers CI tg apply on the authentik stack)
```
Watch: GHA → Woodpecker `default.yml` apply → outpost stays healthy
(`kubectl -n authentik get endpoints ak-outpost-authentik-embedded-outpost` = 2
IPs; an anonymous request to any `auth=required` host still 302s to Authentik).
The branch is inert (empty group) so no access changes yet.

---

## Step 2 — Authentik SMTP (B1, BLOCKER before any flow)

Email verification is the **entire identity boundary** (TripIt trusts the
Authentik email verbatim). Authentik currently has the **default/unconfigured**
transport (`email.host = localhost`), so verification/recovery mail cannot send.

Add to **both** `server.env` and `worker.env` in
`stacks/authentik/modules/authentik/values.yaml` (wire the password from a secret;
the cluster mailserver is what TripIt already relays through —
`mailserver.mailserver.svc`):
```yaml
    - { name: AUTHENTIK_EMAIL__HOST,     value: "mailserver.mailserver.svc" }
    - { name: AUTHENTIK_EMAIL__PORT,     value: "587" }
    - { name: AUTHENTIK_EMAIL__USE_TLS,  value: "true" }
    - { name: AUTHENTIK_EMAIL__FROM,     value: "noreply@viktorbarzin.me" }
    - { name: AUTHENTIK_EMAIL__USERNAME, value: "<relay user>" }      # confirm relay creds
    - { name: AUTHENTIK_EMAIL__PASSWORD, valueFrom: { secretKeyRef: { name: <secret>, key: <key> } } }
```
**Gate:** after apply, Authentik UI → System → Settings (or an Email stage) →
**Send test email**; it must arrive. Then prove enrollment cannot complete for an
address you do NOT control.

---

## Step 3 — Bind Vault → `Allow Login Users` (close the one open OIDC gap)

Authentik UI → Applications → **Vault** → bind an authorization policy requiring
group **`Allow Login Users`** (the base group every real homelab user inherits;
parentless `TripIt External` is excluded). This changes nothing for existing
users and denies External users at the Vault consent step.
Verify: an External test account (Step 6) cannot complete Vault OIDC login.

---

## Step 4 — Build the flows (Authentik UI; UI-managed per ADR split)

All three flows: designation as noted, no password stage.

**Flow `tripit-enrollment`** (Enrollment):
| Order | Stage | Key settings |
|---|---|---|
| 5  | Captcha | reCAPTCHA **v2 checkbox** keys (v3/invisible fail — see `crowdsec-recaptcha-key-type`) |
| 10 | Identification | email only; **no** `password_stage`; `sources` optional |
| 20 | Email (verification) | activate, blocking — **before** user_write |
| 30 | WebAuthn authenticator setup | `user_verification = required`, `resident_key = required` |
| 40 | User Write | **`create_users_group` = `TripIt External`** (the keystone tag); `user_type = external` |
| 50 | User Login | session as default (`weeks=4`) |

**Flow `tripit-login`** (Authentication, passwordless):
Identification (sets `enrollment_flow`/`recovery_flow`) → Authenticator
Validation (`device_classes = [webauthn]`, `user_verification = required`) → User
Login. Prefer routing a passkey-less email to recovery over minting a credential.

**Flow `tripit-recovery`** (Recovery):
Identification (`pretend_user_exists = on`) → Email (recovery link) → WebAuthn
authenticator setup → User Login. Notify the account on recovery + new-passkey.

> Do **NOT** bind the `brute-force-protection` ReputationPolicy to these flows —
> it denies anonymous users (2026-04-06 regression). The Captcha is the bot gate.

---

## Step 5 — Surface "Sign up"

Recommended: a **TripIt-scoped** signup link / share-invite rather than a global
login-screen button (narrower bot surface). Enrollment URL:
`https://authentik.viktorbarzin.me/if/flow/tripit-enrollment/`.

---

## Step 6 — Verification (before/after — "all access keeps working")

Hosts for the matrix (must be real `auth="required"` default-allow hosts, NOT
`auth="app"` apps like immich/nextcloud which bypass the catch-all):
`tripit`, `family`, `hackmd`, `health` (default-allow) + `terminal` (admin-only).

**Before** (capture per user, no redirect-follow; 200=ALLOW, 302→authentik/403=DENY):
```
COOKIE='authentik_session=<paste for this user>'; for H in tripit family hackmd health terminal; do
  printf '%-10s %s\n' "$H" "$(curl -s -o /dev/null -w '%{http_code}' --max-redirs 0 -H "Cookie: $COOKIE" https://$H.viktorbarzin.me/)"; done
```
Representative non-admin: `kadir.tugan@gmail.com` (Wrongmove-only) → tripit/family/hackmd/health ALLOW, terminal DENY. Admin `vbarzin@gmail.com` → all ALLOW.

**After Step 1 apply — regression:** re-run identically; both users' results MUST
be unchanged (diff empty).

**After flows — external smoke test (the security proof):** enrol a throwaway
account via the enrollment URL (email verify + passkey). Confirm it is tagged
`TripIt External`, then with its cookie:
```
for H in tripit family hackmd health terminal frigate; do printf '%-10s %s\n' "$H" \
  "$(curl -s -o /dev/null -w '%{http_code}' --max-redirs 0 -H "Cookie: authentik_session=<external>" https://$H.viktorbarzin.me/)"; done
```
Expect **tripit=200, every other host DENY** (family/hackmd/health were ALLOW for
kadir — the contrast is the fence proof). Then:
- **OIDC containment:** with the external account, attempt OIDC login to Vault,
  Immich, Forgejo, Grafana → each must be DENIED at the app's own login.
- **Auto-provision:** the TripIt `users` row exists (CNPG primary in ns `dbaas`:
  `select id,email from tripit.users where email='<throwaway>'`).
- **Walling-off guard** `AuthentikWallingOffPublicPath` stays green.

**Any 200 on a non-tripit host, or any OIDC app admitting the external account →
ROLLBACK.**

---

## Step 7 — Standing regression probe (recommended)

Add a permanent `TripIt External` identity to the `blackbox-exporter` guard
(`stacks/monitoring/.../authentik_walloff_probe.tf` pattern): assert 200 on
`tripit.viktorbarzin.me` AND DENY on `family.viktorbarzin.me`. This converts the
"branch stays first" and "user_write keeps the keystone tag" invariants into
automated `#security` alerts.

---

## Rollback

Revert the `admin-services-restriction.tf` expression (delete the branch) and push
(= apply); removing a prepended `if g: return …` is behaviour-preserving on
non-members, restoring prior authz. Disable/delete the throwaway external account
(with the branch gone, a tagged account falls into default-allow). The empty group
may stay (harmless). Plan-gate the revert too.

## Operational invariants

- `TripIt External` stays **parentless** (never under `Allow Login Users`).
- The fence branch stays **first** in `admin-services-restriction`.
- **Never** co-assign `TripIt External` to a trusted/internal user.
- The `tripit-enrollment` user_write **`create_users_group`** setting is the
  keystone — re-verify after any flow edit (clearing it makes UNtagged accounts
  that fall into default-allow).
- Authentik SMTP is a live dependency of enrollment + recovery.
