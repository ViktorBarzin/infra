"""Fill phpIPAM with every IPv4 address in use, and publish the names it owns.

Run every 5 minutes by the phpipam-import CronJob (stacks/phpipam/main.tf).
Design and rules: docs/adr/0032-phpipam-is-an-auto-filled-address-inventory.md
and docs/plans/2026-10-13-phpipam-inventory.md; terms in CONTEXT.md, "Address
inventory".

Each run reads every Source first:
  - the OpenWrt site routers (London, Valchedrym, Mladost 3): leases, static
    leases and ARP, fetched by the job's shell wrapper over the pfSense SSH hop
    into SOURCE_DIR/<site>.txt;
  - pfSense (SOURCE_DIR/sofia.txt): Kea leases and reservations, the ARP table
    after a ping sweep of the home LAN, and the WireGuard peers;
  - Kubernetes: node addresses and LoadBalancer addresses, from the API;
  - Headscale: tailnet nodes, from its API;
  - Technitium: the viktorbarzin.lan zone, for existing names.
Then it reconciles phpIPAM rows (hand rows are never touched), publishes the
OpenWrt sites' lease names and the hand-row names to viktorbarzin.lan, and
exits non-zero if any Source failed. A failed Source's rows are left as they
are. DRY_RUN=1 prints every write instead of making it.
"""
from __future__ import annotations

import csv
import datetime as dt
import io
import ipaddress
import json
import os
import re
import ssl
import sys
import time
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from dataclasses import dataclass, field

ZONE = "viktorbarzin.lan"
TTL = 300
# Technitium record comment marking records this job owns outside the site
# ranges (hand-row names), so a renamed or deleted hand row can be cleaned up.
COMMENT = "phpipam"
GRACE_HOURS = 24


@dataclass(frozen=True)
class Net:
    cidr: str
    description: str
    location: str | None
    vlan: int | None = None
    # The OpenWrt site whose lease names this job publishes to DNS, or None.
    publish: str | None = None
    reverse_zone: str | None = None


NETWORKS = [
    Net("192.168.1.0/24", "Sofia home LAN", "Sofia"),
    Net("10.0.10.0/24", "Sofia management (VLAN 10)", "Sofia", vlan=10),
    Net("10.0.20.0/24", "Sofia Kubernetes (VLAN 20)", "Sofia", vlan=20),
    Net("10.0.30.0/24", "Sofia CCTV (VLAN 30)", "Sofia", vlan=30),
    Net("10.3.2.0/24", "WireGuard site tunnels", "Sofia"),
    Net("192.168.8.0/24", "London LAN", "London", publish="london", reverse_zone="8.168.192.in-addr.arpa"),
    Net("192.168.9.0/24", "London Guest", "London", publish="london", reverse_zone="9.168.192.in-addr.arpa"),
    Net("192.168.0.0/24", "Valchedrym LAN", "Valchedrym", publish="valchedrym", reverse_zone="0.168.192.in-addr.arpa"),
    Net("192.168.3.0/24", "Mladost 3 LAN", "Mladost 3", publish="mladost3", reverse_zone="3.168.192.in-addr.arpa"),
    Net("100.64.0.0/10", "Headscale tailnet", None),
]
_PARSED = [(ipaddress.ip_network(n.cidr), n) for n in NETWORKS]
LOCATIONS = ["Sofia", "London", "Valchedrym", "Mladost 3"]
VLANS = {10: "Management", 20: "Kubernetes", 30: "CCTV"}
DEMO_VLANS = {(2001, "IPv6 private 1"), (4001, "Servers DMZ")}
SITES = ["london", "valchedrym", "mladost3"]  # publishing order; earlier sites keep a contested name
SOURCES = {"sofia", "london", "valchedrym", "mladost3", "k8s", "headscale"}
DYNAMIC_KINDS = {"dhcp", "arp"}
DECLARED_KINDS = {"reservation", "interface", "wireguard", "k8s", "headscale"}


@dataclass(frozen=True)
class Lease:
    mac: str
    ip: str
    hostname: str


@dataclass(frozen=True)
class Host:
    """A reservation: a Kea reservation or an OpenWrt static lease."""
    mac: str
    ip: str | None
    name: str | None


@dataclass(frozen=True)
class Obs:
    """One address a Source reports this run."""
    ip: str
    subnet_id: int
    kind: str  # "dynamic" or "declared"
    mac: str
    name: str | None
    desc: str
    source: str
    tier: int  # 0 declared, 1 DHCP lease, 2 ARP entry: the lower wins an address


@dataclass(frozen=True)
class Row:
    id: int
    ip: str
    subnet_id: int
    mac: str
    hostname: str
    description: str
    last_seen: dt.datetime


@dataclass
class RowPlan:
    inserts: list[Obs] = field(default_factory=list)
    updates: list[tuple[int, Obs]] = field(default_factory=list)
    deletes: list[int] = field(default_factory=list)
    skipped: list[Obs] = field(default_factory=list)


# --- pure helpers ------------------------------------------------------------


def network_of(ip: str) -> Net | None:
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return None
    return next((n for net, n in _PARSED if addr in net), None)


def sanitize(raw: str | None) -> str | None:
    """A hostname as a DNS label: lowercase [a-z0-9-], at most 63 long."""
    if not raw or raw == "*":
        return None
    label = raw.split(".")[0].lower()
    label = re.sub(r"[^a-z0-9-]+", "-", label)
    label = re.sub(r"-+", "-", label).strip("-")[:63].strip("-")
    return label or None


def mac4(mac: str) -> str:
    return mac.replace(":", "").lower()[-4:]


