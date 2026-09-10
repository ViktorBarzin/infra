# Runbook: Registry VM (docker-registry, 10.0.20.10)

Last updated: 2026-09-03

The registry VM is an Ubuntu 24.04 VM on the cluster LAN subnet
`10.0.20.0/24`, with a static netplan config (no DHCP). Because it
sits on a subnet that only has pfSense as its gateway, its DNS must
be statically configured.

**As of Phase 4 of forgejo-registry-consolidation 2026-05-07** the VM
no longer hosts the private R/W registry. It hosts pull-through
caches only:

| Port | Upstream |
|---|---|
| 5000 | docker.io (Docker Hub) — auth via dockerhub_registry_password |
| 5010 | ghcr.io |
| 5020 | quay.io |
| 5030 | registry.k8s.io |
| 5040 | reg.kyverno.io |

All five are wired on all six k8s nodes and serving, verified 2026-09-03.

## The node side is declared, and used to be the weak half

`/etc/containerd/certs.d/<registry>/hosts.toml` is what makes a node use
these caches, and until 2026-09-03 nothing reconciled it. Two one-shot
scripts wrote it at different times, so the six nodes held three different
configurations:

| nodes | mirrored |
|---|---|
| master | docker.io, forgejo, ghcr.io |
| node1, node2, node3 | the above, plus two dead entries for the port-5050 registry decommissioned 2026-05-07 |
| node4, node5 | the above, plus quay.io and registry.k8s.io |

Four of six therefore pulled quay.io and registry.k8s.io straight from the
internet while these caches sat unused, and three carried mirrors resolving
to a listener gone since May.

It is now declared in `playbooks/k8s-node-tuning.yml` as a
`registry_mirrors` list of registry, upstream and port, and reconciled
hourly. **Adding a registry to that list is the whole change needed to put
every node behind a new cache.** All six trees are byte-identical; the
check is one line:

```bash
for n in k8s-master k8s-node1 k8s-node2 k8s-node3 k8s-node4 k8s-node5; do
  printf '%-12s ' "$n"
  ssh "$n" 'sudo find /etc/containerd/certs.d -name hosts.toml -not -path "*retired-*" \
    | sort | xargs sudo cat | md5sum | cut -d" " -f1'
done
```

Two properties of those files worth knowing before editing one:

- **certs.d is read per pull, not at containerd startup.** A mirror change
  takes effect on the next pull with no restart, which is what makes hourly
  reconciliation safe.
- **Every entry lists the real registry second, as a fallback.** node5's
  ghcr.io entry once had the cache as its only host, which fails ghcr pulls
  closed whenever this VM is down, and this VM ran out of disk for 45 days
  unnoticed. The fallback costs nothing on a hit and degrades to a direct
  pull instead of an outage.

## Port 5040 was pointed at the wrong registry for an unknown period

The table above has always said `reg.kyverno.io`, and it was right.
`config-kyverno.yml` carried `remoteurl: https://ghcr.io`, which made the
cache look like a duplicate of 5010 and made it useless: this cluster runs
`reg.kyverno.io/kyverno/{kyverno,background-controller,cleanup-controller}`
at v1.18.2, so nothing it could serve was ever asked for. The evidence was
its size, 4.0K, and that no node mirrored `reg.kyverno.io` at all, so every
kyverno pull went to the internet.

Corrected 2026-09-03: `remoteurl` names `reg.kyverno.io`, `ttl` goes 0 to
168h matching the other four, and the registry joins `registry_mirrors`.
Verified with a real pull on node2, 44.4 MB in 2.1 s, with the request
visible in nginx's log and the cache growing 4.0K to 276K.

**The lesson is the reusable part:** a pull-through cache that serves
nothing looks identical to one nothing needs. Size plus a `remoteurl` that
matches an image the cluster actually runs is the check.


The decommissioned private registry (port 5050) is now hosted on
Forgejo at `forgejo.viktorbarzin.me/viktor/<image>`. See
`docs/plans/2026-05-07-forgejo-registry-consolidation-plan.md` for the
migration. Break-glass tarballs of `infra-ci` are still produced on
each build to `/opt/registry/data/private/_breakglass/` — see
`docs/runbooks/forgejo-registry-breakglass.md`.

## DNS configuration

Ubuntu ships `systemd-resolved` and uses netplan to declare per-link
`nameservers`. Netplan writes systemd-networkd or NetworkManager
configs that resolved reads at runtime. There is **no automatic
merging** of netplan DNS with the `[Resolve]` section of
`/etc/systemd/resolved.conf` — per-link settings override the global
ones. So both layers must be in sync:

