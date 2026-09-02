# proxy

Per-user **persistent remote browsers**, each surfing from a country of your
choice through NordVPN. Log in at `proxy.viktorbarzin.me`, pick a country, and
get your own Chrome — streamed via **neko** (WebRTC: hardware-H.264 video on the
T4 plus Opus audio, with live resolution changes) — whose traffic egresses
from a NordVPN exit in that country. Your logins are saved in an encrypted
profile across visits. Chrome opens **maximised (windowed)**, so the address bar
and tabs are always reachable — never fullscreen-by-default.

The same stack also serves **cluster VPN egress**: any workload can send its
outbound HTTP through the same NordVPN tunnel by setting one environment
variable — see "Cluster VPN egress" below.

Design + rationale: `docs/plans/2026-07-25-proxy-scale-design.md`
(scale-up) · `docs/plans/2026-07-24-proxy-nordvpn-design.md` (original) ·
`docs/plans/2026-08-16-cluster-vpn-egress-service-design.md` (egress service).

## Architecture — shared per-country gateways, per-user browsers, one permanent egress gateway

```
user ─▶ proxy.viktorbarzin.me/ (Authentik login)  ─▶ proxy-broker (per-user API)
                                                        │ POST /api/browser {country}
                                                        ▼
                    per COUNTRY (shared, ≤ MAX_COUNTRIES-RESERVED = 6 concurrent):
                      Pod  proxy-gw-<i>   [ gluetun(NordVPN,country) + wg-server ]
                      Svc  proxy-gw-<i>   (ClusterIP :51820/UDP — stable WG endpoint)
                      CM   proxy-gw-<i>-peers   (broker-maintained; sidecar reconciles wg0)

                    index 1 is PERMANENT (declared in Terraform, always-on, UK):
                      Deploy proxy-gw-1  [ same pod shape + HTTPPROXY :8888 + SOCKS5 :1080 ]
                      Svc    proxy-gw-1        (:51820/UDP — browsers, as above)
                      Svc    proxy-egress-uk   (:8888 + :1080 TCP — cluster workloads)

                    per USER (persistent):
                      PVC  proxy-profile-<user>  (encrypted, RWO — the Chromium profile)
                      Pod  proxy-br-<user>   [ gluetun(custom-WG → gateway) + neko+Chromium ]
                      Svc/Ing  proxy-br-<user>   proxy-<token>.viktorbarzin.me (auth=none, token-gated)
user ─▶ proxy-<token>.viktorbarzin.me ─▶ neko UI + WS signaling (HTTP)
user ◀▶ turn.viktorbarzin.me (coturn relay) ◀▶ neko WebRTC media (H.264 + Opus)

any pod ─▶ proxy-egress-uk.proxy.svc:8888  (HTTPS_PROXY / ALL_PROXY)
           proxy-egress-uk.proxy.svc:1080  (socks5h://)
              └─▶ gluetun re-originates the request out tun0 (UK exit)
```

