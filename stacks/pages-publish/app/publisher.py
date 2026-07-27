"""Render + git publish pipeline.

Every function that can touch the filesystem or shell out is small and behind
the single ``_run`` subprocess seam so tests can stub git/render without a
network or a real repo. The security-critical invariant lives in
``sanitize_slug`` + ``target_subdir`` + the realpath assertion in ``publish``:
the service is structurally incapable of writing outside ``<repo>/pages/<user>/``
or ``<repo>/pages/shared/``.
"""

from __future__ import annotations

import os
import re
import subprocess
import tempfile

from .config import Config

STATUSES = ("draft", "approved", "executing", "done")
PAGES_PREFIX = "pages"

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


def commit_and_push(
    cfg: Config, subdir: str, slug: str, user: str, status: str, *, retries: int = 5
) -> None:
    """Stage the target dir, commit as <user>, push to master with rebase-retry.

    Staging is scoped to the target dir (new page + regenerated index) — never
    ``git add -A``. A clean tree after staging is treated as an idempotent
    no-op. On a non-fast-forward push we ``pull --rebase`` and retry.
    """
    env = _git_env(cfg, author=user)
    add = _run(["git", "-C", cfg.repo_dir, "add", "--", f"{subdir}/"], env=env)
    if add.returncode != 0:
        raise RenderError(f"git add failed: {add.stderr.strip()}")

    st = _run(["git", "-C", cfg.repo_dir, "status", "--porcelain"], env=env)
    if not st.stdout.strip():
        return  # identical content already committed — nothing to publish

    msg = f"pages: publish {slug} for {user} ({status})"
    commit = _run(["git", "-C", cfg.repo_dir, "commit", "-m", msg], env=env)
    if commit.returncode != 0:
        raise RenderError(f"git commit failed: {commit.stderr.strip()}")

    last_err = ""
    for _ in range(retries):
        push = _run(
            ["git", "-C", cfg.repo_dir, "push", "origin", "HEAD:master"], env=env
        )
        if push.returncode == 0:
            return
        last_err = push.stderr.strip()
        pull = _run(
            ["git", "-C", cfg.repo_dir, "pull", "--rebase", "origin", "master"],
            env=env,
        )
        if pull.returncode != 0:
            raise RenderError(f"git pull --rebase failed: {pull.stderr.strip()}")
    raise RenderError(f"git push failed after {retries} attempts: {last_err}")


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
) -> dict[str, str]:
    """Full pipeline: validate -> render -> commit + push. Returns url + path.

    ``user`` is the token-resolved identity; callers must never pass a
    request-body value here.
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
    os.makedirs(abs_target, exist_ok=True)

    with tempfile.TemporaryDirectory() as td:
        md_path = os.path.join(td, f"{slug}.md")
        with open(md_path, "w", encoding="utf-8") as f:
            f.write(content)
        out_path = render_page(cfg, md_path, abs_target, status)

    commit_and_push(cfg, subdir, slug, user, status)
    return {
        "url": derive_url(cfg, out_path, shared),
        "path": os.path.relpath(out_path, cfg.repo_dir),
    }
