"""Tests for scripts/opnsense-production-config.py.

    python3 -m pytest scripts/opnsense_production_config_test.py -q
"""
import importlib.util
import os
import xml.etree.ElementTree as ET

import pytest

HERE = os.path.dirname(__file__)
_spec = importlib.util.spec_from_file_location(
    "opc", os.path.join(HERE, "opnsense-production-config.py"))
opc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(opc)

FW = {
    "wan": "192.168.1.2", "lan": "10.0.10.1", "opt1": "10.0.20.1", "opt4": "10.0.30.1",
    "wan_v6": "fdfe:e989:d3ce:1::1/64", "lan_v6": "2001:470:6f:43d::1/64",
    "opt1_v6": "2001:470:5a7f:20::1/64",
}
WG = {"interface": "opt2", "interface_address": "10.3.2.1/24"}
DNS = ["1.1.1.1", "1.0.0.1"]
HE = {"key": "opt3", "device": "gif0", "description": "HE_IPv6", "mtu": 1480, "mss": 1480}
TS = {"key": "opt5", "device": "tailscale0", "description": "Tailscale"}

STAGING = """<?xml version="1.0"?>
<opnsense>
  <system>
    <hostname>opnsense</hostname>
    <webgui><protocol>https</protocol></webgui>
    <dnsserver>94.140.14.14</dnsserver>
    <dnsserver>1.1.1.1</dnsserver>
  </system>
  <interfaces>
    <wan><enable>1</enable><if>vtnet0</if><descr>WAN</descr><ipaddr>192.168.1.250</ipaddr><subnet>24</subnet><gateway>WANGW</gateway></wan>
    <lan><enable>1</enable><if>vtnet1</if><descr>dManagementsVms</descr><ipaddr>10.0.10.2</ipaddr><subnet>24</subnet></lan>
    <opt1><enable>1</enable><if>vtnet2</if><descr>dKubernetes</descr><ipaddr>10.0.20.2</ipaddr><subnet>24</subnet></opt1>
    <opt4><enable>1</enable><if>vtnet3</if><descr>dCCTV</descr><ipaddr>10.0.30.2</ipaddr><subnet>24</subnet></opt4>
    <lo0><if>lo0</if><ipaddr>127.0.0.1</ipaddr></lo0>
  </interfaces>
  <OPNsense><Interfaces><settings><disableipv6>1</disableipv6></settings></Interfaces></OPNsense>
</opnsense>
"""


def render(src=STAGING):
    return ET.fromstring(opc.render(src.encode(), FW, WG, DNS, HE, TS))


def ifc(root, key):
    el = root.find("interfaces/" + key)
    assert el is not None, key
    return {c.tag: (c.text or "") for c in el}


@pytest.mark.parametrize("key,addr", [("wan", "192.168.1.2"), ("lan", "10.0.10.1"),
                                      ("opt1", "10.0.20.1"), ("opt4", "10.0.30.1")])
def test_ipv4_moves_to_production_address(key, addr):
    got = ifc(render(), key)
    assert (got["ipaddr"], got["subnet"]) == (addr, "24")


@pytest.mark.parametrize("key,addr", [("wan", "fdfe:e989:d3ce:1::1"), ("lan", "2001:470:6f:43d::1"),
                                      ("opt1", "2001:470:5a7f:20::1")])
def test_ipv6_static_addresses(key, addr):
    got = ifc(render(), key)
    assert (got["ipaddrv6"], got["subnetv6"]) == (addr, "64")


def test_cctv_gets_no_ipv6():
    assert "ipaddrv6" not in ifc(render(), "opt4")


def test_wan_keeps_gateway_and_device():
    got = ifc(render(), "wan")
    assert (got["if"], got["gateway"]) == ("vtnet0", "WANGW")


def test_wireguard_interface_assigned_with_pfsense_address():
    got = ifc(render(), "opt2")
    assert (got["if"], got["enable"], got["ipaddr"], got["subnet"]) == ("wg0", "1", "10.3.2.1", "24")


def test_he_tunnel_interface_assigned_without_address():
    got = ifc(render(), "opt3")
    assert (got["if"], got["enable"], got["descr"], got["mtu"], got["mss"]) == (
        "gif0", "1", "HE_IPv6", "1480", "1480")
    assert "ipaddr" not in got and "ipaddrv6" not in got


def test_tailscale_interface_assigned_without_address():
    got = ifc(render(), "opt5")
    assert (got["if"], got["enable"], got["descr"]) == ("tailscale0", "1", "Tailscale")
    assert "ipaddr" not in got


def test_dns_rebind_check_off_as_on_pfsense():
    # Unbound writes private-address lines (rebind protection) unless this is set.
    assert render().find("system/webgui/nodnsrebindcheck") is not None


def test_ipv6_switched_on():
    assert render().findtext("OPNsense/Interfaces/settings/disableipv6") == "0"


def test_system_resolvers_are_pfsense_ones():
    assert [e.text for e in render().findall("system/dnsserver")] == DNS


def test_other_interfaces_untouched():
    assert ifc(render(), "lo0") == {"if": "lo0", "ipaddr": "127.0.0.1"}


def test_idempotent():
    once = opc.render(STAGING.encode(), FW, WG, DNS, HE, TS)
    assert opc.render(once, FW, WG, DNS, HE, TS) == once


def test_missing_interface_fails():
    src = STAGING.replace("<opt4>", "<optx>").replace("</opt4>", "</optx>")
    with pytest.raises(opc.ConfigError):
        opc.render(src.encode(), FW, WG, DNS, HE, TS)


def test_profile_without_ipv6_is_not_production():
    staging_fw = {k: v for k, v in FW.items() if not k.endswith("_v6")}
    with pytest.raises(opc.ConfigError):
        opc.render(STAGING.encode(), staging_fw, WG, DNS, HE, TS)
