"""HTML pages, Bundles and public links for every user (infra ADR-0042).

Design: docs/plans/2026-11-12-pages-rich-content-design.md. Three things live
here, all published with the caller's normal API token and confined to their
own Space (``<user>/``) or ``shared/``:

- **An HTML page**: one ``.html`` file, stored as ``<space>/<date>-<slug>.html``
  with ``plan-*`` meta added so the Space index lists it.
- **A Bundle**: several files, stored as ``<space>/<date>-<slug>/``. Its entry
  is ``index.html``, or ``index.md`` rendered into one. Pages run in a
  sandboxed frame whose requests carry no sign-in cookie, so the Bundle's own
  files are also served at an unguessable **Bundle URL** ``/c/<cap>/``:
  ``c/<cap>`` is a symlink to the Bundle dir, and the marker
  ``<bundle>/.pages-bundle.json`` (users cannot write dotfiles) tells the
  site's shell which cap to frame. The cap rotates on every publish.
- **A public link**: ``p/<token>`` is a symlink into the Space, so the page or
  Bundle is readable at ``/p/<token>/`` without signing in until unshared.

Identity is the source name (decision 8): publishing the same file or
directory name again replaces the same page or Bundle, whatever the day, so
its URL and its public links stay put.
"""

from __future__ import annotations

import datetime
import html
import json
import logging
import os
import re
import secrets
import shutil
import tempfile

from . import publisher
from .config import Config

log = logging.getLogger(__name__)

MAX_FILE_BYTES = 10 * 1024 * 1024
MAX_PUBLISH_BYTES = 25 * 1024 * 1024
# Checked from Content-Length before the body is read: 25 MiB of files is about
# 34 MB once base64-encoded, plus JSON framing.
MAX_REQUEST_BYTES = 40 * 1024 * 1024

# Web files, images, 3D models, fonts and short clips. Anything else (archives,
# executables, office documents) has no business on a page and is refused.
ALLOWED_EXTENSIONS = frozenset(
    """html htm css js mjs json csv tsv txt md svg map wasm xml
    png jpg jpeg gif webp avif ico bmp
    glb gltf bin stl obj mtl ply hdr ktx2 drc riv
    woff woff2 ttf otf
    mp4 webm m4v mov mp3 ogg oga wav m4a vtt
    pdf geojson topojson webmanifest""".split()
)

MARKER = ".pages-bundle.json"
CAP_RE = re.compile(r"^[0-9a-f]{32}$")
DATED_RE = re.compile(r"^(\d{4}-\d{2}-\d{2})-(.+)$")
META_RE = re.compile(r'<meta name="plan-(\w+)" content="([^"]*)"')
PLAN_META_TAG_RE = re.compile(r'<meta name="plan-\w+" content="[^"]*">\n?')
TITLE_RE = re.compile(r"<title[^>]*>(.*?)</title>", re.IGNORECASE | re.DOTALL)
HEAD_RE = re.compile(r"<head(\s[^>]*)?>", re.IGNORECASE)
DOCTYPE_RE = re.compile(r"<!doctype[^>]*>", re.IGNORECASE)

LINKS_DIR = "p"
CAPS_DIR = "c"
# Public link lifetimes: {token: {target, created, ttl, expires}}. A dotfile, so
# Caddy never serves it. Links made before 2026-11-12 have no entry and never
# expire ("new ones only", Viktor).
LINK_REGISTRY = ".links.json"


def today() -> str:
    """Seam for tests."""
    return datetime.date.today().isoformat()


def lifetime(explicit: str | None, prior_exists: bool, prior_ttl: str | None) -> tuple[str, str | None]:
    """``(ttl, expires)`` for something being published or shared now.

    An explicit ttl wins. Otherwise an existing item keeps its own ttl (and
    one from before expiry existed keeps none), and a new one gets 90 days.
    The clock restarts at every publish. ``ttl`` is "" for no expiry.
    """
    ttl = explicit or (prior_ttl or "" if prior_exists else publisher.DEFAULT_TTL)
    if not ttl or ttl == "never":
        return ttl, None
    days = int(ttl[:-1])
    return ttl, (datetime.date.fromisoformat(today()) + datetime.timedelta(days=days)).isoformat()


