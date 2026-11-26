#!/usr/bin/env python3
"""Run a repo's queued `runs-on: homelab` jobs on one-shot GitHub runners.

The infra pipeline .woodpecker/gha-runner.yml runs this when ci-route has
dispatched a workflow with runner=homelab (plan docs/plans/
2026-11-26-gha-quota-fallback.md). Each pass registers a just-in-time runner
with the label homelab, which takes one job and exits. A workflow with
several jobs queues the next one when the last ends, so the loop goes on
until no homelab job of the repo has waited for IDLE_SECONDS.

Env: RUNNER_REPO (repo name under ViktorBarzin), GITHUB_RUNNER_TOKEN
(fine-grained: Administration read and write, Actions read).
Exit 1 on a GitHub API error, so the pipeline fails and Slack hears of it.
A failed job is the workflow's own business: its notify step reports it.
"""

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

OWNER = "ViktorBarzin"
LABEL = "homelab"
IDLE_SECONDS = 90
POLL_SECONDS = 10
MAX_SECONDS = 90 * 60
RUNNER_DIR = "/home/runner"


def api(method, path, token, body=None):
    req = urllib.request.Request(
        "https://api.github.com" + path,
        method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read()
    return json.loads(raw) if raw else None


def waiting_jobs(runs_jobs):
    """Queued jobs that ask for the homelab runner, from {run_id: [jobs]}."""
    return [
        j for jobs in runs_jobs.values() for j in jobs if j.get("status") == "queued" and LABEL in j.get("labels", [])
    ]


def fetch_runs_jobs(repo, token):
    out = {}
    for status in ("queued", "in_progress"):
        runs = api("GET", f"/repos/{OWNER}/{repo}/actions/runs?status={status}&per_page=20", token)
        for run in runs["workflow_runs"]:
            out[run["id"]] = api("GET", f"/repos/{OWNER}/{repo}/actions/runs/{run['id']}/jobs", token)["jobs"]
    return out


def run_one_job(repo, token):
    jit = api(
        "POST",
        f"/repos/{OWNER}/{repo}/actions/runners/generate-jitconfig",
        token,
        {"name": f"homelab-{uuid.uuid4().hex[:8]}", "runner_group_id": 1, "labels": [LABEL], "work_folder": "_work"},
    )
    print(f"gha-runner: runner {jit['runner']['name']} registered for {repo}", flush=True)
    rc = subprocess.call(["./run.sh", "--jitconfig", jit["encoded_jit_config"]], cwd=RUNNER_DIR)
    print(f"gha-runner: runner exited {rc}", flush=True)


def main():
    repo, token = os.environ["RUNNER_REPO"], os.environ["GITHUB_RUNNER_TOKEN"]
    start, idle_since, ran = time.time(), time.time(), 0
    try:
        while time.time() - start < MAX_SECONDS:
            if waiting_jobs(fetch_runs_jobs(repo, token)):
                run_one_job(repo, token)
                ran += 1
                idle_since = time.time()
                continue
            if time.time() - idle_since >= IDLE_SECONDS:
                print(f"gha-runner: {repo}: ran {ran} job(s); none waiting for {IDLE_SECONDS}s")
                return 0
            time.sleep(POLL_SECONDS)
    except urllib.error.HTTPError as e:
        print(f"gha-runner: {e.code} from {e.url}: {e.read()[:300]!r}", file=sys.stderr)
        return 1
    print(f"gha-runner: {repo}: stopped after {MAX_SECONDS // 60} minutes with jobs still waiting", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
