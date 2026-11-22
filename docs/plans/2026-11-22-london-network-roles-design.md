---
status: draft
plan: true
---

# London network: one Wi-Fi, a role per device

Today the London Wi-Fi a device joins decides two things at once: what it can discover in the flat, and whether it can reach Sofia. This plan puts every device in one shared network, so casting to the projector always works. Each device gets a role, and only the role decides what it can reach in Sofia.

## In numbers

```numbers
caption: DHCP leases and firewall zones on the London Flint 2, read over SSH on 2026-11-22
rows:
  - {label: Leased devices that can open connections to Sofia, before: "24 of 24", after: "5"}
  - {label: Devices with all of Sofia, before: "24", after: "2 (work laptop, work phone)"}
  - {label: Wi-Fi subnets in the flat, before: "2", after: "1"}
  - {label: Address rewrites between London and Sofia, before: "2 (Flint, OPNsense)", after: "0"}
  - {label: Devices that must re-join the Wi-Fi, before: "-", after: "0"}
  - {label: New services to run in Sofia, before: "0", after: "1 (wifi app)", better: false}
```

## The system, with the change on it

```topology
caption: One routed network; the Flint applies one role per MAC, and the wifi app holds the roles
direction: TD
groups:
  - {id: flat, label: London flat}
  - {id: flint, label: Flint 2 router}
  - {id: sofia, label: Sofia}
nodes:
  - {id: psk, label: "5G-Tower / 2.4G-Tower / 5G-Tower Admin", note: "guest SSID joins br-lan; one subnet 192.168.8.0/24", group: flat, state: changed, risk: medium}
  - {id: guestnet, label: "Guest subnet 192.168.9.0/24", group: flat, state: removed, risk: low}
  - {id: agent, label: Role agent, note: "ipset of MACs per role; iot isolation", group: flint, state: new, risk: high}
  - {id: tunnel, label: WireGuard tunnel, note: "no masquerade; per-role forward rules", group: flint, state: changed, risk: high}
  - {id: opn, label: OPNsense, note: "no source NAT for London", group: sofia, state: changed, risk: medium}
  - {id: tplink, label: Sofia TP-Link router, note: "static route 192.168.8.0/24 via 192.168.1.2", group: sofia, state: changed, risk: medium}
  - {id: app, label: wifi.viktorbarzin.me, note: "own LoadBalancer IP; device list, sign-in, role moves", group: sofia, state: new, risk: medium}
  - {id: authentik, label: Authentik, note: "groups london-admin, london-storage", group: sofia, state: changed, risk: low}
  - {id: nfs, label: ha-london NFS export, note: "admits 192.168.8.103", group: sofia, state: changed, risk: low}
  - {id: services, label: Other Sofia services, group: sofia, state: same}
edges:
  - {from: psk, to: agent, state: changed, label: "role by MAC"}
  - {from: agent, to: app, state: new, label: "pull roles"}
  - {from: app, to: authentik, state: new, label: sign-in}
  - {from: agent, to: tunnel, state: new, label: "allowed roles only"}
  - {from: tunnel, to: opn, state: changed, label: "real London addresses"}
  - {from: opn, to: nfs, state: changed}
  - {from: nfs, to: tplink, state: changed, label: "replies to London"}
  - {from: opn, to: services}
  - {from: psk, to: app, state: new, label: "every role may reach the sign-in page"}
checks:
  - {node: tunnel, text: "A Sofia host sees a London device under its 192.168.8.x address; replies return through the tunnel", status: open}
  - {node: agent, text: "A guest device gets no answer from 10.0.20.0/24; the devvm still reaches the projector over adb", status: open}
  - {node: agent, text: "An iot device cannot reach a laptop in the flat, or iot is recorded as equal to guest", status: open}
  - {node: app, text: "The app sees the device's own address and the Flint maps it to the right MAC", status: open}
  - {node: psk, text: "The work Mac casts to the projector while the projector is a guest", status: open}
  - {node: nfs, text: "The ha-london backup writes to NFS from 192.168.8.103", status: open}
left_out:
  - "Certificates (802.1X, FreeRADIUS, Vault PKI): Viktor accepts that a MAC can be copied"
  - "Tailscale as the identity: Viktor wants no app on the devices"
  - "A captive portal that pops up on join: every device stays guest until it asks for more"
  - "Reflash to OpenWrt 24: loses GL per-app stats and the GL presence integration"
  - "Two subnets with an mDNS reflector: Chromecast discovery over the reflector is unreliable"
  - "Wired LAN ports: nothing is plugged in"
```

## Roles