def new_token() -> str:
    return secrets.token_hex(16)


# ---- input checks ---------------------------------------------------------


def source_name(name: str | None) -> tuple[str, str]:
    """``(source, slug)`` for a client-sent file or directory name.

    The source is the name as sent (it identifies the page across publishes);
    the slug is that name without ``.html``/``.htm``/``.md``, held to the same
    charset as every other path segment the service writes.
    """
    source = (name or "").rstrip("/")
    slug = re.sub(r"\.(html?|md)$", "", source)
    if not slug or slug.startswith("."):
        raise publisher.PublishError(
            "a Bundle needs a name: the file or directory name, in [0-9A-Za-z._-]"
        )
    return source, publisher.sanitize_slug(slug)


def check_files(decoded: list[tuple[str, bytes]]) -> None:
    total = 0
    for path, data in decoded:
        ext = path.rsplit(".", 1)[-1].lower() if "." in os.path.basename(path) else ""
        if ext not in ALLOWED_EXTENSIONS:
            raise publisher.PublishError(
                f"{path!r}: file type not allowed on pages. Allowed: "
                + " ".join(sorted(ALLOWED_EXTENSIONS))
            )
        if len(data) > MAX_FILE_BYTES:
            raise publisher.PublishError(
                f"{path!r} is {len(data)} bytes; one file may be at most "
                f"{MAX_FILE_BYTES // (1024 * 1024)} MiB"
            )
        total += len(data)
    if total > MAX_PUBLISH_BYTES:
        raise publisher.PublishError(
            f"the files add up to {total} bytes; one publish may be at most "
            f"{MAX_PUBLISH_BYTES // (1024 * 1024)} MiB"
        )


def dated(slug: str) -> str:
    return slug if DATED_RE.match(slug) else f"{today()}-{slug}"


def _date_of(name: str) -> str:
    m = DATED_RE.match(name)
    return m.group(1) if m else today()


def _key(source: str) -> str:
    return os.path.basename(html.unescape(source).rstrip("/"))


# ---- what already exists in a Space ---------------------------------------


def _head_meta(path: str) -> dict[str, str]:
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return dict(META_RE.findall(fh.read(4096)))
    except OSError:
        return {}


def read_marker(bundle_dir: str) -> dict:
    try:
        with open(os.path.join(bundle_dir, MARKER), encoding="utf-8") as fh:
            marker = json.load(fh)
    except (OSError, ValueError):
        return {}
    return marker if isinstance(marker, dict) else {}


def find_page(abs_space: str, source: str) -> str | None:
    """The top-level page whose recorded source has this name, newest first."""
    if not os.path.isdir(abs_space):
        return None
    hits = []
    for name in os.listdir(abs_space):
        if not name.endswith(".html") or name == "index.html":
            continue
        meta = _head_meta(os.path.join(abs_space, name))
        if "source" in meta and _key(meta["source"]) == _key(source):
            hits.append((meta.get("date", ""), name))
    return max(hits)[1] if hits else None


def find_bundle(abs_space: str, source: str) -> str | None:
    if not os.path.isdir(abs_space):
        return None
    hits = []
    for name in os.listdir(abs_space):
        d = os.path.join(abs_space, name)
        if os.path.isdir(d) and not os.path.islink(d):
            marker = read_marker(d)
            if marker.get("source") and _key(str(marker["source"])) == _key(source):
                hits.append((str(marker.get("date", "")), name))
    return max(hits)[1] if hits else None


# ---- writing --------------------------------------------------------------


def html_title(text: str) -> str | None:
    m = TITLE_RE.search(text[:65536])
    if not m:
        return None
    title = html.unescape(re.sub(r"\s+", " ", m.group(1))).strip()
    return title or None


