# CCTV segment on a dedicated pfSense leg, not an 802.1Q trunk

Status: accepted (2026-07-02)

The first owned camera at the Sofia/Vermont site (`vermont-garage`, HiLook
IPC-T241H-C at the garage entrance) needs to be network-isolated: its cable is
physically exposed outside the apartment, so anything plugged into that cable
must land in a segment that can reach nothing. The original design doc
(NAS: `Emo shared/Claude shared/garage-camera/`) called for an "802.1Q trunk
to pfSense" — but nothing in this network terminates dot1q on pfSense; the
site idiom is one vlan-aware Proxmox bridge → one tagged VM NIC → one clean
untagged pfSense interface per segment.

**Decision:** the CCTV segment (`dCCTV`, 10.0.30.1/24) rides a dedicated
physical leg — R730 `eno2` (spare) → new bridge `vmbr2` → pfSense `net3`
(vtnet3), untagged end-to-end. The shared TL-SG105PE PoE switch in the rack
splits via port-based VLANs: {camera port, eno2 uplink} in an internal VLAN,
{home-LAN uplink, 4G router 192.168.1.7, UPS mgmt, switch mgmt 192.168.1.6}
stay in VLAN 1. Cameras are untrusted: default-deny on dCCTV with a single
NTP-to-gateway exception; Frigate (k8s) pulls RTSP in; ha-sofia (192.168.1.8)
may reach ISAPI/RTSP directly; home-LAN clients route in via an AX6000 static
route (10.0.30.0/24 via 192.168.1.2). 10.0.30.0/24 is deliberately NOT in the
10.0.20.0/22 trusted source-IP allowlist.

## Considered options

- **802.1Q tag over the existing LAN path (eno1/vmbr0)** — rejected: vmbr0 is
  vlan-aware with `bridge-vids 2-4094`, so ANY device on the home LAN could
  inject tagged frames straight into the camera segment (defeats the
  cable-tap threat model); tag-passing through the unmanaged SW1 is
  undefined; and it reconfigures the live bridge carrying the host IP and
  pfSense WAN.
- **AX6000 as the camera gateway** — rejected earlier in the design (consumer
  router, no inter-VLAN firewall).

## Consequences

- eno2 is consumed; eno3/eno4 remain the last spare NICs on the R730.
- The TL-SG105PE is now load-bearing shared infra: it carries pfSense's
  backup-WAN path (4G router), UPS mgmt, AND the CCTV segment. Its Easy
  Smart mgmt UI answers on every port regardless of VLAN — mitigated by a
  strong password; residual L2 risk accepted.
- Adding a future camera = one PoE port in the CCTV VLAN + a Kea
  reservation; no pfSense/PVE work.
- Frigate's ADR-0016 VRAM budget was bumped 2000 → 2300 MiB for the extra
  NVDEC stream.
