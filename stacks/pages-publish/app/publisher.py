"""Render + git publish pipeline.

Every function that can touch the filesystem or shell out is small and behind
the single ``_run`` subprocess seam so tests can stub git/render without a
network or a real repo. The security-critical invariant lives in
``sanitize_slug`` + ``target_subdir`` + the realpath assertion in ``publish``:
the service is structurally incapable of writing outside ``<repo>/pages/<user>/``
or ``<repo>/pages/shared/``.
"""

from __future__ import annotations

import base64
import binascii
import logging
import os
import re
import shutil
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

# Every asset a rendered page can reference, as it appears in the HTML. The
# charset has no '/' so a match is always a bare filename inside pages/assets/,
# which is what keeps the preview from serving an arbitrary repo file.
_ASSET_REF_RE = re.compile(r"/assets/([0-9A-Za-z._-]+)")

# Assets are text (css/js). A preview of a page with a mermaid diagram carries
# mermaid.min.js, ~3.5 MB, so the ceiling is well above that and still bounded.
MAX_ASSET_BYTES = 8 * 1024 * 1024


# /publish-bundle limits. The showcase site is a handful of text files plus one
# OpenGraph PNG; these leave room for growth while bounding one request.
MAX_BUNDLE_FILES = 200
MAX_BUNDLE_BYTES = 20 * 1024 * 1024
MAX_BUNDLE_DEPTH = 3  # path segments, so "a/b/file" at most
BUNDLE_ENCODINGS = ("utf-8", "base64")

# Second-level dirs under pages/ that belong to the site itself, not to a
# bundle owner.
_RESERVED_SEGMENTS = ("shared", "assets", "tools")


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


def collect_assets(cfg: Config, html: str) -> dict[str, str]:
    """Read the ``/assets/<name>`` files a rendered page links, keyed by path.

    Only names the page actually references are read, so a page with no diagram
    does not carry mermaid.min.js. A missing or oversized asset is skipped
    rather than raised: a preview is for looking at, and one absent stylesheet
    is a worse reason to fail than an unstyled page is to return.
    """
    assets: dict[str, str] = {}
    root = os.path.realpath(os.path.join(cfg.repo_dir, PAGES_PREFIX, "assets"))
    for name in sorted(set(_ASSET_REF_RE.findall(html))):
        path = os.path.realpath(os.path.join(root, name))
        if path != root and not path.startswith(root + os.sep):
            continue  # unreachable given the charset; kept as the explicit gate
        try:
            if os.path.getsize(path) > MAX_ASSET_BYTES:
                log.warning("preview: skipping oversized asset %s", name)
                continue
            with open(path, encoding="utf-8") as f:
                assets[f"assets/{name}"] = f.read()
        except OSError as e:
            log.warning("preview: skipping unreadable asset %s: %s", name, e)
    return assets


def render_preview(
    cfg: Config,
    *,
    user: str,
    content: str,
    filename: str,
    status: str = "draft",
    shared: bool = False,
) -> dict:
    """Render a doc and hand back the bytes, without committing or pushing.

    Same validation and the same renderer as :func:`publish`, so what comes
    back is what publishing would put on the site. ``shared`` is accepted so a
    caller can preview with the exact flags it will publish with; it changes
    where a page LANDS, not how it renders, so it is validated and then unused.

    Rendering goes to a throwaway directory rather than into the clone. An
    untracked page left behind in ``pages/<user>/`` would be swept up by the
    next publish's ``git add -- pages/<user>/`` and pushed as part of somebody
    else's page, which is a far worse failure than a preview whose generated
    index.html lists only the one page nobody is looking at.
    """
    slug = sanitize_slug(filename)
    status = validate_status(status)
    target_subdir(user, shared)  # validation parity with publish()

    ensure_repo(cfg)
    # The renderer and the stylesheet both live in the clone, so a preview of
    # current master is only truthful after a sync.
    sync_to_master(cfg)

    with tempfile.TemporaryDirectory() as td:
        md_path = os.path.join(td, f"{slug}.md")
        with open(md_path, "w", encoding="utf-8") as f:
            f.write(content)
        out_dir = os.path.join(td, "out")
        os.makedirs(out_dir, exist_ok=True)
        out_path = render_page(cfg, md_path, out_dir, status)
        with open(out_path, encoding="utf-8") as f:
            html = f.read()

    log.info("previewed %s for %s (%s), no push", slug, user, status)
    return {
        "filename": os.path.basename(out_path),
        "html": html,
        "assets": collect_assets(cfg, html),
    }


# ---- bundles: raw multi-file publish into pages/<user>/<slug>/ -------------


def _check_bundle_path(path: str) -> list[str]:
    """Split a bundle file path into safe segments, or reject it.

    Every segment must match the slug charset, contain no ``..`` and not start
    with ``.`` (which rules out ``.git`` and other dotfiles git or Caddy would
    treat specially). Empty segments catch a leading ``/``, ``a//b`` and a
    trailing ``/``.
    """
    segments = path.split("/")
    if len(segments) > MAX_BUNDLE_DEPTH or any(
        not seg
        or seg.startswith(".")
        or ".." in seg
        or not _SLUG_RE.fullmatch(seg)
        for seg in segments
    ):
        raise PublishError(
            f"invalid bundle path {path!r}: use up to {MAX_BUNDLE_DEPTH} "
            "'/'-separated segments of [0-9A-Za-z._-], none starting with '.'"
        )
    return segments


