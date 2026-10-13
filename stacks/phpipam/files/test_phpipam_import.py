"""Unit tests for the pure parts of phpipam_import.py.

Run with: cd infra/stacks/phpipam/files && python3 -m unittest test_phpipam_import
"""
import datetime as dt
import importlib.util
import sys
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "phpipam_import", Path(__file__).parent / "phpipam_import.py"
)
pi = importlib.util.module_from_spec(_spec)
sys.modules["phpipam_import"] = pi  # dataclasses look their module up here
_spec.loader.exec_module(pi)

NOW = dt.datetime(2026, 10, 13, 12, 0, 0)
LAN = 11
GUEST = 13
K8S = 8


def lease(mac, ip, hostname="*"):
    return pi.Lease(mac=mac, ip=ip, hostname=hostname)


def obs(ip, subnet, kind="dynamic", mac="", name=None, desc="-- dhcp london --", source="london", tier=1):
    return pi.Obs(ip=ip, subnet_id=subnet, kind=kind, mac=mac, name=name, desc=desc, source=source, tier=tier)


def row(id, ip, subnet, mac="", hostname="", description="-- dhcp london --", last_seen=NOW):
    return pi.Row(id=id, ip=ip, subnet_id=subnet, mac=mac, hostname=hostname,
                  description=description, last_seen=last_seen)


class SanitizeTests(unittest.TestCase):
    def test_cases(self):
        cases = [
            ("ViktorBnsiPhone", "viktorbnsiphone"),
            ("Portal-75AE8F9C2A8A", "portal-75ae8f9c2a8a"),
            ("Viktor's MBP 14", "viktor-s-mbp-14"),
            ("apollo_air.local", "apollo-air"),
            ("proxmox.viktorbarzin.lan", "proxmox"),
            ("--x--", "x"),
            ("*", None),
            ("", None),
            (None, None),
            ("---", None),
            ("a" * 80, "a" * 63),
            ("x'); DROP TABLE ipaddresses;--", "x-drop-table-ipaddresses"),
        ]
        for raw, want in cases:
            with self.subTest(raw=raw):
                self.assertEqual(pi.sanitize(raw), want)


class NetworkTests(unittest.TestCase):
    def test_network_of(self):
        for ip, want in [
            ("192.168.8.1", "192.168.8.0/24"), ("192.168.9.254", "192.168.9.0/24"),
            ("192.168.1.8", "192.168.1.0/24"), ("10.0.20.200", "10.0.20.0/24"),
            ("100.64.0.61", "100.64.0.0/10"), ("192.168.10.1", None), ("10.10.3.4", None),
            ("8.8.8.8", None), ("not-an-ip", None),
        ]:
            with self.subTest(ip=ip):
                net = pi.network_of(ip)
                self.assertEqual(net.cidr if net else None, want)

    def test_router_addresses_are_tracked(self):
        for site, ips in pi.SITE_ROUTERS.items():
            for ip in ips:
                with self.subTest(site=site, ip=ip):
                    self.assertIsNotNone(pi.network_of(ip))

    def test_router_addresses_match_the_fetch_script(self):
        script = (Path(__file__).parent / "fetch_sources.sh").read_text()
        for site in pi.SITES:
            self.assertIn(f"{site}={pi.SITE_ROUTERS[site][0]}", script)

    def test_site_nets(self):
        self.assertEqual(
            sorted(n.cidr for n in pi.NETWORKS if n.publish == "london"),
            ["192.168.8.0/24", "192.168.9.0/24"],
        )


