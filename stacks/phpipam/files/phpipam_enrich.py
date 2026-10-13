"""Extra inventory data for phpIPAM rows: MAC, vendor, model, OS, state, Device.

Used by phpipam_import.py after it has reconciled the rows. Sources:
  - the IEEE OUI registry (py3-netaddr, offline) for a MAC's vendor;
  - the Home Assistant device registries (Sofia and London), matched by MAC;
  - Proxmox (VM name, cores, memory, OS type, NIC MACs);
  - Kubernetes node info (OS, kernel, CPU, memory, GPU), matched by address;
  - devices.yaml, the declared list of infrastructure Devices.
An enrichment source that fails is logged and skipped: it owns no rows, so the
fields it would have set keep their last value until it answers again.

Hand rows (ADR-0032) only ever get fields that are empty; importer rows follow
the sources. Precedence per field is in merge().
"""
from __future__ import annotations

import datetime as dt
import json
import re
import ssl
import urllib.request
from dataclasses import dataclass
from typing import Callable

TAG_OFFLINE, TAG_USED, TAG_RESERVED, TAG_DHCP = 1, 2, 3, 4  # phpIPAM ipTags ids
OFFLINE_AFTER = dt.timedelta(hours=24)
CUSTOM_FIELDS = ("Vendor", "Model", "OS")  # extra columns on ipaddresses and devices
FIELD_LEN = 128
DEVICE_TYPES = ("Switch", "Router", "Firewall", "Wireless", "Server", "Virtual machine",
                "Storage", "Power", "Management", "Other")
_MAC_RE = re.compile(r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}")


@dataclass(frozen=True)
class Info:
    vendor: str | None
    model: str | None
    os: str | None


@dataclass(frozen=True)
class Device:
    name: str
    type: str
    location: str | None
    vendor: str | None
    model: str | None
    os: str | None
    description: str | None
    addresses: tuple[str, ...]
    macs: tuple[str, ...]


def _clip(text: str | None) -> str | None:
    text = (text or "").strip()
    return text[:FIELD_LEN] if text else None


def oui_vendor(mac: str, lookup: Callable[[str], str | None]) -> str | None:
    """Registered vendor of a MAC; "private MAC" for a locally administered (randomised) one."""
    if not mac or not _MAC_RE.fullmatch(mac.lower()):
        return None
    if int(mac[:2], 16) & 0x02:
        return "private MAC"
    return lookup(mac.lower())


def netaddr_lookup(mac: str) -> str | None:
    import netaddr  # py3-netaddr in the job image

    try:
        return netaddr.EUI(mac).oui.registration().org
    except Exception:  # NotRegisteredError and friends: not in the registry
        return None


def ha_by_mac(devices: list[dict]) -> dict[str, Info]:
    out: dict[str, Info] = {}
    for d in devices:
        model = d.get("model")
        if model and d.get("model_id") and d["model_id"] != model:
            model = f"{model} ({d['model_id']})"
        info = Info(_clip(d.get("manufacturer")), _clip(model), _clip(d.get("sw_version")))
        if info == Info(None, None, None):
            continue
        for kind, value in d.get("connections") or []:
            if kind == "mac" and _MAC_RE.fullmatch(str(value).lower()):
                out[value.lower()] = info
    return out


_OSTYPES = {"l26": "Linux", "l24": "Linux", "win11": "Windows 11", "win10": "Windows 10", "w2k22": "Windows Server 2022"}


def proxmox_by_mac(vms: list[dict]) -> dict[str, Info]:
    """vms: {vmid, name, cpus, maxmem, config} as the Proxmox API returns them."""
    out: dict[str, Info] = {}
    for vm in vms:
        cfg = vm.get("config", {})
        if int(cfg.get("template") or 0):
            continue
        gib = round(int(vm.get("maxmem") or 0) / 2**30)
        info = Info("Proxmox VE", _clip(f"VM {vm['vmid']} {vm.get('name', '')}: {vm.get('cpus')} vCPU, {gib} GiB"),
                    _OSTYPES.get(cfg.get("ostype", "")))
        for key, value in cfg.items():
            if re.fullmatch(r"net\d+", key):
                m = re.search(r"=((?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2})", value)
                if m:
                    out[m.group(1).lower()] = info
    return out


def _gib(quantity: str) -> int:
    units = {"Ki": 2**10, "Mi": 2**20, "Gi": 2**30}
    for suffix, factor in units.items():
        if quantity.endswith(suffix):
            return int(int(quantity[: -len(suffix)]) * factor / 2**30)
    return int(int(quantity) / 2**30)


