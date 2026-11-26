#!/usr/bin/env python3
"""Start a repo's GitHub workflow on GitHub's runners or on the homelab's.

Every push to a repo starts its .woodpecker/build.yml, which runs this once
per GitHub workflow that the push would have started (docs/plans/
2026-11-26-gha-quota-fallback.md). Public repos build on GitHub for free.
A private repo spends the account's 2,000 monthly minutes, so:

- under GATE_MINUTES used this month: dispatch with runner=ubuntu-latest and
  watch the run; if GitHub refuses the job for billing, go on as below;
- at GATE_MINUTES or more: dispatch with runner=homelab and start the infra
  pipeline gha-runner, which registers a one-shot self-hosted runner.

Each job's runs-on reads `${{ inputs.runner || 'ubuntu-latest' }}`.

Two halves, so the GitHub token never reaches an app repo:
- in an app repo's .woodpecker/build.yml: `ci-route --request <workflow>`
  starts the infra pipeline .woodpecker/ci-route.yml (env WOODPECKER_TOKEN;
  Woodpecker sets CI_REPO_NAME, CI_COMMIT_BRANCH and CI_COMMIT_TAG);
- in that infra pipeline: `ci-route` with ROUTE_REPO, ROUTE_WORKFLOW,
  ROUTE_REF and ROUTE_FORCE routes it (env GITHUB_ROUTE_TOKEN,
  WOODPECKER_TOKEN).

By hand: ci-route <workflow> --repo R --ref master [--check] [--force-homelab | --force-hosted]
"""

import argparse
import datetime
import json
import os
import sys
import time
import urllib.error
import urllib.request

OWNER = "ViktorBarzin"
# 2,000 included minutes, less a margin for the billing figure's lag behind
# finished jobs (under 45 minutes measured on 2026-11-26).
GATE_MINUTES = 1950
# GitHub's minute multipliers for the included allowance.
MULTIPLIER = {"Actions Linux": 1, "Actions Windows": 2, "Actions macOS": 10}
WATCH_SECONDS = 180
WOODPECKER = "https://ci.viktorbarzin.me"
INFRA_REPO_ID = 1  # ViktorBarzin/infra in Woodpecker
REFUSAL_WORDS = ("spending limit", "payments have failed")


