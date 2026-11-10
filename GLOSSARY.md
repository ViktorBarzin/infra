# Homelab infrastructure

The language we use for the homelab's infrastructure. It starts with network security monitoring; add other areas as their terms settle.

## Language

### Network security monitoring

**Alert**:
A detection the IDS raised against one packet or flow, naming the signature that matched.
_Avoid_: event, hit, incident

**Ban**:
A time-limited CrowdSec decision that an address or range may not pass the firewall.
_Avoid_: block, blacklist entry

**Protocol metadata**:
What the IDS records about a connection's application layer: DNS queries and answers, TLS server names and fingerprints, HTTP hosts. This is what we mean by DPI.
_Avoid_: DPI data, app identification

**Flow record**:
A summary of one connection's addresses, ports, protocol, bytes and packets, taken from the firewall's NetFlow export.
_Avoid_: flow event, connection log

**Firewall-crossing traffic**:
Traffic that passes through the edge firewall: between the internet and the homelab, or between VLANs. It is the only traffic the IDS sees.
_Avoid_: monitored traffic, all traffic

**Home LAN**:
The Sofia household network 192.168.1.0/24, run by the TP-Link AX6000. Its devices reach the internet without crossing the edge firewall.
_Avoid_: LAN, client network

**Host agent**:
Security software installed on a server we run, reporting to the central stores. Never installed on personal devices.
_Avoid_: endpoint agent, management agent

**Opted-in machine**:
A machine that trusts the homelab's interception certificate, so the firewall's proxy decrypts its HTTPS.
_Avoid_: decrypted device, MITM target

**East-west traffic**:
Traffic between hosts on the same VLAN that never reaches the firewall, such as node-to-node traffic on VLAN 20.
_Avoid_: internal traffic, lateral traffic
