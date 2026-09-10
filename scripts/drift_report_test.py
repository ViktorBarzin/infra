#!/usr/bin/env python3
"""Unit tests for drift-report.py pure logic.

Run: python3 scripts/drift_report_test.py
Prior art: scripts/check_ingress_descriptions_test.py.
"""
import importlib.util
import os
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "drift_report", os.path.join(_HERE, "drift-report.py")
)
dr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(dr)


# Real shape: terragrunt prefixes every terraform line with a timestamp and
# "STDOUT terraform: ". Anchoring on bare terraform output matched nothing on
# the first run that reached this branch, so the parser is tested against the
# prefixed form specifically.
TERRAGRUNT_DRIFT = """
00:04:11.220 STDOUT terraform: Terraform will perform the following actions:
00:04:11.221 STDOUT terraform:   # module.tls_secret.kubernetes_secret.tls_secret will be updated in-place
00:04:11.221 STDOUT terraform:   ~ resource "kubernetes_secret" "tls_secret" {
00:04:11.222 STDOUT terraform:       ~ data = (sensitive value)
00:04:11.223 STDOUT terraform:   # module.dbaas.null_resource.pg_cluster must be replaced
00:04:11.224 STDOUT terraform:   # module.dbaas.null_resource.pg_lesson_harvester_db will be created
00:04:11.225 STDOUT terraform:   # module.old.kubernetes_job.gone will be destroyed
00:04:11.999 STDOUT terraform: Plan: 2 to add, 1 to change, 2 to destroy.
"""

BARE_CLEAN = """
Terraform has compared your real infrastructure against your configuration
and found no differences, so no changes are needed.

No changes. Your infrastructure matches the configuration.
"""

ANSI_DRIFT = (
    "00:04:11 STDOUT terraform: \x1b[1m  # module.a.b will be created\x1b[0m\n"
    "00:04:12 STDOUT terraform: \x1b[1mPlan: 1 to add, 0 to change, 0 to destroy.\x1b[0m\n"
)


class TestParsePlan(unittest.TestCase):
    def test_counts_from_terragrunt_prefixed_output(self):
        p = dr.parse_plan(TERRAGRUNT_DRIFT)
        self.assertEqual((p["add"], p["change"], p["destroy"]), (2, 1, 2))

    def test_extracts_resource_addresses_with_symbols(self):
        p = dr.parse_plan(TERRAGRUNT_DRIFT)
        self.assertIn(("~", "module.tls_secret.kubernetes_secret.tls_secret"), p["resources"])
        self.assertIn(("±", "module.dbaas.null_resource.pg_cluster"), p["resources"])
        self.assertIn(("+", "module.dbaas.null_resource.pg_lesson_harvester_db"), p["resources"])
        self.assertIn(("-", "module.old.kubernetes_job.gone"), p["resources"])

    def test_does_not_pick_up_body_lines_as_resources(self):
        # `~ resource "kubernetes_secret"` and `~ data = ...` are diff body, not
        # resource headers; only the `# <addr> will be` lines name a resource.
        p = dr.parse_plan(TERRAGRUNT_DRIFT)
        self.assertEqual(len(p["resources"]), 4)

    def test_clean_plan_has_no_changes(self):
        p = dr.parse_plan(BARE_CLEAN)
        self.assertEqual((p["add"], p["change"], p["destroy"]), (0, 0, 0))
        self.assertEqual(p["resources"], [])

    def test_ansi_escapes_are_stripped(self):
        p = dr.parse_plan(ANSI_DRIFT)
        self.assertEqual(p["add"], 1)
        self.assertEqual(p["resources"], [("+", "module.a.b")])


class TestAbortedRunHeuristic(unittest.TestCase):
    """The 2026-08-16 run errored 29 stacks that formed an alphabetical tail —
    the signature of a run that died partway (PG state backend went away
    mid-run), not 29 independently broken stacks."""

    def test_alphabetical_tail_is_flagged(self):
        stacks = ["ac", "authentik", "dbaas", "stremio", "traefik", "wireguard", "ytdlp"]
        errored = ["stremio", "traefik", "wireguard", "ytdlp"]
        self.assertTrue(dr.looks_like_aborted_tail(errored, stacks))

    def test_scattered_errors_are_not_flagged(self):
        stacks = ["ac", "authentik", "dbaas", "stremio", "traefik", "wireguard", "ytdlp"]
        errored = ["authentik", "traefik"]
        self.assertFalse(dr.looks_like_aborted_tail(errored, stacks))

    def test_no_errors_is_not_flagged(self):
        self.assertFalse(dr.looks_like_aborted_tail([], ["a", "b"]))

    def test_single_trailing_error_is_not_enough_to_claim_abort(self):
        # One stack failing at the end is ordinary breakage, not an aborted run.
        stacks = ["a", "b", "c", "d", "e"]
        self.assertFalse(dr.looks_like_aborted_tail(["e"], stacks))


