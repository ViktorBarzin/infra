"""Tests for ci_route against saved GitHub responses (fixtures/).

Run: python3 -m unittest discover -s ci/route
"""

import json
import pathlib
import unittest
from urllib.parse import parse_qs, urlsplit

import ci_route

FIX = pathlib.Path(__file__).parent / "fixtures"


def load(name):
    return json.loads((FIX / name).read_text())


class FakeGitHub:
    """Answers the calls ci_route makes, from fixtures and per-test values."""

    def __init__(self, private=("wealth", "tv"), runs=None, jobs=None, annotations=None):
        self.private = set(private)
        self.runs = runs or []
        self.jobs = jobs or {}
        self.annotations = annotations or {}
        self.dispatched = []

    def get(self, path):
        if path.startswith("/users/ViktorBarzin/settings/billing/usage"):
            return load("billing-nov.json")
        if path.startswith("/user/repos"):
            page = int(parse_qs(urlsplit(path).query)["page"][0])
            names = sorted(self.private)
            return [{"name": n, "private": True} for n in names] if page == 1 else []
        if path.startswith("/repos/ViktorBarzin/") and path.count("/") == 3:
            name = path.split("/")[3]
            return {"name": name, "private": name in self.private}
        if "/actions/workflows/" in path and path.endswith("/runs?event=workflow_dispatch&per_page=5"):
            return {"workflow_runs": self.runs}
        if "/actions/runs/" in path and path.endswith("/jobs"):
            return self.jobs[int(path.split("/")[5])]
        if "/check-runs/" in path and path.endswith("/annotations"):
            return self.annotations.get(int(path.split("/")[5]), [])
        raise AssertionError(f"unexpected GET {path}")

    def post(self, path, body):
        if path.endswith("/dispatches"):
            self.dispatched.append((path.split("/")[6], body["ref"], body["inputs"]["runner"]))
            return None
        raise AssertionError(f"unexpected POST {path}")


class PrivateMinutes(unittest.TestCase):
    def test_counts_only_private_repos(self):
        gh = FakeGitHub(private={"wealth"})
        used = ci_route.private_minutes(gh, year=2026, month=11)
        expected = sum(
            i["quantity"] for i in load("billing-nov.json")["usageItems"] if i["repositoryName"] == "wealth"
        )
        self.assertEqual(used, expected)
        self.assertGreater(used, 0)

    def test_macos_minutes_count_ten_times(self):
        item = {"sku": "Actions macOS", "quantity": 3, "unitType": "Minutes", "repositoryName": "x"}
        self.assertEqual(ci_route.weighted(item), 30)


class Refusal(unittest.TestCase):
    def test_the_30_october_refusal_is_a_refusal(self):
        jobs = load("jobs-refused.json")["jobs"]
        notes = load("annotations-refused.json")
        self.assertTrue(ci_route.refused(jobs, lambda job_id: notes))

    def test_a_job_that_ran_is_not_a_refusal(self):
        jobs = load("jobs-ok.json")["jobs"]
        self.assertFalse(ci_route.refused(jobs, lambda job_id: []))

    def test_a_queued_job_is_not_a_refusal(self):
        jobs = [{"id": 1, "status": "queued", "conclusion": None, "runner_name": None, "steps": []}]
        self.assertFalse(ci_route.refused(jobs, lambda job_id: []))


class Route(unittest.TestCase):
    def setUp(self):
        self.started = []
        self.waits = []

    def route(self, gh, repo, minutes=0, refusal=False, force=None):
        return ci_route.route(
            gh,
            repo=repo,
            workflow="build.yml",
            ref="master",
            minutes_used=lambda: minutes,
            watch=lambda *a: refusal,
            start_runner=lambda r: self.started.append(r),
            force=force,
        )

    def test_a_public_repo_always_goes_to_github(self):
        gh = FakeGitHub(private=set())
        self.assertEqual(self.route(gh, "app-kit", minutes=5000), "hosted")
        self.assertEqual(gh.dispatched, [("build.yml", "master", "ubuntu-latest")])
        self.assertEqual(self.started, [])

    def test_a_private_repo_under_the_gate_goes_to_github(self):
        gh = FakeGitHub(private={"wealth"})
        self.assertEqual(self.route(gh, "wealth", minutes=1200), "hosted")
        self.assertEqual(gh.dispatched, [("build.yml", "master", "ubuntu-latest")])
        self.assertEqual(self.started, [])

    def test_a_private_repo_at_the_gate_builds_in_the_cluster(self):
        gh = FakeGitHub(private={"wealth"})
        self.assertEqual(self.route(gh, "wealth", minutes=ci_route.GATE_MINUTES), "homelab")
        self.assertEqual(gh.dispatched, [("build.yml", "master", "homelab")])
        self.assertEqual(self.started, ["wealth"])

    def test_a_refused_hosted_job_moves_to_the_cluster(self):
        gh = FakeGitHub(private={"wealth"})
        self.assertEqual(self.route(gh, "wealth", minutes=1900, refusal=True), "homelab")
        self.assertEqual(
            gh.dispatched,
            [("build.yml", "master", "ubuntu-latest"), ("build.yml", "master", "homelab")],
        )
        self.assertEqual(self.started, ["wealth"])

    def test_force_homelab_skips_the_billing_check(self):
        gh = FakeGitHub(private={"wealth"})
        self.assertEqual(self.route(gh, "wealth", force="homelab"), "homelab")
        self.assertEqual(self.started, ["wealth"])


if __name__ == "__main__":
    unittest.main()