class GitHub:
    def __init__(self, token):
        self.token = token

    def _call(self, method, path, body=None):
        req = urllib.request.Request(
            "https://api.github.com" + path,
            method=method,
            data=None if body is None else json.dumps(body).encode(),
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
        return json.loads(raw) if raw else None

    def get(self, path):
        return self._call("GET", path)

    def post(self, path, body):
        return self._call("POST", path, body)


def weighted(item):
    return item["quantity"] * MULTIPLIER.get(item["sku"], 1)


def private_repos(gh):
    names, page = set(), 1
    while True:
        batch = gh.get(f"/user/repos?visibility=private&affiliation=owner&per_page=100&page={page}")
        if not batch:
            return names
        names.update(r["name"] for r in batch if r.get("private"))
        page += 1


def private_minutes(gh, year, month):
    usage = gh.get(f"/users/{OWNER}/settings/billing/usage?year={year}&month={month}")
    private = private_repos(gh)
    return sum(
        weighted(i)
        for i in usage["usageItems"]
        if i.get("unitType") == "Minutes" and i.get("repositoryName", "").split("/")[-1] in private
    )


def refused(jobs, annotations_for):
    """True when GitHub turned the run's jobs away for billing.

    A refused job ends at once with no runner and no steps, and its check run
    carries the billing message (seen on 2026-10-30).
    """
    for job in jobs:
        if job.get("conclusion") == "failure" and not job.get("steps") and not job.get("runner_name"):
            text = " ".join(a.get("message", "") for a in annotations_for(job["id"]))
            if any(w in text for w in REFUSAL_WORDS):
                return True
    return False


def dispatch(gh, repo, workflow, ref, runner):
    gh.post(
        f"/repos/{OWNER}/{repo}/actions/workflows/{workflow}/dispatches",
        {"ref": ref, "inputs": {"runner": runner}},
    )


def watch_for_refusal(gh, repo, workflow, since):
    """Wait for the dispatched run to start; True if GitHub refused it."""
    deadline = time.time() + WATCH_SECONDS
    while time.time() < deadline:
        time.sleep(10)
        runs = gh.get(f"/repos/{OWNER}/{repo}/actions/workflows/{workflow}/runs?event=workflow_dispatch&per_page=5")
        fresh = [r for r in runs["workflow_runs"] if r["created_at"] >= since]
        if not fresh:
            continue
        jobs = gh.get(f"/repos/{OWNER}/{repo}/actions/runs/{fresh[0]['id']}/jobs")["jobs"]
        if refused(jobs, lambda job_id: gh.get(f"/repos/{OWNER}/{repo}/check-runs/{job_id}/annotations")):
            return True
        if any(j.get("runner_name") or j.get("steps") for j in jobs):
            return False
    print(f"ci-route: no runner took {workflow} within {WATCH_SECONDS}s; leaving it queued on GitHub")
    return False


def start_infra_pipeline(body):
    """Start a manual pipeline of the infra repo in Woodpecker."""
    req = urllib.request.Request(
        f"{WOODPECKER}/api/repos/{INFRA_REPO_ID}/pipelines",
        method="POST",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {os.environ['WOODPECKER_TOKEN']}", "Content-Type": "application/json"},
    )
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                print(f"ci-route: started infra pipeline {body['variables']['PIPELINE']} (HTTP {resp.status})")
                return
        except urllib.error.URLError as e:
            print(f"ci-route: attempt {attempt + 1} to reach Woodpecker failed: {e}")
            time.sleep(15)
    raise SystemExit("ci-route: could not start the infra pipeline")


def start_runner_pipeline(repo):
    """Start the infra pipeline that runs one-shot runners for this repo."""
    start_infra_pipeline({"branch": "master", "variables": {"PIPELINE": "gha-runner", "RUNNER_REPO": repo}})


def request_route(repo, workflow, ref, force, post=start_infra_pipeline):
    """From an app repo: ask the infra pipeline ci-route to route this push."""
    post(
        {
            "branch": "master",
            "variables": {
                "PIPELINE": "ci-route",
                "ROUTE_REPO": repo,
                "ROUTE_WORKFLOW": workflow,
                "ROUTE_REF": ref,
                "ROUTE_FORCE": force or "",
            },
        }
    )


def route(gh, repo, workflow, ref, minutes_used, watch, start_runner, force=None):
    """Dispatch the workflow and return where it runs: 'hosted' or 'homelab'."""
    target = force
    if target is None:
        if not gh.get(f"/repos/{OWNER}/{repo}")["private"]:
            target = "hosted"
        else:
            used = minutes_used()
            print(f"ci-route: private minutes this month {used:.0f} of 2000 (gate {GATE_MINUTES})")
            target = "hosted" if used < GATE_MINUTES else "homelab"
    if target == "hosted":
        since = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        dispatch(gh, repo, workflow, ref, "ubuntu-latest")
        print(f"ci-route: {repo} {workflow} on {ref} -> GitHub runners")
        if force == "hosted" or not watch(gh, repo, workflow, since):
            return "hosted"
        print("ci-route: GitHub refused the job for billing; moving it to the homelab")
    dispatch(gh, repo, workflow, ref, "homelab")
    start_runner(repo)
    print(f"ci-route: {repo} {workflow} on {ref} -> homelab runner")
    return "homelab"


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("workflow", nargs="?", default=os.environ.get("ROUTE_WORKFLOW"))
    p.add_argument(
        "--repo", default=os.environ.get("ROUTE_REPO") or os.environ.get("CI_REPO_NAME")
    )
    p.add_argument(
        "--ref",
        default=os.environ.get("ROUTE_REF") or os.environ.get("CI_COMMIT_TAG") or os.environ.get("CI_COMMIT_BRANCH"),
    )
    p.add_argument("--check", action="store_true", help="print the decision, dispatch nothing")
    p.add_argument("--request", action="store_true", help="from an app repo: ask infra to route this push")
    force = p.add_mutually_exclusive_group()
    force.add_argument("--force-homelab", dest="force", action="store_const", const="homelab")
    force.add_argument("--force-hosted", dest="force", action="store_const", const="hosted")
    a = p.parse_args(argv)
    if not a.workflow or not a.repo or not a.ref:
        p.error("need a workflow, --repo and --ref (or the ROUTE_* or CI_* variables)")
    a.force = a.force or os.environ.get("ROUTE_FORCE") or None
    if a.request:
        request_route(a.repo, a.workflow, a.ref, a.force)
        return 0
    gh = GitHub(os.environ["GITHUB_ROUTE_TOKEN"])
    now = datetime.datetime.now(datetime.timezone.utc)

    def minutes_used():
        return private_minutes(gh, now.year, now.month)

    if a.check:
        private = gh.get(f"/repos/{OWNER}/{a.repo}")["private"]
        used = minutes_used() if private else 0
        where = "homelab" if a.force == "homelab" or (private and used >= GATE_MINUTES) else "hosted"
        print(f"ci-route --check: {a.repo} private={private} minutes={used:.0f} -> {where}")
        return 0
    try:
        route(gh, a.repo, a.workflow, a.ref, minutes_used, watch_for_refusal, start_runner_pipeline, a.force)
    except urllib.error.HTTPError as e:
        print(f"ci-route: {e.code} from {e.url}: {e.read()[:300]!r}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
