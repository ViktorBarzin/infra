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
import sqlite3
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
# How long to wait on the reindex trigger before assuming the server has it.
TRIGGER_TIMEOUT = int(os.environ.get("REINDEX_TRIGGER_TIMEOUT", "120"))
# A failed pass retries on this shorter delay rather than the full interval —
# an hour is far too long to sit on a transient error.
RETRY_DELAY = int(os.environ.get("SYNC_RETRY_SECONDS", "300"))
CROSS_REPO_TIMEOUT = int(os.environ.get("CROSS_REPO_TIMEOUT", "1800"))
# How many page-less repos to repair per pass. A full resync is expensive, and
# repairing every one at once would saturate the API for the rest of the hour.
MAX_REPAIRS = int(os.environ.get("MAX_PAGE_REPAIRS", "5"))
KUMA_PUSH_URL = os.environ.get("KUMA_PUSH_URL", "")
# Which repo the dashboard and single-repo MCP queries default to. `repowise
# init --all` picks one on its own and picks the first alphabetically, which
# here is Website — 338 files of png/md/html/svg and no source code, so it
# indexes to nothing and every graph view opens empty. Setting it explicitly
# each pass means a volume rebuild cannot quietly reintroduce that.
DEFAULT_REPO = os.environ.get("REPOWISE_DEFAULT_REPO", "infra")

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
    except TimeoutError as exc:
        # socket.timeout on a slow endpoint; the caller decides if it matters.
        raise ReconcileError(f"{method} {url} -> timed out after {timeout}s") from exc
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
    # --force: a tag that MOVED upstream is rejected by a plain fetch with
    # "would clobber existing tag" and git exits 1, which marked the whole
    # reconcile pass failed even though the branch fetched cleanly. Observed
    # 2026-08-31 on terminal-lobby (tags v-vanilla-final and v0.1.0 re-pointed):
    # the pass reported "42 repos, 0 updated, 0 added; failed: terminal-lobby"
    # every 5 minutes and the Uptime-Kuma push monitor stayed DOWN, while
    # `* branch master -> FETCH_HEAD` succeeded on the same run. Forcing is the
    # right call for the same reason the reset below is: this clone is a mirror
    # of upstream, so upstream's tag placement wins, always.
    run(["git", "fetch", "origin", branch, "--tags", "--prune", "--force"], cwd=repo_dir, timeout=1800)
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


def set_default_repo(alias: str) -> None:
    """Point the workspace at *alias* as its default repo, if it is not already.

    Idempotent and best-effort: a failure here leaves a usable Corpus with a
    poor landing page, which is not worth failing a pass over.
    """
    config = WORKSPACE / WORKSPACE_CONFIG
    try:
        current = ""
        for line in config.read_text().splitlines():
            if line.startswith("default_repo:"):
                current = line.split(":", 1)[1].strip()
                break
        if current == alias:
            return
        # Match against declared aliases, not directory names: aliases are
        # lower-cased, so a dir check would reject e.g. Website/website.
        aliases = [
            line.split(":", 1)[1].strip()
            for line in config.read_text().splitlines()
            if line.strip().startswith("alias:")
        ]
        if alias not in aliases:
            log.warning("default repo %r is not in the Corpus; leaving %r", alias, current)
            return
        log.info("setting default repo: %s -> %s", current or "(unset)", alias)
        run(["repowise", "workspace", "set-default", alias], cwd=WORKSPACE, timeout=300)
    except (ReconcileError, OSError) as exc:
        log.warning("could not set default repo to %r: %s", alias, exc)


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
    """Ask the API to reindex every stale or unindexed repo.

    repowise never fetches, so without this the index would only catch up on
    the server's own 15-minute poll. One workspace-wide call covers every repo
    that moved, and reuses the same job machinery as a per-repo sync.

    The call is bounded and a timeout is not an error. Observed on the first
    catch-up run: with dozens of repos to index the endpoint holds the
    connection open far longer than any per-pass budget, and waiting on it
    would stop the loop from finishing a pass, heartbeating, or ever fetching
    again. This function's responsibility ends at having asked; the server
    keeps indexing on its own, and the next pass asks again for whatever is
    still outstanding.
    """
    log.info("triggering reindex of stale repos")
    try:
        api_request(
            "POST",
            "/api/workspace/sync",
            token=API_KEY,
            scheme="Bearer",
            timeout=TRIGGER_TIMEOUT,
        )
    except ReconcileError as exc:
        if "timed out" in str(exc).lower() or "timeout" in str(exc).lower():
            log.info("reindex accepted; server still working (%s)", exc)
            return
        raise


