"""Unit tests for the pure parts of london_import.py.

Run with: cd infra/stacks/phpipam/files && python3 -m unittest test_london_import
"""
import datetime as dt
import importlib.util
import sys
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "london_import", Path(__file__).parent / "london_import.py"
)
li = importlib.util.module_from_spec(_spec)
sys.modules["london_import"] = li  # dataclasses look their module up here
_spec.loader.exec_module(li)

NOW = dt.datetime(2026, 10, 13, 12, 0, 0)
LAN = 11
GUEST = 13


def lease(mac, ip, hostname="*"):
    return li.Lease(mac=mac, ip=ip, hostname=hostname)


class SanitizeTests(unittest.TestCase):
    def test_cases(self):
        cases = [
            ("ViktorBnsiPhone", "viktorbnsiphone"),
            ("Portal-75AE8F9C2A8A", "portal-75ae8f9c2a8a"),
            ("Viktor's MBP 14", "viktor-s-mbp-14"),
            ("apollo_air.local", "apollo-air"),
            ("--x--", "x"),
            ("*", None),
            ("", None),
            ("---", None),
            ("a" * 80, "a" * 63),
            ("x'); DROP TABLE ipaddresses;--", "x-drop-table-ipaddresses"),
        ]
        for raw, want in cases:
            with self.subTest(raw=raw):
                self.assertEqual(li.sanitize(raw), want)


class ParseTests(unittest.TestCase):
    def test_parse_leases_keeps_newest_per_mac(self):
        text = (
            "1760000000 72:A5:AF:75:CF:67 192.168.8.116 Watch 01:72:a5\n"
            "1760000100 f4:9d:8a:26:0b:18 192.168.8.100 * *\n"
            "1760000050 f4:9d:8a:26:0b:18 192.168.9.100 projector-london *\n"
            "garbage line\n"
        )
        got = li.parse_leases(text)
        self.assertEqual(
            got,
            [
                lease("72:a5:af:75:cf:67", "192.168.8.116", "Watch"),
                lease("f4:9d:8a:26:0b:18", "192.168.8.100", "*"),
            ],
        )

    def test_parse_leases_drops_other_networks(self):
        text = "1 aa:bb:cc:dd:ee:ff 192.168.1.5 x *\n1 aa:bb:cc:dd:ee:00 192.168.10.5 y *\n"
        self.assertEqual(li.parse_leases(text), [])

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
            "dhcp.lan=dhcp\n"
            "dhcp.lan.interface='lan'\n"
        )
        self.assertEqual(
            li.parse_uci_hosts(text),
            {
                "78:8c:b5:74:30:11": "plug-livia",
                "84:2f:57:39:9a:d9": "mbp-london",
                "16:a8:3e:53:fe:6b": "mbp-london",
            },
        )


