"""Name every London device in DNS from the Flint's DHCP leases.

Run by the phpipam-remote-import CronJob (stacks/phpipam/main.tf), which
fetches the Flint's lease file and its `uci show dhcp` over SSH and passes
them in FLINT_DATA_FILE, separated by a ---UCI--- line.

Each run:
  1. names every leased device: the curated name from a Flint static lease
     (uci dhcp host with a name) when there is one, otherwise the hostname the
     device announced. A name already used outside London gets "-london"; a
     name two London devices share gets the last four hex digits of each MAC.
  2. records the devices in phpIPAM, one row per MAC, in the London LAN or
     London Guest subnet. Rows this job writes carry MARK in their description
     and are the only rows it changes or deletes; hand-made rows such as
     ha-london are read as fixed names and never touched. A device whose lease
     is gone keeps its row for GRACE_HOURS, then the row is deleted.
  3. reconciles the A records in viktorbarzin.lan that point into London, and
     the PTR records in the London reverse zones, writing only what differs.

This is the only writer of London names: phpipam-dns-sync skips the London
subnets. See docs/architecture/dns.md, "London devices".
"""
from __future__ import annotations

import datetime as dt
import ipaddress
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from collections import Counter
from dataclasses import dataclass, field

ZONE = "viktorbarzin.lan"
MARK = "-- london dhcp (london_import) --"
# The Flint's networks that hand out leases. IoT (192.168.10.0/24) is
# disabled on the router, so it has no leases to read.
LONDON_NETS = {
    "192.168.8.0/24": ("London LAN", "8.168.192.in-addr.arpa"),
    "192.168.9.0/24": ("London Guest", "9.168.192.in-addr.arpa"),
}
_NETS = [ipaddress.ip_network(n) for n in LONDON_NETS]
TTL = 300


@dataclass(frozen=True)
class Lease:
    mac: str
    ip: str
    hostname: str


@dataclass(frozen=True)
class Named:
    mac: str
    ip: str
    subnet_id: int
    name: str | None


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
    inserts: list[Named] = field(default_factory=list)
    updates: list[tuple[int, Named]] = field(default_factory=list)
    deletes: list[int] = field(default_factory=list)
    skipped: list[Named] = field(default_factory=list)


def in_london(ip: str) -> bool:
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return any(addr in n for n in _NETS)


def london_net(ip: str) -> str:
    addr = ipaddress.ip_address(ip)
    return next(str(n) for n in _NETS if addr in n)


def sanitize(raw: str) -> str | None:
    """A DHCP hostname as a DNS label: lowercase [a-z0-9-], at most 63 long."""
    if not raw or raw == "*":
        return None
    label = raw.split(".")[0].lower()
    label = re.sub(r"[^a-z0-9-]+", "-", label)
    label = re.sub(r"-+", "-", label).strip("-")[:63].strip("-")
    return label or None


def mac4(mac: str) -> str:
    return mac.replace(":", "").lower()[-4:]


def parse_leases(text: str) -> list[Lease]:
    """dnsmasq lease lines, newest lease per MAC, London networks only."""
    newest: dict[str, tuple[int, Lease]] = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 4 or not parts[0].isdigit():
            continue
        expiry, mac, ip, hostname = int(parts[0]), parts[1].lower(), parts[2], parts[3]
        if not in_london(ip):
            continue
        if mac not in newest or expiry > newest[mac][0]:
            newest[mac] = (expiry, Lease(mac=mac, ip=ip, hostname=hostname))
    return [lease for _, lease in newest.values()]


def parse_uci_hosts(text: str) -> dict[str, str]:
    """MAC -> name for every `uci show dhcp` host section that has a name."""
    sections: dict[str, dict[str, str]] = {}
    kinds: dict[str, str] = {}
    for line in text.splitlines():
        m = re.match(r"^dhcp\.([^.=]+)=(\S+)$", line)
        if m:
            kinds[m.group(1)] = m.group(2)
            continue
        m = re.match(r"^dhcp\.([^.=]+)\.(mac|name)=(.*)$", line)
        if m:
            sections.setdefault(m.group(1), {})[m.group(2)] = m.group(3)
    curated: dict[str, str] = {}
    for sec, opts in sections.items():
        if kinds.get(sec) != "host" or "name" not in opts or "mac" not in opts:
            continue
        name = sanitize(opts["name"].strip("'"))
        if not name:
            continue
        for mac in re.findall(r"[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}", opts["mac"]):
            curated[mac.lower()] = name
    return curated