def split_sections(text: str) -> dict[str, str]:
    """Split a source dump on ---NAME--- lines; text before the first is ''."""
    out: dict[str, list[str]] = {"": []}
    cur = ""
    for line in text.splitlines(keepends=True):
        m = re.match(r"^---([A-Z0-9_]+)---\s*$", line)
        if m:
            cur = m.group(1)
            out.setdefault(cur, [])
        else:
            out[cur].append(line)
    return {k: "".join(v) for k, v in out.items()}


def parse_leases(text: str) -> list[Lease]:
    """dnsmasq lease lines, newest lease per MAC, tracked networks only."""
    newest: dict[str, tuple[int, Lease]] = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 4 or not parts[0].isdigit():
            continue
        expiry, mac, ip, hostname = int(parts[0]), parts[1].lower(), parts[2], parts[3]
        if network_of(ip) is None:
            continue
        if mac not in newest or expiry > newest[mac][0]:
            newest[mac] = (expiry, Lease(mac=mac, ip=ip, hostname=hostname))
    return [lease for _, lease in newest.values()]


_MAC_RE = re.compile(r"[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}")


def parse_uci_hosts(text: str) -> list[Host]:
    """One Host per MAC (or one without a MAC) for every `uci show dhcp` host section."""
    sections: dict[str, dict[str, str]] = {}
    kinds: dict[str, str] = {}
    for line in text.splitlines():
        m = re.match(r"^dhcp\.([^.=]+)=(\S+)$", line)
        if m:
            kinds[m.group(1)] = m.group(2)
            continue
        m = re.match(r"^dhcp\.([^.=]+)\.(mac|name|ip)=(.*)$", line)
        if m:
            sections.setdefault(m.group(1), {})[m.group(2)] = m.group(3)
    hosts: list[Host] = []
    for sec, opts in sections.items():
        if kinds.get(sec) != "host":
            continue
        name = sanitize(opts.get("name", "").strip("'"))
        ip = opts.get("ip", "").strip("'") or None
        macs = [m.lower() for m in _MAC_RE.findall(opts.get("mac", ""))]
        for mac in macs or [""]:
            hosts.append(Host(mac=mac, ip=ip, name=name))
    return hosts


def curated_names(hosts: list[Host]) -> dict[str, str]:
    return {h.mac: h.name for h in hosts if h.mac and h.name}


def parse_proc_arp(text: str) -> list[tuple[str, str]]:
    """(ip, mac) for complete entries of Linux /proc/net/arp, tracked networks only."""
    out = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 4 or parts[2] != "0x2" or network_of(parts[0]) is None:
            continue
        if _MAC_RE.fullmatch(parts[3]) and parts[3] != "00:00:00:00:00:00":
            out.append((parts[0], parts[3].lower()))
    return out


def parse_bsd_arp(text: str) -> list[tuple[str, str, bool]]:
    """(ip, mac, is_own_interface) from FreeBSD `arp -an`, tracked networks only."""
    out = []
    for line in text.splitlines():
        m = re.match(r"^\S+ \((\d+\.\d+\.\d+\.\d+)\) at ([0-9a-fA-F:]{17}) on \S+ (.*)$", line)
        if m and network_of(m.group(1)) is not None:
            out.append((m.group(1), m.group(2).lower(), "permanent" in m.group(3)))
    return out


def parse_kea_leases(text: str, now_epoch: float) -> list[Lease]:
    """Active Kea memfile leases: the last line per address wins; state 0 and unexpired only."""
    last: dict[str, dict[str, str]] = {}
    for rec in csv.DictReader(io.StringIO(text)):
        if rec.get("address") and rec["address"] != "address":
            last[rec["address"]] = rec
    out = []
    for ip, rec in last.items():
        try:
            expire = int(rec.get("expire") or 0)
        except ValueError:
            continue
        if rec.get("state", "0") != "0" or expire <= now_epoch or network_of(ip) is None:
            continue
        out.append(Lease(mac=(rec.get("hwaddr") or "").lower(), ip=ip, hostname=rec.get("hostname") or "*"))
    return out


def parse_kea_reservations(text: str) -> list[Host]:
    conf = json.loads(text)
    out = []
    for subnet in conf.get("Dhcp4", {}).get("subnet4", []):
        for r in subnet.get("reservations", []):
            if r.get("ip-address"):
                out.append(Host(mac=(r.get("hw-address") or "").lower(), ip=r["ip-address"],
                                name=sanitize(r.get("hostname"))))
    return out


def parse_wg_allowed_ips(text: str) -> list[tuple[str, str]]:
    """(tunnel address, the peer's other routes) from `wg show <if> allowed-ips`."""
    out = []
    for line in text.splitlines():
        if "\t" not in line:
            continue
        nets = line.split("\t", 1)[1].split()
        hosts = [n.split("/")[0] for n in nets if n.endswith("/32") and network_of(n.split("/")[0])]
        others = " ".join(n for n in nets if not n.endswith("/32"))
        for h in hosts:
            out.append((h, others))
    return out


