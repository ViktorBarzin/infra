#!/usr/bin/env python3
"""Render the first-boot config.xml for the OPNsense VM (staging profile).

docs/plans/2026-11-03-opnsense-migration.md, phase 2. The output is imported
once over the serial console; from then on Ansible manages the box through
its REST API. This file only holds what the API cannot set (interface
assignment and addresses, GUI port, SSH, root password, the first API key,
NAT reflection) plus the settings that must be off before any NIC is
connected (dnsmasq DHCP/RA, IPv6, the setup wizard).

Starts from OPNsense's own default (src/etc/config.xml.sample on the
release branch) and changes only the listed elements, so the box's
migrations upgrade it like any fresh install.

Secrets come from Vault secret/opnsense at run time and only their hashes
are written. Run:

    scripts/opnsense-bootstrap-config.py --out /tmp/opnsense-bootstrap/config.xml
"""

import argparse
import base64
import json
import subprocess
import sys
import urllib.request
import xml.etree.ElementTree as ET

import bcrypt

SAMPLE_URL = "https://raw.githubusercontent.com/opnsense/core/stable/26.7/src/etc/config.xml.sample"

# Staging profile (plan decision 6). Production addresses replace these at cutover.
STAGING = {
    "hostname": "opnsense",
    "domain": "viktorbarzin.lan",
    "interfaces": {
        # key: (device, description, address, prefix)
        "wan": ("vtnet0", "WAN", "192.168.1.250", "24"),
        "lan": ("vtnet1", "dManagementsVms", "10.0.10.2", "24"),
        "opt1": ("vtnet2", "dKubernetes", "10.0.20.2", "24"),
        "opt4": ("vtnet3", "dCCTV", "10.0.30.2", "24"),
    },
    "wan_gateway": ("WANGW", "192.168.1.1"),
    # The box's own resolvers while staging; it must not depend on pfSense.
    "dns": ["94.140.14.14", "1.1.1.1"],
    "gui_port": "8443",
    "gui_althostnames": "opnsense.viktorbarzin.me",
    "timezone": "Europe/Sofia",
}


def vault(field: str) -> str:
    out = subprocess.run(
        ["vault", "kv", "get", "-field=" + field, "secret/opnsense"],
        check=True, capture_output=True, text=True,
    )
    return out.stdout.strip()


def sub(parent: ET.Element, tag: str, text: str | None = None) -> ET.Element:
    el = parent.find(tag)
    if el is None:
        el = ET.SubElement(parent, tag)
    if text is not None:
        el.text = text
    return el


def drop(parent: ET.Element, tag: str) -> None:
    for el in parent.findall(tag):
        parent.remove(el)


def render(sample: bytes) -> bytes:
    root = ET.fromstring(sample)
    drop(root, "trigger_initial_wizard")

    system = root.find("system")
    sub(system, "hostname", STAGING["hostname"])
    sub(system, "domain", STAGING["domain"])
    sub(system, "timezone", STAGING["timezone"])
    drop(system, "dnsserver")
    for server in STAGING["dns"]:
        ET.SubElement(system, "dnsserver").text = server
    # The box resolves with the servers above, not with whatever a DHCP lease offers.
    drop(system, "dnsallowoverride")
    # pfSense has NAT reflection on (pure NAT); keep parity from the start.
    drop(system, "disablenatreflection")
    # No IPv6 anywhere in staging (plan review: pfSense holds the ::1 addresses).
    drop(system, "ipv6allow")

    # Keep a login on the serial console (the nano image's own default has
    # it; the release sample does not). Without it the box is reachable only
    # over the network once this file is in place.
    sub(system, "primaryconsole", "serial")
    sub(system, "secondaryconsole", "video")
    sub(system, "serialspeed", "115200")

    webgui = sub(system, "webgui")
    sub(webgui, "protocol", "https")
    sub(webgui, "port", STAGING["gui_port"])
    sub(webgui, "althostnames", STAGING["gui_althostnames"])

    ssh = sub(system, "ssh")
    sub(ssh, "group", "admins")
    sub(ssh, "enabled", "enabled")
    sub(ssh, "permitrootlogin", "1")
    drop(ssh, "passwordauth")  # absent = key-only

    user = system.find("user")
    pw = bcrypt.hashpw(vault("root_password").encode(), bcrypt.gensalt(rounds=11)).decode()
    sub(user, "password", pw.replace("$2b$", "$2y$", 1))
    sub(user, "authorizedkeys", base64.b64encode(vault("ssh_public_key").encode() + b"\n").decode())
    api_secret = subprocess.run(
        ["openssl", "passwd", "-6", "-stdin"], input=vault("api_secret"),
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    apikeys = sub(user, "apikeys")
    for item in apikeys.findall("item"):
        apikeys.remove(item)
    item = ET.SubElement(apikeys, "item")
    ET.SubElement(item, "key").text = vault("api_key")
    ET.SubElement(item, "secret").text = api_secret

    interfaces = root.find("interfaces")
    for el in list(interfaces):
        interfaces.remove(el)
    for key, (dev, descr, addr, prefix) in STAGING["interfaces"].items():
        ifc = ET.SubElement(interfaces, key)
        ET.SubElement(ifc, "enable").text = "1"
        ET.SubElement(ifc, "if").text = dev
        ET.SubElement(ifc, "descr").text = descr
        ET.SubElement(ifc, "ipaddr").text = addr
        ET.SubElement(ifc, "subnet").text = prefix
        if key == "wan":
            ET.SubElement(ifc, "gateway").text = STAGING["wan_gateway"][0]
            # pfSense passes the home LAN and private ranges on WAN.
            ET.SubElement(ifc, "blockpriv").text = "0"
            ET.SubElement(ifc, "blockbogons").text = "0"

    gateways = sub(root, "gateways")
    for el in list(gateways):
        gateways.remove(el)
    gw = ET.SubElement(gateways, "gateway_item")
    for tag, text in (
        ("interface", "wan"), ("gateway", STAGING["wan_gateway"][1]),
        ("name", STAGING["wan_gateway"][0]), ("weight", "1"),
        ("ipprotocol", "inet"), ("defaultgw", "1"), ("descr", "Home router"),
    ):
        ET.SubElement(gw, tag).text = text

    # dnsmasq ships with DHCP + RA on LAN; nothing may answer DHCP or RA in staging.
    dnsmasq = root.find("dnsmasq")
    for el in list(dnsmasq):
        dnsmasq.remove(el)
    ET.SubElement(dnsmasq, "enable").text = "0"

    # The sample's two LAN allow rules stay (management access from VLAN 10);
    # Ansible owns every other rule.
    ET.indent(root, space="  ")
    return b'<?xml version="1.0"?>\n' + ET.tostring(root, encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", required=True)
    ap.add_argument("--sample", help="local copy of config.xml.sample (default: fetch the 26.7 branch)")
    args = ap.parse_args()
    if args.sample:
        sample = open(args.sample, "rb").read()
    else:
        with urllib.request.urlopen(SAMPLE_URL, timeout=30) as r:
            sample = r.read()
    data = render(sample)
    with open(args.out, "wb") as f:
        f.write(data)
    print(json.dumps({"out": args.out, "bytes": len(data)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
