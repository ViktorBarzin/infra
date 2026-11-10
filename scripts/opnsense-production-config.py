#!/usr/bin/env python3
"""Rewrite an OPNsense config.xml from the staging to the production addresses.

docs/runbooks/opnsense.md, cutover. Covers only what the REST API cannot
set: interface assignment and addresses (pfSense's .1 IPv4 and static IPv6
addresses, the WireGuard and HE tunnel interfaces), the switch that turns
IPv6 on, the Tailscale interface, the DNS rebind check and the system resolvers. Everything else (WireGuard instance and
peers, the gif device, gateways, rules, Kea, radvd, Tailscale) is the
production profile of playbooks/opnsense.yml, applied afterwards.

Addresses come from playbooks/files/opnsense/addresses.yml (profile
production), the WireGuard interface from wireguard.yml and the resolvers
from misc.yml, so the YAML stays the one source. No secrets are read.

    scripts/opnsense-production-config.py --in staging.xml --out production.xml
"""

import argparse
import json
import os
import sys
import xml.etree.ElementTree as ET

import yaml

OPN_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "playbooks", "files", "opnsense")

# Interface key -> address keys in the profile (IPv4, IPv6 or None).
ADDRESSED = {"wan": ("wan", "wan_v6"), "lan": ("lan", "lan_v6"), "opt1": ("opt1", "opt1_v6"), "opt4": ("opt4", None)}


class ConfigError(Exception):
    pass


def _set(parent: ET.Element, tag: str, text: str) -> None:
    el = parent.find(tag)
    if el is None:
        el = ET.SubElement(parent, tag)
    el.text = text


def _drop(parent: ET.Element, *tags: str) -> None:
    for tag in tags:
        for el in parent.findall(tag):
            parent.remove(el)


def _assign(interfaces: ET.Element, key: str, fields: dict[str, str]) -> None:
    """Replace interfaces/<key> with exactly these fields, in this order."""
    _drop(interfaces, key)
    el = ET.SubElement(interfaces, key)
    for tag, text in fields.items():
        ET.SubElement(el, tag).text = text


def render(src: bytes, fw: dict[str, str], wg: dict[str, str], dns: list[str], he: dict, ts: dict) -> bytes:
    """he and ts are misc.yml interface entries. The HE interface has no address
    of its own (the gif device carries the tunnel addresses); the Tailscale one
    takes its address from tailscaled and exists so the tailnet rules have an
    interface (pfSense used a dynamic interface group instead)."""
    missing = [k for k in ("wan_v6", "lan_v6", "opt1_v6") if k not in fw]
    if missing:
        raise ConfigError(f"profile has no {', '.join(missing)}: not the production profile")
    root = ET.fromstring(src)
    interfaces = root.find("interfaces")
    if interfaces is None:
        raise ConfigError("config.xml has no <interfaces>")

    for key, (v4, v6) in ADDRESSED.items():
        el = interfaces.find(key)
        if el is None:
            raise ConfigError(f"interface {key} is not assigned")
        _set(el, "ipaddr", fw[v4])
        _set(el, "subnet", "24")
        _drop(el, "ipaddrv6", "subnetv6")
        if v6:
            addr, prefix = fw[v6].split("/")
            _set(el, "ipaddrv6", addr)
            _set(el, "subnetv6", prefix)

    wg_addr, wg_prefix = wg["interface_address"].split("/")
    _assign(interfaces, wg["interface"], {
        "enable": "1", "if": "wg0", "descr": "WireGuard", "ipaddr": wg_addr, "subnet": wg_prefix,
    })
    _assign(interfaces, he["key"], {
        "enable": "1", "if": he["device"], "descr": he["description"], "mtu": str(he["mtu"]), "mss": str(he["mss"]),
    })

    _assign(interfaces, ts["key"], {"enable": "1", "if": ts["device"], "descr": ts["description"]})

    settings = root.find("OPNsense/Interfaces/settings")
    if settings is None:
        raise ConfigError("config.xml has no OPNsense/Interfaces/settings")
    _set(settings, "disableipv6", "0")

    system = root.find("system")
    if system is None:
        raise ConfigError("config.xml has no <system>")
    # pfSense had the DNS rebind check off (misc.yml webgui.dns_rebind_check);
    # on OPNsense the same switch also keeps Unbound from dropping private
    # answers for public names.
    webgui = system.find("webgui")
    if webgui is None:
        raise ConfigError("config.xml has no system/webgui")
    _set(webgui, "nodnsrebindcheck", "1")
    old = system.findall("dnsserver")
    pos = list(system).index(old[0]) if old else len(system)
    _drop(system, "dnsserver")
    for i, server in enumerate(dns):
        el = ET.Element("dnsserver")
        el.text = server
        system.insert(pos + i, el)

    ET.indent(root, space="  ")
    return b'<?xml version="1.0"?>\n' + ET.tostring(root, encoding="utf-8") + b"\n"


def _yaml(name: str) -> dict:
    with open(os.path.join(OPN_DIR, name)) as f:
        return yaml.safe_load(f)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--in", dest="src", required=True, help="config.xml from the staging box")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    fw = _yaml("addresses.yml")["profiles"]["production"]
    tunnel = _yaml("wireguard.yml")["tunnels"][0]
    misc = _yaml("misc.yml")
    dns = misc["dns_servers"]
    he = next(i for i in misc["interfaces"] if i["device"] == "gif0")
    ts = next(i for i in misc["interfaces"] if i["device"] == "tailscale0")
    with open(args.src, "rb") as f:
        src = f.read()
    try:
        data = render(src, fw, tunnel, dns, he, ts)
    except ConfigError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    fd = os.open(args.out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    print(json.dumps({"out": args.out, "bytes": len(data)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
