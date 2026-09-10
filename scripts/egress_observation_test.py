#!/usr/bin/env python3
"""Unit tests for egress-observation.py pure logic.

Run: python3 scripts/egress_observation_test.py
Prior art: scripts/drift_report_test.py.

Nothing here talks to Loki, Prometheus or the cluster. The parts that do are
covered by running the script itself against the live stack, which is how the
2026-09-04 observation snapshot was produced.
"""
import importlib.util
import json
import os
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "egress_observation", os.path.join(_HERE, "egress-observation.py")
)
eo = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(eo)


class TestDurations(unittest.TestCase):
    def test_parse_known_units(self):
        for text, seconds in [
            ("30s", 30), ("15m", 900), ("6h", 21600),
            ("7d", 604800), ("2w", 1209600),
        ]:
            self.assertEqual(eo.parse_duration(text), seconds, text)

    def test_parse_rejects_junk(self):
        for text in ("", "h", "6", "6y", "-1h", "1.5h", "6 h"):
            with self.assertRaises(ValueError, msg=text):
                eo.parse_duration(text)

    def test_format_picks_the_largest_even_unit(self):
        self.assertEqual(eo.format_duration(604800), "1w")
        self.assertEqual(eo.format_duration(86400), "1d")
        self.assertEqual(eo.format_duration(21600), "6h")
        self.assertEqual(eo.format_duration(900), "15m")
        self.assertEqual(eo.format_duration(90), "90s")

    def test_round_trip(self):
        for text in ("15m", "1h", "6h", "24h", "7d"):
            self.assertEqual(
                eo.parse_duration(eo.format_duration(eo.parse_duration(text))),
                eo.parse_duration(text),
                text,
            )

    def test_offset_clause_omits_zero(self):
        # PromQL and LogQL both reject `offset 0s`, so bucket 0 gets no clause.
        self.assertEqual(eo.offset_clause(0), "")
        self.assertEqual(eo.offset_clause(900), " offset 15m")


class TestClassify(unittest.TestCase):
    def test_cluster_ranges(self):
        self.assertEqual(eo.classify("10.10.195.217"), "pod")
        self.assertEqual(eo.classify("10.96.0.10"), "service")
        self.assertEqual(eo.classify("10.101.16.5"), "service")
        self.assertEqual(eo.classify("10.0.20.101"), "node")

    def test_lan_ranges(self):
        self.assertEqual(eo.classify("192.168.1.127"), "lan")  # NFS
        self.assertEqual(eo.classify("172.16.4.1"), "lan")
        self.assertEqual(eo.classify("169.254.1.1"), "lan")
        self.assertEqual(eo.classify("127.0.0.1"), "lan")

    def test_external(self):
        for addr in ("99.83.136.103", "151.101.64.223", "172.217.112.4", "8.8.8.8"):
            self.assertEqual(eo.classify(addr), "external", addr)

    def test_172_16_12_split(self):
        # 172.16/12 is private, the neighbours either side are not. Cloudflare
        # sits on 172.66/172.67, which must never be mistaken for RFC1918.
        self.assertEqual(eo.classify("172.15.0.1"), "external")
        self.assertEqual(eo.classify("172.31.255.254"), "lan")
        self.assertEqual(eo.classify("172.32.0.1"), "external")
        self.assertEqual(eo.classify("172.66.44.56"), "external")

    def test_unparseable_stays_visible(self):
        # Better a junk row in the report than a silently dropped destination.
        self.assertEqual(eo.classify("<over-500-destinations>"), "external")
        self.assertEqual(eo.classify(""), "external")

    def test_internal_matcher_agrees_with_classify(self):
        # The Loki-side dst filter and the Python-side classifier have to draw
        # the same line, or destinations vanish between the two.
        import re
        matcher = re.compile(f"^(?:{eo.INTERNAL_DST_RE})$")
        for addr in ("10.10.1.2", "10.96.0.10", "10.0.20.101", "192.168.1.127",
                     "172.16.0.1", "172.31.0.1", "169.254.1.1"):
            self.assertTrue(matcher.match(addr), f"{addr} should be filtered in Loki")
            self.assertNotEqual(eo.classify(addr), "external", addr)
        for addr in ("99.83.136.103", "172.66.44.56", "172.15.0.1", "8.8.8.8"):
            self.assertIsNone(matcher.match(addr), f"{addr} should survive the filter")
            self.assertEqual(eo.classify(addr), "external", addr)


class TestLineFilter(unittest.TestCase):
    def test_dots_are_escaped_and_ips_sorted(self):
        got = eo._ip_line_filter(["10.10.2.1", "10.10.1.1"])
        self.assertEqual(got, r"|~ `SRC=(?:10\.10\.1\.1|10\.10\.2\.1) `")

    def test_trailing_space_anchors_the_octet(self):
        # Without the trailing space, SRC=10.10.1.1 also matches 10.10.1.10.
        self.assertTrue(eo._ip_line_filter(["10.10.1.1"]).endswith(") `"))