def assign_names(leases: list[Lease], curated: dict[str, str], taken: set[str], site: str) -> dict[str, str | None]:
    """MAC -> DNS name (or None) for one OpenWrt site. Deterministic regardless of lease order.

    Curated names win over announced ones. A name shared by several devices at
    the site gets each device's MAC suffix (a curated holder keeps the bare
    name). A name in `taken` (held outside the site) gets "-<site>". The result
    never repeats a name and never uses one from `taken`.
    """
    base: dict[str, tuple[str, bool]] = {}
    for lease in leases:
        if lease.mac in curated:
            base[lease.mac] = (curated[lease.mac], True)
        else:
            name = sanitize(lease.hostname)
            if name:
                base[lease.mac] = (name, False)

    counts = Counter(name for name, _ in base.values())
    curated_counts = Counter(name for name, is_curated in base.values() if is_curated)

    out: dict[str, str | None] = {lease.mac: None for lease in leases}
    for mac in sorted(base):
        name, is_curated = base[mac]
        if counts[name] > 1 and not (is_curated and curated_counts[name] == 1):
            name = f"{name}-{mac4(mac)}"
        if name in taken:
            name = f"{name}-{site}"
        out[mac] = name

    # A rename above can land on a name another device already holds. Those,
    # and anything still in `taken`, get the MAC suffix; if even that clashes
    # the device stays unnamed rather than share a name.
    used: set[str] = set()
    for mac in sorted(out, key=lambda m: (out[m] is None, out[m] or "", m)):
        name = out[mac]
        if name is None:
            continue
        if name in used or name in taken:
            name = f"{name}-{mac4(mac)}"
        if name in used or name in taken:
            print(f"  WARN {mac}: no free name for {out[mac]!r}, left unnamed")
            out[mac] = None
            continue
        used.add(name)
        out[mac] = name
    return out


def pick_name(reserved: str | None, leased: str | None, from_dns: str | None) -> str | None:
    """Name precedence below a hand row: reservation, then lease hostname, then DNS."""
    for candidate in (reserved, leased, from_dns):
        name = sanitize(candidate)
        if name:
            return name
    return None


def row_kind(description: str) -> tuple[str, str | None]:
    """("hand", None), ("dynamic", source) or ("declared", source) from a row description."""
    if not description.startswith("-- "):
        return ("hand", None)
    tokens = description.strip("- ").split()
    kind = tokens[0] if tokens else ""
    if kind in DYNAMIC_KINDS and len(tokens) > 1 and tokens[1] in SOURCES:
        return ("dynamic", tokens[1])
    if kind in DECLARED_KINDS:
        if kind in ("k8s", "headscale"):
            return ("declared", kind)
        if kind == "wireguard":
            return ("declared", "sofia")
        if len(tokens) > 1 and tokens[1] in SOURCES:
            return ("declared", tokens[1])
    # Rows from before 2026-10-13 ("-- autodiscovered --", "-- wg tunnel scan --",
    # the first London marker): treated as dynamic, so they expire unless seen.
    return ("dynamic", "legacy")


def plan_rows(seen: list[Obs], rows: list[Row], now: dt.datetime, failed: set[str],
              grace_hours: int = GRACE_HOURS) -> RowPlan:
    """What to change in phpIPAM so each observed address has exactly one row."""
    plan = RowPlan()

    # One observation per address: declared beats a lease, a lease beats ARP.
    by_ip: dict[str, Obs] = {}
    for o in sorted(seen, key=lambda o: o.tier):
        by_ip.setdefault(o.ip, o)
    obs_list = sorted(by_ip.values(), key=lambda o: ipaddress.ip_address(o.ip))

    hand_ips = {r.ip for r in rows if row_kind(r.description)[0] == "hand"}
    owned = [r for r in rows if row_kind(r.description)[0] != "hand"]
    owned_by_ip = {r.ip: r for r in owned}
    owned_by_mac: dict[str, list[Row]] = defaultdict(list)
    for r in owned:
        if r.mac:
            owned_by_mac[r.mac.lower()].append(r)
    dyn_ips_per_mac = Counter(o.mac for o in obs_list if o.kind == "dynamic" and o.mac)

    matched: dict[int, Obs] = {}
    for o in obs_list:
        if o.ip in hand_ips:
            plan.skipped.append(o)
            continue
        mine = None
        if o.kind == "declared":
            mine = owned_by_ip.get(o.ip)
        elif o.mac:
            candidates = [r for r in owned_by_mac.get(o.mac, []) if r.id not in matched]
            if dyn_ips_per_mac[o.mac] > 1:
                candidates = [r for r in candidates if r.ip == o.ip]
            # Prefer the row already at this address, then the most recently seen.
            candidates.sort(key=lambda r: (r.ip != o.ip, -r.last_seen.timestamp()))
            mine = candidates[0] if candidates else None
        else:
            mine = owned_by_ip.get(o.ip)
        if mine is not None and mine.id in matched:
            mine = None
        if mine is None:
            plan.inserts.append(o)
        else:
            matched[mine.id] = o
            plan.updates.append((mine.id, o))

    # A row sitting on an address that now belongs to another observation goes,
    # unless it is itself moving elsewhere in this plan.
    targets = {o.ip for o in plan.inserts} | {o.ip for _, o in plan.updates}
    deletes: set[int] = set()
    for r in owned:
        if r.id in matched:
            continue
        if r.ip in targets:
            deletes.add(r.id)
            continue
        kind, source = row_kind(r.description)
        if source in failed:
            continue
        if kind == "declared" or r.last_seen < now - dt.timedelta(hours=grace_hours):
            deletes.add(r.id)
    plan.deletes = sorted(deletes)
    return plan


def plan_dns(desired: dict[str, str], current: dict[str, set[str]]) -> tuple[dict[str, str], dict[str, set[str]]]:
    """(upserts, deletes): write a key whose value set differs, drop keys no longer wanted."""
    upserts = {k: v for k, v in desired.items() if current.get(k) != {v}}
    deletes = {k: set(v) for k, v in current.items() if k not in desired}
    return upserts, deletes


