#!/usr/bin/env python3
"""Unit tests for pool.py — the proxy shared-gateway decision logic.

Pure, no cluster needed:  python3 -m unittest pool_test -v
Tests external behaviour only (the decisions), never internal helpers' shape.
"""
import unittest

import pool


class NormalizeCountry(unittest.TestCase):
    ALLOWED = ["United States", "Netherlands", "Japan"]

    def test_exact(self):
        self.assertEqual(pool.normalize_country("Netherlands", self.ALLOWED), "Netherlands")

    def test_case_and_space_insensitive(self):
        self.assertEqual(pool.normalize_country("  netherlands ", self.ALLOWED), "Netherlands")

    def test_unknown_is_none(self):
        self.assertIsNone(pool.normalize_country("Atlantis", self.ALLOWED))

    def test_empty_is_none(self):
        self.assertIsNone(pool.normalize_country("", self.ALLOWED))
        self.assertIsNone(pool.normalize_country(None, self.ALLOWED))


class SubnetAllocation(unittest.TestCase):
    def test_first_index_is_one(self):
        self.assertEqual(pool.alloc_subnet_idx([]), 1)

    def test_lowest_free_index(self):
        self.assertEqual(pool.alloc_subnet_idx([1, 2, 4]), 3)

    def test_subnet_and_gateway_ip_shapes(self):
        self.assertEqual(pool.gateway_subnet(5), "10.13.5.0/24")
        self.assertEqual(pool.gateway_ip(5), "10.13.5.1")

    def test_exhaustion_raises(self):
        with self.assertRaises(RuntimeError):
            pool.alloc_subnet_idx(range(1, 255))


class ClientIpAllocation(unittest.TestCase):
    def test_first_client_is_dot_two(self):
        self.assertEqual(pool.alloc_client_ip(7, []), "10.13.7.2")

    def test_skips_used(self):
        self.assertEqual(
            pool.alloc_client_ip(7, ["10.13.7.2", "10.13.7.3"]), "10.13.7.4")

    def test_exhaustion_raises(self):
        used = ["10.13.7.%d" % h for h in range(2, 255)]
        with self.assertRaises(RuntimeError):
            pool.alloc_client_ip(7, used)


class PlanGateway(unittest.TestCase):
    def test_reuse_existing_country(self):
        gws = [{"country": "Japan", "idx": 1}]
        action, payload = pool.plan_gateway("Japan", gws)
        self.assertEqual(action, "reuse")
        self.assertEqual(payload["idx"], 1)

    def test_create_when_country_absent(self):
        gws = [{"country": "Japan", "idx": 1}]
        action, payload = pool.plan_gateway("Netherlands", gws)
        self.assertEqual(action, "create")
        self.assertEqual(payload["idx"], 2)
        self.assertEqual(payload["subnet"], "10.13.2.0/24")

    def test_one_gateway_per_country_reuse_beats_cap(self):
        # Even AT the cap, an existing-country request reuses, never rejects.
        gws = [{"country": "C%d" % i, "idx": i} for i in range(1, 7)]  # 6 = budget
        action, _ = pool.plan_gateway("C3", gws, max_countries=8, reserved=2)
        self.assertEqual(action, "reuse")

    def test_reject_at_capacity_for_new_country(self):
        gws = [{"country": "C%d" % i, "idx": i} for i in range(1, 7)]  # 6 gws
        action, payload = pool.plan_gateway("New", gws, max_countries=8, reserved=2)
        self.assertEqual(action, "reject")
        self.assertIn("capacity", payload["reason"])

    def test_reserved_slots_are_subtracted(self):
        # max=8 reserved=3 => budget 5; 5 live => the 6th new country is rejected.
        gws = [{"country": "C%d" % i, "idx": i} for i in range(1, 6)]  # 5 gws
        action, _ = pool.plan_gateway("New", gws, max_countries=8, reserved=3)
        self.assertEqual(action, "reject")
        action2, _ = pool.plan_gateway("New", gws[:4], max_countries=8, reserved=3)
        self.assertEqual(action2, "create")

    def test_create_reuses_freed_subnet_index(self):
        # gateway at idx 1 was reaped; a new country takes the lowest free (1).
        gws = [{"country": "Japan", "idx": 2}]
        _, payload = pool.plan_gateway("Spain", gws)
        self.assertEqual(payload["idx"], 1)


class PlanReaping(unittest.TestCase):
    def test_idle_gateway_with_no_browsers_is_reaped(self):
        gws = [{"idx": 1, "last_used": 0}]
        dead_gws, _ = pool.plan_reaping(gws, [], now=1000, gw_idle_seconds=300)
        self.assertEqual(dead_gws, [1])

    def test_gateway_with_live_browser_is_kept(self):
        gws = [{"idx": 1, "last_used": 0}]
        browsers = [{"id": "b1", "gateway_idx": 1, "dead": False}]
        dead_gws, _ = pool.plan_reaping(gws, browsers, now=99999, gw_idle_seconds=300)
        self.assertEqual(dead_gws, [])

    def test_recently_used_empty_gateway_is_kept(self):
        gws = [{"idx": 1, "last_used": 900}]
        dead_gws, _ = pool.plan_reaping(gws, [], now=1000, gw_idle_seconds=300)
        self.assertEqual(dead_gws, [])  # idle only 100s < 300s

    def test_dead_browsers_are_collected(self):
        browsers = [
            {"id": "b1", "gateway_idx": 1, "dead": True},
            {"id": "b2", "gateway_idx": 1, "dead": False},
        ]
        gws = [{"idx": 1, "last_used": 0}]
        dead_gws, dead_browsers = pool.plan_reaping(gws, browsers, now=99999, gw_idle_seconds=300)
        self.assertEqual(dead_browsers, ["b1"])
        self.assertEqual(dead_gws, [])  # b2 still live keeps the gateway

    def test_gateway_reaped_only_after_last_browser_dies(self):
        # all browsers dead -> gateway has no live browsers -> reaped if idle
        browsers = [{"id": "b1", "gateway_idx": 1, "dead": True}]
        gws = [{"idx": 1, "last_used": 0}]
        dead_gws, dead_browsers = pool.plan_reaping(gws, browsers, now=1000, gw_idle_seconds=300)
        self.assertEqual(dead_gws, [1])
        self.assertEqual(dead_browsers, ["b1"])


if __name__ == "__main__":
    unittest.main()
