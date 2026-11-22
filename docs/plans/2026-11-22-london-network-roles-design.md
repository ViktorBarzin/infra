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
  - {label: Devices that must re-join the Wi-Fi, before: "-", after: "0"}
  - {label: New services to run in Sofia, before: "0", after: "2 (FreeRADIUS, wifi app)", better: false}
```

## The system, with the change on it

```topology
caption: The Flint applies one role per device; certificates prove the strong roles, the wifi app holds the rest
direction: TD
groups:
  - {id: flat, label: London flat}
  - {id: flint, label: Flint 2 router}
  - {id: sofia, label: Sofia cluster}
nodes:
  - {id: psk, label: "5G-Tower / 2.4G-Tower (shared password)", note: "the guest SSID joins br-lan; one subnet 192.168.8.0/24", group: flat, state: changed, risk: medium}
  - {id: cert, label: Hidden certificate SSID, note: "EAP-TLS, both bands", group: flat, state: new, risk: medium}
  - {id: guestnet, label: "Guest subnet 192.168.9.0/24", group: flat, state: removed, risk: low}
  - {id: agent, label: Role agent, note: "ipsets per role, ebtables SSID mark, iot isolation", group: flint, state: new, risk: high}
  - {id: tunnel, label: WireGuard tunnel to Sofia, note: "no blanket lan or guest forward", group: flint, state: changed, risk: high}
  - {id: radius, label: FreeRADIUS, note: "certificate to role", group: sofia, state: new, risk: medium}
  - {id: pki, label: Vault PKI mount, note: "device certificates, CRL", group: sofia, state: new, risk: low}
  - {id: app, label: wifi.viktorbarzin.me, note: "device list, sign-in, role moves", group: sofia, state: new, risk: medium}
  - {id: authentik, label: Authentik, note: "groups london-admin, london-storage", group: sofia, state: changed, risk: low}
  - {id: services, label: Sofia services, group: sofia, state: same}
edges:
  - {from: psk, to: agent, state: changed, label: "role by MAC"}
  - {from: cert, to: agent, state: new, label: "role by certificate"}
  - {from: cert, to: radius, state: new, label: EAP-TLS}
  - {from: radius, to: pki, state: new, label: "CA, CRL"}
  - {from: app, to: authentik, state: new, label: sign-in}
  - {from: agent, to: app, state: new, label: "pull roles"}
  - {from: agent, to: tunnel, state: new, label: "only allowed roles"}
  - {from: tunnel, to: services}
checks:
  - {node: agent, text: "A frame from the certificate SSID gets the ebtables mark; the same MAC on the password SSID does not", status: open}
  - {node: agent, text: "An iot device cannot reach a laptop in the flat, or iot is recorded as equal to guest", status: open}
  - {node: radius, text: "8021xd on the Flint authenticates a test certificate against FreeRADIUS over the tunnel", status: open}
  - {node: psk, text: "The work Mac casts to the projector while the projector is a guest", status: open}
  - {node: tunnel, text: "A guest device gets no answer from 10.0.20.0/24; the devvm still reaches the projector over adb", status: open}
left_out:
  - "Tailscale as the identity: Viktor wants no app on the devices"
  - "A captive portal that pops up on join: every device stays guest until it asks for more"
  - "Reflash to OpenWrt 24 for RADIUS VLANs: loses GL per-app stats and the GL presence integration"
  - "Two subnets with an mDNS reflector: Chromecast discovery over the reflector is unreliable"
  - "Wired LAN ports: nothing is plugged in"
```

## Roles

```config
- {key: admin, where: "work laptop, work phone", old: "any device on 5G-Tower Admin", new: "certificate; all of Sofia"}
- {key: infra-ha, where: ha-london, old: "main LAN", new: "certificate (MAC if HAOS cannot hold it); 192.168.1.127:2049, 10.0.20.200:19532"}
- {key: infra-k8s, where: dell-worker, old: "main LAN, 192.168.8.0/24 not NATed", new: "certificate via Ansible; Kubernetes ports, only its address not NATed"}
- {key: storage, where: "Anca's MacBook", old: "guest, all of Sofia", new: "MAC after Authentik sign-in; 192.168.1.13:445"}
- {key: guest, where: "everyone else: visitors, phones, projector, Echo", old: "guest or main LAN", new: "default, kept forever; internet and the flat"}
- {key: iot, where: "6 plugs, air sensor", old: "main LAN", new: "MAC, moved by Viktor; internet, no flat if the radio allows"}
```

Sofia can open connections to every role. A role limits only connections that start in London.

## Decisions

```decision
- question: What decides that a London device can reach Sofia?
  options:
    - {name: The SSID it joined, note: "casting breaks across SSIDs"}
    - {name: Tailscale on the device, note: "needs an app"}
    - {name: "A role per device, enforced by the Flint", chosen: true}
  why: One network for discovery, and identity for Sofia access.
