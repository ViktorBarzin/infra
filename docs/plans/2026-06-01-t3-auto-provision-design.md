# t3code per-user auto-provisioning — design

- **Date:** 2026-06-01
- **Status:** design (approved verbally; spec under review)
- **Owner:** Viktor (wizard)
- **Builds on:** the multi-user t3 setup shipped earlier 2026-06-01 (commit `ad9472ab`): Authentik forward-auth on `t3.viktorbarzin.me` → in-cluster nginx `t3-dispatch` → per-OS-user `t3 serve` on devvm (wizard→:3773, emo→:3774).

## Goal

When an onboarded user logs in via Authentik, they land **straight in their own t3 workspace** — no admin pre-creating per-user systemd units / dispatch entries, and no manual t3 pairing. "Full hands-off," scoped to users who are valid OS accounts on devvm.

## Constraints (load-bearing)

1. **t3 is single-owner with no trust-upstream-auth.** No flag/header lets t3 trust an upstream identity and skip its own session (verified against `t3 serve --help` + source: no `trustedHeader`/`REMOTE_USER`/`disableAuth`). So we cannot make t3 zero-auth-after-Authentik the way ttyd is; we **auto-mint + auto-inject** t3's own session instead.
2. **t3 users must be valid OS users on devvm.** No auto-creating Linux accounts. Membership = an `/etc/ttyd-user-map` entry (Authentik username → existing OS user), the same map the `terminal` stack already uses.
3. **File permissions must be enforced by the OS.** Each user's t3 instance (and every agent/process it spawns) must run as that user's uid, so file access is bounded by Unix permissions — not by t3 app logic.
4. **t3's web session is a cookie** (`/api/auth/bootstrap` calls `HttpServerResponse.setCookie`; `t3 auth session list` shows `method: browser-session-cookie`). A proxy can therefore mint and inject it.

## Source of truth

`/etc/ttyd-user-map` (already: `vbarzin=wizard`, `emil.barzin=emo`). One file drives both the terminal and t3. A user with no entry → 403 (no shared fallback). Adding a person = one line here (plus they must already be an Authentik identity + OS account — i.e., your existing onboarding).

## Discovered auth contract

