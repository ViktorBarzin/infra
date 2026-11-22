# Homelab infrastructure

The language we use for the homelab's infrastructure. It covers network security monitoring, sites and backups, deal watches, notifications and the London radio; add other areas as their terms settle.

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

### Sites and backups

**Site**:
A physical place where homelab hardware runs on its own network: Sofia or London.
_Avoid_: location, region, datacenter

**Off-site copy**:
A backup copy kept at a different Site from the data it protects.
_Avoid_: offsite (for a copy in the same Site), remote backup

**Opportunistic worker**:
A machine that runs non-critical, retryable work whenever it is online; nothing depends on it being up.
_Avoid_: spare node, batch box, build server

**Physical node**:
A Kubernetes node running on its own hardware, as opposed to a VM node on the Sofia Proxmox host.
_Avoid_: bare-metal node, edge node, server

**State volume**:
The encrypted volume on a Physical node that holds every secret and all cluster state; it opens only when the node can reach Tang in Sofia.
_Avoid_: data disk, encrypted partition

**Tether**:
A Physical node's rule to close its State volume when Tang has been unreachable for ten minutes.
_Avoid_: kill switch, dead man's switch

**Spill-over**:
Work that normally runs in the Sofia cluster or on hosted CI and moves to an Opportunistic worker while one is online.
_Avoid_: offload, overflow, burst

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

### Notifications

**Notification**:
One short piece of news the infrastructure sends to people, with a title and a body. It goes to the people subscribed to its alert rule, or to one Recipient.
_Avoid_: alert, message, push

**Alert rule**:
A Prometheus or Loki alerting rule, named by its alertname, such as PVFillingUp. Every one that fires reaches the notify pipe, which is the only way it reaches people.
_Avoid_: alert (an IDS detection), topic

**Rule group**:
A named set of alert rules in Prometheus, such as "R730 Host". A Subscription to a rule group also covers the alert rules added to it later.
_Avoid_: topic, category

**Recipient**:
A person who can receive Notifications, named by their Authentik username. They need not have a devvm account.
_Avoid_: subscriber, user, roster person

**Channel**:
One way to reach one Recipient: their phone through a Home Assistant instance, their email address, or Slack (a direct message, or a channel such as #alerts for an admin).
_Avoid_: provider, target, destination

**Subscription**:
A Recipient's choice to receive one alert rule or one rule group, and on which of their Channels; one Subscription may name several. A choice on an alert rule wins over the choice on its rule group.
_Avoid_: follow, opt-in

**Default channel**:
The Channel that receives the Notifications sent to a Recipient by name instead of through a Subscription.
_Avoid_: primary channel, fallback

### London radio

**Station**:
A radio programme in the London flat's radio, played from its public stream address. Each Station has a button, grouped by genre or country.
_Avoid_: channel, source, preset

**Radio speaker**:
The Logitech Z537 speaker in the London living room, the only place the radio plays.
_Avoid_: player, Echo, projector speaker

**Station directory**:
The public list of internet radio stations from which any station can be found and played without a button.
_Avoid_: catalogue, station list