class ParseTests(unittest.TestCase):
    def test_parse_leases_keeps_newest_per_mac(self):
        text = (
            "1760000000 72:A5:AF:75:CF:67 192.168.8.116 Watch 01:72:a5\n"
            "1760000100 f4:9d:8a:26:0b:18 192.168.8.100 * *\n"
            "1760000050 f4:9d:8a:26:0b:18 192.168.9.100 projector-london *\n"
            "garbage line\n"
        )
        self.assertEqual(
            pi.parse_leases(text),
            [
                lease("72:a5:af:75:cf:67", "192.168.8.116", "Watch"),
                lease("f4:9d:8a:26:0b:18", "192.168.8.100", "*"),
            ],
        )

    def test_parse_leases_drops_untracked_networks(self):
        text = "1 aa:bb:cc:dd:ee:ff 8.8.8.8 x *\n1 aa:bb:cc:dd:ee:00 192.168.10.5 y *\n"
        self.assertEqual(pi.parse_leases(text), [])

    def test_parse_uci_hosts(self):
        text = (
            "dhcp.plug_livia=host\n"
            "dhcp.plug_livia.name='plug-livia'\n"
            "dhcp.plug_livia.mac='78:8C:B5:74:30:11'\n"
            "dhcp.cfg09fe63=host\n"
            "dhcp.cfg09fe63.mac='84:2f:57:39:9a:d9' '16:a8:3e:53:fe:6b'\n"
            "dhcp.cfg09fe63.name='mbp-london'\n"
            "dhcp.cfg0b=host\n"
            "dhcp.cfg0b.mac='28:05:A5:08:0C:00'\n"
            "dhcp.cfg0b.ip='192.168.8.184'\n"
            "dhcp.cfg0b.tag='esphome-web-080c00'\n"
            "dhcp.@host[0]=host\n"
            "dhcp.@host[0].name='Security-System'\n"
            "dhcp.@host[0].ip='192.168.0.10'\n"
            "dhcp.lan=dhcp\n"
            "dhcp.lan.interface='lan'\n"
        )
        hosts = pi.parse_uci_hosts(text)
        self.assertEqual(
            pi.curated_names(hosts),
            {
                "78:8c:b5:74:30:11": "plug-livia",
                "84:2f:57:39:9a:d9": "mbp-london",
                "16:a8:3e:53:fe:6b": "mbp-london",
            },
        )
        self.assertEqual(
            sorted((h.ip, h.name) for h in hosts if h.ip),
            [("192.168.0.10", "security-system"), ("192.168.8.184", None)],
        )

    def test_parse_proc_arp(self):
        text = (
            "IP address       HW type     Flags       HW address            Mask     Device\n"
            "192.168.8.198    0x1         0x2         a4:0e:2b:0e:48:a3     *        br-lan\n"
            "192.168.9.100    0x1         0x0         00:00:00:00:00:00     *        br-guest\n"
            "192.168.8.1      0x1         0x2         AA:BB:CC:00:00:01     *        br-lan\n"
        )
        self.assertEqual(
            pi.parse_proc_arp(text),
            [("192.168.8.198", "a4:0e:2b:0e:48:a3"), ("192.168.8.1", "aa:bb:cc:00:00:01")],
        )

    def test_parse_bsd_arp(self):
        text = (
            "? (192.168.1.104) at a4:0e:2b:2f:18:33 on vtnet0 expires in 1098 seconds [ethernet]\n"
            "? (192.168.1.2) at bc:24:11:00:00:02 on vtnet0 permanent [ethernet]\n"
            "? (192.168.1.77) at (incomplete) on vtnet0 expired [ethernet]\n"
            "? (8.8.8.8) at 00:11:22:33:44:55 on vtnet9 expires in 3 seconds [ethernet]\n"
        )
        self.assertEqual(
            pi.parse_bsd_arp(text),
            [("192.168.1.104", "a4:0e:2b:2f:18:33", False), ("192.168.1.2", "bc:24:11:00:00:02", True)],
        )

    def test_parse_kea_leases_last_line_wins_and_expired_dropped(self):
        text = (
            "address,hwaddr,client_id,valid_lifetime,expire,subnet_id,fqdn_fwd,fqdn_rev,hostname,state,user_context,pool_id\n"
            "10.0.30.70,50:e5:38:81:7a:c1,01:50,7200,1791935697,3,0,0,garage-cam,0,,0\n"
            "10.0.20.103,00:50:56:b0:a1:37,,7200,1700000000,2,0,0,k8s-node3,0,,0\n"
            "10.0.20.103,00:50:56:b0:a1:37,,7200,1791935755,2,0,0,k8s-node3,0,,0\n"
            "10.0.20.150,00:50:56:00:00:01,,7200,1700000000,2,0,0,old,0,,0\n"
            "10.0.20.151,00:50:56:00:00:02,,7200,1791935755,2,0,0,released,2,,0\n"
        )
        got = pi.parse_kea_leases(text, now_epoch=1791930000)
        self.assertEqual(
            got,
            [lease("50:e5:38:81:7a:c1", "10.0.30.70", "garage-cam"),
             lease("00:50:56:b0:a1:37", "10.0.20.103", "k8s-node3")],
        )

    def test_parse_kea_reservations(self):
        text = (
            '{"Dhcp4": {"subnet4": [{"id": 1, "subnet": "10.0.10.0/24", "reservations": ['
            '{"hw-address": "00:0C:29:C0:89:EC", "ip-address": "10.0.10.10", "hostname": "devvm"},'
            '{"hw-address": "00:0c:29:e0:82:b0", "ip-address": "10.0.10.15"}]}]}}'
        )
        self.assertEqual(
            pi.parse_kea_reservations(text),
            [pi.Host(mac="00:0c:29:c0:89:ec", ip="10.0.10.10", name="devvm"),
             pi.Host(mac="00:0c:29:e0:82:b0", ip="10.0.10.15", name=None)],
        )

    def test_parse_wg_allowed_ips(self):
        text = (
            "YWlj=\t10.3.2.5/32 192.168.0.0/24\n"
            "bDmc=\t192.168.10.0/24 192.168.9.0/24 192.168.8.0/24 10.3.2.6/32\n"
            "jxwL=\t10.3.2.10/32\n"
            "none=\t(none)\n"
        )
        self.assertEqual(
            pi.parse_wg_allowed_ips(text),
            [("10.3.2.5", "192.168.0.0/24"), ("10.3.2.6", "192.168.10.0/24 192.168.9.0/24 192.168.8.0/24"),
             ("10.3.2.10", "")],
        )

    def test_split_sections(self):
        text = "a\nb\n---ARP---\nc\n---UCI---\nd\n"
        self.assertEqual(pi.split_sections(text), {"": "a\nb\n", "ARP": "c\n", "UCI": "d\n"})


