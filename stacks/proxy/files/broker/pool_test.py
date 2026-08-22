#!/usr/bin/env python3
"""Unit tests for pool.py — the proxy shared-gateway decision logic.

Pure, no cluster needed:  python3 -m unittest pool_test -v
Tests external behaviour only (the decisions), never internal helpers' shape.

Gateway index `pool.PERMANENT_IDX` belongs to the always-on cluster VPN egress
gateway declared in Terraform (`pool.PERMANENT_COUNTRY`). Three rules follow
from that, and each has its own tests below: the allocator never leases that
index, `plan_gateway` always reuses it for its country, and `plan_reaping`
never reaps it. Fixtures that used to sit on index 1 were moved to index 2+ so
they keep exercising the ORDINARY path they were written for.
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
    def test_first_index_skips_the_permanent_gateway(self):
        # Was "first index is 1"; index 1 is now the permanent gateway's, so the
        # lowest index the broker may hand an on-demand gateway is 2.
        idx = pool.alloc_subnet_idx([])
        self.assertNotEqual(idx, pool.PERMANENT_IDX)
        self.assertEqual(idx, 2)

    def test_permanent_index_skipped_even_when_absent_from_used(self):
        # The case that would collide silently. The permanent gateway is a
        # Deployment, so during a rollout (or any window where its pod carries a
        # deletionTimestamp) it is absent from list_gateways() and its index never
        # reaches `used_idxs`. Allocating it anyway would hand an on-demand
        # gateway the Terraform-owned proxy-gw-1 Service/Secret/ConfigMap names.
        self.assertNotEqual(pool.alloc_subnet_idx([2, 3, 4]), pool.PERMANENT_IDX)

    def test_permanent_index_is_not_a_last_resort(self):
        # Everything but the reserved index taken -> raise, never lease it.
        with self.assertRaises(RuntimeError):
            pool.alloc_subnet_idx(range(2, 255))

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
        gws = [{"country": "Japan", "idx": 3}]
        action, payload = pool.plan_gateway("Japan", gws)
        self.assertEqual(action, "reuse")
        self.assertEqual(payload["idx"], 3)

    def test_create_when_country_absent(self):
        # idx 1 is the permanent gateway's and idx 2 is taken, so the new
        # country lands on 3 — the allocator never falls back onto 1.
        gws = [{"country": "Japan", "idx": 2}]
        action, payload = pool.plan_gateway("Netherlands", gws)
        self.assertEqual(action, "create")
        self.assertEqual(payload["idx"], 3)
        self.assertEqual(payload["subnet"], "10.13.3.0/24")

    def test_one_gateway_per_country_reuse_beats_cap(self):
        # Even AT the cap, an existing-country request reuses, never rejects.
        gws = [{"country": "C%d" % i, "idx": i} for i in range(2, 8)]  # 6 = budget
        action, _ = pool.plan_gateway("C3", gws, max_countries=8, reserved=2)
        self.assertEqual(action, "reuse")

    def test_reject_at_capacity_for_new_country(self):
        gws = [{"country": "C%d" % i, "idx": i} for i in range(2, 8)]  # 6 gws
        action, payload = pool.plan_gateway("New", gws, max_countries=8, reserved=2)
        self.assertEqual(action, "reject")
        self.assertIn("capacity", payload["reason"])

    def test_reject_at_capacity_still_applies_alongside_the_permanent_gateway(self):
        # Unchanged behaviour, guarded: the permanent short-circuit must not turn
        # into a blanket bypass of the tunnel budget for every other country.
        gws = [{"country": pool.PERMANENT_COUNTRY, "idx": pool.PERMANENT_IDX}]
        gws += [{"country": "C%d" % i, "idx": i} for i in range(2, 7)]  # 6 total
        action, payload = pool.plan_gateway("New", gws, max_countries=8, reserved=2)
        self.assertEqual(action, "reject")
        self.assertIn("capacity", payload["reason"])

    def test_reserved_slots_are_subtracted(self):
        # max=8 reserved=3 => budget 5; 5 live => the 6th new country is rejected.
        gws = [{"country": "C%d" % i, "idx": i} for i in range(2, 7)]  # 5 gws
        action, _ = pool.plan_gateway("New", gws, max_countries=8, reserved=3)
        self.assertEqual(action, "reject")
        action2, _ = pool.plan_gateway("New", gws[:4], max_countries=8, reserved=3)
        self.assertEqual(action2, "create")

    def test_create_reuses_freed_subnet_index(self):
        # gateway at idx 2 was reaped; a new country takes the lowest free
        # ORDINARY index (2) — the still-free permanent index 1 stays untouched.
        gws = [{"country": "Japan", "idx": 3}]
        _, payload = pool.plan_gateway("Spain", gws)
        self.assertEqual(payload["idx"], 2)


class PlanGatewayPermanent(unittest.TestCase):
    def test_permanent_country_reuses_when_the_pod_is_not_listed(self):
        # The permanent gateway's identity comes from Terraform, not from a
        # listed pod. Deriving reuse from `gateways` alone would fall through to
        # "create" during a rollout and start a SECOND UK tunnel on the
        # account-wide NordLynx key — the invariant plan_gateway exists to hold.
        action, payload = pool.plan_gateway(pool.PERMANENT_COUNTRY, [])
        self.assertEqual(action, "reuse")
        self.assertEqual(payload["idx"], pool.PERMANENT_IDX)

    def test_permanent_country_reuses_at_capacity(self):
        # A permanent gateway is never rejected: its tunnel is already running,
        # so serving a browser from it costs no additional NordVPN slot. This
        # fails if the permanent short-circuit sits after the capacity check.
        gws = [{"country": "C%d" % i, "idx": i} for i in range(2, 8)]  # 6 = budget
        action, payload = pool.plan_gateway(
            pool.PERMANENT_COUNTRY, gws, max_countries=8, reserved=2)
        self.assertEqual(action, "reuse")
        self.assertEqual(payload["idx"], pool.PERMANENT_IDX)

    def test_permanent_country_reuses_when_the_pod_is_listed(self):
        gws = [{"country": pool.PERMANENT_COUNTRY, "idx": pool.PERMANENT_IDX}]
        action, payload = pool.plan_gateway(pool.PERMANENT_COUNTRY, gws)
        self.assertEqual(action, "reuse")
        self.assertEqual(payload["idx"], pool.PERMANENT_IDX)

    def test_permanent_country_never_creates_even_with_room(self):
        gws = [{"country": "Japan", "idx": 2}]
        action, payload = pool.plan_gateway(pool.PERMANENT_COUNTRY, gws)
        self.assertEqual(action, "reuse")
        self.assertEqual(payload["idx"], pool.PERMANENT_IDX)


class PlanReaping(unittest.TestCase):
    def test_idle_gateway_with_no_browsers_is_reaped(self):
        gws = [{"idx": 2, "last_used": 0}]
        dead_gws, _ = pool.plan_reaping(gws, [], now=1000, gw_idle_seconds=300)
        self.assertEqual(dead_gws, [2])

    def test_gateway_with_live_browser_is_kept(self):
        gws = [{"idx": 2, "last_used": 0}]
        browsers = [{"id": "b1", "gateway_idx": 2, "dead": False}]
        dead_gws, _ = pool.plan_reaping(gws, browsers, now=99999, gw_idle_seconds=300)
        self.assertEqual(dead_gws, [])

    def test_recently_used_empty_gateway_is_kept(self):
        gws = [{"idx": 2, "last_used": 900}]
        dead_gws, _ = pool.plan_reaping(gws, [], now=1000, gw_idle_seconds=300)
        self.assertEqual(dead_gws, [])  # idle only 100s < 300s

    def test_dead_browsers_are_collected(self):
        browsers = [
            {"id": "b1", "gateway_idx": 2, "dead": True},
            {"id": "b2", "gateway_idx": 2, "dead": False},
        ]
        gws = [{"idx": 2, "last_used": 0}]
        dead_gws, dead_browsers = pool.plan_reaping(gws, browsers, now=99999, gw_idle_seconds=300)
        self.assertEqual(dead_browsers, ["b1"])
        self.assertEqual(dead_gws, [])  # b2 still live keeps the gateway

    def test_gateway_reaped_only_after_last_browser_dies(self):
        # all browsers dead -> gateway has no live browsers -> reaped if idle
        browsers = [{"id": "b1", "gateway_idx": 2, "dead": True}]
        gws = [{"idx": 2, "last_used": 0}]
        dead_gws, dead_browsers = pool.plan_reaping(gws, browsers, now=1000, gw_idle_seconds=300)
        self.assertEqual(dead_gws, [2])
        self.assertEqual(dead_browsers, ["b1"])


class PlanReapingPermanent(unittest.TestCase):
    def test_permanent_gateway_is_never_reaped(self):
        # Its `proxy/last-used` annotation is never touched (the broker patches a
        # pod by name and a Deployment's pods carry generated suffixes), so
        # list_gateways reads last_used=0 and the idle test is satisfied on the
        # very FIRST reaper tick — this is not a defensive edge case.
        gws = [{"idx": pool.PERMANENT_IDX, "last_used": 0}]
        dead_gws, _ = pool.plan_reaping(gws, [], now=1000, gw_idle_seconds=300)
        self.assertEqual(dead_gws, [])

    def test_permanent_gateway_kept_after_carrying_no_browsers_for_days(self):
        gws = [{"idx": pool.PERMANENT_IDX, "last_used": 0}]
        dead_gws, _ = pool.plan_reaping(gws, [], now=10 ** 9, gw_idle_seconds=600)
        self.assertEqual(dead_gws, [])

    def test_permanent_gateway_kept_after_its_last_browser_dies(self):
        browsers = [{"id": "b1", "gateway_idx": pool.PERMANENT_IDX, "dead": True}]
        gws = [{"idx": pool.PERMANENT_IDX, "last_used": 0}]
        dead_gws, dead_browsers = pool.plan_reaping(
            gws, browsers, now=1000, gw_idle_seconds=300)
        self.assertEqual(dead_gws, [])
        self.assertEqual(dead_browsers, ["b1"])

    def test_ordinary_gateways_still_reaped_alongside_the_permanent_one(self):
        gws = [
            {"idx": pool.PERMANENT_IDX, "last_used": 0},
            {"idx": 2, "last_used": 0},
            {"idx": 3, "last_used": 900},
        ]
        dead_gws, _ = pool.plan_reaping(gws, [], now=1000, gw_idle_seconds=300)
        self.assertEqual(dead_gws, [2])  # 1 reserved, 3 idle only 100s


if __name__ == "__main__":
    unittest.main()