```config
- {key: admin, where: "work laptop, work phone", old: "any device on 5G-Tower Admin", new: "MAC; all of Sofia"}
- {key: infra-ha, where: ha-london, old: "main LAN", new: "MAC; 192.168.1.127:2049, 10.0.20.200:19532"}
- {key: infra-k8s, where: dell-worker, old: "main LAN, the only address not NATed", new: "MAC; Kubernetes ports"}
- {key: storage, where: "Anca's MacBook", old: "guest, all of Sofia", new: "MAC; 192.168.1.13:445"}
- {key: guest, where: "everyone else: visitors, phones, projector, Echo", old: "guest or main LAN", new: "default, kept forever; internet and the flat"}
- {key: iot, where: "6 plugs, air sensor", old: "main LAN", new: "MAC; internet, no flat if the radio allows"}
```

A person in an Authentik group gets that group's role for a device when they sign in on wifi.viktorbarzin.me from it. Viktor can move any device on the same page. Sofia can open connections to every role. A role limits only connections that start in London.

## Decisions

```decision
- question: What decides that a London device can reach Sofia?
  options:
    - {name: The SSID it joined, note: "casting breaks across SSIDs"}
    - {name: Tailscale on the device, note: "needs an app"}
    - {name: "A role per MAC, enforced by the Flint", chosen: true}
  why: One network for discovery, and a role for Sofia access.
- question: How does a device prove its role?
  options:
    - {name: "MAC address for every role", chosen: true}
    - {name: "Certificate for admin and infra", note: "a hidden SSID, FreeRADIUS and a CA to run"}
  why: Viktor accepts that a visitor who copies a MAC borrows its role.
- question: Do London and Sofia rewrite addresses?
  options:
    - {name: "No NAT: plain routing in both directions", chosen: true}
    - {name: "Masquerade as 10.3.2.6, as today", note: "Sofia cannot tell devices apart"}
  why: Every device keeps its own address, so Sofia logs and the wifi app see the real device.
- question: How do Sofia home LAN hosts (192.168.1.x) answer London without NAT?
  options:
    - {name: "A static route on the TP-Link, 192.168.8.0/24 via 192.168.1.2", chosen: true}
    - {name: Keep NAT to the home LAN only, note: "home LAN hosts see 192.168.1.2"}
  why: The TP-Link already routes 10/8 the same way; one more entry removes the last NAT.
- question: Does routing replace the role firewall?
  options:
    - {name: "No: routing plus role rules on the Flint", chosen: true}
    - {name: "Yes: fully open both ways", note: "visitors and plugs reach Sofia"}
  why: Routing makes devices reachable; the role still decides who may start a connection.
- question: One subnet or two in the flat?
  options:
    - {name: One subnet, chosen: true}
    - {name: Two subnets with an mDNS reflector, note: "Chromecast discovery is unreliable over it"}
  why: Cast, AirPlay and Spotify Connect discovery then work with no extra parts.
- question: When does a device sign in?
  options:
    - {name: A pop-up portal on every join, note: "Google TV and Echo do not support captive portals"}
    - {name: "Only when the person opens wifi.viktorbarzin.me", chosen: true}
  why: Every device works as a guest at once, and a role stays until someone changes it.
- question: How do guests reach the sign-in page without reaching Sofia?
  options:
    - {name: "The app gets its own LoadBalancer IP; every role may reach only that IP", chosen: true}
    - {name: "Open the shared Traefik IP to guests", note: "the local-only middleware admits 192.168.8.0/24"}
  why: A guest then reaches the page and nothing else in Sofia.
- question: How do devices move to the new layout?
  options:
    - {name: "Keep all SSID names and passwords; the guest SSID joins br-lan", chosen: true}
    - {name: New names and passwords, note: "6 plugs, the Echo and the projector re-pair"}
  why: No device re-joins. A holder of the old guest password lands as a guest.
- question: How are iot devices kept away from the flat?
  options:
    - {name: "ebtables on the one SSID; if the radio cannot, iot equals guest", chosen: true}
    - {name: A separate IoT SSID, note: "7 devices re-pair"}
  why: No re-pairing. Plugs keep internet for the vendor apps and updates.
- question: How does enforcement start?
  options:
    - {name: "One week of log-only, then enforce", chosen: true}
    - {name: Enforce on day one}
  why: The pinhole list comes from real traffic; a 16-second sample found 3 flows.
- question: Who can open the Flint admin pages from the LAN?
  options:
    - {name: Every device, as today, chosen: true}
    - {name: Admin role only}
  why: Viktor's call. SSH takes keys only.
```

## Order of work