class AssignNamesTests(unittest.TestCase):
    def test_auto_name_used_when_free(self):
        got = pi.assign_names([lease("72:a5:af:75:cf:67", "192.168.8.116", "Watch")], {}, set(), "london")
        self.assertEqual(got, {"72:a5:af:75:cf:67": "watch"})

    def test_nameless_lease_gets_no_name(self):
        got = pi.assign_names([lease("4a:90:90:41:c7:7e", "192.168.8.199")], {}, set(), "london")
        self.assertEqual(got, {"4a:90:90:41:c7:7e": None})

    def test_clash_outside_the_site_appends_the_site(self):
        for site in ("london", "valchedrym", "mladost3"):
            with self.subTest(site=site):
                got = pi.assign_names(
                    [lease("aa:1c:ce:36:58:a8", "192.168.8.242", "Ancas-MacBook-Air")],
                    {}, {"ancas-macbook-air"}, site,
                )
                self.assertEqual(got, {"aa:1c:ce:36:58:a8": f"ancas-macbook-air-{site}"})

    def test_duplicates_inside_a_site_get_mac_suffix(self):
        leases = [
            lease("78:8c:b5:74:30:11", "192.168.8.118", "KP115"),
            lease("78:8c:b5:74:38:23", "192.168.8.228", "KP115"),
        ]
        got = pi.assign_names(leases, {}, set(), "london")
        self.assertEqual(got, {"78:8c:b5:74:30:11": "kp115-3011", "78:8c:b5:74:38:23": "kp115-3823"})

    def test_naming_does_not_depend_on_order(self):
        leases = [
            lease("78:8c:b5:74:30:11", "192.168.8.118", "KP115"),
            lease("78:8c:b5:74:38:23", "192.168.8.228", "KP115"),
            lease("7e:d0:86:38:d9:30", "192.168.8.155", "Mac"),
        ]
        self.assertEqual(
            pi.assign_names(leases, {}, set(), "london"),
            pi.assign_names(list(reversed(leases)), {}, set(), "london"),
        )

    def test_curated_name_wins_and_auto_twin_gets_suffix(self):
        leases = [
            lease("52:9f:c2:9a:64:ab", "192.168.8.126", "Mac"),
            lease("7e:d0:86:38:d9:30", "192.168.8.155", "Mac"),
            lease("aa:aa:aa:aa:11:22", "192.168.8.10", "mbp-london"),
        ]
        got = pi.assign_names(leases, {"52:9f:c2:9a:64:ab": "mbp-london"}, set(), "london")
        self.assertEqual(got["52:9f:c2:9a:64:ab"], "mbp-london")
        self.assertEqual(got["7e:d0:86:38:d9:30"], "mac")
        self.assertEqual(got["aa:aa:aa:aa:11:22"], "mbp-london-1122")

    def test_names_are_unique_and_never_taken(self):
        leases = [
            lease("00:00:00:00:00:01", "192.168.8.1", "a"),
            lease("00:00:00:00:00:02", "192.168.8.2", "a"),
            lease("00:00:00:00:00:03", "192.168.8.3", "a-london"),
            lease("00:00:00:00:00:04", "192.168.8.4", "b"),
            lease("00:00:00:00:00:05", "192.168.8.5", "b-london"),
            lease("00:00:00:00:00:06", "192.168.8.6", "c"),
        ]
        taken = {"b", "c", "c-london"}
        named = [n for n in pi.assign_names(leases, {}, taken, "london").values() if n]
        self.assertEqual(len(named), len(set(named)))
        self.assertFalse(set(named) & taken)