| Layer | File | Role |
|---|---|---|
| Netplan | `/etc/netplan/50-cloud-init.yaml` | Per-link DNS servers that resolved reports on `Link 2 (eth0)` |
| Resolved global | `/etc/systemd/resolved.conf.d/10-internal-dns.conf` | `Global` scope `DNS=` / `FallbackDNS=` — also shown in `resolvectl status` |

### Current state

`/etc/systemd/resolved.conf.d/10-internal-dns.conf`:

```ini
[Resolve]
DNS=10.0.20.1
FallbackDNS=94.140.14.14
Domains=viktorbarzin.lan
```

`/etc/netplan/50-cloud-init.yaml` (eth0 block, simplified):

```yaml
nameservers:
  addresses:
  - 10.0.20.1
  - 94.140.14.14
  search:
  - viktorbarzin.lan
```

`resolvectl status` output after the change:

```
Global
  resolv.conf mode: stub
  Current DNS Server: 10.0.20.1
  DNS Servers: 10.0.20.1
  Fallback DNS Servers: 94.140.14.14
  DNS Domain: viktorbarzin.lan

Link 2 (eth0)
  Current Scopes: DNS
  Current DNS Server: 10.0.20.1
  DNS Servers: 10.0.20.1 94.140.14.14
  DNS Domain: viktorbarzin.lan
```

| Field | Value | Purpose |
|---|---|---|
| Primary | `10.0.20.1` | pfSense OPT1 interface (dnsmasq forwarder → Technitium LB) — resolves `.viktorbarzin.lan` |
| Fallback | `94.140.14.14` | AdGuard public DNS — used if pfSense unreachable (e.g., OPT1 flap) |
| Search | `viktorbarzin.lan` | Unqualified names resolve against the internal zone |

### Why this matters for the registry

Container builds on this VM reference `.lan` hostnames (Technitium,
NFS, etc.) and external hostnames (Docker Hub, GHCR). Before the
hardening the netplan had `1.1.1.1` / `8.8.8.8` only, which meant:

1. Internal hostname lookups silently failed (slow timeout) — the
   VM could not resolve `idrac.viktorbarzin.lan` or any internal
   helper.
2. If Cloudflare's 1.1.1.1 had an outage, the VM would lose DNS
   entirely.

With the new config the VM can resolve both zones and keeps working
if the primary DNS server is unreachable.

## Apply / re-apply

```sh
ssh root@10.0.20.10 '
  netplan generate
  netplan apply
  systemctl restart systemd-resolved
  resolvectl status | head -20
'
```

`netplan apply` is not disruptive when only `nameservers` change — it
does not bounce the link.

## Verification

```sh
ssh root@10.0.20.10 '
  dig +short idrac.viktorbarzin.lan       # 192.168.1.4
  dig +short github.com                   # GitHub A record
  dig +short forgejo.viktorbarzin.me      # split-horizon answer (registry.viktorbarzin.me records were deleted 2026-07-08 — the name retired with the :5050 registry)
'
```

Fallback test — blackhole the primary and confirm external lookups
still succeed through 94.140.14.14:

```sh
ssh root@10.0.20.10 '
  ip route add blackhole 10.0.20.1
  dig +short +time=5 +tries=2 github.com   # should still answer
  ip route del blackhole 10.0.20.1
'
```

Internal lookups do fail during the blackhole (the fallback is a
public resolver and does not know about the internal zone), which is
expected — the fallback buys availability for external pulls, not
internal hostnames.

### Is the cache actually serving? Do not trust /v2/

`/v2/` and a bare `/healthz` are storage-free: they answer 200 while
content requests 500 under ENOSPC. That is the larger half of why this VM
sat 100% full for 45 days with nobody noticing. Each port's `/healthz` is
therefore a **real manifest fetch** of a pinned tag on a repo the cluster
actually pulls, so it fails when storage does:

```sh
for p in 5000 5010 5020 5030 5040; do
  printf ':%s ' "$p"
  curl -s -o /dev/null -w '%{http_code}\n' --max-time 15 "http://10.0.20.10:$p/healthz"
done
```

A content request through a node's own mirror is the end-to-end check, and
it also proves the node-side wiring:

```sh
ssh k8s-node2 'sudo ctr -n cachetest images pull --hosts-dir /etc/containerd/certs.d \
  reg.kyverno.io/kyverno/kyverno:v1.18.2'
ssh 10.0.20.10 'sudo docker logs registry-nginx --since 2m | grep kyverno'   # should show the node's IP
ssh k8s-node2 'sudo ctr -n cachetest images rm reg.kyverno.io/kyverno/kyverno:v1.18.2'
```

