# Homelab infrastructure

The language we use for the homelab's infrastructure. It starts with network security monitoring and deal watches; add other areas as their terms settle.

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

**Opted-in machine**:
A machine that trusts the homelab's interception certificate, so the firewall's proxy decrypts its HTTPS.
_Avoid_: decrypted device, MITM target

**East-west traffic**:
Traffic between hosts on the same VLAN that never reaches the firewall, such as node-to-node traffic on VLAN 20.
_Avoid_: internal traffic, lateral traffic

### Deal watches

**Deal watch**:
A standing request to be told when one product, on one shop page, sells new below its target price. All deal watches are on one list that every deal watcher shares.
_Avoid_: price watch, price alert, monitor

**Target price**:
The price that a deal watch's product must go below before anyone is told. If the requester names no price, it is the price on the day the watch was added.
_Avoid_: threshold, trigger price

**Deal watcher**:
A person who may add, list and remove deal watches. Membership of the Authentik group "Deal Watchers" makes a person one.
_Avoid_: subscriber, watch owner

**Requester**:
The deal watcher who added a deal watch. The watch shows their Authentik username; it does not give them more rights than other deal watchers.
_Avoid_: owner

**Price history**:
The past prices of one product on one shop, as a price tracker such as Keepa recorded them. It helps to choose a target price; it never fires a deal watch.
_Avoid_: price chart, price graph
