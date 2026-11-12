# Real-Debrid through the AIOStreams proxy, so emo can share the config

Research note, 2026-11-11. Read-only: no Terraform, AIOStreams config, Stremio
account or device was changed. The AIOStreams config was read once with
`GET /api/v1/user/?raw=true` and only non-secret fields were printed. Emo's TV
was not touched (Viktor's rule, memory #13055).

The question: emo (Sofia, own Stremio account, Sony BRAVIA on Stremio 1.12)
should use Viktor's self-hosted AIOStreams config so every improvement reaches
him. Real-Debrid (RD) is the only debrid in that config, RD allows one public
IP at a time, and Viktor streams from London. Does routing RD playback through
AIOStreams' built-in proxy solve that, and at what cost?

Every claim carries one of three labels:

- **[measured]** read on the live system today.
- **[source]** read in upstream code or first-party documentation, with a file
  and line or a URL. AIOStreams references are to tag `v2.37.0` (commit
  `ed8b085f`), the tag pinned in `stacks/servarr/aiostreams/main.tf:60`.
- **[inferred]** reasoning from the above, not observed or tested.

## Summary

1. **The proxy works as hoped, technically.** The built-in proxy re-streams
   the bytes through the AIOStreams pod, passes `Range` through, follows RD's
   redirects itself and strips the viewer's IP headers, so RD would see only
   the cluster's egress IP for both link resolution and download. [source]
2. **But the person to proxy is Viktor, not emo.** Emo's TV is
   `192.168.1.54` on the Sofia home LAN, the same LAN the cluster sits behind,
   and both leave the internet as `176.12.22.76`. Proxying emo changes nothing
   RD can see. The odd IP out is London. To give RD one IP, Viktor's London
   playback has to go through Sofia. [measured for the cluster and a LAN host;
   inferred for the TV]
3. **RD's own terms forbid what this setup would hide.** The terms say the
   account is "for personal use only. Only the individual who holds the account
   is allowed to connect on it", and that downloading "with or through a
   dedicated server (RDP, personal VPN, private proxy, and so on)" requires
   paid Remote Traffic. A single IP makes the sharing harder for RD to detect;
   it does not make it allowed. The downside is a suspension of Viktor's
   account. [source]
4. **The proxy URL host cannot be changed separately for the built-in proxy.**
   Built-in proxy URLs are always `BASE_URL` plus `/api/v1/proxy/...`, and
   `BASE_URL` today is the Cloudflare-proxied host, whose terms bar serving
   video. Using the built-in proxy means moving `BASE_URL` to a grey-cloud
   host. [source]
5. **Proxying one person while sharing one config is supported** through
   variants (v2.33+), which may write the `proxy` block, or through a child
   config with its own `proxy` and `services` sections. [source]

**Recommendation:** for "every improvement reaches emo", use a child config
for emo that inherits Viktor's presets, filters, sorting and formatter and
overrides `services` with emo's own debrid key. That needs no proxy, no
Terraform change and no ToS exposure, but it needs emo to pay for his own
debrid account, which is his spend, not Viktor's. If Viktor instead accepts the
RD risk, proxy the London side (Viktor's base config) and leave emo direct;
section 7 has the Terraform draft for that.

## What is running today [measured]

| Item | Value |
|---|---|
| Image | `viren070/aiostreams:v2.37.0` (`stacks/servarr/aiostreams/main.tf:60`) |
| `BASE_URL` | `https://aiostreams.viktorbarzin.me` (`main.tf:79-80`) |
| Ingress | `auth = "app"`, `dns_type = "proxied"`, Turnstile at its default, which is on for `auth = "app"` (`main.tf:664-682`) |
| Pod resources | request 25m CPU / 512Mi, limit 768Mi memory, no CPU limit (`main.tf:139-149`) |
| `AIOSTREAMS_AUTH` | not set, so no account users exist and the built-in proxy has no credentials to use |
| Cluster egress IP | `176.12.22.76`, from `checkip.amazonaws.com` inside the aiostreams pod (the same check the built-in proxy uses) |
| Sofia LAN egress IP | `176.12.22.76`, from the Proxmox host `192.168.1.127`, default route `192.168.1.1` (the TP-Link) |
| Config `services` | only `realdebrid` enabled |
| Config presets | torrentio, comet, stremthruTorz (all `services: [realdebrid]`, public instances, no custom URL), knaben (built-in), opensubtitles-v3-plus, tmdb-addon, streaming-catalogs |
| Config `proxy` | `{"id":"builtin","proxiedAddons":[],"proxiedServices":[]}`, no `enabled`, no credentials |
| Config variants / parent | none / none |
| Sort order | streamType, cached, library, resolution, quality, ... size ascending; preferred qualities start `BluRay REMUX`, `BluRay` |

The network docs agree on the egress path: the home LAN `192.168.1.0/24` is
served by the TP-Link AX6000, OPNsense's WAN leg is `192.168.1.2` on that LAN,
and pods reach the internet through OPNsense outbound NAT
(`docs/architecture/networking.md:232`, `:243`, `:270`). Emo's TV at
`192.168.1.54` (memories #13055, #17110) is on that LAN. I did not measure the
TV's egress IP; the only way it differs is a per-device VPN or policy route on
the TP-Link, which nothing in the docs mentions.

## 1. How the built-in proxy works

### Config fields [source]

The per-user proxy block is `StreamProxyConfig`
(`packages/core/src/db/schemas.ts:286-295`): `enabled`, `id`
(`mediaflow | stremthru | builtin`), `url`, `publicUrl`, `credentials`,
`publicIp`, `proxiedAddons`, `proxiedServices`.

For `id = "builtin"`:

- `url` is forced to `BASE_URL` and `publicUrl` to undefined in the
  constructor (`packages/core/src/proxy/base.ts:41-44`). The configure page
  hides both fields for the built-in proxy
  (`packages/frontend/src/components/menu/proxy.tsx:149`, `:170`).
- `credentials` is `username:password` of an `AIOSTREAMS_AUTH` user that holds
  the `proxy` permission. It is checked when URLs are generated
  (`packages/core/src/proxy/builtin.ts:24-39`, `:105`) and again on every
  proxied request (`packages/server/src/routes/api/proxy.ts:141-183`). Saving a
  config with the proxy enabled also calls `getPublicIp()`, which validates the
  credentials first (`packages/core/src/utils/config.ts:1446-1449`), so a bad
  credential fails the save.
- `publicIp` is optional. Without it the pod asks `checkip.amazonaws.com` and
  caches the answer for `PROXY_IP_CACHE_TTL` (default 900 s)
  (`builtin.ts:57-99`, `packages/core/src/config/schema/proxy.ts:217-227`).
  Today that returns `176.12.22.76`.
- `proxiedServices` and `proxiedAddons`: an empty list means "all"
  (`packages/core/src/streams/proxifier.ts:264-272`). So
  `proxiedServices: ["realdebrid"]` proxies only RD streams and leaves P2P,
  HTTP and subtitle URLs alone.

Instance-wide bootstrap variables (`.env.sample:96-113`):
`AIOSTREAMS_AUTH=user:pass,...` and
`AIOSTREAMS_AUTH_PERMISSIONS=user=perm|perm`. An unlisted user defaults to
`admin`, so a proxy-only account must be listed as `proxy=proxy`. There are
also `DEFAULT_PROXY_*` and `FORCE_PROXY_*` runtime settings
(`config/schema/proxy.ts:74-216`) that would apply a proxy to every config on
the instance; they are not needed for a per-config setup.

### What a proxied URL looks like and how it is served [source]

`generateStreamUrls` builds
`${BASE_URL}/api/v1/proxy/e.<encrypted auth>.<encrypted data>/<filename>`
(`builtin.ts:107-141`). Both parts are encrypted with `SECRET_KEY`; the data
holds the upstream URL and any request headers (`packages/core/src/proxy/token.ts:3-20`).
There is no expiry field, so a leaked proxy URL keeps working until the proxy
credentials change. [inferred from the schema]

The route (`proxy.ts:332` onwards):

- decrypts the token, checks the user and the `proxy` permission
  (`:141-183`);
- copies the client's headers, including `Range`, but drops `Host` and every
  client-IP header (`X-Forwarded-For`, `X-Real-IP`, `CF-Connecting-IP` and
  others) (`:100-122`);
- opens a stream session that enforces `STREAMS_CONNECTION_LIMITS` and
  redirects to a "limit reached" page when refused (`:371-406`);
- requests the upstream with undici, following up to 20 redirects itself
  (`:464-485`, `MAX_REDIRECTS` in `packages/core/src/utils/http.ts:453`), so
  RD's `302` to its CDN is followed by the pod, not the player;
- copies the upstream status and headers (`206`, `Content-Range`) to the
  client (`:507-511`) and pipes the body through (`:575-577`).

So the bytes do pass through the pod and seeking works. Bandwidth served this
way shows on the dashboard's Streams page and can be capped with
`STREAMS_BANDWIDTH_LIMITS` (`docs/configuration/environment-variables.mdx:1504`,
`:1512` in the AIOStreams repo).

## 2. Which IP Real-Debrid sees

### RD's own wording [source]

RD help answer 36, "maximum number of devices"
(`https://api.real-debrid.com/rest/1.0/support/getAnswer/en/36`, the API behind
`real-debrid.com/support`):

> You can use your account from any public IP address but you can't use your
> account from more than one public IP address at the same time. If your
> devices are connected through the same router, they are getting only one
> public IP address and you can use as many devices you want. If you want to use
> Real-Debrid from two different IP addresses at a time, you have to sign up and
> pay for two different accounts.

Answer 37 repeats this and says a warning revokes third-party app access.
Answer 28: "If you want to download with or through a dedicated server (RDP,
personal VPN, private proxy, and so on), you have to use your 'Remote
Traffic'", which is bought separately. The terms
(`https://real-debrid.com/terms`) say: "The User's account is for personal use
only. Only the individual who holds the account is allowed to connect on it.
Connections to the User's account are recorded so that we can detect account
sharing", and "The User certifies that he will not use a dedicated server, VPS
or any cloud service on our service other than by using his Remote Traffic".

The forum claim in the brief ("any IP, but not more than one at a time") is
therefore RD's own wording. "Warning, then ban" is half confirmed: answer 37
describes the warning; answer 38 covers suspensions without describing a
ladder.

RD does not say which request it counts: the API call that resolves the link,
or the download. Both matter in practice, because the addons pass an IP to RD
when they resolve:

- Torrentio sends an `ip` form field with `addMagnet`, `selectFiles` and
  `unrestrict/link` (`addon/crates/debrid/src/realdebrid.rs:89-103`, `:189-191`
  in TheBeastLT/torrentio-scraper at `69f64f0a`). It takes that IP from the
  `X-Real-IP` header set in front of it, or the TCP peer
  (`addon/crates/addon/src/http/client_ip.rs`). RD's public API page lists only
  `link`, `password` and `remote` for `/unrestrict/link`
  (`https://api.real-debrid.com/`), so the `ip` field is undocumented.
- StremThru (used by the stremthruTorz preset, and by AIOStreams' built-ins
  through the public instance `https://stremthru.13377001.xyz`,
  `packages/core/src/config/schema/builtins.ts:113-120`) also sends `ip`
  (`store/realdebrid/torrent.go:113`, `:149`, `:315`, `:364` in
  MunifTanjim/stremthru `0.105.4`). For public callers it uses a `client_ip`
  query parameter, else the request's IP (`core/request_ip.go:64-69`).

### The resolve path, today and with the proxy [source, inferred]

AIOStreams does not resolve RD links for the torrentio, comet and stremthruTorz
presets; their stream URLs point at the addon's own resolve endpoint. Only the
built-in knaben results go through AIOStreams' playback route
(`/api/v1/debrid/playback/`, `packages/server/src/routes/api/debrid.ts:99`),
which calls the public StremThru with the viewer's IP.

| Step | Today (no proxy) | With the built-in proxy |
|---|---|---|
| Stream list | AIOStreams forwards the viewer's IP to addons in `X-Forwarded-For`, `X-Real-IP` and others (`utils/http.ts:228-235`, `utils/constants.ts:219-227`) | AIOStreams forwards the proxy's public IP instead (`packages/core/src/main/setup.ts:695-759`) |
| Resolve (Torrentio) | the player fetches the resolve URL, Torrentio sends RD the player's IP | the pod fetches it, Torrentio sees `176.12.22.76` and sends that |
| Resolve (knaben built-in) | AIOStreams calls StremThru with the viewer's IP | the proxy calls BASE_URL, rewritten to `INTERNAL_URL` (`utils/http.ts:520-529`); the internal request has no public client IP, so StremThru falls back to the requester, the pod's egress `176.12.22.76` |
| Download | player to RD CDN | pod to RD CDN, then pod to player |

So with the proxy RD sees `176.12.22.76` for resolve and download. The knaben
row is derived from source reading and was not exercised. Comet follows the
same resolve-endpoint pattern; I did not read its source.

What RD still sees from elsewhere, today and with a proxy: cache checks from
the Torrentio, Comet and StremThru servers, and Viktor's own visits to the RD
website. The account has worked for months with the first, so RD evidently
does not count those addon-server calls against the one-IP rule. [inferred]

### Who is the second IP

Emo and the cluster share `176.12.22.76`. Without any proxy, emo playing on
the BRAVIA while Viktor plays in London is two IPs: Sofia and London. With emo
proxied and Viktor direct it is still Sofia and London. With Viktor proxied, it
is Sofia only. [inferred from the measured egress IPs]

## 3. Proxying only one person's playback

Proxy settings live in the config, so turning them on in the base config
proxies everyone who installed it. Two mechanisms allow a difference while
keeping one source of truth.

**Variants** (v2.33, `packages/docs/content/changelog/v2.33.mdx`). A variant
is a named CEL script applied at request time, selected by
`/stremio/<uuid>/<password>/v/<id>/manifest.json`, and each variant gets its
own addon id. Variants may write any root of the config except `accessKey`,
`parentConfig`, `variants` and `healthChecks`
(`packages/core/src/variants/language.ts:115-124`); `proxy` is a writable root
(`packages/core/src/utils/fieldMeta.ts:212`). The reference names proxying as a
good use of conditions (`packages/docs/content/docs/reference/config-expressions.mdx:185`).
So the base config can carry a complete proxy block and a variant can flip it:

```
# variant "sofia": emo's install, played direct from the Sofia LAN
set proxy.enabled = false
set addonName = "AIOStreams (Sofia)"
```

or the reverse (`set proxy.enabled = true` in a `london` variant). The
configure page always edits the base, so emo gets every change. Limits: ten
variants per config, `VARIANT_ACCESS` defaults to `all`
(`changelog/v2.33.mdx:140`). Conditions can read the user agent and request
headers but there is no client-IP function (`config-expressions.mdx:126-138`),
so "proxy only when not in Sofia" is not expressible; a named variant is the
reliable form.

**Parent/child config** (`ParentConfigSchema`, `schemas.ts:719-740`). A
second config points at the first with its UUID and password and per-section
merge strategies, defaulting to `inherit`, for `presets`, `services`,
`filters`, `sorting`, `formatter`, `proxy`, `metadata`, `misc` and `branding`.
This is the designed fit when the second person brings their own debrid
credentials: the v2.33 changelog says a child config "carries their own debrid
credentials, which you never see; a variant is a lens over yours"
(`changelog/v2.33.mdx:128-131`). Note the `services` section also holds the
presets' service selection indirectly; whether `services: override` keeps the
presets' `services: [realdebrid]` working against the child's own key needs a
test. [open]

The variant recipe for "a second debrid account",
`set services[id=realdebrid].credentials.apiKey = "SECOND_ACCOUNT_KEY"`
(`config-expressions.mdx:399-403`), also works, but stores emo's key inside
Viktor's config.

Which side to proxy, if proxying at all: proxying the base config (London)
fails safe for RD, because any new device Viktor adds lands on the one-IP path.
Emo then needs the `sofia` variant above. Without it, the BRAVIA would fetch
video from the grey-cloud host, which resolves to `176.12.22.76`; the TP-Link
has no hairpin NAT (`docs/architecture/networking.md:266`) and the TV's second
DHCP DNS server is AdGuard `94.140.14.14` (`:232`), which bypasses Technitium's
split-horizon rewrite. Playback would then fail whenever the TV asks AdGuard.
[inferred]

## 4. Bandwidth and load

### What the proxy would carry [inferred]

Only London playback, if emo is left direct. Emo's own streams come down the
Sofia downlink straight from RD and do not touch the uplink.

The config prefers cached 1080p, then `BluRay REMUX` before `BluRay`, and sorts
size ascending only after resolution and quality, so a typical top pick for a
film is a 1080p REMUX. RD's 451 filter, which blocks names containing
`WEB-DL`, `WEBRip` and similar (memory #9316), pushes further toward BluRay and
REMUX. General figures, not measured on this setup:

| Stream | Typical average bitrate |
|---|---|
| 1080p BluRay x264/x265 encode | about 8 to 15 Mbit/s |
| 1080p BluRay REMUX (AVC, Blu-ray video cap 40 Mbit/s) | about 20 to 35 Mbit/s, peaks near 40 |
| 2160p REMUX (deprioritised, not excluded) | about 50 to 80 Mbit/s, peaks higher |

Against the measured ~148 Mbit/s average uplink (brief; an older speedtest in
`docs/research/immich-front-cache.md:529` read 118.55 Mbit/s up, 201 down):
one London 1080p REMUX uses a quarter of it, two use about half, and one 2160p
REMUX can take half on its own. Everything else on the grey-cloud path
(Immich, Nextcloud, the stremio stack) shares that uplink. If the proxy goes
ahead, `STREAMS_CONNECTION_LIMITS=**:2` caps concurrent proxied streams.

London to Sofia adds a round trip (the site-to-site tunnel measured 38 ms,
memory #12889). That affects start and seek time slightly; at these bitrates a
single TCP connection over 40 ms is not the bottleneck. [inferred]

### Pod load [inferred]

The proxy is a Node `stream.pipeline` from an undici response to the Express
response (`proxy.ts:575-577`), so memory per stream is bounded by stream
buffers, not the file size. CPU goes to TLS decryption of the RD download and
the copy; Traefik terminates the client TLS. I expect a few percent of a core
per 1080p stream. The pod has no CPU limit and a 768Mi memory limit with a
30-day peak of 409Mi (`main.tf:140`), so it has room. This is an estimate;
measure with the dashboard's Streams page and `container_cpu_usage_seconds_total`
during a test stream.

## 5. Cloudflare and the hostname

### The terms [source]

Cloudflare Service-Specific Terms, Application Services, CDN section, last
updated 2026-09-28
(`https://www.cloudflare.com/service-specific-terms-application-services/`):

> Unless you are an Enterprise customer, Cloudflare offers specific Paid
> Services (e.g., the Developer Platform, Images, and Stream) that you must use
> in order to serve video and other large files via the CDN. Cloudflare
> reserves the right to disable or limit your access to or use of the CDN ...
> if you use or are suspected of using the CDN without such Paid Services to
> serve video or a disproportionate percentage of pictures, audio files, or
> other large files.

Proxied hostnames here ride the tunnel and the CDN (`docs/agents/ingress.md`,
DNS bullet), so proxy URLs must be on a `dns_type = "non-proxied"` host, the
same reason `stacks/stremio/main.tf:256-262` is grey-cloud.

### How to get proxy URLs on a grey host [source]

For the built-in proxy there is no separate public-URL setting: the URL is
`appConfig.bootstrap.baseUrl` (`builtin.ts:140`, `base.ts:41-44`). The v2.30
migration's `FORCE_PUBLIC_PROXY_HOST` replacement, `FORCE_PROXY_PUBLIC_URL`,
is applied in `BaseProxy.generateUrls` (`base.ts:161-181`) and is cleared for
`builtin` before that runs. The options:

- **A. Add a grey-cloud host and point `BASE_URL` at it.** Proxy URLs, the
  built-in playback route (`/api/v1/debrid/playback/`) and the
  `/static/...` error redirects (`proxy.ts:401-402`) then use the grey host.
  The proxied `aiostreams.viktorbarzin.me` keeps serving the configure page and
  every existing install, so nothing needs reinstalling. New install links
  shown on the configure page would use the grey host.
- **B. Make `aiostreams.viktorbarzin.me` itself grey-cloud.** One host, no
  `BASE_URL` change, but the configure page and the addon API lose the
  Cloudflare edge (WAF, edge CrowdSec blocks, the tunnel) and are served
  straight from `176.12.22.76`.
- **C. Use StremThru or MediaFlow as the proxy** (`id: stremthru` or
  `mediaflow`), which honour `url` (internal Service) and `publicUrl` (grey
  host) separately. `BASE_URL` stays as it is, at the cost of a second service.

A is the smallest change that keeps the UI behind Cloudflare.

## 6. Alternatives

| Option | What RD sees | Effort here | Notes |
|---|---|---|---|
| Built-in proxy, `BASE_URL` on a grey host | `176.12.22.76` only | env vars, one secret, one ingress, one config edit | No new service. Credentials are an `AIOSTREAMS_AUTH` user. Section 7. |
| Self-hosted StremThru as the AIOStreams proxy | `176.12.22.76` | new Deployment (Go, SQLite by default), secret, grey ingress | `publicUrl` supported. With proxy auth it tells RD its own machine IP (`internal/shared/http.go:263-271`). Could also replace the public StremThru for built-ins (`BUILTIN_STREMTHRU_URL`) and the stremthruTorz preset. StremThru docs: content proxy is self-hosted only (`docs/getting-started/faq.md:19`), `STREMTHRU_STORE_CONTENT_PROXY` defaults to `*:true`, per-user connection limits exist (`docs/configuration/index.md:184-215`). MIT, pushed 2026-10-25. |
| MediaFlow Proxy | `176.12.22.76` | new Deployment (Python), `API_PASSWORD`, grey ingress | Supported by AIOStreams (`packages/core/src/proxy/mediaflow.ts`). MIT, latest release 2.4.9 on 2026-05-19, last push 2026-09-06. No advantage over builtin for this setup. |
| Route London devices out through Sofia on the Flint 2 (policy routing over the existing site-to-site tunnel) | `176.12.22.76` | router PBR, per-device rules | Covers only devices on the London LAN, not Viktor's phone elsewhere. Same uplink cost, more fragile than an app-level proxy. Not recommended. |
| Emo's own debrid account, child config | emo's IP on emo's own account | config only | No proxy, no Terraform, no RD terms issue. Costs emo a subscription. |
| TorBox instead of RD | n/a | config only | Memory #7565 records TorBox allowing multi-IP use, and its free tier has no API key, so it needs a paid plan. Paid, so out of scope without Viktor's approval. Not re-verified today. |

## 7. Terraform draft (not applied)

Only needed for the proxy route. All in `stacks/servarr/aiostreams/main.tf`,
plus one Vault key.

1. **Vault**: add `aiostreams_proxy_password` (random, 32+ chars) to
   `secret/viktor`.
2. **ExternalSecret** composing the bootstrap auth string:

```hcl
resource "kubernetes_manifest" "auth_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "aiostreams-auth"
      namespace = kubernetes_namespace.aiostreams.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { name = "vault-kv", kind = "ClusterSecretStore" }
      target = {
        name = "aiostreams-auth"
        template = {
          data = {
            # One proxy-only account; the built-in proxy authenticates as it.
            AIOSTREAMS_AUTH = "proxy:{{ .proxy_password }}"
          }
        }
      }
      data = [
        { secretKey = "proxy_password", remoteRef = { key = "viktor", property = "aiostreams_proxy_password" } },
      ]
    }
  }
  depends_on = [kubernetes_namespace.aiostreams]
}
```

3. **Deployment env**:

```hcl
env {
  # Video must not ride the Cloudflare CDN (CDN terms), and the built-in
  # proxy always emits BASE_URL/api/v1/proxy/..., so BASE_URL is the
  # grey-cloud host. The proxied host keeps serving the UI and old installs.
  name  = "BASE_URL"
  value = "https://aiostreams-direct.viktorbarzin.me"
}
env {
  name = "AIOSTREAMS_AUTH"
  value_from {
    secret_key_ref {
      name = "aiostreams-auth"
      key  = "AIOSTREAMS_AUTH"
    }
  }
}
env {
  # Unlisted users default to admin; the proxy account gets proxy only.
  name  = "AIOSTREAMS_AUTH_PERMISSIONS"
  value = "proxy=proxy"
}
env {
  # Uplink guard: at most two proxied streams at once across all users.
  name  = "STREAMS_CONNECTION_LIMITS"
  value = "**:2"
}
```

   `BASE_URL` is a bootstrap variable, so the pod restarts; with
   `strategy = Recreate` and a ~45 s start that is a short outage. The
   deployment reads `AIOSTREAMS_AUTH` only at start, so a password rotation
   also needs a restart (Reloader annotation or a manual rollout). Setting
   `AIOSTREAMS_AUTH` also enables `/login` and the profiles feature; with
   `AIOSTREAMS_AUTH_REQUIRED` left at `false` the configure page stays public as
   today and config creation is not gated (`packages/server/src/routes/api/user.ts:190-205`).

4. **Second ingress**, modelled on `stacks/stremio/main.tf:254-276`:

```hcl
module "ingress_direct" {
  source = "../../../modules/kubernetes/ingress_factory"
  # auth = "app": the same AIOStreams app behind a grey-cloud name. Proxy URLs
  # carry SECRET_KEY-encrypted credentials checked on every request; the rest
  # of the app gates itself exactly as on the proxied host.
  auth         = "app"
  dns_type     = "non-proxied" # video: Cloudflare CDN terms bar it on proxied hosts
  namespace    = kubernetes_namespace.aiostreams.metadata[0].name
  name         = "aiostreams-direct"
  service_name = kubernetes_service.aiostreams.metadata[0].name
  # No Turnstile gate: machine clients (Stremio, ExoPlayer) fetching video.
  turnstile        = false
  homepage_enabled = false
  tls_secret_name  = var.tls_secret_name
}
```

   Middleware chain on that host, from `modules/kubernetes/ingress_factory/main.tf:477-502`:
   `retry`, `error-pages`, `rate-limit` (10 req/s average, burst 50 per client,
   `stacks/traefik/modules/traefik/middleware.tf:99-105`), CSP headers, and,
   because `auth = "app"`, `ai-bot-block` and anti-AI headers. None of these
   buffer bodies; Traefik's `writeTimeout=0s`
   (`stacks/traefik/modules/traefik/main.tf:636`) allows long downloads. Players
   issue a few range requests per seek, well under the rate limit. The
   `ai-bot-block` middleware matches crawler user agents; the same chain
   already serves the Stremio clients on the proxied host. `retry` re-sends a
   request on a connection error before any bytes are written, which is safe
   for idempotent GETs. [inferred]

   CrowdSec covers the grey path in-kernel via nftables on the origin, as for
   the stremio host (`stacks/stremio/main.tf:256-260`, `docs/architecture/networking.md:9`).
   I found no scenario that counts repeated range requests to one URL; watch
   `cscli decisions list` after the first long stream. [open]

5. **Monitoring**: `dns_type = "non-proxied"` turns on the external Uptime Kuma
   monitor by default (`ingress_factory/main.tf:270-275`). The suspended
   `aiostreams-stream-probe` would not cover proxying; a per-stream check is
   not proposed.

6. **Docs to update in the same commit**: `docs/agents/service-notes.md` or the
   AIOStreams entry in `.claude/reference/service-catalog.md`, and the comment
   block on the ingress explaining why two hosts exist.

7. **Config change, not Terraform** (through the configure page or one
   `PUT /api/v1/user`): set
   `proxy = {enabled: true, id: "builtin", credentials: "proxy:<password>", proxiedServices: ["realdebrid"]}`
   on the base config and add the `sofia` variant from section 3. Emo installs
   the `/v/sofia/manifest.json` URL into his own Stremio account.

## Open questions

- **Does emo live at the Sofia house?** The TV at `192.168.1.54` is on the
  cluster's LAN, which is the basis of this note's reframing. If emo also
  streams on another network (phone, another flat), those sessions are a
  second RD IP, and he would need the proxied variant there.
- **The TV's actual egress IP.** Inferred from the Proxmox host on the same
  LAN; not measured on the TV. A look at the TP-Link for per-device VPN or
  policy routes, or RD's `real-debrid.com/devices` page after emo plays
  something, would settle it.
- **Which RD request counts toward the one-IP rule** (resolve or download) is
  not documented. It does not matter if everything goes through one proxy, but
  it does for partial set-ups.
- **Child config `services: override`**: whether the inherited presets bind to
  the child's own RD key without further edits. Needs a test config.
- **Cache key and variants**: `STREAM_CACHE_TTL=3600` caches stream responses;
  the docs say variants are part of the cache key, which should keep proxied
  and direct URLs apart. Not tested.
- **CrowdSec and long streams** on the grey host, as above.
- **London DNS**: if London clients resolve `*.viktorbarzin.me` through the
  site-to-site tunnel to the internal Traefik IP, proxied video would ride the
  WireGuard tunnel rather than the open internet. Same Sofia uplink either way;
  the tunnel's throughput on the Flint 2 was not measured.

## Recommendation

Do not use the proxy as a way to share Viktor's RD account with emo. It works
technically, but it hides exactly the account sharing and private-proxy
downloading that RD's terms prohibit, and the failure mode is a suspended
account for both of them. The proxy also has to carry Viktor's London
playback, not emo's, so its real cost is every London stream on the Sofia
uplink.

To have every improvement reach emo, give emo a child config that inherits
everything from Viktor's except `services`, which holds emo's own debrid key.
No Terraform change is needed. If emo prefers not to pay for debrid, the
remaining zero-spend option is that he plays only while Viktor does not, which
is the rule RD states.

If Viktor accepts the RD risk anyway, the smallest version is section 7: built-in
proxy, `BASE_URL` on a new grey-cloud host, proxy on for the base config,
`proxiedServices: ["realdebrid"]`, a two-stream connection cap, and a `sofia`
variant that keeps emo direct.

## Decision and first results (2026-11-12)

Viktor chose the proxy route as a trial: London playback goes through Sofia
so Real-Debrid sees one IP. He was told of the RD terms risk above and
accepted it.

Applied: infra `6003cd933` and `2e52d9ea9` (section 7 as drafted, with an
`# auth = "app":` comment the CI lint requires). Viktor's config now has
`proxy = {enabled: true, id: builtin, proxiedServices: [realdebrid]}` and a
`sofia` variant (`disable proxy`, addon name "AIOStreams (Sofia)") for emo.

Measured from the London Flint 2 (`192.168.8.1`), fetching one proxied RD
link (a 1080p Comet result for Inception) with range requests [measured]:

| Test | Result |
|---|---|
| First 50 MB, cold | HTTP 206, 4.2 s to first byte (includes RD resolve) |
| Seek to 1 GB | HTTP 206, 0.49 s to first byte |
| 100 MB over IPv4 | about 10.8 MB/s, so about 87 Mbit/s, twice |
| 100 MB over IPv6 | 5.6 to 7.9 MB/s, so about 45 to 63 Mbit/s |
| aiostreams pod during the test | 96m CPU, 216Mi memory |

Stream lists from the base config carry
`https://aiostreams-direct.viktorbarzin.me/api/v1/proxy/...` for RD results
and leave P2P results untouched; the `sofia` variant returns the direct
Comet and Torrentio resolve links. Not yet observed: real playback on the
London projector, behaviour at the two-stream cap, and whether RD shows a
single IP on its devices page after a few days of use.

## Sources

- AIOStreams `v2.37.0`, commit `ed8b085f` (2026-10-23),
  `https://github.com/Viren070/AIOStreams`: files cited inline, plus
  `packages/docs/content/changelog/v2.33.mdx`,
  `packages/docs/content/docs/reference/config-expressions.mdx`,
  `packages/docs/content/docs/guides/config-profiles.mdx`,
  `packages/docs/content/docs/configuration/environment-variables.mdx`, `.env.sample`.
- Real-Debrid terms, `https://real-debrid.com/terms`, fetched 2026-11-11.
- Real-Debrid help answers 26, 28, 36, 37, 38, 68 via
  `https://api.real-debrid.com/rest/1.0/support/getAnswer/en/<id>`, the
  endpoint `real-debrid.com/support` loads them from.
- Real-Debrid API documentation, `https://api.real-debrid.com/`.
- Torrentio, `https://github.com/TheBeastLT/torrentio-scraper` at `69f64f0a`
  (2026-11-10).
- StremThru `0.105.4`, `https://github.com/MunifTanjim/stremthru` at `3472fd5c`.
- MediaFlow Proxy, `https://github.com/mhdzumair/mediaflow-proxy` (repo
  metadata only).
- Cloudflare Service-Specific Terms, Application Services, last updated
  2026-09-28.
- This repo: `stacks/servarr/aiostreams/main.tf`, `stacks/stremio/main.tf`,
  `modules/kubernetes/ingress_factory/main.tf`, `stacks/traefik/modules/traefik/`,
  `docs/agents/ingress.md`, `docs/architecture/networking.md`.
- Memories #7565, #9316, #12889, #13055, #17110, #17607.