*(Task 1 discovery spike — confirmed from `pingdotgg/t3code` source AND a live mint→bootstrap→cookie round-trip against wizard's instance on `http://127.0.0.1:3773`, 2026-06-01.)*

- **Session cookie name: `t3_session`.**
  - Source: `apps/server/src/auth/utils.ts` — `const SESSION_COOKIE_NAME = "t3_session"`. `resolveSessionCookieName({mode, port})` returns the plain name in **web** mode and `t3_session_<port>` only in **desktop** mode. The server passes `serverConfig.mode`/`serverConfig.port` (`SessionCredentialService.ts`); `t3 serve` runs in `web` mode → plain `t3_session`.
  - Live `Set-Cookie` from the running instance returned `t3_session=...` (no port suffix) → confirms web mode and cross-checks the source.

- **Bootstrap request body: `{ "credential": "<TOKEN>" }`** (single field `credential`, a non-empty trimmed string).
  - Schema: `packages/contracts/src/auth.ts` — `AuthBootstrapInput = Schema.Struct({ credential: TrimmedNonEmptyString })`.
  - Server: `apps/server/src/auth/http.ts` `authBootstrapRouteLayer` (POST `/api/auth/bootstrap`) decodes `AuthBootstrapInput`, calls `exchangeBootstrapCredential(payload.credential, ...)`, then `HttpServerResponse.setCookie(sessions.cookieName, result.sessionToken, { httpOnly: true, path: "/", sameSite: "lax", expires })`.
  - Web UI: `apps/web/src/environments/primary/auth.ts` posts `const payload: AuthBootstrapInput = { credential }` with `credentials: "include"`.
  - A wrong/missing field yields `400 "Invalid bootstrap payload."`.
  - **The `t3 auth pairing create --json` CLI returns the pairing token under the `credential` key** (not `token`/`pairingToken`) — feed that value straight into the bootstrap body's `credential` field.

- **Verified curl** (token redacted):

  ```bash
  TOK=$(sudo -u wizard t3 auth pairing create --base-dir /home/wizard/.t3 --ttl 5m --json | jq -r '.credential')
  curl -s -i -XPOST http://127.0.0.1:3773/api/auth/bootstrap \
    -H 'content-type: application/json' \
    -d "{\"credential\":\"<TOKEN>\"}" | grep -iE 'HTTP/|set-cookie'
  # HTTP/1.1 200 OK
  # set-cookie: t3_session=<JWT>; Path=/; Expires=<+30d>; HttpOnly; SameSite=Lax
  ```

  The session cookie is a signed JWT (`v:1, kind:session, sid, sub, role, method:"browser-session-cookie", iat, exp`), default TTL 30 days. The dispatch service must inject it `HttpOnly; Path=/; SameSite=Lax` to match t3's own behaviour.

- **Constants for the dispatch service:** `T3_COOKIE = "t3_session"`; bootstrap endpoint `POST /api/auth/bootstrap`; body `{"credential": "<pairing-token>"}`; success = `200` + `Set-Cookie: t3_session=...`.

## Components

### 1. Per-user systemd template — `t3-serve@.service` (file-permission enforcement)

Replaces the bespoke `t3-serve.service` + `t3-serve-emo.service` with one template:

```ini
[Service]
User=%i
Group=%i
Environment=HOME=/home/%i
Environment=PATH=/usr/local/bin:/usr/bin:/bin:/home/%i/.local/bin
EnvironmentFile=/etc/t3-serve/%i.env          # T3_PORT=37xx (assigned by reconcile)
WorkingDirectory=/home/%i
ExecStart=/usr/bin/t3 serve --host 0.0.0.0 --port ${T3_PORT} --base-dir /home/%i/.t3
Restart=on-failure
RestartSec=5
```

`User=%i` is the enforcement: `t3-serve@wizard` runs as `wizard`, `t3-serve@emo` as `emo`. t3 and the coding agents it launches inherit the uid, so **emo's instance cannot read/write files wizard's uid owns** unless group/world perms allow. Identical guarantee to the terminal's `sudo -u`. Existing port assignments are preserved (wizard=3773, emo=3774) so live sessions aren't disrupted.

### 2. Reconcile — `t3-provision-users.sh` (data-driven)

A devvm script (systemd timer mirroring the `apply-mbps-caps.timer` pattern, `OnBootSec` + hourly + `Persistent=true`, plus on-demand run during onboarding). For each `authentik_user=os_user` in `/etc/ttyd-user-map`:
- allocate a stable port if unassigned (t3 instances use the 3773+ band: wizard=3773, emo=3774, subsequent users 3775, 3776, …) → write `/etc/t3-serve/<os_user>.env` (`T3_PORT=`). Allocation is sticky (never re-number an existing user).
- `systemctl enable --now t3-serve@<os_user>`.

Sources versioned in `infra/scripts/` (like `apply-mbps-caps.{sh,service,timer}`), deployed to devvm via `scp` (same pattern as the other host scripts).

### 3. Dispatch + auto-pair — small devvm service

Replaces the in-cluster nginx `t3-dispatch` (the session-mint needs `sudo` + local base-dir access, so it must live on devvm anyway; consolidating keeps one source of truth and one place for the privileged logic). Fronted by Traefik(Authentik) → K8s Service+Endpoints → this service on devvm at the fixed `10.0.10.10:3780` (outside the 3773+ instance band).

Per request (Authentik forward-auth has injected a trustworthy `X-authentik-username`):
1. Resolve `X-authentik-username` → OS user via `/etc/ttyd-user-map`. No mapping → **403**.
2. **Has a valid t3 session cookie?** → reverse-proxy (incl. WebSocket upgrade) to `127.0.0.1:<T3_PORT>`. (Steady state — the common path.)
3. **No cookie** (first visit / expired) → auto-pair:
   - `sudo -u <os_user> t3 auth pairing create --base-dir /home/<os_user>/.t3 --ttl 5m --json` → one-time token.
   - exchange it at the instance's `POST /api/auth/bootstrap` → capture the returned `Set-Cookie`.
   - relay that `Set-Cookie` to the browser + `302 /`. Browser now holds the t3 session cookie → next request is the steady-state path. **Login → straight in.**

Implementation: a small reverse proxy that supports WebSocket upgrade (Go `httputil.ReverseProxy`, or Python aiohttp) — chosen at plan time.

### 4. Terraform — `stacks/t3code` shrinks

- Remove the in-cluster nginx `t3-dispatch` (ConfigMap + Deployment + Service).
- Add a `Service` + `Endpoints` → `10.0.10.10:3780` (the devvm dispatch service).
- Ingress stays `auth = "required"` (Authentik) + CrowdSec, `service_name` → the new dispatch Service.

### 5. Sudoers — scoped

A `/etc/sudoers.d/t3-autopair` granting the dispatch service's user **only**:
- `t3 auth pairing create --base-dir /home/*/.t3 *`
- `systemctl start t3-serve@*` (if lazy-start is later wanted; reconcile already enables them)

Modeled on the existing `/etc/sudoers.d/ttyd-users`.

## Data flow

```
phone/browser
  → Cloudflare → Traefik (Authentik forward-auth: 302 to SSO if no session)
  → [X-authentik-username injected]
  → K8s Service/Endpoints → devvm dispatch+autopair :3780
       map username→os_user (unmapped → 403)
       cookie?  yes → proxy → 127.0.0.1:<T3_PORT> (t3-serve@<u>)
                no  → mint (sudo -u) → /api/auth/bootstrap → Set-Cookie → 302 /
```

## Security

- **File isolation:** `User=%i` — OS-enforced, the user's explicit requirement.
- **Identity gate:** Authentik SSO at the edge; `X-authentik-username` is trustworthy (forward-auth overwrites client-supplied values; unauth never reaches the backend).
- **Privilege:** the dispatch service holds a *narrowly scoped* sudoers entry (mint pairing tokens + start `t3-serve@*` only). Minted tokens are 5-min, one-time.
- **Blast radius:** unchanged from today — onboarded users only; no new public surface beyond the existing `t3.viktorbarzin.me`.

## Reboot / persistence

Each instance's state (paired devices + 30-day sessions) is on-disk SQLite (`/home/<u>/.t3/userdata/state.sqlite`); template instances are `enabled`, so a **reboot** restarts them and reloads state — no re-pair, auto-pair fires only once per device. A devvm **rebuild** loses it (`~/.t3` is not backed up). Optional follow-up: add `/home/*/.t3` to the backup set if rebuild-survival is wanted.

## Out of scope

- Native app / `app.t3.codes` (cross-origin bearer clients; blocked by Authentik) — deferred until t3 publishes the native app.
- Auto-creating OS accounts / Authentik identities (onboarding stays manual + deliberate).
- Backing up t3 state (separate decision).
- Lazy stop of idle instances (cheap to keep running at this user count).

## Testing / verification

- Reconcile is idempotent: re-run leaves ports + units stable; adding a map line provisions a new instance.
- `t3-serve@emo` runs as uid `emo` (`ps -o user`), cannot write a wizard-owned file (negative test).
- Dispatch: `X-authentik-username: vbarzin` with no cookie → 302 + `Set-Cookie`; with the cookie → 200 proxied (incl. a WS upgrade). Unmapped → 403.
- Live: a real Authentik login in a browser lands in the correct per-user workspace; WS connects; a second device auto-pairs without manual token entry.

## Rollback

Revert `stacks/t3code` to the nginx `t3-dispatch` (commit `ad9472ab`); the per-user systemd template + reconcile are additive and can be left running or disabled.
