# Runbook — pfSense Tailscale subnet router

**What it is:** pfSense (`10.0.20.1`, VMID 101) is a Tailscale subnet router on the
self-hosted Headscale tailnet. It is what lets Tailscale clients reach the Sofia
LAN, the mgmt and k8s VLANs, and the two WireGuard-transited remote sites. It also
offers itself as an exit node.

**Design:** [`docs/plans/2026-08-03-pfsense-tailscale-subnet-router-design.md`](../plans/2026-08-03-pfsense-tailscale-subnet-router-design.md)

| Fact | Value |
|---|---|
| Tailnet address | `100.64.0.9` (Headscale node ID 10, name `pfsense`) |
| Tags | `tag:infra` (owned by `group:admin`) — drives `autoApprovers` |
| Node expiry | **None.** Pre-auth-key registration; do not "fix" this with OIDC login |
| Advertised routes | `192.168.1.0/24`, `10.0.10.0/24`, `10.0.20.0/24`, `192.168.0.0/24`, `192.168.8.0/24`, `192.168.9.0/24` + exit node |
| Client DNS for `.lan` | Technitium **`10.0.20.201`** (NOT `.200` — nothing listens there) |
| Reproducer | `playbooks/pfsense-tailscale.yml` + `playbooks/files/pfsense-tailscale-config.php` |
| Policy source of truth | `stacks/headscale/acl.hujson` (**git-crypt**, main checkout only) |
| Probe | CronJob `tailscale-subnet-router-probe`, `headscale` ns, every 6 h |

---

## Re-run / repair

Always claim presence first — this mutates the estate's single point of failure.

```bash
cd ~/code/infra
scripts/presence claim infra:pfsense --purpose "tailscale subnet router"

ansible-playbook -i playbooks/inventory.ini playbooks/pfsense-tailscale.yml --check --diff   # dry run
ansible-playbook -i playbooks/inventory.ini playbooks/pfsense-tailscale.yml                 # apply
```

The playbook is idempotent: a healthy second run reports `changed=0` and mints no
key. It only registers when `tailscale status` is not `Running`.

**If the node was deleted or expired in Headscale:**

```bash
ansible-playbook -i playbooks/inventory.ini playbooks/pfsense-tailscale.yml -e force_register=true
```

**Adding a route — two edits, or it silently carries nothing:**

1. `$DESIRED_ROUTES` in `playbooks/files/pfsense-tailscale-config.php`
2. `autoApprovers.routes` in `stacks/headscale/acl.hujson`, then
   `cd stacks/headscale && ../../scripts/tg apply`

Then re-run the playbook; its final task asserts every expected route is
**approved**, which is the only thing that catches an advertised-but-unapproved
route.

> `acl.hujson` is git-crypt encrypted. **Edit and apply it from the main checkout
> only** — a worktree bypasses the filter and Terraform would render ciphertext
> into the ConfigMap, breaking policy for every client.

---

## Health checks

```bash
# Headscale side: node online, tagged, never expiring
kubectl -n headscale exec deploy/headscale -c headscale -- headscale nodes list | grep pfsense

# Routes approved (field is approved_routes — the table header "Approved" is not the JSON key)
kubectl -n headscale exec deploy/headscale -c headscale -- headscale nodes list-routes

# pfSense side
ssh admin@10.0.20.1 'tailscale status; tailscale ip -4'
ssh admin@10.0.20.1 'cat /usr/local/etc/rc.conf.d/pfsense_tailscaled'   # what runs on every boot
ssh admin@10.0.20.1 'pfctl -sn | grep 100.64'                            # the two SNAT rules

# Probe on demand (don't wait 6h)
kubectl -n headscale create job --from=cronjob/tailscale-subnet-router-probe probe-adhoc-$(date +%s)
kubectl -n headscale logs -l job-name=probe-adhoc-<ts> -c probe
# healthy: enrolled=1 router_up=1 sofia=1 k8s=1 success=1
```

Expected `rc.conf.d` contents — this file, not the GUI, is what survives a reboot:

```
pfsense_tailscaled_acceptdns_enable="NO"
pfsense_tailscaled_acceptroutes_enable="NO"
pfsense_tailscaled_advertiseroutes="192.168.1.0/24,10.0.10.0/24,10.0.20.0/24,192.168.0.0/24,192.168.8.0/24,192.168.9.0/24"
pfsense_tailscaled_authkey=""
pfsense_tailscaled_loginserver="https://headscale.viktorbarzin.me/"
pfsense_tailscaled_exitnode_enable="YES"
```

---

## Alerts

| Alert | Means | First move |
|---|---|---|
| `TailscaleSubnetRouterDown` | pfSense did not answer a tailnet ping | `ssh admin@10.0.20.1 'tailscale status'`; re-run the playbook |
| `TailscaleLanUnreachableViaTailnet` | Router answers, but a route carries no traffic | Check route approval; `pfctl -sn \| grep 100.64`; if `route="192.168.8.0/24"` or `.0.0/24`, check the WG leg (`wg show tun_wg0`) |
| `TailscaleSubnetRouterProbeStale` | No probe result for >2 runs (13 h) | Reachability is **unverified, not necessarily broken**. Check the CronJob and whether the `tag:probe` key still exists |

Inhibited under `PfSenseVMDown`, `WANGatewayUnreachable`, `InternetEgressDown`,
`HeadscaleDown`, and during `NodeMaintenanceInProgress`.

---

## Diagnosis traps

Three ways to reach a confidently wrong conclusion here. All were hit while
building this.

1. **`tailscale nc` exits 0 without connecting.** It will happily report success
   while tcpdump shows no packets leaving pfSense. Prove a path by reading real
   payload back — an SSH banner, an HTTP status line — never by exit code.
2. **A cluster pod reaches the LAN without the tunnel.** `192.168.1.x` and
   `10.0.20.x` are reachable from pods over ordinary cluster routing, so testing
   from in-cluster proves nothing unless traffic is forced through tailscaled
   (the probe uses its outbound HTTP proxy) *and* you have confirmed a `100.x`
   address first.
3. **busybox `wget` resolves `localhost` to `::1`** while tailscaled's proxy
   listens on IPv4 — "Connection refused" that looks exactly like a dead tunnel.
   Use `127.0.0.1`.

Also:

- **`--advertise-routes` with an empty trailing element** breaks the flag: the
  package joins config rows unconditionally, so a blank row yields `a,b,`. The
  PHP configurator filters blank rows; don't add empty rows in the GUI.
- **`acceptdns` must be present and not `on`.** `tailscale_get_config()` defaults
  that key to `on` when it is *absent*, so deleting it silently re-enables
  MagicDNS on the firewall.
- **The rc script logs the auth key to syslog.** Any key placed in `config.xml`
  ends up in `/var/log/system.log` and in the nightly `config.xml` backup on NFS
  and Synology. The playbook therefore uses a single-use key and blanks it after
  registration.
- **Firewall rules bound to the `Tailscale` interface group do not render.** The
  group has no members in `config.xml`, so pfSense emits nothing for it — verify
  with `pfctl -sr | grep -i tailscale` (empty). Traffic passes because pf never
  filtered it, not because a rule permits it. See the design doc §7.

---

## Manual re-registration (playbook unavailable)

```bash
# 1. Mint a single-use tagged key (user 1 = vbarzin@gmail.com, owns tag:infra)
kubectl -n headscale exec deploy/headscale -c headscale -- \
  headscale preauthkeys create -u 1 --tags tag:infra -e 1h -o json

# 2. On pfSense: store it, resync, register
ssh admin@10.0.20.1 '/usr/local/bin/php -f /tmp/pfsense-tailscale-config.php -- --authkey=<KEY>'

# 3. Confirm, then clear the key
ssh admin@10.0.20.1 'tailscale status'
ssh admin@10.0.20.1 '/usr/local/bin/php -f /tmp/pfsense-tailscale-config.php -- --blank-key'
```

Clearing the key restarts `tailscaled`; it re-authenticates from
`/usr/local/pkg/tailscale/state` and passes through `NoState` for a few seconds
first. Wait for `Running` before concluding anything.