class _FakeLoki:
    """Stands in for Loki: any IP in `hot` overflows the series cap."""

    def __init__(self, hot):
        self.hot = set(hot)
        self.calls = []

    def __call__(self, expr, timeout=600):
        ips = eo.re.findall(r"(\d+\\\.\d+\\\.\d+\\\.\d+)", expr)
        ips = [ip.replace("\\", "") for ip in ips]
        self.calls.append(ips)
        if self.hot & set(ips):
            raise eo.SeriesCapError("maximum number of series (500) reached")
        return [
            {"labels": {"src": ip, "dst": "8.8.8.8", "proto": "UDP", "dpt": "53"},
             "value": 1.0}
            for ip in ips
        ]


class TestBisect(unittest.TestCase):
    def setUp(self):
        self._real = eo.logql

    def tearDown(self):
        eo.logql = self._real

    def test_no_cap_means_one_query(self):
        eo.logql = _FakeLoki(hot=[])
        stats = {}
        rows = eo.flows_for_ips(["10.10.0.1", "10.10.0.2"], 900, 0, True, stats)
        self.assertEqual(len(rows), 2)
        self.assertEqual(stats["queries"], 1)
        self.assertNotIn("bisects", stats)

    def test_one_hot_pod_does_not_lose_its_neighbours(self):
        # The failure this guards: an over-500 pod used to fail the whole batch,
        # taking every quiet namespace in it down with it.
        eo.logql = _FakeLoki(hot=["10.10.0.3"])
        stats = {}
        ips = [f"10.10.0.{i}" for i in range(1, 9)]
        rows = eo.flows_for_ips(ips, 900, 0, True, stats)
        by_src = {r["src"]: r for r in rows}
        self.assertEqual(len(by_src), 8)
        for ip in ips:
            if ip == "10.10.0.3":
                self.assertTrue(by_src[ip]["truncated"])
                self.assertEqual(by_src[ip]["dst"], "<over-500-destinations>")
            else:
                self.assertFalse(by_src[ip]["truncated"])
                self.assertEqual(by_src[ip]["dst"], "8.8.8.8")
        self.assertEqual(stats["truncated_pods"], 1)
        self.assertGreater(stats["bisects"], 0)

    def test_empty_batch_makes_no_query(self):
        eo.logql = _FakeLoki(hot=[])
        stats = {}
        self.assertEqual(eo.flows_for_ips([], 900, 0, True, stats), [])
        self.assertEqual(stats, {})


class TestReadiness(unittest.TestCase):
    def test_three_bands_split_by_how_often_a_destination_appears(self):
        rows = [
            {"dst": "99.83.136.103", "buckets_seen": 10},  # every bucket
            {"dst": "1.1.1.1", "buckets_seen": 5},         # exactly half
            {"dst": "2.2.2.2", "buckets_seen": 4},         # periodic
            {"dst": "3.3.3.3", "buckets_seen": 1},         # one-off
        ]
        stable, recurring, one_off = eo.readiness(rows, buckets_with_pods=10)
        self.assertEqual(stable, ["1.1.1.1", "99.83.136.103"])
        self.assertEqual(recurring, 1)
        self.assertEqual(one_off, 1)

    def test_bands_are_disjoint_and_total_the_destinations(self):
        rows = [{"dst": f"1.1.1.{i}", "buckets_seen": i} for i in range(1, 11)]
        stable, recurring, one_off = eo.readiness(rows, buckets_with_pods=10)
        self.assertEqual(len(stable) + recurring + one_off, 10)

    def test_odd_bucket_count_uses_integer_math(self):
        # 2 of 3 is stable, 1 of 3 is not; no float rounding surprises.
        rows = [{"dst": "a", "buckets_seen": 2}, {"dst": "b", "buckets_seen": 1}]
        self.assertEqual(eo.readiness(rows, 3), (["a"], 0, 1))

    def test_two_ports_on_one_address_count_once(self):
        # A namespace reaching one host on :80 and :443 has one destination,
        # and the band comes from the widest evidence, not the sum.
        rows = [{"dst": "1.1.1.1", "buckets_seen": 8},
                {"dst": "1.1.1.1", "buckets_seen": 2}]
        self.assertEqual(eo.readiness(rows, 8), (["1.1.1.1"], 0, 0))

    def test_namespace_that_never_ran_has_nothing_stable(self):
        self.assertEqual(eo.readiness([], 0), ([], 0, 0))

    def test_a_dead_namespace_does_not_promote_destinations_to_stable(self):
        # buckets_with_pods == 0 with rows present should not divide by zero
        # nor call anything stable.
        rows = [{"dst": "1.1.1.1", "buckets_seen": 3}]
        stable, recurring, one_off = eo.readiness(rows, 0)
        self.assertEqual(stable, [])
        self.assertEqual((recurring, one_off), (1, 0))