def k8s_by_ip(nodes: dict) -> dict[str, Info]:
    out: dict[str, Info] = {}
    for node in nodes.get("items", []):
        st = node.get("status", {})
        cap = st.get("capacity", {})
        ni = st.get("nodeInfo", {})
        model = f"k8s node: {cap.get('cpu')} vCPU, {_gib(cap.get('memory', '0'))} GiB"
        gpu = node.get("metadata", {}).get("labels", {}).get("nvidia.com/gpu.product")
        if gpu:
            model += f", GPU {gpu}"
        os_ = ", ".join(x for x in (ni.get("osImage"), ni.get("kernelVersion") and f"kernel {ni['kernelVersion']}",
                                     ni.get("kubeletVersion") and f"kubelet {ni['kubeletVersion']}") if x)
        for addr in st.get("addresses", []):
            if addr.get("type") == "InternalIP":
                out[addr["address"]] = Info(None, _clip(model), _clip(os_))
    return out


def merge(oui: str | None = None, ha: Info | None = None, proxmox: Info | None = None,
          k8s: Info | None = None) -> Info:
    """Vendor: HA, then Proxmox, then OUI. Model: HA, k8s, Proxmox. OS: k8s, Proxmox, HA."""
    def first(*values):
        return next((v for v in values if v), None)
    return Info(
        vendor=first(ha and ha.vendor, proxmox and proxmox.vendor, k8s and k8s.vendor, oui),
        model=first(ha and ha.model, k8s and k8s.model, proxmox and proxmox.model),
        os=first(k8s and k8s.os, proxmox and proxmox.os, ha and ha.os),
    )


def field_updates(is_hand: bool, current: dict, new: dict) -> dict:
    """Fields to write: every new value that differs, or for a hand row only the empty ones."""
    out = {}
    for key, value in new.items():
        if value in (None, "", 0):
            continue
        have = current.get(key)
        if is_hand and have not in (None, "", 0):
            continue
        if have != value:
            out[key] = value
    return out


def state_for(description: str, seen_now: bool, last_seen: dt.datetime, now: dt.datetime) -> int:
    if description.startswith("-- dhcp "):
        return TAG_DHCP
    if description.startswith("-- reservation "):
        return TAG_RESERVED
    if description.startswith("-- "):
        return TAG_USED
    return TAG_USED if seen_now or now - last_seen < OFFLINE_AFTER else TAG_OFFLINE


def load_devices(text: str) -> list[Device]:
    import yaml  # py3-yaml in the job image

    out: list[Device] = []
    seen: set[str] = set()
    for i, e in enumerate(yaml.safe_load(text) or []):
        name = (e or {}).get("name")
        if not name:
            raise ValueError(f"devices.yaml entry {i}: no name")
        if name in seen:
            raise ValueError(f"devices.yaml: {name} listed twice")
        if e.get("type") not in DEVICE_TYPES:
            raise ValueError(f"devices.yaml {name}: type {e.get('type')!r} is not one of {DEVICE_TYPES}")
        seen.add(name)
        out.append(Device(
            name=name, type=e["type"], location=e.get("location"), vendor=e.get("vendor"),
            model=e.get("model"), os=e.get("os"), description=e.get("description"),
            addresses=tuple(str(a) for a in e.get("addresses") or []),
            macs=tuple(str(m).lower() for m in e.get("macs") or []),
        ))
    return out


def device_links(devices: list[Device], rows: list[tuple[int, str, str]]) -> dict[int, str]:
    """Row id -> device name, for rows whose address or MAC a device lists."""
    by_ip = {a: d.name for d in devices for a in d.addresses}
    by_mac = {m: d.name for d in devices for m in d.macs}
    out = {}
    for rid, ip, mac in rows:
        name = by_ip.get(ip) or by_mac.get((mac or "").lower())
        if name:
            out[rid] = name
    return out


# --- source readers --------------------------------------------------------------


def read_ha_registry(url: str, token: str) -> list[dict]:
    """config/device_registry/list over Home Assistant's websocket API."""
    from websockets.sync.client import connect  # py3-websockets in the job image

    ws_url = url.rstrip("/").replace("https://", "wss://").replace("http://", "ws://") + "/api/websocket"
    with connect(ws_url, open_timeout=15, close_timeout=5, max_size=2**25) as ws:
        if json.loads(ws.recv(timeout=15)).get("type") != "auth_required":
            raise RuntimeError("no auth_required from Home Assistant")
        ws.send(json.dumps({"type": "auth", "access_token": token}))
        if json.loads(ws.recv(timeout=15)).get("type") != "auth_ok":
            raise RuntimeError("Home Assistant rejected the token")
        ws.send(json.dumps({"id": 1, "type": "config/device_registry/list"}))
        reply = json.loads(ws.recv(timeout=30))
        if not reply.get("success"):
            raise RuntimeError(f"device_registry/list failed: {str(reply)[:200]}")
        return reply["result"]