def repos_missing_pages(names: list[str]) -> list[tuple[str, str]]:
    """Repos that indexed symbols but rendered no wiki pages: ``(name, repo_id)``.

    Indexing a repo and rendering its deterministic wiki are separate phases, and
    only the full pipeline does both. A repo indexed by the API's incremental
    sync — which is what happens when a bootstrap is interrupted part-way — ends
    up with a populated graph and an empty Documentation tab, and nothing
    afterwards notices. Observed on 10 of 42 repos after this stack's first
    rollout, including one with 1,851 symbols and no pages at all.

    Deliberately narrow: symbols present AND pages exactly zero. A repo that is
    simply small, or has genuinely few documentable files, is left alone.
    """
    out: list[tuple[str, str]] = []
    for name in names:
        db = WORKSPACE / name / ".repowise" / "wiki.db"
        if not db.is_file():
            continue
        try:
            conn = sqlite3.connect(f"file:{db.as_posix()}?mode=ro", uri=True)
            try:
                row = conn.execute("SELECT id FROM repositories LIMIT 1").fetchone()
                symbols = conn.execute("SELECT COUNT(*) FROM wiki_symbols").fetchone()[0]
                pages = conn.execute("SELECT COUNT(*) FROM wiki_pages").fetchone()[0]
            finally:
                conn.close()
        except sqlite3.Error:
            continue
        if row and symbols and not pages:
            out.append((name, row[0]))
    return out


def repair_missing_pages(names: list[str]) -> int:
    """Full-resync repos whose wiki never rendered. Returns how many were asked.

    A full resync is what re-runs the whole pipeline, including deterministic
    page rendering; an incremental sync will not backfill them. Capped per pass,
    and each request is fire-and-forget — the server queues the work.
    """
    missing = repos_missing_pages(names)
    if not missing:
        return 0
    batch = missing[:MAX_REPAIRS]
    log.info(
        "%d repo(s) indexed with no wiki pages; repairing %d this pass: %s",
        len(missing), len(batch), ", ".join(n for n, _ in batch),
    )
    asked = 0
    for name, repo_id in batch:
        try:
            api_request(
                "POST",
                f"/api/repos/{repo_id}/full-resync",
                token=API_KEY,
                scheme="Bearer",
                timeout=TRIGGER_TIMEOUT,
            )
            asked += 1
        except ReconcileError as exc:
            if "timed out" in str(exc).lower():
                asked += 1  # queued; the server carries on
            else:
                log.warning("could not repair %s: %s", name, exc)
    return asked


def build_cross_repo_layer() -> str:
    """Rebuild the workspace-level layer: co-changes, contracts, system graph.

    Separate from the per-repo reindex the API runs, and not reachable from it —
    those hooks only live on the CLI's workspace-update path. Without this the
    System Map, Contracts and Co-Changes views stay empty however well each
    individual repo is indexed.

    Note the refresh semantics: the API reads these artefacts into memory once at
    startup and cannot reload them, so rebuilding here keeps the files current
    for the next restart (and for the initContainer that runs the same script).
    Failure is not fatal — a stale cross-repo layer beside a healthy per-repo
    index is worth reporting, not worth failing a pass over.
    """
    try:
        proc = run(
            ["python3", "/opt/repowise/cross_repo.py"],
            cwd=WORKSPACE,
            timeout=CROSS_REPO_TIMEOUT,
            check=False,
        )
        if proc.returncode != 0:
            log.warning("cross-repo build exited %s", proc.returncode)
            return "cross-repo failed"
        for line in reversed((proc.stdout or "").splitlines()):
            if "cross-repo layer built" in line:
                return line.split("cross-repo layer built:", 1)[1].strip()
        return "cross-repo rebuilt"
    except (ReconcileError, subprocess.TimeoutExpired) as exc:
        log.warning("cross-repo build did not finish: %s", exc)
        return "cross-repo timed out"


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


def wait_for_api(timeout: int = 300) -> bool:
    """Block until the API answers /health, or give up after *timeout*.

    The containers in this pod start together, and the sync loop reaches its
    first reindex trigger within seconds — well before uvicorn is listening.
    Without this the first pass dies on a connection refusal and then waits out
    a whole interval before trying again. /health needs no bearer.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            api_request("GET", "/health", token="", timeout=10)
            return True
        except ReconcileError:
            time.sleep(3)
    log.warning("API did not become ready within %ds; continuing anyway", timeout)
    return False


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
        set_default_repo(DEFAULT_REPO)
        return f"bootstrapped {len(remote)} repos"

    set_default_repo(DEFAULT_REPO)

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

    repaired = repair_missing_pages(sorted(remote.keys() & local))

    cross = build_cross_repo_layer()

    status = f"{len(remote)} repos, {moved} updated, {len(fresh)} added"
    if unindexed:
        status += f", {len(unindexed)} awaiting first index"
    if repaired:
        status += f", {repaired} wiki repair(s) queued"
    status += f"; {cross}"
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

    wait_for_api()

    while True:
        started = time.monotonic()
        ok = True
        try:
            status = reconcile()
            log.info("pass complete: %s", status)
            heartbeat(True, status)
        except (ReconcileError, subprocess.TimeoutExpired) as exc:
            log.error("pass failed: %s", exc)
            heartbeat(False, str(exc)[:200])
            ok = False
        except Exception:  # noqa: BLE001 - the loop must outlive any surprise
            log.exception("pass failed unexpectedly")
            heartbeat(False, "unexpected error, see logs")
            ok = False

        elapsed = time.monotonic() - started
        budget = INTERVAL if ok else min(RETRY_DELAY, INTERVAL)
        sleep_for = max(60.0, budget - elapsed)
        log.info("next pass in %ds", int(sleep_for))
        time.sleep(sleep_for)


if __name__ == "__main__":
    sys.exit(main())