class TestNamespaceRecord(unittest.TestCase):
    """The record shape is what render_markdown and the JSON artifact both read.
    A 7-day pass costs ~35 minutes before this code runs, so a mismatch here is
    expensive to find any other way -- which is exactly how it was found."""

    def _rows(self):
        return [
            {"dst": "99.83.136.103", "proto": "TCP", "port": "443",
             "packets": 40, "buckets_seen": 8, "truncated": False},
            {"dst": "1.2.3.4", "proto": "TCP", "port": "443",
             "packets": 1, "buckets_seen": 1, "truncated": False},
        ]

    def test_counts_are_ints_not_collections(self):
        rec = eo.namespace_record(
            tier="4-aux", rows=self._rows(), pods={"10.10.0.1"},
            buckets_with_pods=8, unattributed=set(), internal_packets=12,
        )
        self.assertIsInstance(rec["one_off_destinations"], int)
        self.assertIsInstance(rec["recurring_destinations"], int)
        self.assertEqual(rec["one_off_destinations"], 1)
        self.assertEqual(rec["stable_destinations"], ["99.83.136.103"])
        self.assertEqual(rec["external_destinations"], 2)
        self.assertEqual(rec["pods_observed"], 1)
        self.assertTrue(rec["had_traffic"])

    def test_record_survives_json_round_trip(self):
        rec = eo.namespace_record(
            tier="3-edge", rows=self._rows(), pods={"10.10.0.1", "10.10.0.2"},
            buckets_with_pods=8, unattributed={"10.10.0.9"}, internal_packets=0,
        )
        self.assertEqual(json.loads(json.dumps(rec)), rec)
        self.assertEqual(rec["pods_unattributed"], ["10.10.0.9"])

    def test_render_accepts_what_record_produces(self):
        # Locks the two halves together: the renderer only ever sees these keys.
        rec = eo.namespace_record(
            tier="4-aux", rows=self._rows(), pods={"10.10.0.1"},
            buckets_with_pods=8, unattributed=set(), internal_packets=0,
        )
        md = eo.render_markdown({
            "generated_at": "2026-09-04T00:00:00Z", "window": "7d", "bucket": "15m",
            "buckets": 8, "tiers": ["4-aux"], "namespaces_in_scope": 1,
            "elapsed_seconds": 1.0, "loki_queries": 1, "bisects": 0,
            "truncated_pods": 0, "pod_ip_collisions": {}, "namespaces": {"n": rec},
        })
        self.assertIn("99.83.136.103", md)
        self.assertIn("Enforcement readiness", md)

    def test_silent_namespace_is_not_marked_as_having_traffic(self):
        rec = eo.namespace_record(
            tier="4-aux", rows=[], pods=set(), buckets_with_pods=0,
            unattributed=set(), internal_packets=0,
        )
        self.assertFalse(rec["had_traffic"])
        self.assertEqual(rec["stable_destinations"], [])


class TestRenderMarkdown(unittest.TestCase):
    def _result(self, **over):
        base = {
            "generated_at": "2026-09-04T00:00:00Z", "window": "7d", "bucket": "15m",
            "buckets": 672, "tiers": ["3-edge", "4-aux"], "namespaces_in_scope": 2,
            "elapsed_seconds": 1.0, "loki_queries": 3, "bisects": 0,
            "truncated_pods": 0, "pod_ip_collisions": {}, "namespaces": {},
        }
        base.update(over)
        return base

    def test_idle_namespace_is_called_out(self):
        md = eo.render_markdown(self._result(namespaces={
            "recruiter-responder": {
                "tier": "4-aux", "pods_observed": 0, "buckets_with_pods": 0,
                "pods_unattributed": [], "external_destinations": 0,
                "stable_destinations": [], "one_off_destinations": 0,
                "external_flows": [], "internal_packets": 0, "had_traffic": False,
            }
        }))
        self.assertIn("no pods in the window", md)
        self.assertIn("`recruiter-responder`", md)

    def test_collisions_are_reported_not_hidden(self):
        md = eo.render_markdown(self._result(
            pod_ip_collisions={"10.10.122.129": ["claude-agent", "monitoring"]}))
        self.assertIn("Pod IP reuse", md)
        self.assertIn("10.10.122.129", md)
        self.assertIn("claude-agent, monitoring", md)


if __name__ == "__main__":
    unittest.main(verbosity=2)