# Injected into a published HTML page. The page runs in a sandboxed frame,
# and a navigation the frame starts itself carries no sign-in cookie, so a
# plain link to another page would land on the login redirect inside the
# frame. Links that leave this document open at the top level instead, which
# the sandbox allows on a click (allow-top-navigation-by-user-activation).
TOP_LINKS_SCRIPT = (
    '<script id="pages-top-links">document.addEventListener("click",function(e){'
    'var a=e.target&&e.target.closest?e.target.closest("a[href]"):null;'
    'if(!a||a.target||a.hasAttribute("download"))return;'
    'var u=new URL(a.href,location.href);'
    'if(!/^https?:$/.test(u.protocol))return;'
    'if(u.pathname===location.pathname&&u.search===location.search)return;'
    'a.target="_top"},true)</script>'
)


def free_name(abs_space: str, stem: str, source: str, *, is_dir: bool) -> str:
    """``stem`` (``.html`` for a page), unless another source holds it.

    foo.md and foo.html both map to <date>-foo.html, and a Bundle dir may
    collide with a hand-made one; the second publish took the first's place.
    The same rule lives in render.free_name for markdown.
    """
    for n in range(1, 100):
        name = stem if n == 1 else f"{stem}-{n}"
        path = os.path.join(abs_space, name if is_dir else f"{name}.html")
        if not os.path.lexists(path):
            return name
        if is_dir:
            owner = read_marker(path).get("source")
        else:
            owner = _head_meta(path).get("source")
        if owner and _key(str(owner)) == _key(source):
            return name
    raise publisher.PublishError(f"no free name for {stem!r}")


def inject_meta(
    text: str, *, title: str, status: str, date: str, source: str,
    ttl: str = "", expires: str | None = None,
) -> str:
    """Add the ``plan-*`` meta the Space index reads, replacing any already there.

    The index only reads a page's first 4 KB, so the tags go right after
    ``<head>`` (or after the doctype when there is no head).
    """
    text = PLAN_META_TAG_RE.sub("", text)
    text = re.sub(r'<script id="pages-top-links">.*?</script>', "", text, flags=re.DOTALL)
    esc = lambda v: html.escape(v, quote=True)  # noqa: E731
    tags = (
        f'\n<meta name="plan-title" content="{esc(title)}">'
        f'\n<meta name="plan-status" content="{esc(status)}">'
        f'\n<meta name="plan-date" content="{esc(date)}">'
        f'\n<meta name="plan-source" content="{esc(source)}">'
        + (f'\n<meta name="plan-ttl" content="{esc(ttl)}">' if ttl else "")
        + (f'\n<meta name="plan-expires" content="{esc(expires)}">' if expires else "")
        + f"\n{TOP_LINKS_SCRIPT}\n"
    )
    m = HEAD_RE.search(text, 0, 4096)
    if m is None:
        m = DOCTYPE_RE.search(text, 0, 1024)
    at = m.end() if m else 0
    return text[:at] + tags + text[at:]


def _render(cfg: Config, *args: str) -> str:
    p = publisher._run([cfg.python_bin, cfg.render_script, *args])
    if p.returncode == 3:
        raise publisher.PublishError(p.stderr.strip().removeprefix("error: "))
    if p.returncode != 0:
        raise publisher.RenderError(f"render.py failed: {p.stderr.strip()}")
    return (p.stdout.strip().splitlines() or [""])[-1]


def rebuild_index(cfg: Config, abs_space: str) -> None:
    _render(cfg, "--index-only", cfg.render_dir_flag, abs_space)


def _expect_inside(cfg: Config, rel: str) -> str:
    """``<repo>/<rel>``, refusing anything a committed symlink redirects."""
    path = os.path.join(cfg.repo_dir, rel)
    if os.path.realpath(path) != os.path.join(os.path.realpath(cfg.repo_dir), rel):
        raise publisher.PublishError(f"{rel} resolves outside its place in the repo")
    return path