class TestBuildReport(unittest.TestCase):
    def _entries(self):
        return [
            ("clean-stack", 0, BARE_CLEAN),
            ("dbaas", 2, TERRAGRUNT_DRIFT),
            ("broken", 1, "Error: could not load state"),
        ]

    def test_shows_actual_resource_differences_not_just_names(self):
        text = dr.build_report(self._entries())
        self.assertIn("module.dbaas.null_resource.pg_cluster", text)
        self.assertIn("module.tls_secret.kubernetes_secret.tls_secret", text)

    def test_shows_per_stack_counts(self):
        text = dr.build_report(self._entries())
        self.assertIn("+2", text)
        self.assertIn("~1", text)
        self.assertIn("-2", text)

    def test_errors_are_reported_separately_from_drift(self):
        # An error means "we could not determine", NOT "this differs". Lumping
        # them together is what made a half-finished run read as 79 drifting.
        text = dr.build_report(self._entries())
        drift_i = text.index("dbaas")
        err_i = text.index("broken")
        self.assertLess(drift_i, err_i, "drift section should precede errors")
        # "state unknown", not the headline phrase — the headline always names
        # the error count, so asserting on that would pass even with no section.
        self.assertIn("state unknown", text.lower())

    def test_clean_stacks_are_counted_not_listed(self):
        text = dr.build_report(self._entries())
        self.assertNotIn("clean-stack", text)
        self.assertIn("1 clean", text)

    def test_commit_is_recorded_so_a_stale_checkout_is_visible(self):
        text = dr.build_report(self._entries(), commit="a1b2c3d")
        self.assertIn("a1b2c3d", text)

    def test_resources_per_stack_are_capped(self):
        big = "\n".join(
            "STDOUT terraform:   # module.m.r%d will be created" % i for i in range(50)
        ) + "\nSTDOUT terraform: Plan: 50 to add, 0 to change, 0 to destroy."
        text = dr.build_report([("big", 2, big)], max_resources=3)
        self.assertIn("module.m.r0", text)
        self.assertNotIn("module.m.r40", text)
        self.assertIn("47 more", text)

    def test_bulk_changes_collapse_by_resource_type(self):
        # A stack changing 115 instances of one resource is better described as
        # "115 x <type>" than as six arbitrary addresses. cloudflared's
        # allow-list refactor listed 6 destroys and hid the 115 creates that
        # were the actual story.
        lines = ["STDOUT terraform:   # module.c.route.host[\"h%d\"] will be created" % i
                 for i in range(115)]
        lines += ["STDOUT terraform:   # module.c.route.carve[\"c%d\"] will be destroyed" % i
                  for i in range(10)]
        lines.append("STDOUT terraform: Plan: 115 to add, 0 to change, 10 to destroy.")
        text = dr.build_report([("cloudflared", 2, "\n".join(lines))], max_resources=6)
        self.assertIn("115 x module.c.route.host", text.replace("×", "x"))
        self.assertIn("10 x module.c.route.carve", text.replace("×", "x"))

    def test_small_change_sets_still_list_exact_addresses(self):
        # Collapsing only helps in bulk; a handful of changes must stay literal
        # so you can see exactly which resource moved.
        text = dr.build_report([("dbaas", 2, TERRAGRUNT_DRIFT)], max_resources=6)
        self.assertIn("module.dbaas.null_resource.pg_lesson_harvester_db", text)
        self.assertNotIn("x module.dbaas", text.replace("×", "x"))

    def test_stack_list_is_capped(self):
        entries = [("s%02d" % i, 2, TERRAGRUNT_DRIFT) for i in range(30)]
        text = dr.build_report(entries, max_stacks=5)
        self.assertIn("s00", text)
        self.assertNotIn("s29", text)
        self.assertIn("25 more", text)

    def test_aborted_run_adds_a_warning_instead_of_claiming_drift(self):
        entries = [("a", 0, BARE_CLEAN), ("b", 0, BARE_CLEAN)]
        entries += [(n, 1, "Error: state") for n in ("x", "y", "z")]
        text = dr.build_report(entries)
        self.assertIn("aborted", text.lower())

    def test_all_clean_produces_no_drift_section(self):
        text = dr.build_report([("a", 0, BARE_CLEAN)])
        self.assertIn("1 clean", text)
        self.assertNotIn("state unknown", text.lower())


class TestSlackPayload(unittest.TestCase):
    def test_payload_is_valid_json_with_channel_and_text(self):
        import json

        p = json.loads(dr.slack_payload("hello <&> \"quoted\"", channel="general"))
        self.assertEqual(p["channel"], "general")
        self.assertIn("hello", p["text"])

    def test_payload_escapes_quotes_that_would_break_the_curl_data(self):
        import json

        # The old pipeline built JSON by hand in a shell string; a plan
        # containing a double quote (every resource address with a for_each key
        # does, e.g. route["ac"]) would have broken the payload.
        text = 'module.r.route["ac"] will be created'
        p = json.loads(dr.slack_payload(text))
        self.assertIn('route["ac"]', p["text"])

    def test_payload_is_truncated_to_stay_under_slack_limits(self):
        import json

        p = json.loads(dr.slack_payload("x" * 60000))
        self.assertLessEqual(len(p["text"]), dr.SLACK_MAX_CHARS)


if __name__ == "__main__":
    unittest.main(verbosity=2)