### Disk is now watched, which it was not

The VM's node_exporter answers on `:9100` and was scraped by nothing until
2026-09-03. It is now the `registry-cache-host` Prometheus job, so the
existing `LowDiskSpace` rule covers it with no new alert needed: that rule
is `node_filesystem_avail_bytes / node_filesystem_size_bytes * 100 < 5`
with no job selector, so it started covering this host the moment the
series existed. The gap was a missing target, not a missing rule.

```sh
homelab metrics query 'up{job="registry-cache-host"}'
homelab metrics query 'node_filesystem_avail_bytes{job="registry-cache-host",mountpoint="/"}'
```

## Rollback

A pre-change backup of `/etc/resolv.conf`, `/etc/systemd/resolved.conf`,
and `/etc/netplan/` lives at
`/root/dns-backups/dns-config-backup-YYYYMMDD-HHMMSS.tar.gz` on the
VM. To roll back:

```sh
ssh root@10.0.20.10 '
  BACKUP=$(ls -t /root/dns-backups/dns-config-backup-*.tar.gz | head -1)
  tar -xzf "$BACKUP" -C /
  rm -f /etc/systemd/resolved.conf.d/10-internal-dns.conf
  netplan apply
  systemctl restart systemd-resolved
  resolvectl status | head -10
'
```

## Auto-sync pipeline

Changes to `modules/docker-registry/{docker-compose.yml, fix-broken-blobs.sh,
cleanup-tags.sh, nginx_registry.conf, config-private.yml}` deploy
automatically via `.woodpecker/registry-config-sync.yml`:

- Fires on `push` to master touching any of those paths, or via `manual`
  event (Woodpecker UI / API).
- SCPs every managed file to `/opt/registry/` on `10.0.20.10`.
- Bounces containers + nginx when a compose-visible file changed; leaves
  them alone when only scripts changed (cron picks up automatically).
- Runs a dry-run `fix-broken-blobs.sh` at the end to verify the registry
  is still coherent.

SSH credentials: Woodpecker repo-secret `registry_ssh_key` (ed25519,
provisioned 2026-04-19). Public key at `/root/.ssh/authorized_keys` on
`10.0.20.10`. Private key mirrored at `secret/woodpecker/registry_ssh_key`
in Vault (subkeys `private_key` / `public_key` / `known_hosts_entry`).

Manual override if you need to sync right now:

```sh
curl -sf -X POST \
  -H "Authorization: Bearer $WOODPECKER_TOKEN" \
  "https://ci.viktorbarzin.me/api/repos/1/pipelines" \
  -d '{"branch":"master"}' | jq .number
```

## Bouncing registry containers — the nginx DNS trap

`docker compose up -d` on `/opt/registry/docker-compose.yml` recreates
`registry-*` containers when their image tag changes, which assigns them
new IPs on the `registry` bridge network. **`registry-nginx` resolves its
upstream DNS names (`registry-private`, `registry-dockerhub`, …) ONCE at
startup and caches the results** — it does not re-resolve after a
recreate.

Symptom if you forget: `/v2/_catalog` on `:5050` returns
`{"repositories": []}`, `/v2/` returns 200 without auth, pulls return
the wrong image. nginx is forwarding to a stale IP that now belongs to a
different registry-* backend (commonly the pull-through ghcr or
dockerhub cache, which have empty catalogs from the htpasswd-auth user's
perspective).

**Always follow a registry-* bounce with `docker restart registry-nginx`.**
Or prevent the problem by setting a `resolver` directive in
`nginx_registry.conf` so upstream names are re-resolved per request.

```sh
ssh root@10.0.20.10 '
  cd /opt/registry && docker compose up -d
  docker restart registry-nginx
  sleep 3
  docker ps --format "{{.Names}}\t{{.Image}}\t{{.Status}}" \
    | grep -E "registry-"
'
```

## Related docs

- `docs/architecture/dns.md` — resolver IP assignments per subnet.
- `.claude/CLAUDE.md` (at repo root) — notes on the private registry
  and `containerd` `hosts.toml` redirects.
- `docs/runbooks/registry-rebuild-image.md` — rebuild an image after an
  orphan OCI-index incident (different class of problem than DNS).
- `docs/post-mortems/2026-04-19-registry-orphan-index.md` — root cause
  + detection gaps behind the recurring missing-blob incidents.