class AssignNamesTests(unittest.TestCase):
    def test_auto_name_used_when_free(self):
        got = li.assign_names([lease("72:a5:af:75:cf:67", "192.168.8.116", "Watch")], {}, set())
        self.assertEqual(got, {"72:a5:af:75:cf:67": "watch"})

    def test_nameless_lease_gets_no_name(self):
        got = li.assign_names([lease("4a:90:90:41:c7:7e", "192.168.8.199")], {}, set())
        self.assertEqual(got, {"4a:90:90:41:c7:7e": None})

    def test_clash_with_sofia_appends_london(self):
        got = li.assign_names(
            [lease("aa:1c:ce:36:58:a8", "192.168.8.242", "Ancas-MacBook-Air")],
            {},
            {"ancas-macbook-air"},
        )
        self.assertEqual(got, {"aa:1c:ce:36:58:a8": "ancas-macbook-air-london"})

    def test_duplicates_inside_london_get_mac_suffix(self):
        leases = [
            lease("78:8c:b5:74:30:11", "192.168.8.118", "KP115"),
            lease("78:8c:b5:74:38:23", "192.168.8.228", "KP115"),
        ]
        got = li.assign_names(leases, {}, set())
        self.assertEqual(
            got,
            {"78:8c:b5:74:30:11": "kp115-3011", "78:8c:b5:74:38:23": "kp115-3823"},
        )

    def test_duplicate_naming_does_not_depend_on_order(self):
        leases = [
            lease("78:8c:b5:74:30:11", "192.168.8.118", "KP115"),
            lease("78:8c:b5:74:38:23", "192.168.8.228", "KP115"),
            lease("7e:d0:86:38:d9:30", "192.168.8.155", "Mac"),
        ]
        a = li.assign_names(leases, {}, set())
        b = li.assign_names(list(reversed(leases)), {}, set())
        self.assertEqual(a, b)

    def test_curated_name_wins_and_auto_twin_gets_suffix(self):
        leases = [
            lease("52:9f:c2:9a:64:ab", "192.168.8.126", "Mac"),
            lease("7e:d0:86:38:d9:30", "192.168.8.155", "Mac"),
            lease("aa:aa:aa:aa:11:22", "192.168.8.10", "mbp-london"),
        ]
        got = li.assign_names(leases, {"52:9f:c2:9a:64:ab": "mbp-london"}, set())
        self.assertEqual(got["52:9f:c2:9a:64:ab"], "mbp-london")
        self.assertEqual(got["7e:d0:86:38:d9:30"], "mac")
        self.assertEqual(got["aa:aa:aa:aa:11:22"], "mbp-london-1122")

    def test_curated_name_taken_in_sofia_gets_london_suffix(self):
        got = li.assign_names(
            [lease("78:8c:b5:74:30:11", "192.168.8.118", "KP115")],
            {"78:8c:b5:74:30:11": "portal"},
            {"portal"},
        )
        self.assertEqual(got, {"78:8c:b5:74:30:11": "portal-london"})

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
        got = li.assign_names(leases, {}, taken)
        named = [n for n in got.values() if n]
        self.assertEqual(len(named), len(set(named)))
        self.assertFalse(set(named) & taken)


