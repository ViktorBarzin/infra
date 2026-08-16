#!/usr/bin/env python3
"""Unit tests for image_flipflop_detect.find_flipflops.

Run: python3 image_flipflop_detect_test.py

The detector's whole job is telling a two-owner fight apart from ordinary
deploy churn, so most of these cases are the near-misses that a naive
"lots of ReplicaSets" or "an image repeats" check gets wrong. A false
positive here means a Slack alert on every normal rollback, which would
get the alert muted and defeat the point.
"""

import unittest

from image_flipflop_detect import find_flipflops

NOW = "2026-08-16T18:00:00Z"


def rs(ns, owner, ts, *images):
    return {
        "namespace": ns,
        "owner": owner,
        "creationTimestamp": ts,
        "images": list(images),
    }


class FindFlipflops(unittest.TestCase):
    def test_alternating_two_images_is_a_flipflop(self):
        items = [
            rs("monitoring", "prometheus-server", "2026-08-16T10:00:00Z", "alpine:3.21"),
            rs("monitoring", "prometheus-server", "2026-08-16T11:00:00Z", "alpine:3.21.7"),
            rs("monitoring", "prometheus-server", "2026-08-16T12:00:00Z", "alpine:3.21"),
            rs("monitoring", "prometheus-server", "2026-08-16T13:00:00Z", "alpine:3.21.7"),
        ]
        found = find_flipflops(items, now=NOW)
        self.assertEqual([(f["namespace"], f["deployment"]) for f in found],
                         [("monitoring", "prometheus-server")])
        self.assertEqual(found[0]["replicaset_count"], 4)

    def test_monotonic_upgrade_sequence_is_not_a_flipflop(self):
        # v1 -> v2 -> v3 -> v4 is a normal upgrade history. The first
        # detector written for this flagged it, because an old image
        # reappeared much earlier in a long RS list.
        items = [
            rs("kyverno", "kyverno-admission-controller", "2026-08-16T09:00:00Z", "kyverno:v1.16.4"),
            rs("kyverno", "kyverno-admission-controller", "2026-08-16T10:00:00Z", "kyverno:v1.17.2"),
            rs("kyverno", "kyverno-admission-controller", "2026-08-16T11:00:00Z", "kyverno:v1.18.1"),
            rs("kyverno", "kyverno-admission-controller", "2026-08-16T12:00:00Z", "kyverno:v1.18.2"),
        ]
        self.assertEqual(find_flipflops(items, now=NOW), [])

    def test_identical_images_repeated_is_not_a_flipflop(self):
        # Scale events / restarts produce several ReplicaSets carrying the
        # SAME image. Nothing is fighting.
        items = [
            rs("traefik", "auth-proxy", "2026-08-16T09:00:00Z", "nginx:1-alpine"),
            rs("traefik", "auth-proxy", "2026-08-16T10:00:00Z", "nginx:1-alpine"),
            rs("traefik", "auth-proxy", "2026-08-16T11:00:00Z", "nginx:1-alpine"),
            rs("traefik", "auth-proxy", "2026-08-16T12:00:00Z", "nginx:1-alpine"),
        ]
        self.assertEqual(find_flipflops(items, now=NOW), [])

    def test_consecutive_duplicates_collapse_before_the_repeat_test(self):
        # A -> A -> B -> A still alternates once the consecutive pair is
        # collapsed; the repeat of A after B is the signal.
        items = [
            rs("ebooks", "book-search", "2026-08-16T09:00:00Z", "img:a"),
            rs("ebooks", "book-search", "2026-08-16T10:00:00Z", "img:a"),
            rs("ebooks", "book-search", "2026-08-16T11:00:00Z", "img:b"),
            rs("ebooks", "book-search", "2026-08-16T12:00:00Z", "img:a"),
        ]
        found = find_flipflops(items, now=NOW)
        self.assertEqual(len(found), 1)

    def test_single_rollback_is_not_flagged(self):
        # A -> B -> A needs THREE distinct entries to alternate, but a
        # deploy-then-rollback (A -> B) is only two and must stay quiet.
        items = [
            rs("app", "thing", "2026-08-16T10:00:00Z", "img:v1"),
            rs("app", "thing", "2026-08-16T11:00:00Z", "img:v2"),
        ]
        self.assertEqual(find_flipflops(items, now=NOW), [])

    def test_replicasets_outside_the_window_are_ignored(self):
        # The same alternation, but spread over weeks, is history — not a
        # fight happening now.
        items = [
            rs("app", "thing", "2026-07-01T10:00:00Z", "img:a"),
            rs("app", "thing", "2026-07-08T10:00:00Z", "img:b"),
            rs("app", "thing", "2026-07-15T10:00:00Z", "img:a"),
            rs("app", "thing", "2026-07-22T10:00:00Z", "img:b"),
        ]
        self.assertEqual(find_flipflops(items, now=NOW), [])

    def test_multi_container_pods_compare_the_whole_image_set(self):
        # claude-agent-service flipped only its `curl` sidecar; the app
        # image never moved. Comparing just containers[0] would miss it.
        items = [
            rs("claude-agent", "claude-agent-service", "2026-08-16T09:00:00Z", "svc:latest", "curl:8.11.0"),
            rs("claude-agent", "claude-agent-service", "2026-08-16T10:00:00Z", "svc:latest", "curl:8.11.1"),
            rs("claude-agent", "claude-agent-service", "2026-08-16T11:00:00Z", "svc:latest", "curl:8.11.0"),
        ]
        found = find_flipflops(items, now=NOW)
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0]["deployment"], "claude-agent-service")

    def test_container_order_does_not_create_a_false_positive(self):
        # The live container order can differ from the declared order
        # (stacks/proxy hit exactly this). Same set, different order, is
        # the same image set.
        items = [
            rs("proxy", "proxy-gw-1", "2026-08-16T09:00:00Z", "gluetun:x", "wireguard:y"),
            rs("proxy", "proxy-gw-1", "2026-08-16T10:00:00Z", "wireguard:y", "gluetun:x"),
            rs("proxy", "proxy-gw-1", "2026-08-16T11:00:00Z", "gluetun:x", "wireguard:y"),
        ]
        self.assertEqual(find_flipflops(items, now=NOW), [])

    def test_deployments_are_kept_separate(self):
        # Two deployments each seeing normal churn must not combine into
        # one phantom alternation.
        items = [
            rs("ns", "a", "2026-08-16T09:00:00Z", "img:1"),
            rs("ns", "b", "2026-08-16T09:30:00Z", "img:2"),
            rs("ns", "a", "2026-08-16T10:00:00Z", "img:3"),
            rs("ns", "b", "2026-08-16T10:30:00Z", "img:4"),
            rs("ns", "a", "2026-08-16T11:00:00Z", "img:5"),
        ]
        self.assertEqual(find_flipflops(items, now=NOW), [])

    def test_orphan_replicasets_without_an_owner_are_skipped(self):
        items = [
            {"namespace": "ns", "owner": None,
             "creationTimestamp": "2026-08-16T10:00:00Z", "images": ["img:a"]},
            {"namespace": "ns", "owner": None,
             "creationTimestamp": "2026-08-16T11:00:00Z", "images": ["img:b"]},
            {"namespace": "ns", "owner": None,
             "creationTimestamp": "2026-08-16T12:00:00Z", "images": ["img:a"]},
        ]
        self.assertEqual(find_flipflops(items, now=NOW), [])

    def test_result_reports_the_two_images_being_fought_over(self):
        items = [
            rs("monitoring", "prometheus-server", "2026-08-16T10:00:00Z", "alpine:3.21"),
            rs("monitoring", "prometheus-server", "2026-08-16T11:00:00Z", "alpine:3.21.7"),
            rs("monitoring", "prometheus-server", "2026-08-16T12:00:00Z", "alpine:3.21"),
        ]
        found = find_flipflops(items, now=NOW)
        self.assertCountEqual(found[0]["images"], ["alpine:3.21", "alpine:3.21.7"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