class PickNameTests(unittest.TestCase):
    def test_precedence(self):
        self.assertEqual(pi.pick_name("devvm", "devvm-lease", "devvm-dns"), "devvm")
        self.assertEqual(pi.pick_name(None, "Lease-Name", "dns-name"), "lease-name")
        self.assertEqual(pi.pick_name(None, "*", "dns-name"), "dns-name")
        self.assertEqual(pi.pick_name(None, None, None), None)


class RowKindTests(unittest.TestCase):
    def test_kinds(self):
        for desc, want in [
            ("-- dhcp london --", ("dynamic", "london")),
            ("-- arp sofia --", ("dynamic", "sofia")),
            ("-- k8s lb traefik/traefik --", ("declared", "k8s")),
            ("-- k8s node --", ("declared", "k8s")),
            ("-- reservation sofia --", ("declared", "sofia")),
            ("-- wireguard peer --", ("declared", "sofia")),
            ("-- headscale --", ("declared", "headscale")),
            ("-- london dhcp (london_import) --", ("dynamic", "legacy")),
            ("-- autodiscovered --", ("dynamic", "legacy")),
            ("-- wg tunnel scan --", ("dynamic", "legacy")),
            ("SONY TV", ("hand", None)),
            ("", ("hand", None)),
        ]:
            with self.subTest(desc=desc):
                self.assertEqual(pi.row_kind(desc), want)