class PlanRowsTests(unittest.TestCase):
    MARK = li.MARK

    def row(self, id, ip, subnet, mac="", hostname="", description=None, last_seen=NOW):
        return li.Row(
            id=id, ip=ip, subnet_id=subnet, mac=mac, hostname=hostname,
            description=description if description is not None else self.MARK,
            last_seen=last_seen,
        )

    def test_new_device_is_inserted(self):
        plan = li.plan_rows([li.Named("72:a5:af:75:cf:67", "192.168.8.116", LAN, "watch")], [], NOW)
        self.assertEqual(plan.inserts, [li.Named("72:a5:af:75:cf:67", "192.168.8.116", LAN, "watch")])
        self.assertEqual(plan.updates, [])
        self.assertEqual(plan.deletes, [])

    def test_name_follows_device_to_new_network(self):
        rows = [self.row(5, "192.168.9.100", GUEST, "f4:9d:8a:26:0b:18", "projector-london")]
        plan = li.plan_rows(
            [li.Named("f4:9d:8a:26:0b:18", "192.168.8.100", LAN, "projector-london")], rows, NOW
        )
        self.assertEqual(plan.inserts, [])
        self.assertEqual(
            plan.updates,
            [(5, li.Named("f4:9d:8a:26:0b:18", "192.168.8.100", LAN, "projector-london"))],
        )

    def test_unnamed_artefact_in_the_way_is_removed(self):
        rows = [self.row(7, "192.168.8.118", LAN, description="-- wg tunnel scan --")]
        plan = li.plan_rows([li.Named("78:8c:b5:74:30:11", "192.168.8.118", LAN, "plug-livia")], rows, NOW)
        self.assertEqual(plan.deletes, [7])
        self.assertEqual(len(plan.inserts), 1)

    def test_hand_made_row_is_never_touched(self):
        rows = [self.row(1, "192.168.8.103", LAN, "", "ha-london", description="Home Assistant London")]
        plan = li.plan_rows([li.Named("b8:27:eb:e9:18:92", "192.168.8.103", LAN, "homeassistant")], rows, NOW)
        self.assertEqual(plan.deletes, [])
        self.assertEqual(plan.inserts, [])
        self.assertEqual(plan.updates, [])
        self.assertEqual(len(plan.skipped), 1)

    def test_departed_device_kept_for_grace_then_removed(self):
        recent = self.row(3, "192.168.8.50", LAN, "aa:aa:aa:aa:aa:01", "gone-soon", last_seen=NOW - dt.timedelta(hours=2))
        old = self.row(4, "192.168.8.51", LAN, "aa:aa:aa:aa:aa:02", "gone", last_seen=NOW - dt.timedelta(hours=30))
        unowned_old = self.row(9, "192.168.8.52", LAN, description="-- wg tunnel scan --", last_seen=NOW - dt.timedelta(days=200))
        plan = li.plan_rows([], [recent, old, unowned_old], NOW)
        self.assertEqual(plan.deletes, [4])

    def test_two_devices_swapping_addresses_keep_their_rows(self):
        rows = [
            self.row(1, "192.168.8.10", LAN, "aa:aa:aa:aa:aa:01", "one"),
            self.row(2, "192.168.8.11", LAN, "aa:aa:aa:aa:aa:02", "two"),
        ]
        seen = [
            li.Named("aa:aa:aa:aa:aa:01", "192.168.8.11", LAN, "one"),
            li.Named("aa:aa:aa:aa:aa:02", "192.168.8.10", LAN, "two"),
        ]
        plan = li.plan_rows(seen, rows, NOW)
        self.assertEqual(plan.deletes, [])
        self.assertEqual(plan.inserts, [])
        self.assertEqual(sorted(rid for rid, _ in plan.updates), [1, 2])

    def test_owned_row_of_other_device_on_same_ip_is_replaced(self):
        rows = [self.row(3, "192.168.8.50", LAN, "aa:aa:aa:aa:aa:01", "old-device", last_seen=NOW - dt.timedelta(hours=2))]
        plan = li.plan_rows([li.Named("bb:bb:bb:bb:bb:02", "192.168.8.50", LAN, "new-device")], rows, NOW)
        self.assertEqual(plan.deletes, [3])
        self.assertEqual(plan.inserts, [li.Named("bb:bb:bb:bb:bb:02", "192.168.8.50", LAN, "new-device")])


class PlanDnsTests(unittest.TestCase):
    def test_diff(self):
        desired = {"watch": "192.168.8.116", "projector-london": "192.168.8.100", "ha-london": "192.168.8.103"}
        current = {
            "watch": {"192.168.8.116"},
            "projector-london": {"192.168.9.100"},
            "mbp-london": {"192.168.8.168"},
        }
        upserts, deletes = li.plan_dns(desired, current)
        self.assertEqual(upserts, {"projector-london": "192.168.8.100", "ha-london": "192.168.8.103"})
        self.assertEqual(deletes, {"mbp-london": {"192.168.8.168"}})

    def test_no_change_means_no_writes(self):
        upserts, deletes = li.plan_dns({"watch": "192.168.8.116"}, {"watch": {"192.168.8.116"}})
        self.assertEqual((upserts, deletes), ({}, {}))

    def test_extra_ip_on_a_name_is_rewritten(self):
        upserts, deletes = li.plan_dns({"watch": "192.168.8.116"}, {"watch": {"192.168.8.116", "192.168.8.117"}})
        self.assertEqual(upserts, {"watch": "192.168.8.116"})
        self.assertEqual(deletes, {})


class InLondonTests(unittest.TestCase):
    def test_ranges(self):
        for ip, want in [
            ("192.168.8.1", True), ("192.168.9.254", True), ("192.168.10.1", False),
            ("192.168.1.8", False), ("10.0.20.1", False), ("192.168.80.1", False),
        ]:
            with self.subTest(ip=ip):
                self.assertEqual(li.in_london(ip), want)


if __name__ == "__main__":
    unittest.main()