def assign_names(leases: list[Lease], curated: dict[str, str], taken: set[str]) -> dict[str, str | None]:
    """MAC -> DNS name (or None). Deterministic regardless of lease order.

    Curated names win over announced ones. A name shared by several London
    devices gets each device's MAC suffix (a curated holder keeps the bare
    name). A name in `taken` (held outside London, or by a hand-made London
    record) gets "-london". The result never repeats a name and never uses
    one from `taken`.
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
    curated_names = Counter(name for name, is_curated in base.values() if is_curated)

    out: dict[str, str | None] = {lease.mac: None for lease in leases}
    for mac in sorted(base):
        name, is_curated = base[mac]
        if counts[name] > 1 and not (is_curated and curated_names[name] == 1):
            name = f"{name}-{mac4(mac)}"
        if name in taken:
            name = f"{name}-london"
        out[mac] = name

    # A rename above can land on a name another device already holds
    # ("a-london" announced vs "a" renamed). Those, and anything still in
    # `taken`, get the MAC suffix; if even that clashes the device stays
    # unnamed rather than share a name.
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


def plan_rows(seen: list[Named], rows: list[Row], now: dt.datetime, grace_hours: int = 24) -> RowPlan:
    """What to change in phpIPAM so each leased device has exactly one row."""
    plan = RowPlan()
    owned_by_mac: dict[str, Row] = {}
    for row in rows:
        if row.description == MARK and row.mac:
            if row.mac.lower() in owned_by_mac:
                plan.deletes.append(row.id)
            else:
                owned_by_mac[row.mac.lower()] = row
    by_slot = {(r.ip, r.subnet_id): r for r in rows}
    seen_macs = {n.mac for n in seen}

    for dev in seen:
        mine = owned_by_mac.get(dev.mac)
        other = by_slot.get((dev.ip, dev.subnet_id))
        if other is not None and (mine is None or other.id != mine.id):
            if other.description == MARK:
                # A device seen elsewhere in this run moves its own row away,
                # which frees the slot; only a departed device's row goes.
                if other.mac.lower() not in seen_macs:
                    plan.deletes.append(other.id)
            elif not other.hostname:
                plan.deletes.append(other.id)
            else:
                plan.skipped.append(dev)
                continue
        if mine is None:
            plan.inserts.append(dev)
        else:
            plan.updates.append((mine.id, dev))

    cutoff = now - dt.timedelta(hours=grace_hours)
    for mac, row in owned_by_mac.items():
        if mac not in seen_macs and row.last_seen < cutoff and row.id not in plan.deletes:
            plan.deletes.append(row.id)

    # A deleted row cannot also be updated.
    plan.updates = [(rid, dev) for rid, dev in plan.updates if rid not in plan.deletes]
    plan.deletes = sorted(set(plan.deletes))
    return plan


def plan_dns(desired: dict[str, str], current: dict[str, set[str]]) -> tuple[dict[str, str], dict[str, set[str]]]:
    """(upserts, deletes): write a key whose value set differs, drop keys no longer wanted."""
    upserts = {k: v for k, v in desired.items() if current.get(k) != {v}}
    deletes = {k: set(v) for k, v in current.items() if k not in desired}
    return upserts, deletes


# --- I/O --------------------------------------------------------------------


class Technitium:
    def __init__(self, url: str, token: str | None, user: str, password: str, dry_run: bool):
        self.url = url.rstrip("/")
        self.dry_run = dry_run
        self.token = token or self._login(user, password)

    def _call(self, path: str, params: dict[str, str]) -> dict:
        data = urllib.parse.urlencode(params).encode()
        req = urllib.request.Request(f"{self.url}{path}", data=data, method="POST")
        with urllib.request.urlopen(req, timeout=20) as resp:
            body = json.load(resp)
        # Technitium answers HTTP 200 for failures too; the outcome is "status".
        if body.get("status") != "ok":
            raise RuntimeError(f"technitium {path}: {json.dumps(body)[:300]}")
        return body.get("response", {})

    def _login(self, user: str, password: str) -> str:
        return self._call("/api/user/login", {"user": user, "pass": password})["token"]

    def call(self, path: str, **params: str) -> dict:
        return self._call(path, {"token": self.token, **params})

    def write(self, path: str, **params: str) -> None:
        if self.dry_run:
            print(f"  DRY-RUN {path} {params}")
            return
        self.call(path, **params)

    def records(self, zone: str) -> list[dict]:
        return self.call("/api/zones/records/get", domain=zone, zone=zone, listZone="true")["records"]

    def zones(self) -> set[str]:
        return {z["name"] for z in self.call("/api/zones/list")["zones"]}


def zone_label(fqdn: str, zone: str) -> str | None:
    suffix = "." + zone
    fqdn = fqdn.lower().rstrip(".")
    return fqdn[: -len(suffix)] if fqdn.endswith(suffix) else None


def main() -> int:
    import pymysql  # in the job image only; the tests never need it

    dry_run = os.environ.get("DRY_RUN") == "1"
    grace = int(os.environ.get("GRACE_HOURS", "24"))
    with open(os.environ["FLINT_DATA_FILE"]) as f:
        data = f.read()
    if "---UCI---" not in data:
        print("no data from the Flint (tunnel or SSH down); changing nothing")
        return 1
    lease_text, uci_text = data.split("---UCI---", 1)
    leases = parse_leases(lease_text)
    curated = parse_uci_hosts(uci_text)
    print(f"Flint: {len(leases)} London leases, {len(curated)} curated MACs")

    tech = Technitium(
        os.environ["TECH_URL"], os.environ.get("TECH_API_TOKEN"),
        os.environ.get("TECH_USER", "admin"), os.environ.get("TECH_PASS", ""), dry_run,
    )
    zone_records = tech.records(ZONE)
    london_a: dict[str, set[str]] = {}
    outside: set[str] = set()
    for rec in zone_records:
        label = zone_label(rec["name"], ZONE)
        if not label:
            continue
        ip = rec.get("rData", {}).get("ipAddress", "")
        if rec["type"] == "A" and in_london(ip):
            london_a.setdefault(label, set()).add(ip)
        else:
            outside.add(label)

    db = pymysql.connect(
        host=os.environ["DB_HOST"], port=int(os.environ.get("DB_PORT", "3306")), user=os.environ["DB_USER"],
        password=os.environ["DB_PASS"], database=os.environ["DB_NAME"],
        # TLS without verification, as the mysql client in phpipam-dns-sync does
        # by default: dbaas serves a self-signed certificate, and MySQL 8.4's
        # caching_sha2_password needs TLS for a full login.
        ssl={"check_hostname": False}, autocommit=False,
    )
    with db.cursor() as cur:
        subnet_ids: dict[str, int] = {}
        for cidr, (desc, _) in LONDON_NETS.items():
            net = ipaddress.ip_network(cidr)
            cur.execute(
                "SELECT id FROM subnets WHERE subnet=%s AND mask=%s",
                (str(int(net.network_address)), str(net.prefixlen)),
            )
            hit = cur.fetchone()
            if not hit and subnet_ids:
                # Create a missing London subnet as a copy of the first one
                # (same section and settings), so a rebuilt phpIPAM, or one
                # that predates the guest network, needs no hand step.
                template = next(iter(subnet_ids.values()))
                print(f"  creating phpIPAM subnet {cidr} ({desc})")
                if not dry_run:
                    cur.execute(
                        "INSERT INTO subnets (subnet, mask, sectionId, description, masterSubnetId,"
                        " showName, pingSubnet, discoverSubnet, resolveDNS, scanAgent, isFolder, state)"
                        " SELECT %s, %s, sectionId, %s, masterSubnetId, showName, pingSubnet,"
                        " discoverSubnet, resolveDNS, scanAgent, isFolder, state FROM subnets WHERE id=%s",
                        (str(int(net.network_address)), str(net.prefixlen), desc, template),
                    )
                    db.commit()
                    cur.execute(
                        "SELECT id FROM subnets WHERE subnet=%s AND mask=%s",
                        (str(int(net.network_address)), str(net.prefixlen)),
                    )
                    hit = cur.fetchone()
                else:
                    hit = (-1,)
            if not hit:
                raise RuntimeError(f"phpIPAM has no subnet {cidr} ({desc})")
            subnet_ids[cidr] = int(hit[0])

        def load_rows() -> list[Row]:
            ids = tuple(subnet_ids.values())
            cur.execute(
                "SELECT id, INET_NTOA(ip_addr), subnetId, COALESCE(mac,''), COALESCE(hostname,''),"
                " COALESCE(description,''), lastSeen FROM ipaddresses WHERE subnetId IN %s",
                (ids,),
            )
            return [Row(int(r[0]), r[1], int(r[2]), r[3], r[4], r[5], r[6]) for r in cur.fetchall()]

        rows = load_rows()
        fixed = {r.hostname.lower(): r.ip for r in rows if r.description != MARK and r.hostname}
        taken = outside | set(fixed)
        names = assign_names(leases, curated, taken)
        seen = [Named(l.mac, l.ip, subnet_ids[london_net(l.ip)], names[l.mac]) for l in leases]
        for dev in seen:
            print(f"  {dev.ip:15} {dev.mac}  {dev.name or '-'}")

        now = dt.datetime.now().replace(microsecond=0)
        plan = plan_rows(seen, rows, now, grace)
        for dev in plan.skipped:
            print(f"  SKIP {dev.ip}: held by a hand-made phpIPAM row")
        print(f"phpIPAM: {len(plan.inserts)} new, {len(plan.updates)} seen, {len(plan.deletes)} removed")
        if not dry_run:
            if plan.deletes:
                cur.execute("DELETE FROM ipaddresses WHERE id IN %s", (tuple(plan.deletes),))
            # (ip_addr, subnetId) is unique, so two devices swapping addresses
            # would collide mid-update. Park every updated row on a NULL subnet
            # first (NULLs never collide), then write the final values.
            if plan.updates:
                cur.execute(
                    "UPDATE ipaddresses SET subnetId=NULL WHERE id IN %s",
                    (tuple(rid for rid, _ in plan.updates),),
                )
            for rid, dev in plan.updates:
                cur.execute(
                    "UPDATE ipaddresses SET ip_addr=INET_ATON(%s), subnetId=%s, hostname=%s, mac=%s,"
                    " lastSeen=%s WHERE id=%s",
                    (dev.ip, dev.subnet_id, dev.name or "", dev.mac, now, rid),
                )
            for dev in plan.inserts:
                cur.execute(
                    "INSERT INTO ipaddresses (ip_addr, subnetId, hostname, mac, description, lastSeen)"
                    " VALUES (INET_ATON(%s), %s, %s, %s, %s, %s)",
                    (dev.ip, dev.subnet_id, dev.name or "", dev.mac, MARK, now),
                )
            db.commit()
            rows = load_rows()

    # Desired DNS: hand-made names, then devices newest first, so a departed
    # device in its grace period never takes a name back from a current one.
    desired: dict[str, str] = dict(fixed)
    if dry_run:
        for dev in seen:
            if dev.name:
                desired.setdefault(dev.name, dev.ip)
    for row in sorted(rows, key=lambda r: r.last_seen, reverse=True):
        if row.description == MARK and row.hostname:
            desired.setdefault(row.hostname.lower(), row.ip)
    clash = set(desired) & outside
    if clash:
        raise RuntimeError(f"refusing to write names held outside London: {sorted(clash)}")

    upserts, deletes = plan_dns(desired, london_a)
    for name, ip in sorted(upserts.items()):
        print(f"  A {name} -> {ip}")
        tech.write("/api/zones/records/add", domain=f"{name}.{ZONE}", zone=ZONE, type="A",
                   ipAddress=ip, overwrite="true", ttl=str(TTL))
    for name, ips in sorted(deletes.items()):
        for ip in sorted(ips):
            print(f"  A {name} -> {ip} removed")
            tech.write("/api/zones/records/delete", domain=f"{name}.{ZONE}", zone=ZONE, type="A", ipAddress=ip)
    print(f"DNS: {len(upserts)} A written, {len(deletes)} removed, {len(desired) - len(upserts)} unchanged")

    zones = tech.zones()
    for cidr, (_, rev_zone) in LONDON_NETS.items():
        if rev_zone not in zones:
            print(f"  creating reverse zone {rev_zone}")
            tech.write("/api/zones/create", zone=rev_zone, type="Primary")
            current_ptr: dict[str, set[str]] = {}
        else:
            current_ptr = {}
            for rec in tech.records(rev_zone):
                if rec["type"] == "PTR":
                    current_ptr.setdefault(rec["name"].lower(), set()).add(rec["rData"]["ptrName"].lower())
        net = ipaddress.ip_network(cidr)
        want = {
            ipaddress.ip_address(ip).reverse_pointer: f"{name}.{ZONE}"
            for name, ip in desired.items() if ipaddress.ip_address(ip) in net
        }
        ptr_up, ptr_del = plan_dns(want, current_ptr)
        for owner, target in sorted(ptr_up.items()):
            tech.write("/api/zones/records/add", domain=owner, zone=rev_zone, type="PTR",
                       ptrName=target, overwrite="true", ttl=str(TTL))
        for owner, targets in sorted(ptr_del.items()):
            for target in targets:
                tech.write("/api/zones/records/delete", domain=owner, zone=rev_zone, type="PTR", ptrName=target)
        print(f"PTR {rev_zone}: {len(ptr_up)} written, {len(ptr_del)} removed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
