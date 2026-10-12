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


def _module(body, name="ingress"):
    return (
        f'module "{name}" {{\n'
        '  source = "../../modules/kubernetes/ingress_factory"\n'
        f"{body}"
        "  extra_annotations = {\n"
        '    "gethomepage.dev/name" = "Not a host"\n'
        "  }\n"
        "}\n"
    )


class ExtractForwardAuthIngresses(unittest.TestCase):
    def test_host_from_name(self):
        tf = _module('  name = "draw"\n  auth = "required"\n')
        self.assertEqual(
            cag.extract_forward_auth_ingresses(tf),
            [{"module": "ingress", "host": "draw.viktorbarzin.me",
              "groups": ["Home Server Admins"]}],
        )

    def test_host_overrides_name(self):
        tf = _module('  name = "ytdlp"\n  host = "yt"\n'
                     '  allowed_groups = ["Home Server Admins", "Home Users"]\n')
        self.assertEqual(
            cag.extract_forward_auth_ingresses(tf),
            [{"module": "ingress", "host": "yt.viktorbarzin.me",
              "groups": ["Home Server Admins", "Home Users"]}],
        )

    def test_full_host_wins(self):
        tf = _module('  name = "x"\n  host = "y"\n  full_host = "z.example.org"\n')
        self.assertEqual(cag.extract_forward_auth_ingresses(tf)[0]["host"], "z.example.org")

    def test_auth_defaults_to_required(self):
        tf = _module('  name = "speedtest"\n')
        self.assertEqual(len(cag.extract_forward_auth_ingresses(tf)), 1)

    def test_skips_non_forward_auth(self):
        for auth in ("none", "app", "public"):
            tf = _module(f'  name = "prep"\n  host = "pages"\n  auth = "{auth}"\n')
            self.assertEqual(cag.extract_forward_auth_ingresses(tf), [], auth)

    def test_non_literal_host_is_none(self):
        tf = _module('  name = var.name\n')
        self.assertIsNone(cag.extract_forward_auth_ingresses(tf)[0]["host"])

    def test_skips_other_modules(self):
        tf = 'module "x" {\n  source = "../../modules/kubernetes/nfs_volume"\n  name = "a"\n}\n'
        self.assertEqual(cag.extract_forward_auth_ingresses(tf), [])

    def test_two_modules(self):
        tf = _module('  name = "a"\n', "one") + _module('  name = "b"\n', "two")
        hosts = [i["host"] for i in cag.extract_forward_auth_ingresses(tf)]
        self.assertEqual(hosts, ["a.viktorbarzin.me", "b.viktorbarzin.me"])


class MapMismatches(unittest.TestCase):
    ADM = "Home Server Admins"

    def ing(self, host, groups):
        return {"module": "m", "host": host, "groups": groups}

    def test_admin_only_host_not_in_map_is_fine(self):
        self.assertEqual(cag.map_mismatches([self.ing("a.x", [self.ADM])], {}), [])

    def test_matching_entry_is_fine(self):
        ings = [self.ing("a.x", [self.ADM, "Home Users"])]
        self.assertEqual(cag.map_mismatches(ings, {"a.x": ["Home Users"]}), [])

    def test_admins_implied_and_order_ignored(self):
        ings = [self.ing("k.x", ["B", "A", self.ADM])]
        self.assertEqual(cag.map_mismatches(ings, {"k.x": ["A", "B"]}), [])

    def test_non_admin_group_missing_from_map(self):
        out = cag.map_mismatches([self.ing("a.x", ["Home Users"])], {})
        self.assertEqual(len(out), 1)
        self.assertIn("a.x", out[0])

    def test_groups_disagree(self):
        out = cag.map_mismatches([self.ing("a.x", ["Home Users"])], {"a.x": ["T3 Users"]})
        self.assertEqual(len(out), 1)

    def test_map_grants_host_that_ingress_keeps_admin_only(self):
        out = cag.map_mismatches([self.ing("a.x", [self.ADM])], {"a.x": ["Home Users"]})
        self.assertEqual(len(out), 1)

    def test_non_literal_host_with_non_admin_group(self):
        out = cag.map_mismatches([self.ing(None, ["Home Users"])], {})
        self.assertEqual(len(out), 1)

    def test_non_literal_admin_only_is_fine(self):
        self.assertEqual(cag.map_mismatches([self.ing(None, [self.ADM])], {}), [])


class OrphanMapEntries(unittest.TestCase):
    def test_entry_without_ingress(self):
        ings = [{"module": "m", "host": "a.x", "groups": ["G"]}]
        self.assertEqual(cag.orphan_map_entries(ings, {"a.x": ["G"], "b.x": ["G"]}), ["b.x"])


if __name__ == "__main__":
    unittest.main()
