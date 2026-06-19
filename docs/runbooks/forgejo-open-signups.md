# Runbook: Forgejo open self-service signups

Last updated: 2026-06-19

`forgejo.viktorbarzin.me` allows **open native self-registration** (anyone can
create a local Forgejo account from the web form), gated against bots by two
layers:

1. **Cloudflare Turnstile** captcha on the registration form.
2. **Mandatory email confirmation** — a new account stays inactive until the
   user clicks an activation link emailed to the address they registered with.

Two external login sources also work alongside local accounts: the pre-existing
**Authentik OAuth2 login** (SSO) and **Sign in with GitHub** (see the GitHub
section below). Opening local signups was additive — it did not touch SSO.

Most of this is Terraform-managed in `stacks/forgejo/`. The one exception is the
OAuth2 login *sources* (Authentik, GitHub), which live in Forgejo's own DB and
are added via `forgejo admin auth` — there is no clean Terraform resource for
them (their secrets are mirrored to Vault for recovery).

## What is configured (and where)

All on the `kubernetes_deployment.forgejo` container env in
`stacks/forgejo/main.tf` (Forgejo reads `app.ini` keys from `FORGEJO__<section>__<KEY>`
env vars):

| Setting | Value | Effect |
|---|---|---|
| `service.DISABLE_REGISTRATION` | `false` | Registration is enabled |
| `service.ALLOW_ONLY_EXTERNAL_REGISTRATION` | `false` | Native local sign-up allowed (was `true` = OAuth-only) |
| `service.ENABLE_CAPTCHA` | `true` | Captcha required on the signup form |
| `service.CAPTCHA_TYPE` | `cfturnstile` | Cloudflare Turnstile |
| `service.CF_TURNSTILE_SITEKEY` | widget id | Public; rendered in the page |
| `service.CF_TURNSTILE_SECRET` | from `forgejo-turnstile` Secret | Server-side verification |
| `service.REGISTER_EMAIL_CONFIRM` | `true` | Account inactive until email is confirmed |
| `mailer.*` | see below | Sends the activation email |
| `oauth2_client.ENABLE_AUTO_REGISTRATION` | `true` | First GitHub (OAuth2) sign-in auto-creates the account |

Captcha guards **registration only** — `REQUIRE_CAPTCHA_FOR_LOGIN` is left at the
default `false`, so existing users are not captcha'd on every login.

## Cloudflare Turnstile widget — `turnstile.tf`

- The widget is a Terraform resource: `cloudflare_turnstile_widget.forgejo_signup`
  (mode `managed`, domain `forgejo.viktorbarzin.me`), created with the CF Global
  API Key already wired in `cloudflare_provider.tf`. The account id is resolved
  via `data.cloudflare_accounts`.
- `.id` is the **public sitekey** (passed as a plain env value). `.secret` is the
  **secret key**, stored in the `forgejo-turnstile` K8s Secret and injected via
  `secret_key_ref`. The secret also lives in TF state (Tier-1 PG, encrypted at
  rest) — same trust level as the CF API key already in state.
- Forgejo is **non-proxied** (direct A record to Traefik), but Turnstile is a
  client-side JS widget served from `challenges.cloudflare.com`, so proxy status
  is irrelevant — the widget works regardless.

**Rotate the widget secret** (e.g. if it leaks):
```
cd stacks/forgejo && vault login -method=oidc
../../scripts/tg apply --non-interactive -replace=cloudflare_turnstile_widget.forgejo_signup
```
This mints a new sitekey+secret, updates the `forgejo-turnstile` Secret, and (via
the Reloader annotation) rolls the Forgejo pod. Verify the new sitekey appears in
the `/user/sign_up` HTML afterwards.

## Mailer — `email-secret.tf` + `[mailer]` env

- Forgejo sends as **`noreply@viktorbarzin.me`** via **`mail.viktorbarzin.me:587`**
  with `PROTOCOL=smtp+starttls`. This reuses the same mailserver SASL account
  Authentik uses (`stacks/authentik/email-secret.tf`) — one credential, one
  rotation point.
- **The host MUST be `mail.viktorbarzin.me`, not `mailserver.mailserver.svc`**:
  the mailserver serves the `*.viktorbarzin.me` wildcard cert, which does not
  cover the `.svc` DNS name, so STARTTLS cert verification would fail.
  `mail.viktorbarzin.me` resolves in-cluster (→ `10.0.20.1`) and matches the cert.
- The password is synced from Vault `secret/authentik` → `smtp_password` by the
  `forgejo-email` ExternalSecret (ESO `ClusterSecretStore vault-kv`) into the
  `forgejo-email` K8s Secret (key `PASSWD`), referenced by `FORGEJO__mailer__PASSWD`.
- The deployment carries `reloader.stakater.com/auto: "true"`, so a rotation of
  either secret rolls the pod automatically.

## GitHub sign-in (OAuth2 source)