class Zone:
    """An in-memory copy of one Technitium zone, kept current as this run writes."""

    def __init__(self) -> None:
        self.recs: dict[str, list[tuple[str, str, str]]] = defaultdict(list)

    def add(self, name: str, rtype: str, value: str, comment: str = "") -> None:
        self.recs[name].append((rtype, value, comment))

    def set_a(self, name: str, ip: str, comment: str = "") -> None:
        self.recs[name] = [r for r in self.recs[name] if r[0] != "A"] + [("A", ip, comment)]

    def delete_a(self, name: str, ip: str) -> None:
        self.recs[name] = [r for r in self.recs[name] if not (r[0] == "A" and r[1] == ip)]

    def a(self, name: str) -> set[str]:
        return {v for t, v, _ in self.recs.get(name, []) if t == "A"}

    def names(self) -> set[str]:
        return {n for n, rs in self.recs.items() if rs}

    def names_outside(self, nets: list[Net]) -> set[str]:
        """Names with any record that is not an A record into `nets`."""
        out = set()
        for name, rs in self.recs.items():
            for t, v, _ in rs:
                if not (t == "A" and network_of(v) in nets):
                    out.add(name)
        return out

    def a_into(self, nets: list[Net]) -> dict[str, set[str]]:
        out: dict[str, set[str]] = {}
        for name, rs in self.recs.items():
            for t, v, _ in rs:
                if t == "A" and network_of(v) in nets:
                    out.setdefault(name, set()).add(v)
        return out

    def marked_a(self) -> dict[str, set[str]]:
        out: dict[str, set[str]] = {}
        for name, rs in self.recs.items():
            for t, v, c in rs:
                if t == "A" and c == COMMENT:
                    out.setdefault(name, set()).add(v)
        return out

    def is_marked(self, name: str) -> bool:
        rs = self.recs.get(name, [])
        return bool(rs) and all(t == "A" and c == COMMENT for t, _, c in rs)

    def name_for_ip(self, ip: str) -> str | None:
        names = sorted((n for n, rs in self.recs.items() if any(t == "A" and v == ip for t, v, _ in rs)),
                       key=lambda n: (len(n), n))
        return names[0] if names else None


def hand_names(rows: list[Row], zone: Zone) -> tuple[dict[str, str], list[str]]:
    """Name -> address for hand rows; a name several rows share goes to the one DNS already has."""
    by_name: dict[str, list[str]] = defaultdict(list)
    for r in rows:
        if row_kind(r.description)[0] == "hand":
            name = sanitize(r.hostname)
            if name:
                by_name[name].append(r.ip)
    want: dict[str, str] = {}
    dups: list[str] = []
    for name, ips in sorted(by_name.items()):
        if len(set(ips)) == 1:
            want[name] = ips[0]
            continue
        dups.append(name)
        current = zone.a(name) & set(ips)
        if len(current) == 1:
            want[name] = current.pop()
    return want, dups


def plan_hand_dns(want: dict[str, str], zone: Zone) -> tuple[dict[str, str], dict[str, set[str]], list[str]]:
    """(writes, deletes, conflicts) for hand-row names outside the site ranges."""
    writes: dict[str, str] = {}
    conflicts: list[str] = []
    for name, ip in sorted(want.items()):
        rs = zone.recs.get(name, [])
        if not rs:
            writes[name] = ip
        elif zone.a(name) == {ip} and all(t == "A" for t, _, _ in rs):
            if not zone.is_marked(name):
                writes[name] = ip  # adopt: rewrite with the comment
        elif zone.is_marked(name):
            writes[name] = ip
        else:
            conflicts.append(name)
    deletes = {n: ips for n, ips in zone.marked_a().items() if n not in want}
    return writes, deletes, conflicts


# --- I/O -----------------------------------------------------------------------


class Technitium:
    def __init__(self, url: str, token: str | None, user: str, password: str, dry_run: bool):
        self.url = url.rstrip("/")
        self.dry_run = dry_run
        self.token = token or self._call("/api/user/login", {"user": user, "pass": password})["token"]

    def _call(self, path: str, params: dict[str, str]) -> dict:
        req = urllib.request.Request(f"{self.url}{path}", data=urllib.parse.urlencode(params).encode(), method="POST")
        with urllib.request.urlopen(req, timeout=20) as resp:
            body = json.load(resp)
        # Technitium answers HTTP 200 for failures too; the outcome is "status".
        if body.get("status") != "ok":
            raise RuntimeError(f"technitium {path}: {json.dumps(body)[:300]}")
        return body.get("response", {})

    def call(self, path: str, **params: str) -> dict:
        return self._call(path, {"token": self.token, **params})

    def write(self, path: str, **params: str) -> None:
        if self.dry_run:
            print(f"    DRY-RUN {path} {params}")
            return
        self.call(path, **params)

    def zone(self, zone: str) -> Zone:
        z = Zone()
        suffix = "." + zone
        for rec in self.call("/api/zones/records/get", domain=zone, zone=zone, listZone="true")["records"]:
            fqdn = rec["name"].lower().rstrip(".")
            if not fqdn.endswith(suffix):
                continue
            label = fqdn[: -len(suffix)]
            rd = rec.get("rData", {})
            value = rd.get("ipAddress") or rd.get("cname") or rd.get("ptrName") or json.dumps(rd, sort_keys=True)
            z.add(label, rec["type"], value, rec.get("comments") or "")
        return z

    def ptrs(self, zone: str) -> dict[str, set[str]]:
        out: dict[str, set[str]] = {}
        for rec in self.call("/api/zones/records/get", domain=zone, zone=zone, listZone="true")["records"]:
            if rec["type"] == "PTR":
                out.setdefault(rec["name"].lower(), set()).add(rec["rData"]["ptrName"].lower())
        return out

    def zones(self) -> set[str]:
        return {z["name"] for z in self.call("/api/zones/list")["zones"]}


