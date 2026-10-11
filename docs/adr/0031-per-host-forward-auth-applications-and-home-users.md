# ADR-0031: Per-host forward-auth applications for non-admin hosts, and a Home Users group

- Status: accepted
- Date: 2026-10-11
- Supersedes: ADR-0023 (forward-auth authorization via a generated host→groups table)
- Related: `stacks/authentik/forward-auth-apps.tf`, `stacks/authentik/home-users.tf`, `scripts/check-allowed-groups.py`

## Context

Viktor asked for an Authentik group for the household that reaches the services behind Authentik that hold nothing sensitive.

Every `auth = "required"` ingress goes through one Traefik forward-auth middleware, answered by one `forward_domain` provider, the "Domain wide catch all" application. ADR-0023 added a per-host table to an expression policy on that application, generated from each ingress's `allowed_groups`. On 2026-09-19 we found the table could not enforce anything. Domain-level forward auth evaluates policy once, at the OAuth authorize step on `authentik.viktorbarzin.me`, where the host is empty, and the session cookie then covers every subdomain. The authentik docs say the same: domain-level forward auth "cannot restrict individual applications to different users with separate application-level policies". An account in no admin group was served admin-only hosts, and the July verification had missed it because the policy-test API supplies a host that real traffic never does.

The fix that day made the catch-all admin-only (its only binding is Home Server Admins) and the expression return False. That closed the exposure, and it also meant every non-admin grant written in `allowed_groups` (pages for Pages Readers, t3, chrome and chrome-fleet, proxy, the kubernetes groups on k8s) was refused. The note in the policy file named the next step: per-application `forward_single` providers. This ADR is that step.

What we checked before deciding (authentik 2026.8.3, where forward auth runs in the Rust inline outpost inside the goauthentik-server pods):

- The outpost looks up an application by exact external host before it falls back to a `forward_domain` provider's cookie domain (`src/outpost/proxy/mod.rs`, `lookup_app`). A `forward_single` provider for a host therefore takes that host away from the catch-all.
- Each provider names and signs its own cookie, host-only for `forward_single`, so a session on one host opens no other host.
- The login callback returns to `<host>/outpost.goauthentik.io/callback` through the same middleware, so the existing middleware serves both kinds of provider. A host qualifies only if its `/` route goes through forward auth.
- An application with no bindings admits any authenticated user, including the silent `guest` identity.

## Decision

1. **Hosts that a non-admin group may reach get their own `forward_single` provider and application**, generated in `stacks/authentik` from `forward-auth-apps.json` (host → groups). Each application binds its listed groups plus Home Server Admins, with `policy_engine_mode = "any"`. Every other forward-auth host stays on the catch-all, admin-only.
2. **The JSON is static, and the ingress keeps `allowed_groups`.** `scripts/check-allowed-groups.py` fails a stack before plan if the two disagree, and flags JSON entries with no ingress. We chose a static list over generating from live ingress annotations because the authentik stack applies before app stacks in CI, so a generated list lags one apply, and a removed grant would stay enforced for one cycle.
3. **The embedded outpost `depends_on` every per-host binding**, so a provider is served only after its bindings exist, and on removal it is withdrawn before its bindings go.
4. **The expression policy `admin-services-restriction` and its annotation scan are deleted.** Deleting the policy removed its UI-managed binding on the catch-all.
5. **A `Home Users` group** (Valentina, Anca, Gheorghe) is declared with its members in `home-users.tf`. It replaces Pages Readers, TripIt Users and F1 Users, which held the same people for one app each. Headscale Users, Wrongmove Users and Proxy Users stay separate because they include people outside the household.
6. **Home Users reaches**, each opted in explicitly: calibre, stacks, book-search, audiblez, ebook2audiobook, draw, city-guesser, speedtest, yt, yt-highlights, trek, family, qbittorrent, listenarr, torrserver and pages (forward auth), and Immich, Linkwarden, TripIt and F1 Stream (OIDC bindings). The Uptime Kuma status page was already public.
7. **f1 and tripit are not per-host applications.** Forward auth there covers only `/admin/login` and `/metrics`, and their `/` is public, so a per-host callback would never reach the outpost. Their members sign in through their own OIDC applications.

## Consequences

- A new service is admin-only until someone adds it to both its ingress and the JSON. That is the intended default.
- Access is checked once per host, at that host's login. Removing someone from a group takes effect when their session ends, after up to 4 weeks, unless their sessions are revoked in the Authentik admin UI. `home-users.tf` says so next to the member list.
- Admins now log in once per per-host application, in addition to the catch-all. Each extra login is a silent redirect while the authentik session is valid.
- The authfix self-heal for a stale-state 400 covers only the authentik host's callback, not the per-host callbacks.
- Grafana, HackMD, networking-toolbox and dashy stay admin-only. Grafana Viewers can read the finance dashboards and query any datasource, and the other two can make requests into the cluster and the LAN. The owner accepted these risks on hosts that are in: book-search can delete torrents and spend the MAM account, yt downloads any URL to shared storage, qBittorrent runs from the home IP and can run commands on completion, and Listenarr exposes its settings.
- `family` and `torrserver` stay behind `home-lans-only`, so members reach them from home or over the VPN.

## Open questions

- The per-host providers rely on authentik filling in the default scope mappings on create (they carry the `X-authentik-groups` header). This was read from source, and the first rollout is where it gets confirmed.