def validate_bundle_files(files: list[dict]) -> list[tuple[str, bytes]]:
    """Check and decode a bundle's files into ``[(relative path, bytes)]``.

    Runs before anything touches the clone, so a rejected bundle leaves the
    repo exactly as it was.
    """
    if not files:
        raise PublishError("a bundle needs at least one file")
    if len(files) > MAX_BUNDLE_FILES:
        raise PublishError(f"a bundle holds at most {MAX_BUNDLE_FILES} files")

    out: list[tuple[str, bytes]] = []
    seen: set[str] = set()
    dirs: set[str] = set()
    total = 0
    for f in files:
        path, content = f["path"], f["content"]
        encoding = f.get("encoding", "utf-8")
        segments = _check_bundle_path(path)
        if path in seen:
            raise PublishError(f"duplicate bundle path {path!r}")
        seen.add(path)
        dirs.update("/".join(segments[:i]) for i in range(1, len(segments)))

        if encoding == "utf-8":
            data = content.encode("utf-8")
        elif encoding == "base64":
            try:
                data = base64.b64decode(content, validate=True)
            except (binascii.Error, ValueError) as e:
                raise PublishError(f"invalid base64 for {path!r}: {e}") from e
        else:
            raise PublishError(
                f"encoding for {path!r} must be one of {BUNDLE_ENCODINGS}"
            )
        total += len(data)
        if total > MAX_BUNDLE_BYTES:
            raise PublishError(f"a bundle holds at most {MAX_BUNDLE_BYTES} bytes")
        out.append((path, data))

    clash = seen & dirs
    if clash:
        raise PublishError(f"bundle paths used as both file and directory: {sorted(clash)}")
    return out


def bundle_subdir(user: str, slug: str) -> str:
    """Repo-relative bundle dir, ``pages/<user>/<slug>``, from token-bound values.

    Both segments come from PAGES_BUNDLE_KEYS and were validated at config
    load; re-checked here as defense in depth, plus the site's own dirs.
    """
    for seg in (user, slug):
        if not seg or ".." in seg or not _SLUG_RE.fullmatch(seg):
            raise PublishError(f"unsafe bundle segment {seg!r}")
    if user in _RESERVED_SEGMENTS:
        raise PublishError(f"bundle user {user!r} is a reserved pages/ dir")
    return f"{PAGES_PREFIX}/{user}/{slug}"


def stage_and_commit_bundle(cfg: Config, subdir: str, user: str, slug: str) -> bool:
    """Stage the bundle dir, deletions included, and commit. False = unchanged.

    ``add -A`` is what stages the files a new bundle dropped; the pathspec keeps
    it, and the emptiness check, inside the bundle dir.
    """
    env = _git_env(cfg, author=user)
    add = _run(["git", "-C", cfg.repo_dir, "add", "-A", "--", f"{subdir}/"], env=env)
    if add.returncode != 0:
        log.error("git add failed: %s", add.stderr.strip())
        raise RenderError(f"git add failed: {add.stderr.strip()}")

    st = _run(
        ["git", "-C", cfg.repo_dir, "status", "--porcelain", "--", f"{subdir}/"],
        env=env,
    )
    if not st.stdout.strip():
        return False

    msg = f"pages: publish bundle {user}/{slug}"
    commit = _run(["git", "-C", cfg.repo_dir, "commit", "-m", msg], env=env)
    if commit.returncode != 0:
        log.error("git commit failed: %s", commit.stderr.strip())
        raise RenderError(f"git commit failed: {commit.stderr.strip()}")
    return True


def _write_bundle(cfg: Config, subdir: str, files: list[tuple[str, bytes]]) -> None:
    """Replace ``<repo>/<subdir>`` with exactly ``files``.

    The realpath check runs here, after the sync, because the checkout it
    guards is whatever master just put on disk: a symlink committed anywhere
    on the path would otherwise point the rmtree outside the bundle dir.
    """
    abs_target = os.path.join(cfg.repo_dir, subdir)
    expected = os.path.join(os.path.realpath(cfg.repo_dir), subdir)
    if os.path.realpath(abs_target) != expected:
        raise PublishError("bundle target resolves outside its pages/ dir")

    if os.path.isdir(abs_target):
        shutil.rmtree(abs_target)
    for rel, data in files:
        path = os.path.join(abs_target, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(data)


def publish_bundle(
    cfg: Config,
    *,
    user: str,
    slug: str,
    files: list[dict],
    attempts: int = DEFAULT_ATTEMPTS,
) -> dict:
    """Validate -> (sync -> replace dir -> commit -> push), like :func:`publish`.

    ``user`` and ``slug`` come from the bundle token, never the request body.
    Rewriting the files after every sync is what makes a lost push race safe to
    retry: the bundle is the whole content of its dir, so writing it over the
    master that won gives the same tree with nothing to merge. Nothing is
    rendered; the files are committed as sent.
    """
    decoded = validate_bundle_files(files)
    subdir = bundle_subdir(user, slug)
    result = {
        "url": f"{cfg.base_url}/{slug}/",
        "path": subdir,
        "committed": False,
        "files": len(decoded),
    }

    ensure_repo(cfg)

    last_err = ""
    for attempt in range(1, attempts + 1):
        sync_to_master(cfg)
        _write_bundle(cfg, subdir, decoded)

        if not stage_and_commit_bundle(cfg, subdir, user, slug):
            log.info("bundle %s: already current, nothing to push", subdir)
            return result

        pushed, err = push_to_master(cfg, user)
        if pushed:
            log.info("published bundle %s (%d files) -> %s", subdir, len(decoded), result["url"])
            return {**result, "committed": True}

        last_err = err
        log.warning(
            "push rejected for bundle %s (attempt %d/%d), rewriting onto master: %s",
            subdir,
            attempt,
            attempts,
            err,
        )

    log.error("bundle %s failed after %d attempts: %s", subdir, attempts, last_err)
    raise RenderError(f"git push failed after {attempts} attempts: {last_err}")