def http_json(url: str, headers: dict[str, str], ctx: ssl.SSLContext | None = None) -> dict:
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=20, context=ctx) as resp:
        return json.load(resp)


def read_text(path: str) -> str:
    with open(path) as f:
        return f.read()


def read_openwrt(site: str, data: str) -> tuple[list[Lease], list[Host], list[tuple[str, str]]]:
    parts = split_sections(data)
    if "UCI" not in parts or "ARP" not in parts:
        raise RuntimeError(f"{site}: no data from the router (tunnel or SSH down)")
    return parse_leases(parts[""]), parse_uci_hosts(parts["UCI"]), parse_proc_arp(parts["ARP"])


def read_k8s() -> tuple[list[tuple[str, str, str]], dict]:
    """(ip, kind, detail) for node InternalIPs and LoadBalancer addresses, and the raw node list."""
    dump = os.environ.get("K8S_DUMP_DIR")
    if dump:  # a dry run off the cluster: `kubectl get nodes/services -A -o json` saved as files
        nodes = json.loads(read_text(f"{dump}/nodes.json"))
        services = json.loads(read_text(f"{dump}/services.json"))
    else:
        # The address kubelet injects, not kubernetes.default.svc: Kyverno sets
        # ndots:2 and Alpine's resolver then never tries the search domains.
        base = f"https://{os.environ['KUBERNETES_SERVICE_HOST']}:{os.environ.get('KUBERNETES_SERVICE_PORT', '443')}"
        sa = "/var/run/secrets/kubernetes.io/serviceaccount"
        headers = {"Authorization": f"Bearer {read_text(sa + '/token').strip()}"}
        ctx = ssl.create_default_context(cafile=sa + "/ca.crt")
        nodes = http_json(f"{base}/api/v1/nodes", headers, ctx)
        services = http_json(f"{base}/api/v1/services", headers, ctx)
    out = []
    for node in nodes["items"]:
        for addr in node["status"].get("addresses", []):
            if addr["type"] == "InternalIP" and network_of(addr["address"]):
                out.append((addr["address"], "node", node["metadata"]["name"]))
    lbs: dict[str, list[str]] = defaultdict(list)
    for svc in services["items"]:
        if svc["spec"].get("type") != "LoadBalancer":
            continue
        for ing in (svc.get("status", {}).get("loadBalancer", {}).get("ingress") or []):
            if ing.get("ip") and network_of(ing["ip"]):
                lbs[ing["ip"]].append(f"{svc['metadata']['namespace']}/{svc['metadata']['name']}")
    for ip, svcs in lbs.items():
        svcs.sort()
        detail = svcs[0] + (f" +{len(svcs) - 1}" if len(svcs) > 1 else "")
        out.append((ip, "lb", detail))
    return out, nodes


def read_headscale(url: str, key: str) -> list[tuple[str, str]]:
    nodes = http_json(f"{url.rstrip('/')}/api/v1/node", {"Authorization": f"Bearer {key}"})["nodes"]
    return [(ip, n.get("givenName") or n.get("name") or "") for n in nodes
            for ip in n.get("ipAddresses", []) if ":" not in ip and network_of(ip)]


def desc(text: str) -> str:
    return f"-- {text} --"[:64]


