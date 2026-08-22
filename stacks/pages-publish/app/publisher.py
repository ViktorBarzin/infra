"""Render + git publish pipeline.

Every function that can touch the filesystem or shell out is small and behind
the single ``_run`` subprocess seam so tests can stub git/render without a
network or a real repo. The security-critical invariant lives in
``sanitize_slug`` + ``target_subdir`` + the realpath assertion in ``publish``:
the service is structurally incapable of writing outside ``<repo>/pages/<user>/``
or ``<repo>/pages/shared/``.
"""

from __future__ import annotations

import logging
import os
import re
import subprocess
import tempfile

from .config import Config

log = logging.getLogger(__name__)

STATUSES = ("draft", "approved", "executing", "done")
PAGES_PREFIX = "pages"

# How many times publish() will re-sync + re-render + re-push when another
# publish lands on master first.
DEFAULT_ATTEMPTS = 5

# Slug charset. NOTE: '.' is allowed, so '..' matches this class — the explicit
# '..' check in sanitize_slug is what blocks parent traversal, not the regex.
_SLUG_RE = re.compile(r"[0-9A-Za-z._-]+")


class PublishError(Exception):
    """Bad client input — maps to HTTP 400."""


class RenderError(RuntimeError):
    """render.py or a git op failed — maps to HTTP 500."""


def sanitize_slug(filename: str) -> str:
    """Reduce a client filename to a safe slug, or reject it.

    Strip one trailing ``.md``, then require ``^[0-9A-Za-z._-]+$`` with no
    ``..``. A path-bearing name (``../x``, ``a/b``, ``/etc/passwd``) is
    REJECTED outright rather than silently basenamed to its leaf — the charset
    forbids ``/`` and ``\\``, so any accepted value is inherently path-free, and
    ``os.path.basename`` of it is itself. This is the only request value that
    ever reaches a path.
    """
    candidate = filename or ""
    if candidate.endswith(".md"):
        candidate = candidate[:-3]
    if (
        not candidate
        or candidate in (".", "..")
        or ".." in candidate
        or not _SLUG_RE.fullmatch(candidate)
        or os.path.basename(candidate) != candidate  # belt-and-suspenders
    ):
        raise PublishError(
            f"invalid filename {filename!r}: send a bare slug matching "
            "[0-9A-Za-z._-] with no path separators or '..'"
        )
    return candidate


def validate_status(status: str) -> str:
    if status not in STATUSES:
        raise PublishError(f"status must be one of {STATUSES}, got {status!r}")
    return status


def target_subdir(user: str, shared: bool) -> str:
    """Repo-relative target dir with a HARDCODED ``pages/`` prefix.

    The second segment is the literal ``shared`` or the RESOLVED user (from the
    token, never request input). The user was already charset-validated at
    config load; re-checked here as defense in depth.
    """
    segment = "shared" if shared else user
    if segment != "shared" and (".." in segment or not _SLUG_RE.fullmatch(segment)):
        raise PublishError(f"unsafe target segment {segment!r}")
    return f"{PAGES_PREFIX}/{segment}"


def _run(cmd: list[str], *, cwd: str | None = None, env: dict | None = None):
    """The single subprocess seam. Tests monkeypatch this."""
    return subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True)


def _git_env(cfg: Config, author: str | None = None) -> dict[str, str]:
    """Base git env: pin ssh + committer identity; set author when committing.

    Author != committer is expressed via GIT_AUTHOR_* (per-request user) while
    the committer stays the service identity from GIT_COMMITTER_*.
    """
    env = dict(os.environ)
    env["GIT_SSH_COMMAND"] = cfg.git_ssh_command
    env["GIT_COMMITTER_NAME"] = cfg.committer_name
    env["GIT_COMMITTER_EMAIL"] = cfg.committer_email
    if author is not None:
        env["GIT_AUTHOR_NAME"] = author
        env["GIT_AUTHOR_EMAIL"] = f"{author}@{cfg.author_email_domain}"
    return env


def ensure_repo(cfg: Config) -> None:
    """Clone the monorepo on first run and set the committer identity.

    Idempotent: a no-op when ``<repo>/.git`` already exists. The full clone (no
    --depth) keeps rebase-on-conflict reliable during concurrent publishes.
    """
    if not os.path.isdir(os.path.join(cfg.repo_dir, ".git")):
        parent = os.path.dirname(cfg.repo_dir.rstrip("/")) or "/"
        os.makedirs(parent, exist_ok=True)
        p = _run(["git", "clone", cfg.repo_url, cfg.repo_dir], env=_git_env(cfg))
        if p.returncode != 0:
            raise RenderError(f"git clone failed: {p.stderr.strip()}")
    _run(["git", "-C", cfg.repo_dir, "config", "user.name", cfg.committer_name])
    _run(["git", "-C", cfg.repo_dir, "config", "user.email", cfg.committer_email])


