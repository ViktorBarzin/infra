#!/usr/bin/env python3
"""Unit tests for check-allowed-groups.py pure logic (ADR-0023 audit guard).

Run: python3 scripts/check_allowed_groups_test.py
Prior art: stacks/nvidia/modules/nvidia/watchdog_test.py.
"""
import importlib.util
import os
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "check_allowed_groups", os.path.join(_HERE, "check-allowed-groups.py")
)
cag = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cag)


class ExtractGroupUsages(unittest.TestCase):
    def test_single_group(self):
        tf = 'auth = "required"\n  allowed_groups = ["Home Server Admins"]\n'
        self.assertEqual(cag.extract_group_usages(tf), [["Home Server Admins"]])

    def test_multiple_groups_one_line(self):
        tf = '  allowed_groups = ["Proxy Users", "Home Server Admins"]'
        self.assertEqual(
            cag.extract_group_usages(tf), [["Proxy Users", "Home Server Admins"]]
        )

    def test_multiline_list(self):
        tf = 'allowed_groups = [\n  "kubernetes-admins",\n  "Home Server Admins",\n]'
        self.assertEqual(
            cag.extract_group_usages(tf), [["kubernetes-admins", "Home Server Admins"]]
        )

    def test_no_usage(self):
        self.assertEqual(cag.extract_group_usages('auth = "required"'), [])

    def test_two_usages_in_one_file(self):
        tf = 'allowed_groups = ["A"]\n# ...\nallowed_groups = ["B", "C"]\n'
        self.assertEqual(cag.extract_group_usages(tf), [["A"], ["B", "C"]])


class ExtractDefinedGroups(unittest.TestCase):
    def test_finds_authentik_group_names(self):
        tf = (
            'resource "authentik_group" "chrome_users" {\n  name = "Chrome Users"\n}\n'
            'resource "authentik_group" "tripit_users" {\n  name = "TripIt Users"\n}\n'
        )
        self.assertEqual(
            cag.extract_defined_groups(tf), {"Chrome Users", "TripIt Users"}
        )

    def test_ignores_other_resources(self):
        tf = 'resource "authentik_policy_binding" "x" {\n  name = "not a group"\n}\n'
        self.assertEqual(cag.extract_defined_groups(tf), set())


class FindViolations(unittest.TestCase):
    def test_all_valid(self):
        usages = [["Home Server Admins"], ["Proxy Users", "Home Server Admins"]]
        valid = {"Home Server Admins", "Proxy Users"}
        self.assertEqual(cag.find_violations(usages, valid), [])

    def test_typo_flagged(self):
        usages = [["Home Server Admin"]]  # missing trailing 's'
        valid = {"Home Server Admins"}
        self.assertEqual(cag.find_violations(usages, valid), ["Home Server Admin"])

    def test_unique_sorted(self):
        usages = [["Zzz"], ["Aaa"], ["Zzz"]]
        self.assertEqual(cag.find_violations(usages, set()), ["Aaa", "Zzz"])

    def test_ui_managed_groups_are_valid(self):
        # The canonical UI-managed set must cover the baseline groups so the
        # default ["Home Server Admins"] never false-positives.
        for g in ("Home Server Admins", "authentik Admins", "T3 Users"):
            self.assertIn(g, cag.UI_MANAGED_GROUPS)


if __name__ == "__main__":
    unittest.main()
