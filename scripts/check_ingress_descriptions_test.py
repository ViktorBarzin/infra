#!/usr/bin/env python3
"""Unit tests for check-ingress-descriptions.py pure logic.

Run: python3 scripts/check_ingress_descriptions_test.py
Prior art: scripts/check_allowed_groups_test.py.
"""
import importlib.util
import os
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "check_ingress_descriptions", os.path.join(_HERE, "check-ingress-descriptions.py")
)
cid = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cid)


WITH_DESC = '''
module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = "demo"
  name            = "demo"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/description" = "Does a thing"
  }
}
'''

WITHOUT_DESC = '''
module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = "demo"
  name            = "demo"
  tls_secret_name = var.tls_secret_name
}
'''


class FindMissing(unittest.TestCase):
    def test_module_with_description_passes(self):
        self.assertEqual(cid.find_missing(WITH_DESC), [])

    def test_module_without_description_is_flagged(self):
        got = cid.find_missing(WITHOUT_DESC)
        self.assertEqual([g[0] for g in got], ["demo"])

    def test_single_line_annotation_map_counts(self):
        tf = '''
module "ingress" {
  source            = "../../modules/kubernetes/ingress_factory"
  name              = "demo"
  extra_annotations = { "gethomepage.dev/description" = "Inline is fine" }
}
'''
        self.assertEqual(cid.find_missing(tf), [])

    def test_hidden_from_the_dashboard_is_exempt(self):
        # homepage_enabled = false keeps the service out of the catalog
        # entirely, so there is nothing for a description to describe.
        tf = '''
module "ingress" {
  source           = "../../modules/kubernetes/ingress_factory"
  name             = "internal-only"
  homepage_enabled = false
}
'''
        self.assertEqual(cid.find_missing(tf), [])

    def test_annotation_opt_out_is_exempt(self):
        # Secondary/carve-out ingresses keep one app to one tile by overriding
        # the annotation directly rather than using homepage_enabled.
        tf = '''
module "ingress_snapshot" {
  source = "../../modules/kubernetes/ingress_factory"
  name   = "chrome-snapshot"
  extra_annotations = {
    "gethomepage.dev/enabled" = "false"
  }
}
'''
        self.assertEqual(cid.find_missing(tf), [])

    def test_annotations_supplied_by_the_caller_are_deferred(self):
        # The factory pattern passes the whole annotation map in as a
        # variable; whether it carries a description is decided by the caller,
        # so this file has nothing to check.
        tf = '''
module "ingress" {
  source            = "../../modules/kubernetes/ingress_factory"
  name              = "budget-${var.name}"
  extra_annotations = var.homepage_annotations
}
'''
        self.assertEqual(cid.find_missing(tf), [])

    def test_non_ingress_modules_are_ignored(self):
        tf = '''
module "anubis" {
  source = "../../modules/kubernetes/anubis_instance"
  name   = "blog"
}
'''
        self.assertEqual(cid.find_missing(tf), [])

    def test_several_modules_in_one_file(self):
        got = cid.find_missing(WITH_DESC + WITHOUT_DESC.replace('"demo"', '"other"'))
        self.assertEqual([g[0] for g in got], ["other"])

    def test_module_without_a_name_still_reports_something_useful(self):
        tf = '''
module "ingress_x" {
  source = "../../modules/kubernetes/ingress_factory"
}
'''
        got = cid.find_missing(tf)
        self.assertEqual(len(got), 1)
        self.assertTrue(got[0][0])  # some identifier, not an empty string

    def test_nested_braces_do_not_swallow_the_next_module(self):
        tf = '''
module "ingress_a" {
  source  = "../../modules/kubernetes/ingress_factory"
  name    = "a"
  sablier = {
    group = "a"
  }
}

module "ingress_b" {
  source = "../../modules/kubernetes/ingress_factory"
  name   = "b"
  extra_annotations = {
    "gethomepage.dev/description" = "has one"
  }
}
'''
        got = cid.find_missing(tf)
        self.assertEqual([g[0] for g in got], ["a"])


if __name__ == "__main__":
    unittest.main()
