#!/usr/bin/env python3
"""Keep the repowise Corpus in step with Forgejo.

One idempotent reconcile pass, repeated on an interval. The same code path
bootstraps an empty volume and maintains a warm one, so the two can never
drift apart.

Each pass:

1. Lists ``<owner>/*`` from the Forgejo API and keeps the non-archived,
   non-empty repos. That rule *is* the Corpus definition — there is no
   curated list to fall out of date.
2. Clones what is missing, drops what disappeared upstream, and fetches the
   rest. A cheap ``git ls-remote`` decides whether a fetch is needed at all,
   so an unchanged repo costs one ref advertisement and no object transfer.
3. Bootstraps the workspace with ``repowise init`` the first time, and
   registers later arrivals with ``repowise workspace add``.
4. Asks the API to reindex whatever moved. repowise never fetches on its own,
   so this call is what turns a new commit into a fresh index; the server's
   own 15-minute poll is only a safety net behind it.
5. Pushes an Uptime Kuma heartbeat. A wedged pass therefore surfaces as a
   real alert instead of an index that is quietly hours behind.

Only the standard library is used — the image ships Python and git, and
nothing here is worth a dependency.
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

log = logging.getLogger("reconcile")

WORKSPACE = Path(os.environ.get("REPOWISE_WORKSPACE", "/workspace"))
FORGEJO_BASE = os.environ.get("FORGEJO_BASE", "https://forgejo.viktorbarzin.me")
FORGEJO_OWNER = os.environ.get("FORGEJO_OWNER", "viktor")
FORGEJO_USER = os.environ.get("FORGEJO_USER", "viktor")
FORGEJO_TOKEN = os.environ.get("FORGEJO_TOKEN", "")
API = os.environ.get("REPOWISE_API", "http://localhost:7337")
API_KEY = os.environ.get("REPOWISE_API_KEY", "")
INTERVAL = int(os.environ.get("SYNC_INTERVAL_SECONDS", "3600"))
KUMA_PUSH_URL = os.environ.get("KUMA_PUSH_URL", "")

# Passed to `repowise init` so the parser never sees content that cannot
# usefully be parsed. infra's secrets are git-crypt ciphertext in the clone —
# excluding them keeps binary noise out of the index rather than protecting
# anything (they are already encrypted at rest).
EXCLUDES = ["secrets/", "*.tfvars", "*.enc.*", "vendor/", "node_modules/"]

WORKSPACE_CONFIG = ".repowise-workspace.yaml"
BOOTSTRAP_MARKER = ".bootstrap-attempted"


class ReconcileError(Exception):
    """A pass could not be completed. Raised for anything a retry might fix."""


def run(
    cmd: list[str],
    cwd: Path | None = None,
    timeout: int = 600,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    """Run a command, capturing output so failures can be logged usefully."""
    log.debug("run: %s (cwd=%s)", " ".join(cmd), cwd)
    proc = subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if check and proc.returncode != 0:
        raise ReconcileError(
            f"{' '.join(cmd[:3])}... exited {proc.returncode}: "
            f"{(proc.stderr or proc.stdout).strip()[:500]}"
        )
    return proc


def api_request(
    method: str,
    path: str,
    *,
    token: str,
    scheme: str = "token",
    timeout: int = 300,
) -> object:
    """Call a JSON API and return the decoded body (None on 202/empty)."""
    url = path if path.startswith("http") else f"{API}{path}"
    req = urllib.request.Request(url, method=method)
    if token:
        req.add_header("Authorization", f"{scheme} {token}")
    req.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:300]
        raise ReconcileError(f"{method} {url} -> HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise ReconcileError(f"{method} {url} -> {exc.reason}") from exc
    if not body:
        return None
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        return None


def clone_url(name: str) -> str:
    """Authenticated clone URL. The token is needed for the private repos."""
    netloc = urllib.parse.urlsplit(FORGEJO_BASE).netloc
    quoted = urllib.parse.quote(FORGEJO_TOKEN, safe="")
    return f"https://{FORGEJO_USER}:{quoted}@{netloc}/{FORGEJO_OWNER}/{name}.git"


def list_remote_repos() -> dict[str, str]:
    """Return ``{repo_name: default_branch}`` for every repo in the Corpus.

    The filter here is the whole Corpus rule: owned by us, non-archived and
    non-empty. An empty repo has no commits, so there is nothing to index and
    ``repowise init`` would only skip it.

    Uses ``/repos/search`` rather than ``/users/{owner}/repos`` because the
    latter demands the ``read:user`` scope, and search is satisfied by
    ``read:repository`` alone. Search can also return repos we merely
    collaborate on, hence the explicit owner check.
    """
    repos: dict[str, str] = {}
    page = 1
    per_page = 50
    while True:
        query = urllib.parse.urlencode({"limit": per_page, "page": page})
        payload = api_request(
            "GET",
            f"{FORGEJO_BASE}/api/v1/repos/search?{query}",
            token=FORGEJO_TOKEN,
            timeout=60,
        )
        if not isinstance(payload, dict):
            raise ReconcileError("unexpected response shape from Forgejo search")
        batch = payload.get("data") or []
        if not batch:
            break
        for repo in batch:
            if (repo.get("owner") or {}).get("login") != FORGEJO_OWNER:
                continue
            if repo.get("archived") or repo.get("empty"):
                continue
            repos[repo["name"]] = repo.get("default_branch") or "master"
        if len(batch) < per_page:
            break
        page += 1
    if not repos:
        # A transient auth or network failure must never be read as "every repo
        # was deleted" — that would prune the whole volume.
        raise ReconcileError("Forgejo returned no usable repos — refusing to prune")
    return repos


def local_repos() -> set[str]:
    """Directories on the volume that are git clones."""
    if not WORKSPACE.is_dir():
        return set()
    return {
        child.name
        for child in WORKSPACE.iterdir()
        if child.is_dir() and (child / ".git").exists()
    }


def remote_head(repo_dir: Path, branch: str) -> str | None:
    """The upstream commit for *branch*, without transferring objects."""
    proc = run(["git", "ls-remote", "origin", f"refs/heads/{branch}"], cwd=repo_dir, timeout=120)
    line = proc.stdout.strip()
    return line.split()[0] if line else None


def local_head(repo_dir: Path) -> str | None:
    proc = run(["git", "rev-parse", "HEAD"], cwd=repo_dir, timeout=60, check=False)
    return proc.stdout.strip() if proc.returncode == 0 else None


def clone(name: str, branch: str) -> None:
    target = WORKSPACE / name
    log.info("cloning %s (%s)", name, branch)
    staging = WORKSPACE / f".{name}.cloning"
    if staging.exists():
        shutil.rmtree(staging, ignore_errors=True)
    # Clone to a staging path and move into place, so an interrupted clone
    # never leaves a half-populated directory that later passes mistake for
    # a healthy repo.
    run(["git", "clone", "--branch", branch, clone_url(name), str(staging)], timeout=1800)
    staging.rename(target)


def update(name: str, branch: str) -> bool:
    """Fast-forward a clone to upstream. True when the commit changed."""
    repo_dir = WORKSPACE / name
    before = local_head(repo_dir)
    upstream = remote_head(repo_dir, branch)
    if upstream is None:
        raise ReconcileError(f"{name}: branch {branch} vanished upstream")
    if upstream == before:
        return False
    log.info("%s: %s -> %s", name, (before or "?")[:8], upstream[:8])
    run(["git", "fetch", "origin", branch, "--tags", "--prune"], cwd=repo_dir, timeout=1800)
    # reset --hard, not merge: the clone is a read-only mirror of upstream and
    # must never acquire local state that could make a later fetch conflict.
    run(["git", "reset", "--hard", f"origin/{branch}"], cwd=repo_dir, timeout=300)
    return True


def drop(name: str) -> None:
    """Remove a clone whose repo is gone, archived, or emptied upstream."""
    log.info("dropping %s (no longer in the Corpus)", name)
    if workspace_exists():
        run(["repowise", "workspace", "remove", name], cwd=WORKSPACE, check=False, timeout=300)
    shutil.rmtree(WORKSPACE / name, ignore_errors=True)


def workspace_exists() -> bool:
    return (WORKSPACE / WORKSPACE_CONFIG).is_file()


def bootstrap() -> None:
    """First-ever index build over every clone.

    Long and CPU-bound. Resumable: a restart re-enters with --resume and
    picks up from the last checkpoint rather than starting over. The Kuma
    heartbeat stays silent until this finishes, which is the correct signal —
    the Corpus genuinely is not serving yet.
    """
    marker = WORKSPACE / BOOTSTRAP_MARKER
    cmd = [
        "repowise", "init", ".",
        "--all",          # index every detected repo, no prompting
        "--yes",          # skip the cost confirmation
        "--index-only",   # deterministic: no model calls
        "--embedder", "mock",
        "--no-claude-md",  # these are throwaway mirrors; do not write into them
        "--no-cost-tracking",
    ]
    for pattern in EXCLUDES:
        cmd += ["-x", pattern]
    if marker.exists():
        cmd.append("--resume")
        log.info("resuming a previous bootstrap attempt")
    marker.write_text(str(int(time.time())))
    log.info("bootstrapping the Corpus — this takes a while on first run")
    run(cmd, cwd=WORKSPACE, timeout=21600)
    log.info("bootstrap complete")


def register(name: str) -> None:
    """Index a newly-arrived repo and add it to the workspace config.

    ``--no-docs`` is explicit rather than relying on the default: docs default
    to ON whenever a provider looks configured, and a stray provider env var
    should not be able to turn a reconcile pass into LLM calls.
    """
    log.info("registering %s in the workspace", name)
    run(
        [
            "repowise", "workspace", "add", str(WORKSPACE / name),
            "--alias", name,
            "--index",
            "--no-docs",
        ],
        cwd=WORKSPACE,
        timeout=3600,
    )


def trigger_reindex() -> None:
    """Ask the API to reindex every stale repo.

    repowise never fetches, so without this the index would only catch up on
    the server's own 15-minute poll. One workspace-wide call covers every
    repo that moved, and reuses the same job machinery as a per-repo sync.
    """
    log.info("triggering reindex of stale repos")
    api_request("POST", "/api/workspace/sync", token=API_KEY, scheme="Bearer")


def heartbeat(ok: bool, message: str) -> None:
    """Tell Uptime Kuma the pass finished. Silence is what raises the alarm."""
    if not KUMA_PUSH_URL:
        return
    query = urllib.parse.urlencode({"status": "up" if ok else "down", "msg": message})
    try:
        with urllib.request.urlopen(f"{KUMA_PUSH_URL}?{query}", timeout=30):
            pass
    except (urllib.error.URLError, OSError) as exc:
        # A monitoring failure must never take down the thing being monitored.
        log.warning("heartbeat push failed: %s", exc)


def reconcile() -> str:
    """One full pass. Returns a short status message for the heartbeat."""
    WORKSPACE.mkdir(parents=True, exist_ok=True)
    remote = list_remote_repos()
    local = local_repos()

    for name in sorted(local - remote.keys()):
        drop(name)

    fresh: list[str] = []
    for name in sorted(remote.keys() - local):
        clone(name, remote[name])
        fresh.append(name)

    if not workspace_exists():
        bootstrap()
        return f"bootstrapped {len(remote)} repos"

    for name in fresh:
        register(name)

    moved = 0
    failed: list[str] = []
    for name in sorted(remote.keys() & local):
        try:
            if update(name, remote[name]):
                moved += 1
        except (ReconcileError, subprocess.TimeoutExpired) as exc:
            # One unhealthy repo must not stall the other 41.
            log.error("%s: %s", name, exc)
            failed.append(name)

    # Unconditional, not just when something moved. The endpoint fans out to
    # every repo that is stale *or unindexed*, and skips the rest, so calling it
    # each pass is cheap and it repairs the one state a moved-HEAD check would
    # miss: a bootstrap interrupted after the workspace config was written but
    # before every repo was indexed. `workspace_exists()` is true by then, so no
    # later pass would call bootstrap() again, and those repos would otherwise
    # stay unindexed indefinitely.
    trigger_reindex()

    unindexed = [
        name
        for name in sorted(remote.keys() & local)
        if not (WORKSPACE / name / ".repowise" / "wiki.db").exists()
    ]

    status = f"{len(remote)} repos, {moved} updated, {len(fresh)} added"
    if unindexed:
        status += f", {len(unindexed)} awaiting first index"
    if failed:
        raise ReconcileError(f"{status}; failed: {', '.join(failed)}")
    return status


def main() -> int:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(message)s",
        stream=sys.stdout,
    )
    if not FORGEJO_TOKEN:
        log.error("FORGEJO_TOKEN is empty — cannot reach the Corpus")
        return 1

    # The clones are owned by this uid, but a volume restored from a snapshot
    # or written by an earlier image may not be. git refuses to operate on a
    # tree it considers foreign, which would look like a mass repo failure.
    run(["git", "config", "--global", "--add", "safe.directory", "*"], check=False)

    while True:
        started = time.monotonic()
        try:
            status = reconcile()
            log.info("pass complete: %s", status)
            heartbeat(True, status)
        except (ReconcileError, subprocess.TimeoutExpired) as exc:
            log.error("pass failed: %s", exc)
            heartbeat(False, str(exc)[:200])
        except Exception:  # noqa: BLE001 - the loop must outlive any surprise
            log.exception("pass failed unexpectedly")
            heartbeat(False, "unexpected error, see logs")

        elapsed = time.monotonic() - started
        sleep_for = max(60.0, INTERVAL - elapsed)
        log.info("next pass in %ds", int(sleep_for))
        time.sleep(sleep_for)


if __name__ == "__main__":
    sys.exit(main())