def render_page(cfg: Config, md_path: str, abs_target_dir: str, status: str) -> str:
    """Invoke the monorepo renderer; return the absolute path it emitted.

    render.py prints the written page path on stdout (``<date>-<slug>.html``,
    or a reused page) and regenerates that dir's index.html — the emitted path
    is authoritative for the served URL, so we read it back rather than guess.
    """
    cmd = [
        cfg.python_bin,
        cfg.render_script,
        md_path,
        cfg.render_dir_flag,
        abs_target_dir,
        "--status",
        status,
    ]
    p = _run(cmd)
    if p.returncode != 0:
        raise RenderError(f"render.py failed: {p.stderr.strip()}")
    lines = [ln.strip() for ln in p.stdout.splitlines() if ln.strip()]
    if not lines:
        raise RenderError("render.py produced no output path")
    return lines[-1]


def sync_to_master(cfg: Config) -> None:
    """Put the clone on current ``origin/master``, discarding local state.

    Called before every render attempt, which is what makes a lost push race
    recoverable without merging anything: a page is a pure function of its
    markdown, so re-rendering on top of fresh master reproduces the same bytes.

    **This deliberately never rebases.** The previous implementation answered a
    non-fast-forward push with ``git pull --rebase``; when that rebase hit a
    conflict — and it reliably did, because every publish regenerates
    ``pages/<user>/index.html`` — it stopped mid-rebase, leaving
    ``.git/rebase-merge`` behind and HEAD detached. Every later publish then
    failed on "there is already a rebase-merge directory", so ONE conflicting
    race returned HTTP 500 for **every** user until the pod was replaced
    (2026-08-17: 10 unpushed commits stranded in a pod's emptyDir). Any stale
    rebase/merge found here is abandoned rather than inherited, so a pod that
    somehow reaches that state heals itself on the next request.
    """
    env = _git_env(cfg)
    git_dir = os.path.join(cfg.repo_dir, ".git")
    for state in ("rebase-merge", "rebase-apply"):
        if os.path.isdir(os.path.join(git_dir, state)):
            log.warning("abandoning interrupted rebase in %s", cfg.repo_dir)
            _run(["git", "-C", cfg.repo_dir, "rebase", "--abort"], env=env)
    if os.path.exists(os.path.join(git_dir, "MERGE_HEAD")):
        log.warning("abandoning interrupted merge in %s", cfg.repo_dir)
        _run(["git", "-C", cfg.repo_dir, "merge", "--abort"], env=env)

    fetch = _run(["git", "-C", cfg.repo_dir, "fetch", "origin", "master"], env=env)
    if fetch.returncode != 0:
        log.error("git fetch failed: %s", fetch.stderr.strip())
        raise RenderError(f"git fetch failed: {fetch.stderr.strip()}")

    # FETCH_HEAD rather than origin/master: a plain `git fetch origin master`
    # always writes FETCH_HEAD, whatever the remote-tracking refspec does.
    reset = _run(
        ["git", "-C", cfg.repo_dir, "reset", "--hard", "FETCH_HEAD"], env=env
    )
    if reset.returncode != 0:
        log.error("git reset failed: %s", reset.stderr.strip())
        raise RenderError(f"git reset failed: {reset.stderr.strip()}")

    # Land on a real branch. Nothing here needs one (`push HEAD:master` works
    # detached), but a detached HEAD is exactly what made the wedged clone hard
    # to read, so keep the checkout self-describing.
    checkout = _run(
        ["git", "-C", cfg.repo_dir, "checkout", "-B", "master", "FETCH_HEAD"], env=env
    )
    if checkout.returncode != 0:
        log.error("git checkout failed: %s", checkout.stderr.strip())
        raise RenderError(f"git checkout failed: {checkout.stderr.strip()}")