People can **sign up / sign in with GitHub** — a second Forgejo OAuth2 source
alongside Authentik.

- **Source** (Forgejo DB, *not* Terraform — added via CLI, same as Authentik):
  ```
  forgejo admin auth add-oauth --name github --provider github --key <client-id> --secret <client-secret>
  ```
  The source **name must stay `github`** — it is part of the callback URL
  (`/user/oauth2/github/callback`) registered on the GitHub side, so renaming it
  breaks the callback. `forgejo admin auth list` shows it (ID 2).
- **GitHub OAuth App**: a classic OAuth App under the ViktorBarzin GitHub account
  (Settings → Developer settings → OAuth Apps). Homepage
  `https://forgejo.viktorbarzin.me`, callback
  `https://forgejo.viktorbarzin.me/user/oauth2/github/callback`. GitHub has **no
  API to create OAuth Apps** — creating it is a browser-only step.
- **Credentials**: Vault `secret/viktor` → `forgejo_github_oauth_client_id` /
  `forgejo_github_oauth_client_secret` (kept for recovery; the live values are in
  Forgejo's DB).
- **Auto-registration**: `FORGEJO__oauth2_client__ENABLE_AUTO_REGISTRATION=true`
  (`main.tf`) makes a first GitHub login create the account directly. The GitHub
  identity is the trust gate for this path — the Turnstile captcha + email
  confirmation only apply to the **native** signup form, not OAuth.

**Rotate the GitHub client secret** — generate a new one in the GitHub OAuth App, then:
```
vault kv patch secret/viktor forgejo_github_oauth_client_secret=<new>
POD=$(kubectl -n forgejo get pod -l app=forgejo -o jsonpath='{.items[0].metadata.name}')
kubectl -n forgejo exec "$POD" -- su-exec git forgejo admin auth update-oauth --id 2 --secret <new>
```
(Source id from `forgejo admin auth list`.)

**Recreate after a Forgejo DB loss**: the source is not in Terraform, so after a
from-scratch restore, re-run the `add-oauth` command above with the Vault creds.

## Re-closing / tightening signups

Edit `stacks/forgejo/main.tf` and `scripts/tg apply` (or commit + push — CI
applies):

- **OAuth-only again** (revert this change): set
  `FORGEJO__service__ALLOW_ONLY_EXTERNAL_REGISTRATION` back to `"true"`.
- **No new accounts at all** (admins create them): set
  `FORGEJO__service__DISABLE_REGISTRATION` to `"true"`.
- **Require admin approval per signup** (strongest, instead of email confirm):
  set `REGISTER_MANUAL_CONFIRM=true` **and** `REGISTER_EMAIL_CONFIRM=false`
  (Forgejo makes the two mutually exclusive). New accounts then queue under Site
  Administration → Identity & Access → Accounts until an admin activates them.

## Handling spam / abuse accounts

A signup that clears Turnstile + email confirmation is still a real, low-privilege
Forgejo user. To deal with abuse:
- **Ban/delete** via Site Administration → Identity & Access → Accounts, or
  `forgejo admin user delete --username <name>` inside the pod
  (`kubectl -n forgejo exec deploy/forgejo -- forgejo admin user ...`).
- New users get Forgejo defaults (they can create repos/orgs). If abuse warrants,
  tighten with `[service].DEFAULT_ALLOW_CREATE_ORGANIZATION=false` and/or
  `[repository].MAX_CREATION_LIMIT` (add as env vars; out of scope for the initial
  open-signups change).

## Operational notes

- The Forgejo deployment is **single-replica with `Recreate` strategy**, so any
  config apply briefly restarts the pod (git remote + OCI registry unavailable for
  a few seconds). Expected, not an incident.
- The signup page is **not** behind Cloudflare's bot-fight (Forgejo is
  non-proxied) — Turnstile + email confirmation are the bot gate. CrowdSec +
  Traefik rate limiting still front the host.

## Verify it's working

```
POD=$(kubectl -n forgejo get pod -l app=forgejo -o jsonpath='{.items[0].metadata.name}')
# Env present:
kubectl -n forgejo exec "$POD" -- env | grep -E 'ALLOW_ONLY_EXTERNAL|ENABLE_CAPTCHA|CAPTCHA_TYPE|CF_TURNSTILE_SITEKEY|REGISTER_EMAIL_CONFIRM|mailer__ENABLED'
# Turnstile widget rendered on the form:
kubectl -n forgejo exec "$POD" -- wget -qO- http://localhost:3000/user/sign_up | grep -oE 'cf-turnstile|data-sitekey="[^"]*"'
# Secrets healthy:
kubectl -n forgejo get externalsecret forgejo-email
kubectl -n forgejo get secret forgejo-email forgejo-turnstile
```
A full real-world check is to register a throwaway account and confirm the
activation email arrives. The mailer transport (server/port/cert/cred) is shared
with Authentik, which is already in production for external user enrollment.
