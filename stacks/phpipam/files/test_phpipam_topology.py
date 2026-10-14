"""Unit tests for phpipam_topology.py.

Run with: cd infra/stacks/phpipam/files && python3 -m unittest test_phpipam_topology
"""
import datetime as dt
import importlib.util
import sys
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location("phpipam_topology", Path(__file__).parent / "phpipam_topology.py")
pt = importlib.util.module_from_spec(_spec)
sys.modules["phpipam_topology"] = pt
_spec.loader.exec_module(pt)

NOW = dt.datetime(2026, 10, 14, 12, 0, 0)
FRESH = NOW - dt.timedelta(minutes=3)
STALE = NOW - dt.timedelta(hours=5)


def subnet(id, cidr, desc, loc, seen=()):
    return pt.Subnet(id=id, section=1, cidr=cidr, description=desc, location=loc, last_seen=tuple(seen))


def device(id, name, type, loc, addrs, seen=()):
    return pt.Device(id=id, name=name, type=type, location=loc, addresses=tuple(addrs), last_seen=tuple(seen))


LAN = subnet(9, "192.168.1.0/24", "Sofia LAN", "Sofia", [FRESH, FRESH, STALE, None])
K8S = subnet(8, "10.0.20.0/24", "Kubernetes", "Sofia", [FRESH])
LONDON = subnet(11, "192.168.8.0/24", "London LAN", "London", [FRESH])
WG = subnet(10, "10.3.2.0/24", "WireGuard", "Sofia", [FRESH])
TAILNET = subnet(16, "100.64.0.0/10", "Headscale", None, [])

PFSENSE = device(3, "pfsense", "Firewall", "Sofia", ["192.168.1.2", "10.0.20.1", "10.3.2.1"], [FRESH])
FLINT = device(18, "flint-london", "Router", "London", ["192.168.8.1", "10.3.2.6"], [STALE])
NAS = device(8, "synology-nas", "Storage", "Sofia", ["192.168.1.13"], [FRESH])
LONELY = device(30, "spare", "Router", "Sofia", [], [])


class StateTests(unittest.TestCase):
    def test_state(self):
        for seen, want in [
            ((FRESH,), "up"),
            ((STALE, FRESH), "up"),          # any address seen recently is enough
            ((STALE,), "down"),
            ((None, STALE), "down"),
            ((), "unknown"),                 # never seen: no claim either way
            ((None,), "unknown"),
        ]:
            with self.subTest(seen=seen):
                self.assertEqual(pt.state(seen, NOW), want)


class LinkTests(unittest.TestCase):
    def test_network_devices_only(self):
        links = pt.links([LAN, K8S, WG], [PFSENSE, NAS, LONELY])
        self.assertEqual(links, [(PFSENSE, K8S), (PFSENSE, WG), (PFSENSE, LAN)])

    def test_address_outside_every_subnet_is_ignored(self):
        odd = device(31, "odd", "Router", "Sofia", ["172.16.0.1"])
        self.assertEqual(pt.links([LAN], [odd]), [])


class PlacementTests(unittest.TestCase):
    def test_placement(self):
        links = pt.links([LAN, LONDON, WG, TAILNET], [PFSENSE, FLINT])
        where = pt.placement([LAN, LONDON, WG, TAILNET], links)
        self.assertEqual(where[LAN.id], "Sofia")
        self.assertEqual(where[LONDON.id], "London")
        # Routers from two sites sit on it, so it belongs to neither.
        self.assertIsNone(where[WG.id])
        # No location in phpIPAM.
        self.assertIsNone(where[TAILNET.id])


class LabelTests(unittest.TestCase):
    def test_escapes_mermaid_syntax(self):
        self.assertEqual(pt.label('a "b" <c>'), "a #quot;b#quot; #lt;c#gt;")

    def test_subnet_text_counts(self):
        self.assertEqual(pt.subnet_text(LAN, NOW),
                         "<b>192.168.1.0/24</b><br/>Sofia LAN<br/>4 addresses, 2 seen in the last hour")

    def test_subnet_text_without_seen_data(self):
        self.assertEqual(pt.subnet_text(TAILNET, NOW), "<b>100.64.0.0/10</b><br/>Headscale<br/>0 addresses")


class MermaidTests(unittest.TestCase):
    def setUp(self):
        self.out = pt.render_mermaid([LAN, K8S, LONDON, WG, TAILNET], [PFSENSE, FLINT, NAS], NOW)

    def test_sites_are_subgraphs(self):
        self.assertIn('subgraph site_Sofia["Sofia"]', self.out)
        self.assertIn('subgraph site_London["London"]', self.out)

    def test_shared_subnet_outside_sites(self):
        wg_line = next(l for l in self.out.splitlines() if l.strip().startswith("s10"))
        self.assertFalse(wg_line.startswith("    "), wg_line)  # top level, not indented into a subgraph

    def test_edges_and_state_classes(self):
        self.assertIn("s10 -.- d3", self.out)    # shared subnet above the routers, dotted
        self.assertIn("s10 -.- d18", self.out)
        self.assertIn("d3 --- s9", self.out)     # router above its site's subnets
        self.assertIn("class d3 up", self.out)
        self.assertIn("class d18 down", self.out)

    def test_tunnel_presence_is_not_liveness(self):
        # Its WireGuard address is fresh (the peer is configured), its LAN address is not.
        m3 = device(22, "mladost3-openwrt", "Router", "Mladost 3", ["192.168.3.1", "10.3.2.7"], [STALE, FRESH])
        m3_lan = subnet(15, "192.168.3.0/24", "Mladost 3 LAN", "Mladost 3", [STALE])
        out = pt.render_mermaid([LAN, m3_lan, WG], [PFSENSE, m3], NOW)
        self.assertIn("class d22 down", out)

    def test_single_subnet_device_hangs_below(self):
        ap = device(5, "wifi-garaj", "Wireless", "Sofia", ["192.168.1.7"], [FRESH])
        out = pt.render_mermaid([LAN, WG], [PFSENSE, ap], NOW)
        self.assertIn("s9 --- d5", out)

    def test_subnets_link_to_phpipam(self):
        self.assertIn('click s9 "/subnets/1/9/"', self.out)

    def test_non_network_devices_not_drawn(self):
        self.assertNotIn("synology", self.out)

    def test_deterministic(self):
        again = pt.render_mermaid([TAILNET, WG, LONDON, K8S, LAN], [NAS, FLINT, PFSENSE], NOW)
        self.assertEqual(self.out, again)


class HtmlTests(unittest.TestCase):
    def test_page(self):
        page = pt.render_html("flowchart LR\n  a --- b", NOW)
        self.assertIn("<title>Network topology</title>", page)
        self.assertIn("flowchart LR\n  a --- b", page)
        self.assertIn("2026-10-14 12:00", page)

    def test_mermaid_text_is_html_escaped(self):
        page = pt.render_html('flowchart LR\n  a["<b>x</b>"]', NOW)
        self.assertIn("&lt;b&gt;x&lt;/b&gt;", page)


if __name__ == "__main__":
    unittest.main()