def stage_and_commit(
    cfg: Config, subdir: str, slug: str, user: str, status: str
) -> bool:
    """Stage the target dir and commit as ``user``. False = nothing to commit.

    Staging is scoped to the target dir (new page + regenerated index) — never
    ``git add -A`` — and so is the emptiness check, so an unrelated change
    elsewhere in the clone can never read as "this page changed".
    """
    env = _git_env(cfg, author=user)
    add = _run(["git", "-C", cfg.repo_dir, "add", "--", f"{subdir}/"], env=env)
    if add.returncode != 0:
        log.error("git add failed: %s", add.stderr.strip())
        raise RenderError(f"git add failed: {add.stderr.strip()}")

    st = _run(
        ["git", "-C", cfg.repo_dir, "status", "--porcelain", "--", f"{subdir}/"],
        env=env,
    )
    if not st.stdout.strip():
        return False  # identical content already on master — nothing to publish

    msg = f"pages: publish {slug} for {user} ({status})"
    commit = _run(["git", "-C", cfg.repo_dir, "commit", "-m", msg], env=env)
    if commit.returncode != 0:
        log.error("git commit failed: %s", commit.stderr.strip())
        raise RenderError(f"git commit failed: {commit.stderr.strip()}")
    return True


def push_to_master(cfg: Config, user: str) -> tuple[bool, str]:
    """One push attempt. ``(False, stderr)`` on rejection — never raises.

    A rejection is an ordinary lost race, not an error: the caller re-syncs and
    re-renders. Only genuinely broken git state raises, from the other seams.
    """
    env = _git_env(cfg, author=user)
    push = _run(["git", "-C", cfg.repo_dir, "push", "origin", "HEAD:master"], env=env)
    if push.returncode == 0:
        return True, ""
    return False, push.stderr.strip()


def derive_url(cfg: Config, out_path: str, shared: bool) -> str:
    """Served URL for an emitted page.

    Caddy roots each user at their own dir, so a per-user page is served at
    ``<base>/<file>``; shared pages live one level down at ``<base>/shared/<file>``.
    """
    fname = os.path.basename(out_path)
    return f"{cfg.base_url}/shared/{fname}" if shared else f"{cfg.base_url}/{fname}"


def publish(
    cfg: Config,
    *,
    user: str,
    content: str,
    filename: str,
    status: str = "draft",
    shared: bool = False,
    attempts: int = DEFAULT_ATTEMPTS,
) -> dict[str, str]:
    """Full pipeline: validate -> (sync -> render -> commit -> push). url + path.

    ``user`` is the token-resolved identity; callers must never pass a
    request-body value here.

    Each attempt starts by landing on current master (``sync_to_master``) and
    then renders, so a push that loses a race is retried by regenerating the
    page against the master that won — no merge, no rebase, nothing to
    conflict. Rendering has to come *after* the sync in every attempt: the
    renderer rebuilds ``index.html`` from the files it finds on disk, so
    rendering against a stale checkout would publish an index missing whatever
    landed meanwhile.
    """
    slug = sanitize_slug(filename)
    status = validate_status(status)
    subdir = target_subdir(user, shared)
    abs_target = os.path.join(cfg.repo_dir, subdir)

    # Structural guarantee: the resolved write dir stays inside <repo>/pages/.
    pages_root = os.path.realpath(os.path.join(cfg.repo_dir, PAGES_PREFIX))
    resolved = os.path.realpath(abs_target)
    if resolved != pages_root and not resolved.startswith(pages_root + os.sep):
        raise PublishError("computed target escapes the pages/ root")

    ensure_repo(cfg)

    with tempfile.TemporaryDirectory() as td:
        md_path = os.path.join(td, f"{slug}.md")
        with open(md_path, "w", encoding="utf-8") as f:
            f.write(content)

        last_err = ""
        for attempt in range(1, attempts + 1):
            sync_to_master(cfg)
            os.makedirs(abs_target, exist_ok=True)
            out_path = render_page(cfg, md_path, abs_target, status)
            result = {
                "url": derive_url(cfg, out_path, shared),
                "path": os.path.relpath(out_path, cfg.repo_dir),
            }

            if not stage_and_commit(cfg, subdir, slug, user, status):
                log.info("publish %s for %s: already current, nothing to push", slug, user)
                return result

            pushed, err = push_to_master(cfg, user)
            if pushed:
                log.info("published %s for %s (%s) -> %s", slug, user, status, result["url"])
                return result

            last_err = err
            log.warning(
                "push rejected for %s (attempt %d/%d), re-rendering onto master: %s",
                slug,
                attempt,
                attempts,
                err,
            )

    log.error("publish %s for %s failed after %d attempts: %s", slug, user, attempts, last_err)
    raise RenderError(f"git push failed after {attempts} attempts: {last_err}")