class PlanRowsTests(unittest.TestCase):
    def test_new_device_is_inserted(self):
        o = obs("192.168.8.116", LAN, mac="72:a5:af:75:cf:67", name="watch")
        plan = pi.plan_rows([o], [], NOW, set())
        self.assertEqual((plan.inserts, plan.updates, plan.deletes), ([o], [], []))

    def test_name_follows_device_to_new_network(self):
        rows = [row(5, "192.168.9.100", GUEST, "f4:9d:8a:26:0b:18", "projector-london")]
        o = obs("192.168.8.100", LAN, mac="f4:9d:8a:26:0b:18", name="projector-london")
        plan = pi.plan_rows([o], rows, NOW, set())
        self.assertEqual((plan.inserts, plan.updates), ([], [(5, o)]))

    def test_legacy_marker_rows_are_adopted_by_mac(self):
        rows = [row(5, "192.168.8.100", LAN, "f4:9d:8a:26:0b:18", "x", "-- london dhcp (london_import) --")]
        o = obs("192.168.8.100", LAN, mac="f4:9d:8a:26:0b:18", name="projector-london")
        plan = pi.plan_rows([o], rows, NOW, set())
        self.assertEqual(plan.updates, [(5, o)])

    def test_unnamed_artefact_in_the_way_is_removed(self):
        rows = [row(7, "192.168.8.118", LAN, description="-- wg tunnel scan --")]
        o = obs("192.168.8.118", LAN, mac="78:8c:b5:74:30:11", name="plug-livia")
        plan = pi.plan_rows([o], rows, NOW, set())
        self.assertEqual(plan.deletes, [7])
        self.assertEqual(plan.inserts, [o])

    def test_hand_row_is_never_touched_and_its_address_is_skipped(self):
        rows = [row(1, "192.168.8.103", LAN, "", "ha-london", "Home Assistant London")]
        o = obs("192.168.8.103", LAN, mac="b8:27:eb:e9:18:92", name="homeassistant")
        plan = pi.plan_rows([o], rows, NOW, set())
        self.assertEqual((plan.deletes, plan.inserts, plan.updates), ([], [], []))
        self.assertEqual(plan.skipped, [o])

    def test_departed_dynamic_row_kept_for_grace_then_removed(self):
        recent = row(3, "192.168.8.50", LAN, "aa:aa:aa:aa:aa:01", "gone-soon", last_seen=NOW - dt.timedelta(hours=2))
        old = row(4, "192.168.8.51", LAN, "aa:aa:aa:aa:aa:02", "gone", last_seen=NOW - dt.timedelta(hours=30))
        legacy = row(9, "192.168.8.52", LAN, description="-- wg tunnel scan --", last_seen=NOW - dt.timedelta(days=200))
        hand = row(10, "192.168.8.53", LAN, hostname="x", description="Printer", last_seen=NOW - dt.timedelta(days=200))
        plan = pi.plan_rows([], [recent, old, legacy, hand], NOW, set())
        self.assertEqual(plan.deletes, [4, 9])

    def test_declared_row_goes_when_its_source_stops_listing_it(self):
        rows = [row(20, "10.0.20.209", K8S, description="-- k8s lb rustdesk/rustdesk --")]
        plan = pi.plan_rows([], rows, NOW, set())
        self.assertEqual(plan.deletes, [20])

    def test_rows_of_a_failed_source_are_left_alone(self):
        rows = [
            row(20, "10.0.20.209", K8S, description="-- k8s lb rustdesk/rustdesk --"),
            row(21, "192.168.8.51", LAN, "aa:aa:aa:aa:aa:02", "gone", last_seen=NOW - dt.timedelta(hours=30)),
        ]
        plan = pi.plan_rows([], rows, NOW, {"k8s", "london"})
        self.assertEqual(plan.deletes, [])

    def test_declared_rows_are_keyed_by_ip(self):
        rows = [row(20, "10.0.20.200", K8S, description="-- k8s lb headscale/headscale-server --")]
        o = obs("10.0.20.200", K8S, kind="declared", desc="-- k8s lb technitium/technitium-dns --", source="k8s", tier=0)
        plan = pi.plan_rows([o], rows, NOW, set())
        self.assertEqual(plan.updates, [(20, o)])

    def test_declared_beats_dynamic_for_the_same_address(self):
        lb = obs("10.0.20.200", K8S, kind="declared", desc="-- k8s lb x/y --", source="k8s", tier=0)
        arp = obs("10.0.20.200", K8S, mac="00:50:56:00:00:09", desc="-- arp sofia --", source="sofia", tier=2)
        plan = pi.plan_rows([arp, lb], [], NOW, set())
        self.assertEqual(plan.inserts, [lb])

    def test_one_mac_on_several_addresses_keeps_a_row_each(self):
        a = obs("192.168.1.2", 9, mac="bc:24:11:00:00:02", desc="-- arp sofia --", source="sofia", tier=2)
        b = obs("192.168.1.3", 9, mac="bc:24:11:00:00:02", desc="-- arp sofia --", source="sofia", tier=2)
        rows = [row(30, "192.168.1.2", 9, "bc:24:11:00:00:02", description="-- arp sofia --")]
        plan = pi.plan_rows([a, b], rows, NOW, set())
        self.assertEqual(plan.updates, [(30, a)])
        self.assertEqual(plan.inserts, [b])

    def test_two_devices_swapping_addresses_keep_their_rows(self):
        rows = [
            row(1, "192.168.8.10", LAN, "aa:aa:aa:aa:aa:01", "one"),
            row(2, "192.168.8.11", LAN, "aa:aa:aa:aa:aa:02", "two"),
        ]
        seen = [
            obs("192.168.8.11", LAN, mac="aa:aa:aa:aa:aa:01", name="one"),
            obs("192.168.8.10", LAN, mac="aa:aa:aa:aa:aa:02", name="two"),
        ]
        plan = pi.plan_rows(seen, rows, NOW, set())
        self.assertEqual((plan.deletes, plan.inserts), ([], []))
        self.assertEqual(sorted(rid for rid, _ in plan.updates), [1, 2])

    def test_owned_row_of_departed_device_on_same_ip_is_replaced(self):
        rows = [row(3, "192.168.8.50", LAN, "aa:aa:aa:aa:aa:01", "old-device", last_seen=NOW - dt.timedelta(hours=2))]
        o = obs("192.168.8.50", LAN, mac="bb:bb:bb:bb:bb:02", name="new-device")
        plan = pi.plan_rows([o], rows, NOW, set())
        self.assertEqual((plan.deletes, plan.inserts), ([3], [o]))