def main() -> int:
    import pymysql  # in the job image only; the tests never need it

    dry_run = os.environ.get("DRY_RUN") == "1"
    src_dir = os.environ["SOURCE_DIR"]
    now = dt.datetime.now().replace(microsecond=0)
    failed: set[str] = set()
    obs_raw: list[tuple[str, str, str, str, str | None, str | None, str, int]] = []
    # (ip, kind, mac, desc, reserved_name, lease_name, source, tier)

    tech = Technitium(os.environ["TECH_URL"], os.environ.get("TECH_API_TOKEN"),
                      os.environ.get("TECH_USER", "admin"), os.environ.get("TECH_PASS", ""), dry_run)
    zone = tech.zone(ZONE)

    site_leases: dict[str, list[Lease]] = {}
    site_curated: dict[str, dict[str, str]] = {}
    for site in SITES:
        try:
            leases, hosts, arp = read_openwrt(site, read_text(f"{src_dir}/{site}.txt"))
        except Exception as e:  # one site down must not stop the others
            print(f"SOURCE FAILED {site}: {e}")
            failed.add(site)
            continue
        site_leases[site] = leases
        site_curated[site] = curated_names(hosts)
        leased = {l.mac for l in leases}
        for l in leases:
            obs_raw.append((l.ip, "dynamic", l.mac, desc(f"dhcp {site}"), None, None, site, 1))
        for h in hosts:
            if h.ip and network_of(h.ip):
                obs_raw.append((h.ip, "declared", h.mac, desc(f"reservation {site}"), h.name, None, site, 0))
        for ip, mac in arp:
            if mac not in leased:
                obs_raw.append((ip, "dynamic", mac, desc(f"arp {site}"), None, None, site, 2))
        print(f"source {site}: {len(leases)} leases, {len(hosts)} static, {len(arp)} ARP")

    try:
        parts = split_sections(read_text(f"{src_dir}/sofia.txt"))
        for key in ("KEA_LEASES", "KEA_CONF", "ARP", "WG"):
            if key not in parts:
                raise RuntimeError(f"no {key} section (pfSense SSH failed)")
        leases = parse_kea_leases(parts["KEA_LEASES"], time.time())
        res = parse_kea_reservations(parts["KEA_CONF"])
        arp = parse_bsd_arp(parts["ARP"])
        wg = parse_wg_allowed_ips(parts["WG"])
        leased = {l.mac for l in leases}
        for l in leases:
            obs_raw.append((l.ip, "dynamic", l.mac, desc("dhcp sofia"), None, l.hostname, "sofia", 1))
        for h in res:
            obs_raw.append((h.ip, "declared", h.mac, desc("reservation sofia"), h.name, None, "sofia", 0))
        for ip, mac, own in arp:
            if own:
                obs_raw.append((ip, "declared", mac, desc("interface sofia"), None, None, "sofia", 0))
            elif mac not in leased:
                obs_raw.append((ip, "dynamic", mac, desc("arp sofia"), None, None, "sofia", 2))
        for ip, routes in wg:
            obs_raw.append((ip, "declared", "", desc(f"wireguard peer {routes}".strip()), None, None, "sofia", 0))
        print(f"source sofia: {len(leases)} Kea leases, {len(res)} reservations, {len(arp)} ARP, {len(wg)} WireGuard peers")
    except Exception as e:
        print(f"SOURCE FAILED sofia: {e}")
        failed.add("sofia")

    k8s_nodes: dict | None = None
    try:
        k8s, k8s_nodes = read_k8s()
        for ip, kind, detail in k8s:
            if kind == "node":
                obs_raw.append((ip, "declared", "", desc("k8s node"), detail, None, "k8s", 0))
            else:
                obs_raw.append((ip, "declared", "", desc(f"k8s lb {detail}"), None, None, "k8s", 0))
        print(f"source k8s: {len(k8s)} addresses")
    except Exception as e:
        print(f"SOURCE FAILED k8s: {e}")
        failed.add("k8s")

    try:
        hs = read_headscale(os.environ["HEADSCALE_URL"], os.environ["HEADSCALE_API_KEY"])
        for ip, name in hs:
            obs_raw.append((ip, "declared", "", desc("headscale"), name, None, "headscale", 0))
        print(f"source headscale: {len(hs)} nodes")
    except Exception as e:
        print(f"SOURCE FAILED headscale: {e}")
        failed.add("headscale")

    db = pymysql.connect(
        host=os.environ["DB_HOST"], port=int(os.environ.get("DB_PORT", "3306")), user=os.environ["DB_USER"],
        password=os.environ["DB_PASS"], database=os.environ["DB_NAME"],
        # TLS without verification: dbaas serves a self-signed certificate, and
        # MySQL 8.4's caching_sha2_password needs TLS for a full login.
        ssl={"check_hostname": False}, autocommit=False,
    )
    cur = db.cursor()
    subnet_ids = ensure_layout(cur, db, dry_run)

    def load_rows() -> list[Row]:
        cur.execute(
            "SELECT id, INET_NTOA(ip_addr), subnetId, COALESCE(mac,''), COALESCE(hostname,''),"
            " COALESCE(description,''), lastSeen FROM ipaddresses WHERE subnetId IN %s",
            (tuple(i for i in subnet_ids.values() if i > 0) or (-1,),),
        )
        return [Row(int(r[0]), r[1], int(r[2]), r[3].lower(), r[4], r[5], r[6] or dt.datetime(1970, 1, 1))
                for r in cur.fetchall()]

    rows = load_rows()

    # --- names for the OpenWrt sites (London rules), site by site ------------
    hand_rows = [r for r in rows if row_kind(r.description)[0] == "hand"]
    site_nets = {s: [n for n in NETWORKS if n.publish == s] for s in SITES}
    all_site_nets = [n for n in NETWORKS if n.publish]
    claimed: set[str] = set()  # names given to earlier sites in this run
    site_names: dict[str, dict[str, str | None]] = {}
    site_fixed: dict[str, dict[str, str]] = {}
    for site in SITES:
        fixed = {sanitize(r.hostname): r.ip for r in hand_rows
                 if sanitize(r.hostname) and network_of(r.ip) in site_nets[site]}
        site_fixed[site] = fixed
        if site in failed:
            continue
        others = {sanitize(r.hostname) for r in hand_rows if sanitize(r.hostname)} - set(fixed)
        taken = zone.names_outside(site_nets[site]) | set(fixed) | others | claimed
        names = assign_names(site_leases[site], site_curated[site], taken, site)
        site_names[site] = names
        claimed |= {n for n in names.values() if n}

    # --- one observation per address, with its name ----------------------------
    seen: list[Obs] = []
    for ip, kind, mac, d, reserved, leased_name, source, tier in obs_raw:
        net = network_of(ip)
        sid = subnet_ids.get(net.cidr, -1) if net else -1
        if source in site_names and mac in site_names[source]:
            # A leased device at an OpenWrt site: the London rules decided its
            # name, whether this observation is its lease or its static lease.
            name = site_names[source][mac]
        elif net and net.publish:
            name = sanitize(reserved)
        else:
            name = pick_name(reserved, leased_name, zone.name_for_ip(ip))
        seen.append(Obs(ip=ip, subnet_id=sid, kind=kind, mac=mac, name=name, desc=d, source=source, tier=tier))

    plan = plan_rows(seen, rows, now, failed)
    for o in plan.skipped:
        print(f"  hand row holds {o.ip} (seen as {o.desc} {o.mac} {o.name or '-'})")
    print(f"phpIPAM: {len(plan.inserts)} new, {len(plan.updates)} seen, {len(plan.deletes)} removed,"
          f" {len(plan.skipped)} held by hand rows")
    for rid in plan.deletes:
        r = next(r for r in rows if r.id == rid)
        print(f"  remove {r.ip} {r.hostname or '-'} ({r.description})")
    if not dry_run:
        if plan.deletes:
            cur.execute("DELETE FROM ipaddresses WHERE id IN %s", (tuple(plan.deletes),))
        # (ip_addr, subnetId) is unique, so two rows swapping addresses would
        # collide mid-update. Park every updated row on a NULL subnet first.
        if plan.updates:
            cur.execute("UPDATE ipaddresses SET subnetId=NULL WHERE id IN %s",
                        (tuple(rid for rid, _ in plan.updates),))
        for rid, o in plan.updates:
            cur.execute(
                "UPDATE ipaddresses SET ip_addr=INET_ATON(%s), subnetId=%s, hostname=%s, mac=%s,"
                " description=%s, lastSeen=%s WHERE id=%s",
                (o.ip, o.subnet_id, o.name or "", o.mac or None, o.desc, now, rid),
            )
        for o in plan.inserts:
            cur.execute(
                "INSERT INTO ipaddresses (ip_addr, subnetId, hostname, mac, description, lastSeen)"
                " VALUES (INET_ATON(%s), %s, %s, %s, %s, %s)",
                (o.ip, o.subnet_id, o.name or "", o.mac or None, o.desc, now),
            )
        db.commit()
        rows = load_rows()
    else:
        rows = apply_plan_in_memory(rows, plan, now)

    # --- DNS: OpenWrt site leases ---------------------------------------------------
    zones = tech.zones()
    for site in SITES:
        if site in failed:
            print(f"DNS {site}: skipped, source failed")
            continue
        nets = site_nets[site]
        desired: dict[str, str] = dict(site_fixed[site])
        site_rows = [r for r in rows if network_of(r.ip) in nets and row_kind(r.description)[1] == site]
        for r in sorted(site_rows, key=lambda r: r.last_seen, reverse=True):
            if r.hostname:
                desired.setdefault(r.hostname.lower(), r.ip)
        clash = set(desired) & zone.names_outside(nets)
        if clash:
            print(f"  WARN {site}: names held outside the site, not written: {sorted(clash)}")
            for n in clash:
                desired.pop(n)
        upserts, deletes = plan_dns(desired, zone.a_into(nets))
        for name, ip in sorted(upserts.items()):
            print(f"  A {name} -> {ip}")
            tech.write("/api/zones/records/add", domain=f"{name}.{ZONE}", zone=ZONE, type="A",
                       ipAddress=ip, overwrite="true", ttl=str(TTL))
            zone.set_a(name, ip)
        for name, ips in sorted(deletes.items()):
            for ip in sorted(ips):
                print(f"  A {name} -> {ip} removed")
                tech.write("/api/zones/records/delete", domain=f"{name}.{ZONE}", zone=ZONE, type="A", ipAddress=ip)
                zone.delete_a(name, ip)
        print(f"DNS {site}: {len(upserts)} written, {len(deletes)} removed, {len(desired) - len(upserts)} unchanged")
        for net in nets:
            sync_ptrs(tech, zones, net, desired)

    # --- DNS: hand rows outside the site ranges -------------------------------------
    outside = [r for r in rows if network_of(r.ip) and not network_of(r.ip).publish
               and network_of(r.ip).cidr != "100.64.0.0/10"]
    want, dups = hand_names(outside, zone)
    for name in dups:
        print(f"  WARN hand rows share the name {name!r}: {'published once' if name in want else 'not published'}")
    want = {n: ip for n, ip in want.items() if n not in claimed}
    writes, deletes, conflicts = plan_hand_dns(want, zone)
    for name in conflicts:
        print(f"  WARN hand row name {name!r} ({want[name]}) is held elsewhere in DNS ({sorted(zone.a(name)) or 'non-A'}); not published")
    for name, ip in sorted(writes.items()):
        print(f"  A {name} -> {ip} (hand row)")
        tech.write("/api/zones/records/add", domain=f"{name}.{ZONE}", zone=ZONE, type="A",
                   ipAddress=ip, overwrite="true", ttl=str(TTL), comments=COMMENT)
        zone.set_a(name, ip, COMMENT)
    for name, ips in sorted(deletes.items()):
        for ip in sorted(ips):
            print(f"  A {name} -> {ip} removed (hand row gone)")
            tech.write("/api/zones/records/delete", domain=f"{name}.{ZONE}", zone=ZONE, type="A", ipAddress=ip)
            zone.delete_a(name, ip)
    print(f"DNS hand rows: {len(writes)} written, {len(deletes)} removed, {len(conflicts)} conflicts")

    # --- extra inventory data: MAC, vendor, model, OS, state, Devices ---------------
    import phpipam_enrich  # next to this file in the ConfigMap

    seen_mac_by_ip: dict[str, str] = {}
    for o in sorted(seen, key=lambda o: o.tier):
        if o.mac:
            seen_mac_by_ip.setdefault(o.ip, o.mac)
    enrich_failed = phpipam_enrich.run(
        cur, db, subnet_ids=[i for i in subnet_ids.values() if i > 0], seen_mac_by_ip=seen_mac_by_ip,
        # A reservation is listed whether or not its device is up, so it does not count as seen.
        seen_ips={o.ip for o in seen if not o.desc.startswith("-- reservation")}, k8s_nodes=k8s_nodes, env=dict(os.environ), now=now, dry_run=dry_run,
    )
    if enrich_failed:
        # Enrichment owns no rows, so a missing source only leaves its fields stale.
        print(f"enrichment sources skipped this run: {enrich_failed}")

    if failed:
        print(f"FAILED sources: {sorted(failed)}; their rows were left as they were")
        return 1
    return 0


