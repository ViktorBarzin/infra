"""Draw the network topology from phpIPAM's own data, as one HTML page.

Run by the phpipam-import CronJob (stacks/phpipam/main.tf) after every import.
phpIPAM shows addresses per subnet but has no view of how the subnets connect,
so this page draws one: a box per site (phpIPAM Location), each subnet in its
site, and each network device (Router, Firewall, Wireless or Switch in
devices.yaml) joined to every subnet it holds an address in. A subnet with no
Location, or with network devices from more than one site on it (the WireGuard
tunnels), sits between the sites.

A device's border shows whether any of its addresses in its own site's subnets
was seen in the last 15 minutes (tunnel rows only say the peer is configured). Clicking a subnet opens it in phpIPAM.

The page goes into the phpipam-topology ConfigMap, which the phpipam-web pod
mounts at /phpipam/topology, so it is served at
https://phpipam.viktorbarzin.me/topology/ behind the same login as phpIPAM.
DRY_RUN=1 writes the page to TOPOLOGY_OUT (default /tmp/topology.html) instead.
"""
from __future__ import annotations

import datetime as dt
import html
import ipaddress
import json
import os
import re
import ssl
import sys
import urllib.request
from dataclasses import dataclass

NETWORK_TYPES = {"Router", "Firewall", "Wireless", "Switch"}
UP_WINDOW = dt.timedelta(minutes=15)
SEEN_WINDOW = dt.timedelta(hours=1)
CONFIGMAP = "phpipam-topology"
MERMAID_JS = "https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.min.js"


@dataclass(frozen=True)
class Subnet:
    id: int
    section: int
    cidr: str
    description: str
    location: str | None
    last_seen: tuple[dt.datetime | None, ...]  # one entry per address row


@dataclass(frozen=True)
class Device:
    id: int
    name: str
    type: str
    location: str | None
    addresses: tuple[str, ...]
    last_seen: tuple[dt.datetime | None, ...]


def state(last_seen: tuple[dt.datetime | None, ...], now: dt.datetime) -> str:
    seen = [t for t in last_seen if t]
    if not seen:
        return "unknown"
    return "up" if max(seen) >= now - UP_WINDOW else "down"


def links(subnets: list[Subnet], devices: list[Device]) -> list[tuple[Device, Subnet]]:
    """(device, subnet) for every network device address inside a subnet."""
    nets = [(ipaddress.ip_network(s.cidr), s) for s in subnets]
    out = []
    for d in devices:
        if d.type not in NETWORK_TYPES:
            continue
        hit = {s.id: (net, s) for ip in d.addresses for net, s in nets if ipaddress.ip_address(ip) in net}
        out += [(d, s) for _, s in sorted(hit.values(), key=lambda p: p[0])]
    return sorted(out, key=lambda p: (p[0].name, ipaddress.ip_network(p[1].cidr)))


def placement(subnets: list[Subnet], pairs: list[tuple[Device, Subnet]]) -> dict[int, str | None]:
    """Subnet id -> the site it is drawn in, or None for between the sites."""
    sites: dict[int, set[str | None]] = {s.id: set() for s in subnets}
    for d, s in pairs:
        sites[s.id].add(d.location)
    return {s.id: s.location if s.location and len(sites[s.id] - {s.location}) == 0 else None
            for s in subnets}


def label(text: str) -> str:
    """Text safe inside a quoted mermaid label."""
    return text.replace('"', "#quot;").replace("<", "#lt;").replace(">", "#gt;")


def subnet_text(s: Subnet, now: dt.datetime) -> str:
    text = f"<b>{label(s.cidr)}</b><br/>{label(s.description)}<br/>{len(s.last_seen)} addresses"
    if any(s.last_seen):
        recent = sum(1 for t in s.last_seen if t and t >= now - SEEN_WINDOW)
        text += f", {recent} seen in the last hour"
    return text


def site_seen(d: Device, subnets: list[Subnet], where: dict[int, str | None]) -> tuple[dt.datetime | None, ...]:
    """lastSeen of the device's addresses inside its own site's subnets.

    A shared subnet's rows (a configured WireGuard peer, a registered tailnet
    node) are refreshed whenever the hub lists them, whether or not the device
    answers, so they say nothing about liveness. A device with no site address
    falls back to all of its addresses.
    """
    local = [ipaddress.ip_network(s.cidr) for s in subnets if where[s.id] is not None]
    seen = tuple(t for ip, t in zip(d.addresses, d.last_seen)
                 if any(ipaddress.ip_address(ip) in net for net in local))
    return seen or d.last_seen


def site_id(name: str) -> str:
    return "site_" + re.sub(r"\W", "_", name)