class PlanDnsTests(unittest.TestCase):
    def test_diff(self):
        desired = {"watch": "192.168.8.116", "projector-london": "192.168.8.100", "ha-london": "192.168.8.103"}
        current = {
            "watch": {"192.168.8.116"},
            "projector-london": {"192.168.9.100"},
            "mbp-london": {"192.168.8.168"},
        }
        upserts, deletes = pi.plan_dns(desired, current)
        self.assertEqual(upserts, {"projector-london": "192.168.8.100", "ha-london": "192.168.8.103"})
        self.assertEqual(deletes, {"mbp-london": {"192.168.8.168"}})

    def test_no_change_means_no_writes(self):
        self.assertEqual(pi.plan_dns({"watch": "192.168.8.116"}, {"watch": {"192.168.8.116"}}), ({}, {}))


class HandDnsTests(unittest.TestCase):
    def zone(self, *recs):
        z = pi.Zone()
        for name, ip, comment in recs:
            z.add(name, "A", ip, comment)
        return z

    def test_free_name_is_published(self):
        z = self.zone()
        writes, deletes, conflicts = pi.plan_hand_dns({"printer": "192.168.1.50"}, z)
        self.assertEqual((writes, deletes, conflicts), ({"printer": "192.168.1.50"}, {}, []))

    def test_matching_unmarked_record_is_adopted(self):
        z = self.zone(("printer", "192.168.1.50", ""))
        writes, _, _ = pi.plan_hand_dns({"printer": "192.168.1.50"}, z)
        self.assertEqual(writes, {"printer": "192.168.1.50"})

    def test_marked_and_correct_record_is_left(self):
        z = self.zone(("printer", "192.168.1.50", pi.COMMENT))
        self.assertEqual(pi.plan_hand_dns({"printer": "192.168.1.50"}, z), ({}, {}, []))

    def test_name_held_elsewhere_is_a_conflict(self):
        z = self.zone(("proxmox", "192.168.1.127", ""))
        writes, deletes, conflicts = pi.plan_hand_dns({"proxmox": "10.0.10.1"}, z)
        self.assertEqual((writes, deletes), ({}, {}))
        self.assertEqual(conflicts, ["proxmox"])

    def test_owned_record_no_longer_wanted_is_deleted(self):
        z = self.zone(("old-name", "192.168.1.50", pi.COMMENT), ("kea-name", "10.0.10.20", ""))
        _, deletes, _ = pi.plan_hand_dns({}, z)
        self.assertEqual(deletes, {"old-name": {"192.168.1.50"}})

    def test_renamed_hand_row_moves_its_owned_record(self):
        z = self.zone(("my-old", "192.168.1.50", pi.COMMENT))
        writes, deletes, _ = pi.plan_hand_dns({"my-new": "192.168.1.50"}, z)
        self.assertEqual((writes, deletes), ({"my-new": "192.168.1.50"}, {"my-old": {"192.168.1.50"}}))


class HandNamesTests(unittest.TestCase):
    def test_duplicate_hand_names_resolve_to_the_one_dns_already_has(self):
        rows = [
            row(1, "10.0.10.1", 7, hostname="proxmox.viktorbarzin.lan", description="Proxmox VE host"),
            row(2, "192.168.1.127", 9, hostname="proxmox", description="Proxmox VE Host"),
            row(3, "192.168.1.50", 9, hostname="Printer", description="HP"),
            row(4, "192.168.1.51", 9, hostname="", description="nameless"),
        ]
        z = pi.Zone()
        z.add("proxmox", "A", "192.168.1.127", "")
        want, dups = pi.hand_names(rows, z)
        self.assertEqual(want, {"proxmox": "192.168.1.127", "printer": "192.168.1.50"})
        self.assertEqual(dups, ["proxmox"])


if __name__ == "__main__":
    unittest.main()