def apply_plan_in_memory(rows: list[Row], plan: RowPlan, now: dt.datetime) -> list[Row]:
    """The rows a real run would leave, for DRY_RUN's DNS preview."""
    out = [r for r in rows if r.id not in plan.deletes]
    upd = dict(plan.updates)
    out = [Row(r.id, upd[r.id].ip, upd[r.id].subnet_id, upd[r.id].mac, upd[r.id].name or "", upd[r.id].desc, now)
           if r.id in upd else r for r in out]
    out += [Row(-1 - i, o.ip, o.subnet_id, o.mac, o.name or "", o.desc, now) for i, o in enumerate(plan.inserts)]
    return out


def sync_ptrs(tech: Technitium, zones: set[str], net: Net, desired: dict[str, str]) -> None:
    rev = net.reverse_zone
    if not rev:
        return
    if rev not in zones:
        print(f"  creating reverse zone {rev}")
        tech.write("/api/zones/create", zone=rev, type="Primary")
        current: dict[str, set[str]] = {}
    else:
        current = tech.ptrs(rev)
    netobj = ipaddress.ip_network(net.cidr)
    want = {ipaddress.ip_address(ip).reverse_pointer: f"{name}.{ZONE}"
            for name, ip in desired.items() if ipaddress.ip_address(ip) in netobj}
    up, dele = plan_dns(want, current)
    for owner, target in sorted(up.items()):
        tech.write("/api/zones/records/add", domain=owner, zone=rev, type="PTR", ptrName=target,
                   overwrite="true", ttl=str(TTL))
    for owner, targets in sorted(dele.items()):
        for target in targets:
            tech.write("/api/zones/records/delete", domain=owner, zone=rev, type="PTR", ptrName=target)
    print(f"  PTR {rev}: {len(up)} written, {len(dele)} removed")