```timeline
caption: Steps 1 to 3 can be undone with one change; step 4 moves 5 devices to a new SSID
steps:
  - {when: "1. Test", what: "Try iot isolation (AP isolation plus hairpin) on a test SSID", rollback: "Delete the test SSID"}
  - {when: "2. No NAT", what: "Add the TP-Link route; fix the NFS export and the Loki alert; remove the Flint masquerade and the OPNsense source NAT", rollback: "Set masq back on the wgclient1 zone"}
  - {when: "3. Sofia", what: "Authentik groups, wifi app with its database and LoadBalancer IP, alerts", rollback: "Destroy the new stack"}
  - {when: "4. Merge and retire", what: "guest5g joins br-lan; move the 5G-Tower Admin devices to 5G-Tower, then disable 5G-Tower Admin; the role agent starts in log-only mode", ponr: true}
  - {when: "5. Sign in", what: "Assign roles after the move, because private Wi-Fi addresses change with the SSID", rollback: "Move the device back to guest"}
  - {when: "6. One week", what: "Read the log-only entries in Loki; add each needed pinhole to the role list", rollback: "-"}
  - {when: "7. Enforce", what: "Remove the blanket lan and guest forwards to the tunnel; the agent enforces roles", rollback: "Add the lan forward back"}
```

Devices on 5G-Tower Admin on 2026-11-22: Viktor's iPhone, the Watch, mbp-london, portal-london and one unnamed device (`0e:5b:07:32:7e:7d`). dell-worker also joins it when it runs; its Wi-Fi setting is in `playbooks/host_vars/dell-worker.yml`. The Mac and the Watch use private addresses, so they get a new MAC on 5G-Tower. Update their curated names in `provision.sh` in the same step.

## Role sync

```numbers
caption: Requests from the Flint to the wifi app, per day
rows:
  - {label: Role polls, before: "17,280 (every 5 s)", after: "about 1,700 (one held request per 50 s)"}
  - {label: Device table uploads, before: "17,280", after: "one per DHCP change"}
  - {label: Flash writes on the Flint, before: "-", after: "one per role change"}
```

- **Long poll.** The agent sends one request with its list version. The app answers at once when the roles change. Otherwise it answers "no change" after 50 seconds, and the agent asks again.
- **No polling inside the app.** The app waits on Postgres `LISTEN/NOTIFY`, so a role change wakes the held request.
- **Device table on change only.** A dnsmasq `dhcp-script` hook sends the lease table when a lease starts, renews to a new address or ends. Each poll carries a hash of the table. The app asks for the full table only when the hash differs.
- **Atomic apply.** The agent builds new ipsets and swaps them in with `ipset swap`. Then it deletes the open Sofia connections of a device that lost a role. The firewall rules never change.
- **Failure.** When the app does not answer, the agent keeps the last list and waits 5 to 60 seconds before it retries. At boot it loads `/etc/london-roles` before the first poll.
- **Monitoring.** The agent writes the time of its last good sync to the node exporter text file. An alert fires after 10 minutes without a sync.

## Configuration

```config
- {key: wireless.guest5g.network, where: Flint uci, old: "guest", new: "lan"}
- {key: wgclient1 zone masq, where: Flint firewall, old: "1", new: "0"}
- {key: "WireGuard site LANs NAT to WAN", where: playbooks/files/opnsense/nat_outbound.yml, old: "London rewritten to 192.168.1.2", new: "a nonat rule for 192.168.8.0/24 above it"}
- {key: static route, where: "Sofia TP-Link Archer AX6000 web UI (192.168.1.1)", old: "10.0.0.0/8 via 192.168.1.2", new: "plus 192.168.8.0/24 via 192.168.1.2"}
- {key: guest -> wgclient1 forward, where: Flint firewall, old: "accept", new: "removed"}
- {key: lan -> wgclient1 forward, where: Flint firewall, old: "accept", new: "per-role ipset rules from the agent"}
- {key: london-lan-no-nat, where: /etc/firewall.user, old: "192.168.8.0/24 to 10.0.20.0/24", new: "removed (no NAT anywhere)"}
- {key: ha-london-backup export, where: scripts/pve-nfs-exports, old: "192.168.1.2, 10.3.2.6", new: "192.168.8.103"}
- {key: role list, where: "/etc/london-roles on the Flint, kept in sysupgrade.conf", old: "-", new: "copy of the app's roles; rebuilds the ipsets at boot"}
- {key: alerts, where: stacks/monitoring, old: "-", new: "role agent sync older than 10 minutes; the 10.3.2.6 Loki alert moves to 192.168.8.0/24"}
```

The agent and the firewall changes go through `scripts/london-flint/provision.sh`, as the London site doc requires. The app follows `docs/agents/new-app.md`.

> [!NOTE]
> This plan replaces the 2026-09-27 decision that the guest network keeps its path to Sofia.
