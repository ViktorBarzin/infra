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

`/etc/hosts` pin on every k8s node (hot, no drain, no containerd restart):

```
10.0.20.203 forgejo.viktorbarzin.me # forgejo-internal-pin (managed: setup-forgejo-containerd-mirror.sh)
```

Go's resolver (containerd) consults `/etc/hosts` first, so resolve + token
+ blob legs all go to internal Traefik with correct SNI and a valid
wildcard cert (no `skip_verify` needed on this path). Applied live to all
7 nodes; persisted in `modules/create-template-vm/k8s-node-containerd-setup.sh`
(new nodes) and `scripts/setup-forgejo-containerd-mirror.sh` (existing-node
rollout). hosts.toml mirror left in place (harmless, uniform config).

**Renumber hazard:** the pin hardcodes Traefik's LB IP, same as the
hosts.toml mirror and the 5 literals broken by the 2026-05-30 `.200→.203`
move. Any future Traefik LB renumber must update both (grep nodes for
`forgejo-internal-pin`).

## Verification

- `getent hosts forgejo.viktorbarzin.me` → `10.0.20.203` on all 7 nodes;
  `curl https://forgejo.viktorbarzin.me/v2/` → 401 (internal route, valid TLS).
- tuya-bridge pod Running; `/health` `ok=true`; 27/27 devices
  `success=true`; 7/7 `*_tuya_cloud_up` gauges = 1; no tuya-related alerts.

## Lessons

- A mirror that *can* fall back to a broken path is not a fix — it's a
  latency bomb with the blast delayed until the cache misses.
- Registry token realms are absolute URLs: any "redirect the registry"
  scheme must also redirect the *name*, not just the endpoint.
- The remaining hairpin-exposed leg is **devvm git** (manual `/etc/hosts`
  workaround documented in memory); a durable LAN-wide fix would need
  pfSense Unbound host overrides (live network device — deliberate,
  separate change).

## Related

- Beads `code-2or8` (Tuya Cloud subscription) — verified resolved during
  this incident: subscription is active again, all gauges green; closed.
- 2026-06-09 tripit ImagePullBackOff — same cause, self-recovered when the
  hairpin flapped back; the two `ScrapeTargetDown[tripit]` alerts firing
  during this investigation were scrapes of *Completed* cronjob pod
  endpoints (separate monitoring wart, not this outage).