def _link_target(subdir: str, entry: str, is_bundle: bool) -> tuple[str, str]:
    """``(link path under p/<token>, symlink target)`` for a page or Bundle."""
    if is_bundle:
        return "", f"../{subdir}/{entry}"
    return "index.html", f"../../{subdir}/{entry}"


def find_links(cfg: Config, subdir: str, entry: str, is_bundle: bool) -> list[str]:
    """Tokens of the public links that point at this page or Bundle."""
    root = os.path.join(cfg.repo_dir, LINKS_DIR)
    if not os.path.isdir(root):
        return []
    inner, target = _link_target(subdir, entry, is_bundle)
    found = []
    for tok in sorted(os.listdir(root)):
        if not CAP_RE.match(tok):
            continue
        link = os.path.join(root, tok, inner) if inner else os.path.join(root, tok)
        if os.path.islink(link) and os.readlink(link) == target:
            found.append(tok)
    return found


def _registry(cfg: Config) -> dict:
    try:
        with open(os.path.join(cfg.repo_dir, LINKS_DIR, LINK_REGISTRY), encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _save_registry(cfg: Config, reg: dict) -> None:
    root = _expect_inside(cfg, LINKS_DIR)
    os.makedirs(root, exist_ok=True)
    with open(os.path.join(root, LINK_REGISTRY), "w", encoding="utf-8") as fh:
        json.dump(dict(sorted(reg.items())), fh, indent=1)


def make_link(cfg: Config, token: str, subdir: str, entry: str, is_bundle: bool) -> None:
    root = _expect_inside(cfg, LINKS_DIR)
    os.makedirs(root, exist_ok=True)
    inner, target = _link_target(subdir, entry, is_bundle)
    if inner:
        os.makedirs(os.path.join(root, token), exist_ok=True)
        os.symlink(target, os.path.join(root, token, inner))
    else:
        os.symlink(target, os.path.join(root, token))


def remove_link(cfg: Config, token: str) -> None:
    path = os.path.join(cfg.repo_dir, LINKS_DIR, token)
    if os.path.islink(path):
        os.unlink(path)
    elif os.path.isdir(path):
        shutil.rmtree(path)
    reg = _registry(cfg)
    if token in reg:
        del reg[token]
        _save_registry(cfg, reg)


def stage_and_commit(cfg: Config, paths: list[str], user: str, msg: str) -> bool:
    """``git add -A`` scoped to ``paths`` and commit as ``user``. False = no change."""
    env = publisher._git_env(cfg, author=user)
    # Only paths that exist or are tracked: a pathspec matching nothing makes
    # git add fail, and an EMPTY pathspec would stage the whole clone.
    def known(p: str) -> bool:
        if os.path.lexists(os.path.join(cfg.repo_dir, p)):
            return True
        ls = publisher._run(["git", "-C", cfg.repo_dir, "ls-files", "--", f"{p}/"], env=env)
        return bool(ls.stdout.strip())
    spec = [f"{p}/" for p in dict.fromkeys(paths) if known(p)]
    if not spec:
        return False
    add = publisher._run(["git", "-C", cfg.repo_dir, "add", "-A", "--", *spec], env=env)
    if add.returncode != 0:
        raise publisher.RenderError(f"git add failed: {add.stderr.strip()}")
    st = publisher._run(
        ["git", "-C", cfg.repo_dir, "status", "--porcelain", "--", *spec], env=env
    )
    if not st.stdout.strip():
        return False
    commit = publisher._run(["git", "-C", cfg.repo_dir, "commit", "-m", msg], env=env)
    if commit.returncode != 0:
        raise publisher.RenderError(f"git commit failed: {commit.stderr.strip()}")
    return True


def _commit_loop(cfg: Config, user: str, attempts: int, step) -> dict:
    """sync -> step() -> commit -> push, retried on a lost push race.

    ``step`` rewrites the working tree from scratch each time and returns
    ``(result, paths, message)``; re-running it on the master that won is
    what makes a retry safe, as in :func:`publisher.publish`.
    """
    publisher.ensure_repo(cfg)
    last_err = ""
    for attempt in range(1, attempts + 1):
        publisher.sync_to_master(cfg)
        result, paths, msg = step()
        if not stage_and_commit(cfg, paths, user, msg):
            return result
        pushed, err = publisher.push_to_master(cfg, user)
        if pushed:
            log.info("%s -> %s", msg, result.get("url"))
            return result
        last_err = err
        log.warning("push rejected (attempt %d/%d), redoing on master: %s", attempt, attempts, err)
    raise publisher.RenderError(f"git push failed after {attempts} attempts: {last_err}")


def _public_url(cfg: Config, token: str) -> str:
    return f"{cfg.base_url}/{LINKS_DIR}/{token}/"


def _ensure_public(
    cfg: Config, token: str, subdir: str, entry: str, is_bundle: bool,
    ttl: str | None = None,
) -> tuple[str, str | None]:
    """``(url, expires)`` of the page's public link, made if it has none.

    Sharing again returns the same link and restarts its clock.
    """
    existing = find_links(cfg, subdir, entry, is_bundle)
    reg = _registry(cfg)
    if existing:
        token = existing[0]
        prior = reg.get(token)
        new_ttl, expires = lifetime(ttl, True, (prior or {}).get("ttl"))
    else:
        make_link(cfg, token, subdir, entry, is_bundle)
        prior = None
        new_ttl, expires = lifetime(ttl, False, None)
    if new_ttl:
        reg[token] = {
            "target": f"{subdir}/{entry}",
            "created": (prior or {}).get("created", today()),
            "ttl": new_ttl,
            "expires": expires,
        }
        _save_registry(cfg, reg)
    return _public_url(cfg, token), expires


def _space_url(cfg: Config, shared: bool) -> str:
    return f"{cfg.base_url}/shared" if shared else cfg.base_url


# ---- publish --------------------------------------------------------------


def publish(
    cfg: Config,
    *,
    user: str,
    name: str | None,
    files: list[dict],
    status: str = "draft",
    shared: bool = False,
    public: bool = False,
    attempts: int = publisher.DEFAULT_ATTEMPTS,
    ttl: str | None = None,
) -> dict:
    """Publish one HTML file as a page, or several files as a Bundle."""
    source, slug = source_name(name)
    status = publisher.validate_status(status)
    ttl = publisher.validate_ttl(ttl)
    subdir = publisher.target_subdir(user, shared)
    decoded = publisher.validate_bundle_files(files)
    check_files(decoded)

    # The name says what was published: a file name (x.html, x.md) is one
    # page, a directory name is a Bundle, even a Bundle of one file.
    paths = {p for p, _ in decoded}
    kind = source.lower().rsplit(".", 1)[-1] if "." in source else ""
    single = kind in ("html", "htm", "md")
    if single and (len(decoded) != 1 or "/" in decoded[0][0]):
        raise publisher.PublishError(
            f"{source!r} names one file, so send exactly that one file; "
            "publish a directory to send several"
        )
    if single and kind == "md":
        result = publisher.publish(
            cfg, user=user, content=decoded[0][1].decode("utf-8"),
            filename=f"{slug}.md", status=status, shared=shared, attempts=attempts,
            ttl=ttl,
        )
        if public:
            result["public_url"] = share(cfg, user=user, page=os.path.basename(result["path"]), shared=shared)["url"]
        return result
    if not single and "index.html" not in paths and "index.md" not in paths:
        raise publisher.PublishError(
            "a Bundle needs an entry page at its top level: index.html or index.md"
        )

    token = new_token()
    cap = new_token()

    def page_step():
        abs_space = _expect_inside(cfg, subdir)
        os.makedirs(abs_space, exist_ok=True)
        entry = find_page(abs_space, source) or (
            free_name(abs_space, dated(slug), source, is_dir=False) + ".html"
        )
        text = decoded[0][1].decode("utf-8", errors="replace")
        date = _date_of(entry)
        prior_path = os.path.join(abs_space, entry)
        page_ttl, expires = lifetime(
            ttl, os.path.exists(prior_path), _head_meta(prior_path).get("ttl")
        )
        out = inject_meta(
            text, title=html_title(text) or slug, status=status, date=date, source=source,
            ttl=page_ttl, expires=expires,
        )
        _expect_inside(cfg, f"{subdir}/{entry}")
        with open(os.path.join(abs_space, entry), "w", encoding="utf-8") as fh:
            fh.write(out)
        rebuild_index(cfg, abs_space)
        result = {
            "url": f"{_space_url(cfg, shared)}/{entry}",
            "path": f"{subdir}/{entry}",
            "kind": "page",
            "expires": expires,
        }
        touched = [subdir]
        if public:
            result["public_url"], _ = _ensure_public(cfg, token, subdir, entry, False)
            touched.append(LINKS_DIR)
        return result, touched, f"pages: publish {entry} for {user} ({status})"

    def bundle_step():
        abs_space = _expect_inside(cfg, subdir)
        os.makedirs(abs_space, exist_ok=True)
        entry = find_bundle(abs_space, source) or free_name(
            abs_space, dated(slug), source, is_dir=True
        )
        target = _expect_inside(cfg, f"{subdir}/{entry}")
        old_marker = read_marker(target)
        old_cap = old_marker.get("cap")
        bundle_ttl, expires = lifetime(ttl, bool(old_marker), old_marker.get("ttl"))
        if os.path.isdir(target):
            shutil.rmtree(target)
        for rel, data in decoded:
            path = os.path.join(target, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as fh:
                fh.write(data)

        index = os.path.join(target, "index.html")
        if not os.path.exists(index):
            with tempfile.TemporaryDirectory() as td:
                md = os.path.join(td, f"{slug}.md")
                shutil.copyfile(os.path.join(target, "index.md"), md)
                _render(
                    cfg, md, cfg.render_dir_flag, target, "--status", status,
                    "--source-name", source, "--out-name", "index.html", "--no-index",
                    "--bundle", "--index-href", "/shared/" if shared else "/",
                )
        with open(index, encoding="utf-8", errors="replace") as fh:
            title = html_title(fh.read(65536)) or slug

        caps = _expect_inside(cfg, CAPS_DIR)
        os.makedirs(caps, exist_ok=True)
        if isinstance(old_cap, str) and CAP_RE.match(old_cap):
            old = os.path.join(caps, old_cap)
            if os.path.islink(old) and os.readlink(old) == f"../{subdir}/{entry}":
                os.unlink(old)
        os.symlink(f"../{subdir}/{entry}", os.path.join(caps, cap))
        with open(os.path.join(target, MARKER), "w", encoding="utf-8") as fh:
            json.dump(
                {"cap": cap, "source": source, "title": title, "status": status,
                 "date": _date_of(entry),
                 **({"ttl": bundle_ttl} if bundle_ttl else {}),
                 **({"expires": expires} if expires else {})},
                fh, indent=1,
            )
        rebuild_index(cfg, abs_space)
        result = {
            "url": f"{_space_url(cfg, shared)}/{entry}/",
            "path": f"{subdir}/{entry}",
            "kind": "bundle",
            "files": len(decoded),
            "expires": expires,
        }
        touched = [subdir, CAPS_DIR]
        if public:
            result["public_url"], _ = _ensure_public(cfg, token, subdir, entry, True)
            touched.append(LINKS_DIR)
        return result, touched, f"pages: publish bundle {entry} for {user} ({status})"

    return _commit_loop(cfg, user, attempts, page_step if single else bundle_step)


# ---- public links ---------------------------------------------------------


def _resolve(cfg: Config, user: str, page: str, shared: bool) -> tuple[str, str, bool]:
    """``(subdir, entry, is_bundle)`` for a page reference in the caller's reach.

    Accepts a page URL, a served name (``2026-11-12-x.html`` or a Bundle dir),
    ``shared/<name>``, or the source name it was published from. Only the
    caller's own Space and ``shared/`` are searched.
    """
    ref = (page or "").strip()
    ref = ref.split("#", 1)[0].split("?", 1)[0]
    if ref.startswith(cfg.base_url):
        ref = ref[len(cfg.base_url):]
    ref = ref.strip("/")
    if ref.startswith("shared/"):
        shared, ref = True, ref[len("shared/"):]
    elif ref.startswith(f"{user}/"):
        ref = ref[len(user) + 1:]
    if not ref or "/" in ref:
        raise publisher.PublishError(f"not a page on pages.viktorbarzin.me: {page!r}")
    publisher.sanitize_slug(ref)  # charset, no '..'
    subdir = publisher.target_subdir(user, shared)
    abs_space = os.path.join(cfg.repo_dir, subdir)
    candidates = [ref] if ref.endswith(".html") else [ref, f"{ref}.html"]
    for c in candidates:
        p = os.path.join(abs_space, c)
        if os.path.isfile(p) and not os.path.islink(p) and c != "index.html":
            return subdir, c, False
        if os.path.isdir(p) and not os.path.islink(p) and read_marker(p):
            return subdir, c, True
    hit = find_page(abs_space, ref)
    if hit:
        return subdir, hit, False
    hit = find_bundle(abs_space, ref)
    if hit:
        return subdir, hit, True
    raise LookupError(page)


def share(cfg: Config, *, user: str, page: str, shared: bool = False,
          attempts: int = publisher.DEFAULT_ATTEMPTS, ttl: str | None = None) -> dict:
    token = new_token()
    ttl = publisher.validate_ttl(ttl)

    def step():
        subdir, entry, is_bundle = _resolve(cfg, user, page, shared)
        url, expires = _ensure_public(cfg, token, subdir, entry, is_bundle, ttl)
        return ({"url": url, "page": f"{subdir}/{entry}", "expires": expires}, [LINKS_DIR],
                f"pages: public link to {subdir}/{entry} for {user}")

    return _commit_loop(cfg, user, attempts, step)


def unshare(cfg: Config, *, user: str, page: str, shared: bool = False,
            attempts: int = publisher.DEFAULT_ATTEMPTS) -> dict:
    """Remove the public links of a page, or one link given by its URL."""
    m = re.search(r"/p/([0-9a-f]{32})/?$", (page or "").split("?", 1)[0])

    def step():
        if m:
            tok = m.group(1)
            root = os.path.join(cfg.repo_dir, LINKS_DIR, tok)
            link = root if os.path.islink(root) else os.path.join(root, "index.html")
            if not os.path.islink(link):
                raise LookupError(page)
            target = os.readlink(link)
            allowed = {f"{publisher.target_subdir(user, False)}", "shared"}
            parts = [p for p in target.split("/") if p not in ("..", "")]
            if not parts or parts[0] not in allowed:
                raise LookupError(page)
            tokens = [tok]
            what = "/".join(parts)
        else:
            subdir, entry, is_bundle = _resolve(cfg, user, page, shared)
            tokens = find_links(cfg, subdir, entry, is_bundle)
            what = f"{subdir}/{entry}"
        for tok in tokens:
            remove_link(cfg, tok)
        return ({"removed": len(tokens), "page": what}, [LINKS_DIR],
                f"pages: remove public link to {what} for {user}")

    return _commit_loop(cfg, user, attempts, step)


# ---- unpublish and expiry -----------------------------------------------------


def _caps_for(cfg: Config, subdir: str, entry: str) -> list[str]:
    root = os.path.join(cfg.repo_dir, CAPS_DIR)
    if not os.path.isdir(root):
        return []
    target = f"../{subdir}/{entry}"
    return [c for c in os.listdir(root)
            if CAP_RE.match(c) and os.path.islink(os.path.join(root, c))
            and os.readlink(os.path.join(root, c)) == target]


def _remove_entry(cfg: Config, subdir: str, entry: str, is_bundle: bool) -> int:
    """Delete a page or Bundle with its Bundle URL and public links.

    Returns how many public links went with it. The Space index is rebuilt by
    the caller once per Space.
    """
    tokens = find_links(cfg, subdir, entry, is_bundle)
    for tok in tokens:
        remove_link(cfg, tok)
    path = _expect_inside(cfg, f"{subdir}/{entry}")
    if is_bundle:
        for cap in _caps_for(cfg, subdir, entry):
            os.unlink(os.path.join(cfg.repo_dir, CAPS_DIR, cap))
        shutil.rmtree(path)
    else:
        os.unlink(path)
    return len(tokens)


def unpublish(cfg: Config, *, user: str, page: str, shared: bool = False,
              attempts: int = publisher.DEFAULT_ATTEMPTS) -> dict:
    """Delete one page or Bundle from the caller's Space or shared/.

    Its public links and Bundle URL go with it. git history keeps a copy.
    """

    def step():
        subdir, entry, is_bundle = _resolve(cfg, user, page, shared)
        links = len(find_links(cfg, subdir, entry, is_bundle))
        _remove_entry(cfg, subdir, entry, is_bundle)
        rebuild_index(cfg, os.path.join(cfg.repo_dir, subdir))
        return ({"removed": f"{subdir}/{entry}", "links": links},
                [subdir, CAPS_DIR, LINKS_DIR],
                f"pages: unpublish {subdir}/{entry} for {user}")

    return _commit_loop(cfg, user, attempts, step)


def _spaces(cfg: Config) -> list[str]:
    reserved = set(publisher._RESERVED_SEGMENTS) - {"shared"}
    out = []
    for name in sorted(os.listdir(cfg.repo_dir)):
        path = os.path.join(cfg.repo_dir, name)
        if name.startswith(".") or name in reserved or os.path.islink(path) or not os.path.isdir(path):
            continue
        out.append(name)
    return out


def expire(cfg: Config, *, today: str | None = None,
           attempts: int = publisher.DEFAULT_ATTEMPTS) -> dict:
    """Delete every page, Bundle and public link whose expiry date has passed.

    Only items that carry an expiry are touched: pages published or shared
    before 2026-11-12 have none. Runs as the service, a few times a day.
    """
    when = today or globals()["today"]()

    def step():
        pages = links = 0
        touched_spaces = []
        for space in _spaces(cfg):
            abs_space = os.path.join(cfg.repo_dir, space)
            gone = False
            for name in sorted(os.listdir(abs_space)):
                path = os.path.join(abs_space, name)
                if os.path.islink(path):
                    continue
                if name.endswith(".html") and name != "index.html" and os.path.isfile(path):
                    exp = _head_meta(path).get("expires")
                    if exp and exp < when:
                        _remove_entry(cfg, space, name, False)
                        pages += 1
                        gone = True
                elif os.path.isdir(path):
                    exp = read_marker(path).get("expires")
                    if isinstance(exp, str) and exp < when:
                        _remove_entry(cfg, space, name, True)
                        pages += 1
                        gone = True
            if gone:
                rebuild_index(cfg, abs_space)
                touched_spaces.append(space)
        for tok, entry in sorted(_registry(cfg).items()):
            exp = entry.get("expires") if isinstance(entry, dict) else None
            if isinstance(exp, str) and exp < when:
                remove_link(cfg, tok)
                links += 1
        msg = f"pages: expire {pages} page(s) and {links} public link(s) (as of {when})"
        result = {"pages": pages, "links": links}
        return result, touched_spaces + [CAPS_DIR, LINKS_DIR], msg

    return _commit_loop(cfg, "pages-publish", attempts, step)