def render_mermaid(subnets: list[Subnet], devices: list[Device], now: dt.datetime) -> str:
    subnets = sorted(subnets, key=lambda s: ipaddress.ip_network(s.cidr))
    pairs = links(subnets, devices)
    where = placement(subnets, pairs)
    drawn = sorted({d.id: d for d, _ in pairs}.values(), key=lambda d: d.name)

    def subnet_node(s: Subnet) -> str:
        return f's{s.id}("{subnet_text(s, now)}")'

    def device_node(d: Device) -> str:
        return f'd{d.id}["<b>{label(d.name)}</b><br/>{label(d.type)}"]'

    lines = ["flowchart TB"]
    sites = sorted({loc for loc in where.values() if loc} | {d.location for d in drawn if d.location})
    for site in sites:
        lines.append(f'  subgraph {site_id(site)}["{label(site)}"]')
        lines += [f"    {device_node(d)}" for d in drawn if d.location == site]
        lines += [f"    {subnet_node(s)}" for s in subnets if where[s.id] == site]
        lines.append("  end")
    lines += [device_node(d) for d in drawn if not d.location]
    lines += [subnet_node(s) for s in subnets if where[s.id] is None]
    # Edge order sets the layers top to bottom: shared subnets, then the devices
    # that join them, then each site's subnets, then devices on one subnet only
    # (a switch, a Wi-Fi access point) hanging under it. Tunnel links are dotted.
    degree: dict[int, int] = {}
    for d, _ in pairs:
        degree[d.id] = degree.get(d.id, 0) + 1
    for d, s in pairs:
        if where[s.id] is None:
            lines.append(f"  s{s.id} -.- d{d.id}")
        elif degree[d.id] == 1:
            lines.append(f"  s{s.id} --- d{d.id}")
        else:
            lines.append(f"  d{d.id} --- s{s.id}")
    lines += [f'  click s{s.id} "/subnets/{s.section}/{s.id}/" "Open {s.cidr} in phpIPAM"' for s in subnets]
    lines += [f"  class s{s.id} shared" for s in subnets if where[s.id] is None]
    lines += [f"  class d{d.id} {state(site_seen(d, subnets, where), now)}" for d in drawn]
    lines += [
        "  classDef up stroke:#2e9d5b,stroke-width:3px",
        "  classDef down stroke:#d0453b,stroke-width:3px,stroke-dasharray:6 4",
        "  classDef unknown stroke:#8a8a8a,stroke-width:2px",
        "  classDef shared stroke-dasharray:3 3",
    ]
    return "\n".join(lines) + "\n"


PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Network topology</title>
<style>
:root {{ --bg: #ffffff; --fg: #1d1d1f; --muted: #5f6368; --line: #d9d9de; --link: #1a5fb4; }}
@media (prefers-color-scheme: dark) {{
  :root {{ --bg: #17181a; --fg: #e8e8ea; --muted: #a0a3a8; --line: #34363a; --link: #8ab4f8; }}
}}
body {{ margin: 0; background: var(--bg); color: var(--fg);
  font: 15px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; }}
main {{ margin: 0 auto; padding: 24px 16px 48px; }}
h1 {{ font-size: 22px; margin: 0 0 4px; }}
p {{ margin: 0 0 12px; color: var(--muted); }}
a {{ color: var(--link); }}
.legend {{ display: flex; flex-wrap: wrap; gap: 8px 20px; margin: 0 0 16px; color: var(--muted); font-size: 14px; }}
.key {{ display: inline-block; width: 22px; height: 12px; margin-right: 6px; vertical-align: -1px; border-radius: 3px; }}
.up {{ border: 3px solid #2e9d5b; }}
.down {{ border: 3px dashed #d0453b; }}
.unknown {{ border: 2px solid #8a8a8a; }}
.diagram {{ border: 1px solid var(--line); border-radius: 8px; padding: 12px; overflow-x: auto; }}
pre.mermaid {{ margin: 0; text-align: center; }}
/* mermaid 11.4.1 adds an arrowhead to undirected links; these links have no direction. */
pre.mermaid path.flowchart-link {{ marker-end: none !important; }}
</style>
</head>
<body>
<main>
<h1>Network topology</h1>
<p>Drawn from phpIPAM at {generated} UTC, every 5 minutes. Click a subnet to open it in phpIPAM.
<a href="/subnets/">All subnets</a> &middot; <a href="/tools/locations/">Locations map</a></p>
<div class="legend">
<span><span class="key up"></span>device seen in the last 15 minutes</span>
<span><span class="key down"></span>device not seen for 15 minutes</span>
<span><span class="key unknown"></span>device never seen</span>
<span>Subnets outside the site boxes join more than one site.</span>
</div>
<div class="diagram"><pre class="mermaid">
{diagram}</pre></div>
</main>
<script src="{mermaid_js}"></script>
<script>
const dark = window.matchMedia("(prefers-color-scheme: dark)").matches;
mermaid.initialize({{ startOnLoad: true, securityLevel: "loose", theme: dark ? "dark" : "default",
  flowchart: {{ htmlLabels: true, curve: "basis", nodeSpacing: 30, rankSpacing: 60, useMaxWidth: false }} }});
</script>
</body>
</html>
"""


def render_html(diagram: str, now: dt.datetime) -> str:
    return PAGE.format(generated=now.strftime("%Y-%m-%d %H:%M"), diagram=html.escape(diagram, quote=False),
                       mermaid_js=MERMAID_JS)


def as_time(value) -> dt.datetime | None:
    return value if isinstance(value, dt.datetime) else None


def load(cur) -> tuple[list[Subnet], list[Device]]:
    cur.execute("SELECT id, name FROM locations")
    locations = {int(i): name for i, name in cur.fetchall()}
    cur.execute("SELECT subnetId, lastSeen FROM ipaddresses")
    seen_by_subnet: dict[int, list] = {}
    for sid, seen in cur.fetchall():
        seen_by_subnet.setdefault(int(sid), []).append(as_time(seen))
    cur.execute("SELECT id, sectionId, subnet, mask, COALESCE(description,''), location FROM subnets"
                " WHERE isFolder=0 AND subnet IS NOT NULL AND subnet <> ''")
    subnets = []
    for sid, section, subnet, mask, desc, loc in cur.fetchall():
        net = ipaddress.ip_network(f"{ipaddress.ip_address(int(subnet))}/{mask}")
        if net.version != 4:
            continue
        subnets.append(Subnet(int(sid), int(section), str(net), desc, locations.get(int(loc or 0)),
                              tuple(seen_by_subnet.get(int(sid), []))))
    cur.execute("SELECT d.id, d.hostname, COALESCE(t.tname,''), d.location FROM devices d"
                " LEFT JOIN deviceTypes t ON t.tid = d.type")
    raw = cur.fetchall()
    cur.execute("SELECT switch, ip_addr, lastSeen FROM ipaddresses WHERE switch > 0")
    addrs: dict[int, list] = {}
    for dev, ip, seen in cur.fetchall():
        addrs.setdefault(int(dev), []).append((str(ipaddress.ip_address(int(ip))), as_time(seen)))
    devices = [Device(int(i), name, tname, locations.get(int(loc or 0)),
                      tuple(a for a, _ in addrs.get(int(i), [])), tuple(t for _, t in addrs.get(int(i), [])))
               for i, name, tname, loc in raw]
    return subnets, devices


def publish(page: str) -> None:
    """Replace the page in the ConfigMap; the web pod sees it within about a minute."""
    base = f"https://{os.environ['KUBERNETES_SERVICE_HOST']}:{os.environ.get('KUBERNETES_SERVICE_PORT', '443')}"
    sa = "/var/run/secrets/kubernetes.io/serviceaccount"
    with open(f"{sa}/token") as f:
        token = f.read().strip()
    with open(f"{sa}/namespace") as f:
        namespace = f.read().strip()
    req = urllib.request.Request(
        f"{base}/api/v1/namespaces/{namespace}/configmaps/{CONFIGMAP}",
        data=json.dumps({"data": {"index.html": page}}).encode(), method="PATCH",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/merge-patch+json"},
    )
    with urllib.request.urlopen(req, timeout=20, context=ssl.create_default_context(cafile=f"{sa}/ca.crt")):
        pass


def main() -> int:
    import pymysql  # in the job image only; the tests never need it

    db = pymysql.connect(
        host=os.environ["DB_HOST"], port=int(os.environ.get("DB_PORT", "3306")), user=os.environ["DB_USER"],
        password=os.environ["DB_PASS"], database=os.environ["DB_NAME"],
        ssl={"check_hostname": False},  # dbaas serves a self-signed certificate
    )
    subnets, devices = load(db.cursor())
    db.close()
    now = dt.datetime.now().replace(microsecond=0)
    page = render_html(render_mermaid(subnets, devices, now), now)
    if os.environ.get("DRY_RUN") == "1":
        out = os.environ.get("TOPOLOGY_OUT", "/tmp/topology.html")
        with open(out, "w") as f:
            f.write(page)
        print(f"topology: {len(subnets)} subnets, {len(devices)} devices, page written to {out}")
        return 0
    publish(page)
    print(f"topology: {len(subnets)} subnets, {len(devices)} devices, page published")
    return 0


if __name__ == "__main__":
    sys.exit(main())