def read_proxmox(url: str, token_id: str, secret: str) -> list[dict]:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE  # the PVE API serves its own self-signed certificate
    headers = {"Authorization": f"PVEAPIToken={token_id}={secret}"}

    def get(path: str):
        req = urllib.request.Request(f"{url.rstrip('/')}/api2/json{path}", headers=headers)
        with urllib.request.urlopen(req, timeout=20, context=ctx) as resp:
            return json.load(resp)["data"]

    vms = []
    for node in get("/nodes"):
        for vm in get(f"/nodes/{node['node']}/qemu"):
            vm["config"] = get(f"/nodes/{node['node']}/qemu/{vm['vmid']}/config")
            vms.append(vm)
    return vms


# --- applying it -------------------------------------------------------------------


def ensure_schema(cur, dry_run: bool) -> None:
    """Vendor/Model/OS custom fields on addresses and devices, and the Device types."""
    for table in ("ipaddresses", "devices"):
        cur.execute(f"SHOW COLUMNS FROM {table}")
        have = {r[0] for r in cur.fetchall()}
        for col in CUSTOM_FIELDS:
            if col not in have:
                print(f"  adding custom field {table}.{col}")
                if not dry_run:
                    # How phpIPAM's own admin UI adds a custom field (class.Admin.php).
                    cur.execute(f"ALTER TABLE `{table}` ADD COLUMN `{col}` VARCHAR({FIELD_LEN}) NULL DEFAULT NULL"
                                f" COMMENT 'filled by phpipam-import'")
    cur.execute("SELECT tname FROM deviceTypes")
    have = {r[0] for r in cur.fetchall()}
    for t in DEVICE_TYPES:
        if t not in have:
            print(f"  adding device type {t}")
            if not dry_run:
                cur.execute("INSERT INTO deviceTypes (tname, tdescription) VALUES (%s, %s)", (t, t))


def run(cur, db, *, subnet_ids: list[int], seen_mac_by_ip: dict[str, str], seen_ips: set[str],
        k8s_nodes: dict | None, env: dict, now: dt.datetime, dry_run: bool) -> list[str]:
    """Enrich every row in the tracked subnets; returns the names of sources that failed."""
    failed: list[str] = []
    ensure_schema(cur, dry_run)

    ha: dict[str, Info] = {}
    for site in ("sofia", "london"):
        url, token = env.get(f"HA_{site.upper()}_URL"), env.get(f"HA_{site.upper()}_TOKEN")
        if not (url and token):
            continue
        try:
            got = ha_by_mac(read_ha_registry(url, token))
            ha.update(got)
            print(f"enrich ha-{site}: {len(got)} devices with a MAC")
        except Exception as e:
            print(f"ENRICH FAILED ha-{site}: {e}")
            failed.append(f"ha-{site}")
    pve: dict[str, Info] = {}
    if env.get("PVE_URL") and env.get("PVE_TOKEN_ID"):
        try:
            pve = proxmox_by_mac(read_proxmox(env["PVE_URL"], env["PVE_TOKEN_ID"], env["PVE_TOKEN_SECRET"]))
            print(f"enrich proxmox: {len(pve)} VM NICs")
        except Exception as e:
            print(f"ENRICH FAILED proxmox: {e}")
            failed.append("proxmox")
    k8s = k8s_by_ip(k8s_nodes) if k8s_nodes else {}
    devices: list[Device] = []
    try:
        with open(env["DEVICES_FILE"]) as f:
            devices = load_devices(f.read())
    except Exception as e:
        print(f"ENRICH FAILED devices.yaml: {e}")
        failed.append("devices.yaml")

    ids = tuple(subnet_ids) or (-1,)
    custom = ", Vendor, Model, OS" if _has_custom(cur) else ", NULL, NULL, NULL"  # absent only in a dry run
    cur.execute("SELECT id, INET_NTOA(ip_addr), COALESCE(mac,''), COALESCE(description,''), lastSeen,"
                f" state, COALESCE(switch,0){custom} FROM ipaddresses WHERE subnetId IN %s", (ids,))
    rows = cur.fetchall()

    info_by_row: dict[int, Info] = {}
    mac_by_row: dict[int, str] = {}
    for rid, ip, mac, desc, last, *_ in rows:
        mac = (mac or seen_mac_by_ip.get(ip, "")).lower()
        mac_by_row[rid] = mac
        info_by_row[rid] = merge(oui=oui_vendor(mac, netaddr_lookup) if mac else None,
                                 ha=ha.get(mac), proxmox=pve.get(mac), k8s=k8s.get(ip))

    # Devices: declared fields first, gaps filled from their addresses' sources.
    links = device_links(devices, [(r[0], r[1], mac_by_row[r[0]]) for r in rows])
    device_ids = sync_devices(cur, devices, links, info_by_row, now, dry_run)

    updated = 0
    for rid, ip, mac, desc, last, state, switch, vendor, model, os_ in rows:
        is_hand = not desc.startswith("-- ")
        info = info_by_row[rid]
        current = {"mac": mac, "Vendor": vendor, "Model": model, "OS": os_, "switch": int(switch or 0)}
        new = {"mac": mac_by_row[rid] or None, "Vendor": info.vendor, "Model": info.model, "OS": info.os,
               "switch": device_ids.get(links.get(rid), 0)}
        changes = field_updates(is_hand, current, new)
        seen_now = ip in seen_ips
        tag = state_for(desc, seen_now, last or dt.datetime(1970, 1, 1), now)
        if int(state or 0) != tag:
            changes["state"] = tag
        if is_hand and seen_now:
            changes["lastSeen"] = now
        if not changes:
            continue
        updated += 1
        if not dry_run:
            cols = ", ".join(f"`{k}`=%s" for k in changes)
            cur.execute(f"UPDATE ipaddresses SET {cols} WHERE id=%s", (*changes.values(), rid))
        elif updated <= 15:
            print(f"    DRY-RUN row {ip}: {changes}")
    print(f"enrich: {updated} rows updated, {len(device_ids)} devices")
    if not dry_run:
        db.commit()
    return failed