The **NordVPN ~10-tunnel account cap therefore limits concurrent COUNTRIES**
(`pool.MAX_COUNTRIES - RESERVED_SLOTS`, default 8-2=6), **not users** — many
browsers share one country's single tunnel. One of those six is now permanently
the UK (see "Cluster VPN egress"), leaving five user-selectable. Proven
end-to-end by Spike G (memory #10214): a browser pod egresses NordVPN with no
home-IP leak.

- **Broker** (`files/broker/`, pure-stdlib `python:3.12-slim`, ConfigMap-mounted —
  no custom image/GHA). `broker.py` serves the UI + JSON API and orchestrates
  gateways + browsers; `pool.py` (gateway-pool decisions) and `wgkeys.py`
  (X25519 WireGuard keygen) are pure + **unit-tested** (`*_test.py`, 38 tests).
- **Gateway pod** = `gluetun` (NordVPN WireGuard) + a `wg-server` sidecar
  (linuxserver/wireguard) that, once `tun0` is up, brings up `wg0`, adds the
  forwarding rules (`ip_forward` via pod `securityContext.sysctls` + MASQUERADE
  + FORWARD-accept + the gluetun return-path `ip rule ... lookup main pref 90`)
  and **reconciles peers** from the mounted `proxy-gw-<i>-peers` ConfigMap every
  10s (survives restarts, no `kubectl exec`). Pinned to `node2-5` (the workers
  where `net.ipv4.ip_forward` is kubelet-allowed) via the
  `proxy.viktorbarzin.me/gateway=true` node label.
- **Browser pod** = `gluetun` in **custom-WireGuard** mode dialling its country
  gateway's Service ClusterIP (leak-proof: gluetun's kill-switch) + a single
  **neko** container (upstream `ghcr.io/m1k1o/neko/nvidia-chromium`,
  DIGEST-pinned via `NEKO_IMAGE` in `main.tf`) serving its UI + signaling
  WebSocket on HTTP `:8080`. neko v3 streams **hardware H.264** (NVENC on the T4,
  `nvh264enc` at 8 Mbps) plus **Opus audio** over WebRTC, at
  `NEKO_SCREEN=2560x1440@30` by default — an admin can change the resolution live
  from the UI. GPU scheduling: `nvidia.com/gpu=1` + a `viktorbarzin.me/gpumem`
  slot (`GPUMEM_MIB`, ~384) pins the pod to node1, and `GPU_BROWSERS_MAX` caps
  concurrent GPU browsers (1 today — the T4 budget is full). An `xorg-glx-fix`
  initContainer disables GLX in the stock image's `xorg.conf`; the GPU is needed
  for encode, not render.

  **Media relays through coturn** (`10.0.20.200` in-cluster for neko's own
  allocation, `turn.viktorbarzin.me` + STUN for the viewer's browser), with
  ephemeral TURN-REST credentials minted per browser by the broker from Vault
  `secret/coturn`. WebRTC media is not HTTP, so it cannot ride the shared Traefik
  `:443` — the relay is what makes a per-user browser reachable from anywhere.

  Each browser still gets its **own subdomain** `proxy-<token>.viktorbarzin.me`,
  which keeps neko's signaling WebSocket and assets at their own root; the token
  doubles as neko's admin password, so `?usr=proxy&pwd=<token>` auto-logs in.
  Chromium is neko's single app under openbox; the profile persists on the PVC.
  One per user, keyed on the `X-authentik-username` identity header.

  This replaced KasmVNC (which itself replaced noVNC) in infra#81: KasmVNC 1.3.3
  has no H.264/WebCodecs support and its Xvnc build carries no audio path at all,
  so video topped out around 13-17 fps of WebP tiles and audio was not reachable
  over the HTTP-only ingress. `files/kasmvnc/` remains in the tree as the
  previous generation.

## Cluster VPN egress — any workload, one env var

Any pod in the cluster can reach the internet through the NordVPN tunnel by
pointing its HTTP client at the permanent gateway's proxy listeners. The
consumer needs **no capabilities, no sidecar, no shared netns and no new
tunnel**: gluetun's userspace HTTP and SOCKS5 listeners run *inside* the tunnel
netns and **re-originate** the request out `tun0`. That is local origination
rather than packet forwarding, so none of the forwarding machinery the browser
path needs (unsafe sysctl, MASQUERADE, FORWARD rules, return-path routing)
applies to it.

Design + rationale: `docs/plans/2026-08-16-cluster-vpn-egress-service-design.md`.

### Consumer contract

```yaml
env:
  - name: HTTPS_PROXY
    value: http://proxy-egress-uk.proxy.svc.cluster.local:8888
  - name: HTTP_PROXY
    value: http://proxy-egress-uk.proxy.svc.cluster.local:8888
  # Keep cluster-internal traffic off the tunnel.
  - name: NO_PROXY
    value: .svc.cluster.local,.cluster.local,localhost,127.0.0.1
```

- **SOCKS5 is on the same Service at `:1080`.** Use
  `socks5h://proxy-egress-uk.proxy.svc.cluster.local:1080` — the `h` is what
  makes the **proxy** resolve the hostname. Plain `socks5://` resolves locally
  through CoreDNS, which both leaks the lookup and can return home-geo answers.
- **`ALL_PROXY` may be all you need.** Some clients map it to every scheme in
  one variable: verified for `httpx` 0.28.1, which turns it into a single
  `all://` mount covering http and https. Setting it to `""` produces no proxy
  mount at all, so such a consumer flips on and off by editing a value rather
  than adding and removing an env block.
- **Set `NO_PROXY`.** Without it, in-cluster calls take a round trip through the
  UK and arrive at cluster Services from an unexpected source address. Suffix
  entries do match multi-label hosts (`.svc.cluster.local` covers
  `flaresolverr.servarr.svc.cluster.local`), but they match **FQDNs only** — a
  short name such as `annas-archive-stacks.ebooks` still takes the tunnel.
- **CIDR entries in `NO_PROXY` are library-dependent** — prefer DNS suffixes.
  `httpx` splits the value on `/` and builds a malformed `all://10.0.0.0/8`
  pattern (verified in the book-search pod, httpx 0.28.1). Nothing in the
  current consumers calls a raw IP over HTTP, so the suffix list is sufficient.
- **Add any host that must keep its present source address.** A session bound to
  an IP or ASN — a private tracker, an API key allowlisted by address — breaks
  when its traffic moves to a UK exit, and can break a second time on the way
  back if the far side re-binds to the VPN address meanwhile. `myanonamouse.net`
  is the known case in this cluster (its `dynamicSeedbox.php` endpoint exists to
  bind a session to one address), so it stays in `NO_PROXY`.
- Upper- and lower-case forms of these variables both circulate in the wild; set
  whichever the consumer's HTTP library reads.
- **No proxy credentials** — see "Access" below.

Both listeners were confirmed present in the gluetun image running here
(version string `latest`, commit `7eed6ea`, built 2026-08-07): the binary
carries the whole `internal/socks5` and `internal/httpproxy` packages plus the
`SOCKS5_*` / `HTTPPROXY_*` env-var names, and the running container prints both
sections in its startup settings tree. The image tag is **not pinned** (out of
scope for this build), so that is a point-in-time verification rather than a
standing guarantee — re-check the env-var names if a future `:latest` changes
listener behaviour. Note also that `SOCKS5_LOG` does not exist; only the HTTP
proxy has a per-request log switch (`HTTPPROXY_LOG`), and gluetun rejects
unknown env keys.

### One gateway, two products

`proxy-gw-1` is a single always-on pod serving both consumers:

| Consumer | Reaches it via | Path |
|---|---|---|
| Remote browsers (per-user Chrome) | Service `proxy-gw-1`, UDP `:51820` | WireGuard peer → `wg0` → forwarded out `tun0` |
| Cluster workloads (services, jobs) | Service `proxy-egress-uk`, TCP `:8888` / `:1080` | proxy listener re-originates out `tun0` |

Both share **one** NordVPN tunnel. The reason they share rather than each
getting their own UK gateway is the **one-gateway-per-country invariant**: the
NordLynx key is account-wide (memory #8307), and `pool.py` treats two tunnels to
the same country on that one key as a configuration that flaps. The invariant is
enforced in `plan_gateway`, which always returns `reuse` for a country that
already has a gateway. Worth knowing when reading that code: the invariant is
recorded in `pool.py` citing memory #10214, but that memory documents the
forwarding recipe rather than the flap itself — the precise mechanism is
inferred rather than demonstrated. It is treated as binding because the cost of
being wrong is a silently dead tunnel.

The tunnel budget is **unchanged**: the permanent gateway occupies one of the
existing `MAX_COUNTRIES - RESERVED_SLOTS = 6` country slots rather than adding
one, so five slots stay available for user-chosen countries and
`RESERVED_SLOTS = 2` still keeps two tunnels free for Viktor's own devices.

Consequence to keep in mind: the two products are now coupled. A gateway restart
briefly interrupts both the UK browsers and every proxy consumer. The
alternative — two UK tunnels on one account-wide key — was judged worse.

### Access

**Open to the whole cluster, by decision.** There is no NetworkPolicy in front
of the Service and no proxy credentials (`HTTPPROXY_USER` / `SOCKS5_USER` are
deliberately unset). Any pod that can resolve `proxy-egress-uk.proxy.svc` can
egress as this NordVPN identity, and nothing records which pod did.

The trade-off was taken for low friction — wiring a consumer is one env var, in
one apply, with nothing to provision. If the cluster's tenancy assumptions
change, a NetworkPolicy allowlist is the natural first hardening step, and
per-consumer proxy credentials are the second.

### Failing closed, and the one alert

The behaviour on tunnel loss is **fail closed**: gluetun's kill-switch drops
egress, so a consumer's request fails rather than leaving from the home address.
There is no fallback path.

Two details are what make a failure visible rather than silent:

- **Readiness probe.** The gluetun container runs `/gluetun-entrypoint
  healthcheck` as an `exec` readiness probe (~30 ms; it reads the cached state
  of the long-running instance's loopback health server rather than dialling
  out). Without it a pod with a dead tunnel still reads `Ready` — a live browser
  pod did exactly that for days while restarting its VPN roughly every 11 s
  (observed 2026-08-16). gluetun's control server on `:8000` needs auth on every
  route in current images and its health server binds `127.0.0.1:9999`, so an
  `httpGet` probe is not the option here.
  There is deliberately **no liveness probe** on the same check: gluetun already
  restarts the VPN itself, and killing the container mid-recovery risks
  NordVPN's ~10-minute over-limit cooldown (memory #10182).
- **One alert.** `VPNEgressGatewayDown` — the `proxy-gw-1` Deployment has no
  available replica for 10m, `severity: warning` → `#alerts`. It lives inline in
  `stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl` (this repo
  has no `alerting_rules.yml`). Endpoint-level metrics are dropped by that
  file's `metric_relabel_configs`, so deployment availability is how "the
  Service has no endpoints" is expressed. Both Services select the same single
  pod, so one signal covers both halves.

Readiness is per-**pod**, so an unready gluetun removes the pod from *both*
Services at once. That is the intended fail-closed behaviour, and it is a change
for the browser path, which had no readiness gate before.

**`FIREWALL_INPUT_PORTS` is load-bearing and easy to miss.** It is
`51820,8888,1080` on the permanent gateway. gluetun's kill-switch drops inbound
traffic to any port not listed, and **loopback tests do not catch it** — only a
request from another pod does. `:6080` hit exactly this during the geo-browser
build. Add the port here first when exposing anything new on a gateway pod.

### Escape hatch — full-tunnel via a WireGuard sidecar

For a client that ignores proxy environment variables (some native binaries,
tools that make their own DNS queries), the pattern to reach for is the one the
browser pods already use. **This is documentation, not a module** — nothing needs
it today, so no reusable Terraform was built; `build_br_pod` in
`files/broker/broker.py:394` is the working reference to copy from.

The shape:

1. Add a `gluetun` sidecar to the consumer pod in **custom-WireGuard** mode:
   `VPN_SERVICE_PROVIDER=custom`, `VPN_TYPE=wireguard`,
   `WIREGUARD_ENDPOINT_IP=<ClusterIP of Service proxy-gw-1>`,
   `WIREGUARD_ENDPOINT_PORT=51820`, `WIREGUARD_PUBLIC_KEY=<gateway public key>`,
   `WIREGUARD_ADDRESSES=10.13.1.<n>/32`, and `WIREGUARD_PRIVATE_KEY` from a
   Secret. Capabilities `NET_ADMIN` + `SYS_MODULE`; no privileged flag and no
   `/dev/net/tun`.
   The endpoint must be an **IP**, not a hostname — gluetun's custom-WireGuard
   mode does not resolve names here (memory #10222), which is why the ClusterIP
   Service exists.
2. Set `FIREWALL_INPUT_PORTS` to every port the app serves (see the note above)
   and `FIREWALL_OUTBOUND_SUBNETS=10.10.0.0/16,10.96.0.0/12` so cluster-internal
   calls still go direct. Containers in a pod share one netns, so **all** of the
   pod's traffic is otherwise inside the tunnel.
3. Register the sidecar's public key and `/32` in ConfigMap `proxy-gw-1-peers`;
   the gateway's `wg-server` sidecar reconciles `wg0` from it every 10 s.

One piece of step 3 is still open, and worth knowing before starting:
`update_gw_peers` (`broker.py:586`) **rebuilds** that ConfigMap from the live
`app=proxy-browser` pods every 60 s from the reaper, so a hand-added peer is
removed on the next tick. Two ways to close it, neither built:

- a small broker change to carry static peers alongside the generated ones (the
  cleaner option, and the one to prefer if a second consumer ever appears); or
- giving the consumer pod the labels and annotations the broker reads
  (`app=proxy-browser`, `proxy/user`, `proxy/gw-idx`, `proxy/wg-pub`,
  `proxy/wg-ip`). That works with no code change, but the pod then counts as a
  browser everywhere else — the UI, the PVC and routing reapers, and the
  per-user browser accounting. Weigh those side effects before taking it.

## Auth

`auth = "required"` — Authentik forward-auth gates the UI + API; each user's
browser + encrypted profile keys on their identity. The per-user
`proxy-<token>.viktorbarzin.me` ingress stays `auth = "none"` — the unguessable
per-user token (`HMAC(salt, userkey)`) is the gate, and it is also neko's admin
password. (The carve-out dates from KasmVNC, whose WebSocket forward-auth broke;
it has not been retested against neko's `/ws`.)

## Guardrails

- **Concurrency**: gateways capped at `MAX_COUNTRIES - RESERVED_SLOTS` (`pool.py`),
  one gateway per distinct country (same NordLynx key on two tunnels to the same
  country flaps); browsers are one-per-user. `RESERVED_SLOTS=2` keeps NordVPN
  tunnels free for Viktor's own devices. **Index 1 is reserved** for the
  permanent UK gateway (`PERMANENT_IDX` / `PERMANENT_COUNTRY` in `pool.py`):
  `alloc_subnet_idx` never hands it out, and `plan_gateway` returns `reuse` for
  its country whether or not the pod is currently listed. It counts as one of
  the six country slots, leaving five user-selectable. That `reuse` answer means
  "this country is served by index 1, never start a second tunnel" — it says
  nothing about the gateway being up, which `plan_gateway` cannot know (the pod
  is absent from its input during any rollout). Liveness is checked one layer
  out: `ensure_gateway` requires a **Ready** pod at index 1 before wiring a
  browser to it, and otherwise fails the request with a retryable "not ready
  yet" rather than handing out a gateway with no endpoint behind its ClusterIP.
- **Persistence**: profiles are encrypted PVCs (`proxmox-lvm-encrypted`), no
  backup — a rare loss = re-login. Deleting a browser KEEPS its profile.
- **Reaping**: an idle gateway (no browsers for `GW_IDLE_SECONDS=600`) is reaped,
  freeing its tunnel slot; the reaper also re-asserts peers each cycle. The
  permanent gateway at index 1 is **never reaped** — `plan_reaping` skips it and
  `delete_gateway` refuses it. Terraform owns its Deployment, Services and
  Secret, so a broker-side delete would strip a live gateway of its routing
  (the broker's Role grants no `apps` access, so it cannot touch the Deployment
  itself).
- Least-privilege: session pods run UNPRIVILEGED (`NET_ADMIN`+`SYS_MODULE`, no
  `/dev/net/tun`/privileged). The one posture addition is the opt-in
  `net.ipv4.ip_forward` unsafe-sysctl on node2-5 (infra#81; contained to the
  pod netns). ns on `ghcr_private_namespaces` (kyverno) for the
  private image pull (the neko image itself is public).

## Operate

- Health/metrics: `proxy-broker` `/healthz`, `/metrics` (`proxy_gateways_active`,
  `proxy_browsers_active`, `proxy_max_countries`).
- List: `kubectl get pods -n proxy -l 'app in (proxy-gateway,proxy-browser)'`.
- Run the broker tests: `cd files/broker && python3 -m unittest pool_test wgkeys_test`.
- **Check the egress path** from an unrelated pod in another namespace:
  `curl -x http://proxy-egress-uk.proxy.svc.cluster.local:8888 https://ipinfo.io/json`
  and the same through `socks5h://…:1080`. Confirm the address is a NordVPN one
  via gluetun's `/v1/publicip` plus `web-api.nordvpn.com/v1/ips/info` rather
  than a generic geo-IP service (memory #10182). A loopback test inside the
  gateway pod does not exercise `FIREWALL_INPUT_PORTS`, so it can pass while
  cross-pod traffic is dropped.
- Startup settings (which listeners gluetun actually enabled) are printed once
  and scroll out of `kubectl logs` quickly on a restarting pod — read them from
  Loki instead: `homelab logs query '{namespace="proxy", container="gluetun"} |= "settings:"' --since 168h`.
- NordVPN token rotates the NordLynx key account-wide; the broker re-fetches per
  gateway spawn (token in Vault `secret/proxy`). The permanent gateway never
  takes that spawn path, so it carries
  `secret.reloader.stakater.com/reload: nordvpn-wg` — Reloader restarts it when
  the Secret **changes**. For that to fire, something must refresh the Secret:
  `reaper()` calls `ensure_nordvpn_secret()` every `NORDVPN_KEY_REFRESH_SECONDS`
  (default 21600 = 6 h), and an unchanged key is a no-op write, so a quiet
  account never restarts the gateway. No rotation has been observed on this
  account, so this path is defensive and has not been exercised in practice.
- **Two Secrets, two owners — don't conflate them.** `nordvpn-wg` is the
  account-wide NordLynx key gluetun dials NordVPN with (above). `proxy-gw-1-wg`
  is this gateway's own WireGuard **server** key, the one browsers peer against.
  Terraform cannot generate an X25519 keypair, so the broker owns it:
  `ensure_permanent_gateway_secret()` creates it if absent — at startup and on
  every reaper tick — and **never replaces an existing key**, because the
  wg-server sidecar reads `/gw-wg/privkey` once at container start and a rotated
  key would leave browsers handing out a public key the gateway no longer holds
  (handshakes then fail silently on both sides). Symptom if it is ever missing:
  the gateway pod sits in `ContainerCreating` (the volume is deliberately
  non-optional, so this surfaces as `PodStuckPending` at 20 m) and
  `proxy-egress-uk` has no endpoints. Recovery is automatic within one reaper
  tick; a rotation, if ever needed, is delete-the-Secret **plus** restart the
  pod, in that order.

## Deferred (see the design doc)

- **Phase 3 — Headscale exit nodes: DROPPED 2026-09-02 (infra#50).** The plan was
  `tailscale --advertise-exit-node` on the gateways so tailnet users could route
  their own traffic through NordVPN. It was never built — the live gateway pod
  runs exactly two containers, gluetun and wgserver, and
  `grep -rn advertise-exit-node` finds only prose in the design docs.
  Dropped rather than deferred, because two things that shipped after it was
  designed cover most of its case:
    - **workload egress**: `proxy-egress-uk` (2026-08-16) gives any pod a
      NordVPN UK exit through one env var, on this same gateway. Verified
      2026-09-02 — a curl through it egressed as `187.13.137.34`, not the home
      IP.
    - **device exit node**: pfSense has been an approved Headscale exit node
      since 2026-08-03 (node 10, `tag:infra`). Verified 2026-09-02 —
      `headscale nodes list-routes` shows `0.0.0.0/0` both approved and serving.
    - **per-country browsing**: already the product. The per-user browser here
      picks a country through the UI.
  What Phase 3 would still have added, and what nothing covers today, is a
  tailnet *device* choosing a NordVPN country for all of its traffic. That is a
  narrower want than the issue was written around, and it costs a third
  container in every per-country gateway pod plus a live tailnet spike. The
  forwarding primitive it needs is proven and running, so reviving this is
  wiring rather than design if the want returns.
- **WebRTC display — DONE** (neko, infra#81): hardware H.264 over a coturn relay,
  see "Browser pod" above. Two follow-ups it left open: the TURN credential is
  minted at browser-creation time with a 30-day TTL and neko's env is static, so a
  browser outliving the TTL needs a recreate to re-mint (reaper-driven in-place
  rotation is unbuilt); and `GPU_BROWSERS_MAX=1` until the `gpumem` budget frees
  up (ADR-0016), so a second concurrent GPU browser is rejected up-front.
- Social self-signup for non-admins is handled by the Authentik enrollment flow
  (separate work in `stacks/authentik`).
- **Left out of the egress build, deliberately** (recorded as accepted
  trade-offs in the egress design rather than dropped): pinning the gluetun
  image — it tracks `:latest`, which is a standing risk for an always-on
  gateway; a public-IP / country-verification probe, so a tunnel that is up but
  exiting from an unexpected country will not alert; a NetworkPolicy allowlist
  and proxy credentials, see "Access" above; and a reusable Terraform module for
  the WireGuard-sidecar escape hatch, which has no caller yet to validate its
  interface against.
- **Anti-bot efficacy is unproven.** The pilot consumer is `book-search` →
  Anna's Archive, behind a flippable env var. The 403 it currently gets is a
  DDoS-Guard JS challenge (902-byte body, `<title>DDoS-Guard</title>`,
  `/.well-known/ddos-guard/js-challenge`), which gates on ASN reputation and JS
  execution rather than country — and NordVPN exits sit in hosting ASNs that
  anti-bot vendors generally score more harshly than the residential address
  this cluster egresses from today. Routing through the tunnel may therefore
  make that target harder rather than easier. A worsened result is a valid
  finding, not a build failure; measure the 403 rate in Loki over matched
  windows before and after. Note also that only the direct leg moves: the
  FlareSolverr fallback makes its own outbound request from its own pod in the
  `servarr` namespace, which the consumer's proxy env cannot reach.