def ensure_layout(cur, db, dry_run: bool) -> dict[str, int]:
    """Subnets, locations and VLANs as NETWORKS describes them; returns CIDR -> subnet id."""
    cur.execute("SELECT id FROM sections ORDER BY id LIMIT 1")
    section = int(cur.fetchone()[0])
    cur.execute("SELECT id, name FROM locations")
    locations = {name: int(i) for i, name in cur.fetchall()}
    for name in LOCATIONS:
        if name not in locations:
            print(f"  creating location {name}")
            if not dry_run:
                cur.execute("INSERT INTO locations (name, description) VALUES (%s, %s)", (name, "site"))
                locations[name] = int(cur.lastrowid)
    cur.execute("SELECT vlanId, number, name FROM vlans")
    vlans_rows = cur.fetchall()
    vlans = {int(num): int(vid) for vid, num, _ in vlans_rows}
    for vid, num, name in vlans_rows:
        if (int(num), name) in DEMO_VLANS:
            cur.execute("SELECT COUNT(*) FROM subnets WHERE vlanId=%s", (vid,))
            if cur.fetchone()[0] == 0:
                print(f"  removing demo VLAN {num} {name}")
                if not dry_run:
                    cur.execute("DELETE FROM vlans WHERE vlanId=%s", (vid,))
    for num, name in VLANS.items():
        if num not in vlans:
            print(f"  creating VLAN {num} {name}")
            if not dry_run:
                cur.execute("INSERT INTO vlans (domainId, name, number, description) VALUES (1, %s, %s, %s)",
                            (name, num, "Sofia"))
                vlans[num] = int(cur.lastrowid)
    ids: dict[str, int] = {}
    for n in NETWORKS:
        net = ipaddress.ip_network(n.cidr)
        cur.execute("SELECT id, location, vlanId, scanAgent, pingSubnet, discoverSubnet, resolveDNS"
                    " FROM subnets WHERE subnet=%s AND mask=%s",
                    (str(int(net.network_address)), str(net.prefixlen)))
        hit = cur.fetchone()
        loc = locations.get(n.location) if n.location else None
        vlan = vlans.get(n.vlan) if n.vlan else None
        if not hit:
            print(f"  creating subnet {n.cidr} ({n.description})")
            if dry_run:
                ids[n.cidr] = -1
                continue
            cur.execute(
                "INSERT INTO subnets (subnet, mask, sectionId, description, masterSubnetId, location, vlanId,"
                " showName, pingSubnet, discoverSubnet, resolveDNS, scanAgent, isFolder)"
                " VALUES (%s, %s, %s, %s, 0, %s, %s, 1, 0, 0, 0, 0, 0)",
                (str(int(net.network_address)), str(net.prefixlen), section, n.description, loc or 0, vlan or 0),
            )
            ids[n.cidr] = int(cur.lastrowid)
            continue
        sid = int(hit[0])
        ids[n.cidr] = sid
        want = (loc or 0, vlan or 0, 0, 0, 0, 0)
        have = tuple(int(x or 0) for x in hit[1:])
        if have != want:
            print(f"  subnet {n.cidr}: location/VLAN/scan flags {have} -> {want}")
            if not dry_run:
                cur.execute("UPDATE subnets SET location=%s, vlanId=%s, scanAgent=0, pingSubnet=0,"
                            " discoverSubnet=0, resolveDNS=0 WHERE id=%s", (loc or 0, vlan or 0, sid))
    if not dry_run:
        db.commit()
    return ids


if __name__ == "__main__":
    sys.exit(main())