- question: How does a device prove a strong role?
  options:
    - {name: MAC address for every role, note: "visitors know the password and can copy a MAC; the NFS shares have no login"}
    - {name: "Certificate for admin and infra, MAC for storage, guest and iot", chosen: true}
  why: A copied MAC then gets storage at most, and that share asks for a password.
- question: One subnet or two?
  options:
    - {name: "One subnet; the certificate SSID marks its frames", chosen: true}
    - {name: Two subnets with an mDNS reflector, note: "Chromecast discovery is unreliable over it"}
  why: Cast, AirPlay and Spotify Connect discovery then work with no extra parts.
- question: Where does FreeRADIUS run?
  options:
    - {name: A pod in the Sofia cluster, chosen: true}
    - {name: On the Flint, note: "a GL firmware upgrade removes opkg packages"}
    - {name: On dell-worker, note: "dell-worker itself joins by certificate"}
  why: It is in Terraform. Without the tunnel there is no Sofia to reach, so a failed join costs nothing.
- question: How does a device get a certificate?
  options:
    - {name: "homelab wifi enroll / revoke, from a Vault PKI mount", chosen: true}
    - {name: Manual openssl CA, note: "no audit trail"}
  why: Vault records every issue and revoke; FreeRADIUS checks the CRL.
- question: When does a device sign in?
  options:
    - {name: A pop-up portal on every join, note: "Google TV and Echo do not support captive portals"}
    - {name: "Only when the person opens wifi.viktorbarzin.me", chosen: true}
  why: Every device works as a guest at once, and a role is kept until someone changes it.
- question: What can a self-service sign-in grant?
  options:
    - {name: "storage at most; admin only through a certificate or a move by Viktor", chosen: true}
    - {name: The role of any group the user is in, note: "admin by MAC is copyable"}
  why: Admin by MAC exists only for the work phone, and only if its MDM blocks the profile.
- question: How do devices move to the new layout?
  options:
    - {name: "Keep all SSID names and passwords; the guest SSID joins br-lan", chosen: true}
    - {name: New names and passwords, note: "6 plugs, the Echo and the projector re-pair"}
  why: No device re-joins. A holder of the old guest password lands as a guest, with no Sofia.
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
caption: Every step up to the retirement of 5G-Tower Admin can be undone with one change
steps:
  - {when: "1. Tests", what: "Prove each check in the picture on a test SSID; try EAP on HAOS and the work phone profile", rollback: "Delete the test SSID"}
  - {when: "2. Sofia", what: "Vault PKI mount, FreeRADIUS stack, Authentik groups, wifi app and its database, alerts", rollback: "Destroy the new stacks"}
  - {when: "3. Certificate SSID", what: "Hidden SSID live; enrol the work laptop, work phone, dell-worker, ha-london", rollback: "Disable the SSID"}
  - {when: "4. Merge", what: "guest5g joins br-lan; the role agent runs in log-only mode", rollback: "Set guest5g back to the guest network"}
  - {when: "5. One week", what: "Read the log-only entries in Loki; add each needed pinhole to the role list", rollback: "-"}
  - {when: "6. Enforce", what: "Remove the blanket lan and guest forwards to the tunnel; the agent enforces roles", rollback: "Add the lan forward back"}
  - {when: "7. Retire", what: "Disable 5G-Tower Admin after its devices use the certificate SSID or 5G-Tower", ponr: true}
```

## Configuration

```config
- {key: wireless.guest5g.network, where: Flint uci, old: "guest", new: "lan"}
- {key: "certificate SSID (ra, rax)", where: Flint uci, old: "-", new: "encryption wpa2, hidden, auth_server = FreeRADIUS, network lan"}
- {key: guest -> wgclient1 forward, where: Flint firewall, old: "accept", new: "removed"}
- {key: lan -> wgclient1 forward, where: Flint firewall, old: "accept", new: "per-role ipset rules from the agent"}
- {key: london-lan-no-nat, where: /etc/firewall.user, old: "192.168.8.0/24 to 10.0.20.0/24", new: "dell-worker only"}
- {key: role list, where: "/etc/london-roles on the Flint, kept in sysupgrade.conf", old: "-", new: "copy of the app's roles; rebuilds the ipsets at boot"}
- {key: alerts, where: stacks/monitoring, old: "-", new: "FreeRADIUS down; role agent sync older than 10 minutes"}
```

The agent, the SSID and the firewall changes go through `scripts/london-flint/provision.sh`, as the London site doc requires. The app follows `docs/agents/new-app.md`.

> [!NOTE]
> This plan replaces the 2026-09-27 decision that the guest network keeps its path to Sofia.
