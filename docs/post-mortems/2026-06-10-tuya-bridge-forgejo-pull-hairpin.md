# 2026-06-10 — tuya-bridge down 7.5h: forgejo image pulls ride the public-IP hairpin

## Impact

- `tuya-bridge` (Flask/tinytuya bridge feeding HA-Sofia's ATS, fuse-main,
  fuse-garage and 4 thermostat REST sensors) unavailable ~02:15–09:50 EEST.
  HA REST sensors 503'd; the official-tuya integration devices were
  unaffected (hybrid architecture limited the blast radius to the 3 power
  devices' advanced telemetry + thermostats extras).
- Third incident from the same root cause class:
  Woodpecker buildkit pushes (2026-06-04, code-yh33), tripit
  ImagePullBackOff on node2/node3 + devvm git timeouts (2026-06-09),
  tuya-bridge (this one).

## Timeline (EEST)

- **02:15** — tuya-bridge pod rescheduled onto `k8s-node3` (its previous
  node5/6-era home was rebuilt 14d ago; the forgejo-path image was never
  cached on node3 — only stale `docker.io/*` copies). Kubelet must pull
  `forgejo.viktorbarzin.me/viktor/tuya_bridge:3216c87a`.
- **02:15→09:30** — 51 consecutive pull failures:
  `dial tcp 176.12.22.76:443: i/o timeout` → ImagePullBackOff. HA shows
  503s (emo observed at 02:20).
- **09:40** — investigation: forgejo healthy via internal Traefik
  (`10.0.20.203`), manifest exists; node3's hosts.toml mirror present and
  correct; bare-IP request to the mirror returns **404 from Traefik**;
  registry auth realm is the **absolute** public URL.
- **09:48** — `/etc/hosts` pin `10.0.20.203 forgejo.viktorbarzin.me` added
  on node3; `crictl pull` succeeds immediately; pod replaced → Running;
  `/health` ok; all 27 device `getstatus()` calls succeed; all 7
  `*_tuya_cloud_up` Prometheus gauges = 1.
- **10:05** — pin rolled to all 7 nodes; provisioning scripts + docs updated.

## Root cause

Fresh kubelet pulls of `forgejo.viktorbarzin.me` images depend on pfSense
NAT reflection of the public IP `176.12.22.76`, which is intermittently
broken from the `10.0.20.0/24` network. The containerd
`certs.d/.../hosts.toml` mirror that was *believed* to keep pulls internal
cannot do so, for two independent reasons:

1. **Traefik routes by Host/SNI.** The mirror entry
   `[host."https://10.0.20.203"]` makes containerd dial the bare IP (no
   SNI, `Host: 10.0.20.203`) — no Traefik router matches → **404** → con-
   tainerd treats the mirror as a miss and falls back to
   `server = "https://forgejo.viktorbarzin.me"` → public DNS → hairpin.
2. **The Bearer auth realm is absolute.** `/v2/` challenges with
   `realm="https://forgejo.viktorbarzin.me/v2/token"`; containerd fetches
   that URL verbatim — this leg never goes through the mirror at all.

So every fresh pull silently depended on hairpin luck. Cached images masked
the problem; it only fired when a pod landed on a node without the image
(node rebuilds, new nodes, evictions, new tags).

Why DNS-side fixes don't reach this path: nodes resolve via systemd-resolved
→ pfSense (10.0.20.1) + public fallback (94.140.14.14), so Technitium
split-horizon (scoped to `192.168.1.0/24` clients) never applies; the
CoreDNS forgejo rewrite (2026-06-04) covers pods only, not kubelet.

## Fix

**Initial mitigation (same morning):** `/etc/hosts` pin
`10.0.20.203 forgejo.viktorbarzin.me` on every node — restored service
immediately (resolve + token + blob legs all internal with correct SNI).

**Superseded same day (Viktor: "no hardcoded IPs in nodes") by a DNS-based
fix.** Discovery: Technitium's split-horizon zone *already* resolves
`forgejo.viktorbarzin.me → CNAME viktorbarzin.me → A <live Traefik IP>` —
the `technitium-ingress-dns-sync` CronJob auto-CNAMEs every ingress host
hourly, the apex A record tracks the live Traefik LB IP, and the
`viktorbarzin-apex-probe` canary alerts on drift. The nodes simply never
queried Technitium (resolv chain: pfSense + public AdGuard fallback). The
devvm already solved this with a systemd-resolved **routing domain**
drop-in; the same was rolled to all 7 nodes:

```
# /etc/systemd/resolved.conf.d/viktorbarzin.conf
[Resolve]
DNS=10.0.20.201
Domains=~viktorbarzin.me
```

The `/etc/hosts` pins were then removed (verified `getent` still returns
the Traefik IP via DNS, and `crictl pull` succeeds). On node5/6 the
cloud-init `global-dns.conf` (`DNS=8.8.8.8 1.1.1.1`) was demoted to
`FallbackDNS=` only — public servers in the global set merge with and
race the routing domain. That file's original justification ("Technitium
NXDOMAINs forgejo.viktorbarzin.me") was obsolete: the ingress-dns-sync
has since added forgejo to the zone — a stale comment that actively
pointed new nodes at the hairpin.

**Final architecture (same day, round 3 — Viktor: "no customization,
everything handled by the DNS infra"):** the routing-domain drop-ins were
ALSO removed; nodes are now completely stock. Two resolver-side changes
replaced them:

1. **pfSense Unbound domain override** `viktorbarzin.me → 10.0.20.201`
   (forward-zone to Technitium). Every Unbound client on every VLAN gets
   the internal split-horizon answers with zero per-host config. No
   DNSSEC complications (zone unsigned), private-IP answers pass, mail's
   non-Traefik record (`→ 10.0.20.1`) verified working. Runbook:
   `docs/runbooks/pfsense-unbound.md`; on-box backup
   `config.xml.bak-2026-06-10-pre-me-forward`.
2. **CoreDNS pod carve-out** (TF, `stacks/technitium`): a dedicated
   `viktorbarzin.me:53` server block pins forgejo to Traefik's
   **ClusterIP** (interpolated from the live Service — pods cannot reach
   the ETP=Local LB IP that pfSense now returns) and forwards all other
   `.me` names to `8.8.8.8/1.1.1.1`, preserving pods' pre-existing
   public-IP behavior. Replaces the old forgejo rewrite in `.:53`.

   **Addendum (same day, evening):** the "pods cannot reach the
   ETP=Local LB IP" premise was re-tested and is FALSE on k8s 1.34
   (kube-proxy short-circuits in-cluster traffic to LB IPs via the
   cluster path; verified from pods on three non-Traefik nodes). The
   public-answer carve-out had meanwhile left pods as the only client
   class still riding the TP-Link NAT loopback, which hard-died
   2026-06-09 — 27 non-proxied `[External]` uptime-kuma monitors dark.
   Fix: the block now forwards to the Technitium ClusterIP
   (`10.96.0.53`) — pods are ordinary internal clients; forgejo pin
   kept for Technitium-outage resilience. In-cluster `[External]`
   monitors now test the internal path for all names; genuine
   edge-path fidelity belongs to a true external vantage (ha-london).

node5/6 were also re-pointed from link-DNS=Technitium to
`10.0.20.1 94.140.14.14` (netplan + `qm set --nameserver` on PVE VMs
205/206) for fleet parity, and their `global-dns.conf` was deleted.

**Renumber hazard: resolved.** A future Traefik LB renumber propagates
via the apex A record automatically (drift probe alerts if it doesn't);
only the vestigial hosts.toml literal goes stale. **Trade-offs:**
`viktorbarzin.me` resolution via pfSense depends on in-cluster Technitium
(3 replicas) — SERVFAIL during a full cluster outage (services down
anyway; bootstrap images pull via the IP-addressed `10.0.20.10` mirrors).
Nodes keep `94.140.14.14` as secondary DNS: a resolved failover during a
pfSense blip briefly re-exposes public answers — rare, self-healing,
accepted.

## Verification (final architecture)

- All 7 nodes stock (no pins, no drop-ins); `getent hosts
  forgejo.viktorbarzin.me` → `10.0.20.203` via pfSense → Technitium;
  general resolution intact; `crictl pull` succeeds end-to-end.
- pfSense: forgejo/immich/vault → apex CNAME → `.203`; mail →
  `10.0.20.1` (`:993` verified); `google.com` public; `.lan` auth-zone
  unaffected.
- Pods: forgejo → `10.111.111.95` (Traefik ClusterIP),
  immich → `176.12.22.76` (public, status quo) — verified in-pod after
  CoreDNS reload.
- tuya-bridge pod Running; `/health` `ok=true`; 27/27 devices
  `success=true`; 7/7 `*_tuya_cloud_up` gauges = 1; no tuya-related alerts.

## Lessons

- A mirror that *can* fall back to a broken path is not a fix — it's a
  latency bomb with the blast delayed until the cache misses.
- Registry token realms are absolute URLs: any "redirect the registry"
  scheme must also redirect the *name*, not just the endpoint.
- Before inventing a redirect mechanism, check what the DNS authority
  already serves: the Technitium split-horizon zone had the correct,
  auto-maintained answer all along — the clients just weren't asking it.
- Stale config comments are load-bearing: the obsolete "Technitium
  NXDOMAINs forgejo" comment in cloud-init steered new nodes onto public
  DNS, recreating the hairpin exposure on every node added after it.
- All `10.0.x` legs are now DNS-routed (nodes + devvm via routing domain,
  pods via CoreDNS rewrite). pfSense Unbound host overrides remain an
  option for other LAN segments if a non-Technitium client ever needs
  internal answers (live network device — deliberate, separate change).

## Related

- Beads `code-2or8` (Tuya Cloud subscription) — verified resolved during
  this incident: subscription is active again, all gauges green; closed.
- 2026-06-09 tripit ImagePullBackOff — same cause, self-recovered when the
  hairpin flapped back; the two `ScrapeTargetDown[tripit]` alerts firing
  during this investigation were scrapes of *Completed* cronjob pod
  endpoints (separate monitoring wart, not this outage).
