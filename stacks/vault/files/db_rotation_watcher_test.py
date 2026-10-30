#!/usr/bin/env python3
"""Unit tests for db_rotation_watcher.py (the pure functions).

Run: cd stacks/vault/files && python3 -I -m unittest discover -s . -p db_rotation_watcher_test.py
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import db_rotation_watcher as w


def es(name, ns="app", keys=(), extract=(), annotations=None, refresh=None, ready="True"):
    status = {}
    if refresh is not None:
        status["refreshTime"] = refresh
    if ready is not None:
        status["conditions"] = [{"type": "Ready", "status": ready}]
    return {
        "metadata": {"name": name, "namespace": ns, "annotations": annotations or {}},
        "spec": {
            "data": [{"secretKey": f"k{i}", "remoteRef": {"key": k}} for i, k in enumerate(keys)],
            "dataFrom": [{"extract": {"key": k}} for k in extract],
        },
        "status": status,
    }


class RoleFromKeyTest(unittest.TestCase):
    def test_plain_static_creds_key(self):
        self.assertEqual(w.role_from_key("static-creds/pg-linkwarden"), "pg-linkwarden")

    def test_database_prefixed_key(self):
        self.assertEqual(w.role_from_key("database/static-creds/pg-goodreads-sync"), "pg-goodreads-sync")

    def test_leading_slash_and_whitespace(self):
        self.assertEqual(w.role_from_key(" /database/static-creds/mysql-grafana "), "mysql-grafana")

    def test_non_database_keys_are_ignored(self):
        for key in ["secret/data/linkwarden", "linkwarden", "static-creds/", "creds/pg-x",
                    "database/creds/pg-x", "other/static-creds/pg-x", "", None]:
            with self.subTest(key=key):
                self.assertIsNone(w.role_from_key(key))


class EsRolesTest(unittest.TestCase):
    def test_collects_data_and_datafrom_keys(self):
        e = es("verify-db-creds", keys=["static-creds/mysql-verify-probe", "static-creds/pg-verify-probe",
                                         "secret/data/verify"],
               extract=["database/static-creds/pg-x"])
        self.assertEqual(w.es_roles(e), {"mysql-verify-probe", "pg-verify-probe", "pg-x"})

    def test_missing_spec_sections(self):
        self.assertEqual(w.es_roles({"metadata": {"name": "a", "namespace": "b"}, "spec": {}}), set())
        self.assertEqual(w.es_roles({"metadata": {}, "spec": {"data": None, "dataFrom": None}}), set())

    def test_targets_for_role(self):
        items = [
            es("grafana-wealth-pg-creds", ns="monitoring", keys=["static-creds/pg-wealthfolio-sync"]),
            es("wealthfolio-sync-db-creds", ns="fire-planner", keys=["static-creds/pg-wealthfolio-sync"]),
            es("linkwarden-db-creds", ns="linkwarden", keys=["static-creds/pg-linkwarden"]),
        ]
        got = w.targets_for_role(items, "pg-wealthfolio-sync")
        self.assertEqual([(t["metadata"]["namespace"], t["metadata"]["name"]) for t in got],
                         [("fire-planner", "wealthfolio-sync-db-creds"), ("monitoring", "grafana-wealth-pg-creds")])
        self.assertEqual(w.targets_for_role(items, "pg-nothing"), [])


class ParseTimeTest(unittest.TestCase):
    def test_nanoseconds_from_vault(self):
        self.assertAlmostEqual(w.parse_time("2026-10-30T14:31:48.836424434Z"), 1793370708.836424, places=5)

    def test_whole_seconds_from_eso(self):
        self.assertEqual(w.parse_time("2026-10-30T14:46:23Z"), 1793371583.0)

    def test_offset(self):
        self.assertEqual(w.parse_time("2026-10-30T15:46:23+01:00"), 1793371583.0)

    def test_short_fraction(self):
        self.assertAlmostEqual(w.parse_time("2026-10-30T14:46:23.5Z"), 1793371583.5)

    def test_empty_and_garbage(self):
        self.assertIsNone(w.parse_time(""))
        self.assertIsNone(w.parse_time(None))
        self.assertIsNone(w.parse_time("yesterday"))
        # Vault's zero value for a role that has never rotated.
        self.assertIsNone(w.parse_time("0001-01-01T00:00:00Z"))


class DetectRotationsTest(unittest.TestCase):
    def test_changed_roles_only(self):
        prev = {"pg-a": "2026-10-27T10:00:01Z", "pg-b": "2026-10-27T10:02:01Z"}
        cur = {"pg-a": "2026-11-03T10:00:02Z", "pg-b": "2026-10-27T10:02:01Z"}
        self.assertEqual(w.detect_rotations(prev, cur), ["pg-a"])

    def test_first_sight_is_a_baseline_not_a_rotation(self):
        self.assertEqual(w.detect_rotations({}, {"pg-a": "2026-11-03T10:00:02Z"}), [])
        self.assertEqual(w.detect_rotations({"pg-a": "x"}, {"pg-a": "x", "pg-new": "y"}), [])

    def test_role_missing_this_tick_is_not_a_rotation(self):
        # A failed read drops the role from cur; it must not count as changed.
        self.assertEqual(w.detect_rotations({"pg-a": "x", "pg-b": "y"}, {"pg-a": "x"}), [])

    def test_sorted_output(self):
        prev = {"pg-b": "1", "pg-a": "1", "mysql-c": "1"}
        cur = {"pg-b": "2", "pg-a": "2", "mysql-c": "2"}
        self.assertEqual(w.detect_rotations(prev, cur), ["mysql-c", "pg-a", "pg-b"])


class RecentRotationsTest(unittest.TestCase):
    def test_only_roles_rotated_inside_the_window(self):
        now = w.parse_time("2026-11-03T10:10:00Z")
        cur = {"pg-a": "2026-11-03T10:09:00Z", "pg-b": "2026-11-03T10:04:00Z",
               "pg-c": "0001-01-01T00:00:00Z", "pg-d": "", "pg-e": "2026-11-03T10:10:30Z"}
        self.assertEqual(w.recent_rotations(cur, now, 300), ["pg-a"])


class SyncedAfterTest(unittest.TestCase):
    rotated = w.parse_time("2026-11-03T10:10:00.400Z")

    def test_refresh_well_after_rotation_and_ready(self):
        self.assertTrue(w.synced_after(es("x", refresh="2026-11-03T10:10:04Z"), self.rotated))

    def test_refresh_needs_more_than_one_second_margin(self):
        # ESO truncates refreshTime to whole seconds, so 10:10:01 may be a read
        # at 10:10:01.0, before the rotation plus clock skew. Not enough.
        self.assertFalse(w.synced_after(es("x", refresh="2026-11-03T10:10:01Z"), self.rotated))
        self.assertFalse(w.synced_after(es("x", refresh="2026-11-03T10:10:00Z"), self.rotated))
        self.assertTrue(w.synced_after(es("x", refresh="2026-11-03T10:10:02Z"), self.rotated))

    def test_not_ready(self):
        self.assertFalse(w.synced_after(es("x", refresh="2026-11-03T10:11:00Z", ready="False"), self.rotated))
        self.assertFalse(w.synced_after(es("x", refresh="2026-11-03T10:11:00Z", ready=None), self.rotated))

    def test_no_refresh_time(self):
        self.assertFalse(w.synced_after(es("x"), self.rotated))


class FollowUpsTest(unittest.TestCase):
    def test_parses_comma_and_space_separated_names(self):
        e = es("technitium-db-creds", ns="technitium",
               annotations={w.AFTER_SYNC_ANNOTATION: " technitium-password-sync, other-job  third"})
        self.assertEqual(w.after_sync_cronjobs(e), ["technitium-password-sync", "other-job", "third"])

    def test_absent_or_empty(self):
        self.assertEqual(w.after_sync_cronjobs(es("x")), [])
        self.assertEqual(w.after_sync_cronjobs(es("x", annotations={w.AFTER_SYNC_ANNOTATION: " , "})), [])
        self.assertEqual(w.after_sync_cronjobs({"metadata": {"annotations": None}}), [])

    def test_cross_namespace_names_are_rejected(self):
        # RBAC is granted per namespace by the app's own stack, so a follow-up
        # always runs next to its ExternalSecret.
        e = es("x", annotations={w.AFTER_SYNC_ANNOTATION: "other-ns/job,ok-job,Bad_Name"})
        self.assertEqual(w.after_sync_cronjobs(e), ["ok-job"])


class JobFromCronjobTest(unittest.TestCase):
    cronjob = {
        "apiVersion": "batch/v1",
        "kind": "CronJob",
        "metadata": {"name": "technitium-password-sync", "namespace": "technitium", "uid": "abc-123"},
        "spec": {"jobTemplate": {
            "metadata": {"labels": {"app": "pw-sync"}, "annotations": {"a": "b"}},
            "spec": {"template": {"spec": {"containers": [{"name": "c", "image": "i"}]}}},
        }},
    }

    def test_mirrors_kubectl_create_job_from(self):
        job = w.job_from_cronjob(self.cronjob, "technitium-password-sync-rot-1793457108")
        self.assertEqual(job["apiVersion"], "batch/v1")
        self.assertEqual(job["kind"], "Job")
        md = job["metadata"]
        self.assertEqual(md["name"], "technitium-password-sync-rot-1793457108")
        self.assertEqual(md["namespace"], "technitium")
        self.assertEqual(md["labels"], {"app": "pw-sync"})
        self.assertEqual(md["annotations"]["cronjob.kubernetes.io/instantiate"], "manual")
        self.assertEqual(md["annotations"]["a"], "b")
        self.assertEqual(md["ownerReferences"], [{
            "apiVersion": "batch/v1", "kind": "CronJob", "name": "technitium-password-sync",
            "uid": "abc-123", "controller": True,
        }])
        self.assertEqual(job["spec"], self.cronjob["spec"]["jobTemplate"]["spec"])

    def test_job_name_is_deterministic_and_dns_safe(self):
        a = w.job_name("technitium-password-sync", 1793457108.83)
        self.assertEqual(a, "technitium-password-sync-rot-1793457108")
        self.assertEqual(a, w.job_name("technitium-password-sync", 1793457108.1))
        long = w.job_name("x" * 80, 1793457108)
        self.assertLessEqual(len(long), 63)
        self.assertTrue(long.endswith("-rot-1793457108"))
        # Truncation never leaves a dangling hyphen before the suffix.
        self.assertEqual(w.job_name("y" * 56 + "-" + "z" * 10, 1), "y" * 56 + "-rot-1")


class MetricsTest(unittest.TestCase):
    def test_exposition_text(self):
        text = w.metrics_text({"db_rotation_sync_lag_seconds": 7.25, "db_rotation_last_seen_timestamp": 1793457110})
        self.assertEqual(text,
                         "# TYPE db_rotation_last_seen_timestamp gauge\n"
                         "db_rotation_last_seen_timestamp 1793457110\n"
                         "# TYPE db_rotation_sync_lag_seconds gauge\n"
                         "db_rotation_sync_lag_seconds 7.25\n")

    def test_push_url_groups_by_role(self):
        self.assertEqual(w.push_url("http://pgw:9091", "pg-linkwarden"),
                         "http://pgw:9091/metrics/job/db-rotation-watcher/role/pg-linkwarden")
        self.assertEqual(w.push_url("http://pgw:9091/", None),
                         "http://pgw:9091/metrics/job/db-rotation-watcher")


class TrackerTest(unittest.TestCase):
    """The per-rotation state machine: when to annotate, when it is done."""

    def setUp(self):
        self.rot = w.parse_time("2026-11-03T10:10:00.400Z")
        self.t = w.Rotation(role="pg-a", rotated_at=self.rot, seen_at=self.rot + 3)

    def test_waits_past_the_rotation_before_the_first_force_sync(self):
        # A sync started inside the same second could be stamped before the
        # rotation; hold off until rotated_at + SYNC_MARGIN.
        self.assertFalse(self.t.should_annotate("ns/x", now=self.rot + 1.0))
        self.assertTrue(self.t.should_annotate("ns/x", now=self.rot + w.SYNC_MARGIN + 0.1))

    def test_re_annotates_every_interval_until_synced(self):
        now = self.rot + 3
        self.assertTrue(self.t.should_annotate("ns/x", now=now))
        self.t.annotated("ns/x", now)
        self.assertFalse(self.t.should_annotate("ns/x", now=now + w.REANNOTATE_SECONDS - 1))
        self.assertTrue(self.t.should_annotate("ns/x", now=now + w.REANNOTATE_SECONDS))
        self.t.synced["ns/x"] = self.rot + 4
        self.assertFalse(self.t.should_annotate("ns/x", now=now + 60))

    def test_lag_is_last_sync_minus_rotation(self):
        self.t.synced = {"a/x": self.rot + 4.6, "b/y": self.rot + 9.6}
        self.assertAlmostEqual(self.t.lag(), 9.6, places=5)

    def test_lag_without_externalsecrets_is_detection_delay(self):
        self.assertAlmostEqual(self.t.lag(), 3.0)

    def test_timed_out(self):
        self.assertFalse(self.t.timed_out(now=self.t.seen_at + w.SYNC_TIMEOUT_SECONDS - 1))
        self.assertTrue(self.t.timed_out(now=self.t.seen_at + w.SYNC_TIMEOUT_SECONDS))


if __name__ == "__main__":
    unittest.main()