def _has_custom(cur) -> bool:
    cur.execute("SHOW COLUMNS FROM ipaddresses LIKE 'Vendor'")
    return cur.fetchone() is not None


def sync_devices(cur, devices: list[Device], links: dict[int, str], info_by_row: dict[int, Info],
                 now: dt.datetime, dry_run: bool) -> dict[str, int]:
    """Create or update one phpIPAM Device per declared entry; returns name -> device id."""
    if not devices:
        return {}
    cur.execute("SELECT tid, tname FROM deviceTypes")
    types = {name: int(tid) for tid, name in cur.fetchall()}
    cur.execute("SELECT id, name FROM locations")
    locations = {name: int(i) for i, name in cur.fetchall()}
    cur.execute("SELECT id FROM sections ORDER BY id")
    sections = ";".join(str(r[0]) for r in cur.fetchall())
    custom = _has_custom_devices(cur)
    cur.execute("SELECT id, hostname, COALESCE(ip_addr,''), type, COALESCE(description,''), COALESCE(location,0)"
                + (", Vendor, Model, OS" if custom else ", NULL, NULL, NULL") + " FROM devices")
    existing = {r[1]: r for r in cur.fetchall()}
    rows_by_device: dict[str, list[int]] = {}
    for rid, name in links.items():
        rows_by_device.setdefault(name, []).append(rid)

    ids: dict[str, int] = {}
    for d in devices:
        auto = merge()
        for rid in rows_by_device.get(d.name, []):
            i = info_by_row.get(rid)
            if i:
                auto = Info(auto.vendor or i.vendor, auto.model or i.model, auto.os or i.os)
        want = {
            "ip_addr": d.addresses[0] if d.addresses else "",
            "type": types.get(d.type, types.get("Other", 9)),
            "description": d.description or "",
            "location": locations.get(d.location or "", 0),
            "Vendor": _clip(d.vendor or auto.vendor),
            "Model": _clip(d.model or auto.model),
            "OS": _clip(d.os or auto.os),
        }
        if not custom:
            for k in CUSTOM_FIELDS:
                want.pop(k)
        row = existing.get(d.name)
        if row is None:
            print(f"  creating device {d.name}")
            if dry_run:
                ids[d.name] = -1
                continue
            cols = ["hostname", "sections", *want]
            cur.execute(f"INSERT INTO devices ({', '.join(f'`{c}`' for c in cols)})"
                        f" VALUES ({', '.join(['%s'] * len(cols))})", (d.name, sections, *want.values()))
            ids[d.name] = int(cur.lastrowid)
            continue
        ids[d.name] = int(row[0])
        have = dict(zip(("ip_addr", "type", "description", "location", "Vendor", "Model", "OS"), row[2:]))
        changes = {k: v for k, v in want.items() if (have.get(k) if have.get(k) is not None else "") != (v if v is not None else "")}
        if changes and not dry_run:
            cur.execute(f"UPDATE devices SET {', '.join(f'`{k}`=%s' for k in changes)} WHERE id=%s",
                        (*changes.values(), ids[d.name]))
    return ids


def _has_custom_devices(cur) -> bool:
    cur.execute("SHOW COLUMNS FROM devices LIKE 'Vendor'")
    return cur.fetchone() is not None
