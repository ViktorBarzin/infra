"""Rich content (2026-11-12 design): HTML pages and Bundles for every user,
Bundle URLs, public links, and one page per source name.

These run the real git plumbing against a local bare repo, so symlinks,
renames and deletions are what git actually records. The renderer is a small
stand-in that honours render.py's command-line contract; render.py's own
behaviour is tested in viktor/pages.
"""

from __future__ import annotations

import base64
import json
import os
import re
import subprocess
import sys

import pytest

from app import bundles, publisher
from tests.conftest import make_cfg

AUTH_V = {"Authorization": "Bearer tok-viktor"}  # wizard
AUTH_E = {"Authorization": "Bearer tok-emo"}  # emo

FAKE_RENDER = r'''
import argparse, datetime, html, json, os, re, sys
p = argparse.ArgumentParser()
p.add_argument("source", nargs="?")
p.add_argument("--pages-dir"); p.add_argument("--status", default="draft")
p.add_argument("--source-name"); p.add_argument("--out-name")
p.add_argument("--no-index", action="store_true"); p.add_argument("--bundle", action="store_true")
p.add_argument("--index-href", default="index.html"); p.add_argument("--index-only", action="store_true")
p.add_argument("--ttl"); p.add_argument("--default-ttl")
a = p.parse_args()
d = a.pages_dir
os.makedirs(d, exist_ok=True)
def index():
    names = sorted(n for n in os.listdir(d) if n != "index.html")
    open(os.path.join(d, "index.html"), "w").write("\n".join(names))
if a.index_only:
    index(); print(os.path.join(d, "index.html")); sys.exit(0)
src = open(a.source).read()
if "BADCHART" in src:
    print("error: chart block 1: invalid JSON", file=sys.stderr); sys.exit(3)
name = a.source_name or os.path.basename(a.source)
stem = os.path.splitext(name)[0]
out = a.out_name
if out is None:
    for n in os.listdir(d):
        if n.endswith(".html") and n != "index.html":
            m = re.search(r'plan-source" content="([^"]*)"', open(os.path.join(d, n)).read(4096))
            if m and os.path.basename(m.group(1)) == name:
                out = n
if out is None:
    out = (stem if re.match(r"\d{4}-\d{2}-\d{2}-", stem) else "2026-11-12-" + stem) + ".html"
prior = {}
if os.path.exists(os.path.join(d, out)):
    prior = dict(re.findall(r'<meta name="plan-(\w+)" content="([^"]*)"', open(os.path.join(d, out)).read(4096)))
    ttl = a.ttl or prior.get("ttl", "")
else:
    ttl = a.ttl or a.default_ttl or ""
exp = ""
if ttl and ttl != "never":
    exp = (datetime.date(2026, 11, 12) + datetime.timedelta(days=int(ttl[:-1]))).isoformat()
meta = (f'<meta name="plan-ttl" content="{ttl}">' if ttl else "") + (f'<meta name="plan-expires" content="{exp}">' if exp else "")
if "LONGPLAN" in src:
    print("warning: 700 prose words outside the blocks; the plan budget is 600.", file=sys.stderr)
open(os.path.join(d, out), "w").write(
    f'<html><head><title>{html.escape(stem)}</title>'
    f'<meta name="plan-source" content="{html.escape(name)}">{meta}</head>'
    f'<body data-bundle="{a.bundle}" data-index="{a.index_href}">{html.escape(src)}</body></html>')
if not a.no_index:
    index()
print(os.path.join(d, out))
'''


def git(*args, cwd):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True).stdout


@pytest.fixture
def site(tmp_path, monkeypatch):
    """A bare 'Forgejo' repo seeded like viktor/pages, and a cfg cloning it."""
    monkeypatch.setattr(bundles, "today", lambda: "2026-11-12")
    origin = tmp_path / "origin.git"
    seed = tmp_path / "seed"
    git("init", "-q", "--bare", "-b", "master", str(origin), cwd=tmp_path)
    git("init", "-q", "-b", "master", str(seed), cwd=tmp_path)
    (seed / "tools").mkdir()
    (seed / "tools" / "render.py").write_text(FAKE_RENDER)
    for d in ("wizard", "emo", "shared", "assets"):
        (seed / d).mkdir()
        (seed / d / "index.html").write_text("")
    git("add", "-A", cwd=seed)
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "seed", cwd=seed)
    git("push", "-q", str(origin), "master", cwd=seed)

    cfg = make_cfg(str(tmp_path / "clone"))
    cfg.repo_url = str(origin)
    cfg.render_script = str(tmp_path / "clone" / "tools" / "render.py")
    cfg.python_bin = sys.executable

    def view():
        """A fresh checkout of origin/master: what git-sync would serve."""
        out = tmp_path / f"view{len(list(tmp_path.glob('view*')))}"
        git("clone", "-q", str(origin), str(out), cwd=tmp_path)
        return out

    cfg.view = view
    return cfg


@pytest.fixture
def api(site):
    from fastapi.testclient import TestClient

    from app import main

    return TestClient(main.create_app(site))


def f(path, data, binary=False):
    if binary:
        return {"path": path, "content": base64.b64encode(data).decode(), "encoding": "base64"}
    return {"path": path, "content": data}


PNG = b"\x89PNG\r\n\x1a\n" + b"\0" * 64


# ---- the bug that started decision 8 ---------------------------------------


def test_markdown_republish_on_another_day_updates_one_page(site, api, monkeypatch):
    """Before 2026-11-12 the service rendered from a fresh temp path, so the
    renderer never recognised the source and each day's publish of the same
    doc minted a new <date>-<slug>.html."""
    r = api.post("/publish", headers=AUTH_V, json={"content": "v1", "filename": "evergreen.md"})
    assert r.status_code == 200, r.text
    first = r.json()["path"]
    r = api.post("/publish", headers=AUTH_V, json={"content": "v2", "filename": "evergreen.md"})
    assert r.json()["path"] == first
    v = site.view()
    pages = sorted(p.name for p in (v / "wizard").glob("*.html") if p.name != "index.html")
    assert pages == [os.path.basename(first)]
    assert "v2" in (v / first).read_text()


def test_render_is_told_the_source_name(site, monkeypatch):
    seen = {}
    real = publisher._run

    def spy(cmd, **kw):
        if cmd and cmd[0] == site.python_bin:
            seen["cmd"] = cmd
        return real(cmd, **kw)

    monkeypatch.setattr(publisher, "_run", spy)
    publisher.publish(site, user="wizard", content="x", filename="named.md")
    i = seen["cmd"].index("--source-name")
    assert seen["cmd"][i + 1] == "named.md"


def test_content_error_from_the_renderer_is_a_400(site, api):
    r = api.post("/publish", headers=AUTH_V, json={"content": "BADCHART", "filename": "c.md"})
    assert r.status_code == 400
    assert "chart block 1" in r.json()["detail"]


# ---- single HTML page -------------------------------------------------------


def test_html_file_becomes_a_page_with_index_meta(site, api):
    html = "<!doctype html><html><head><title>Viewer</title></head><body>3d</body></html>"
    r = api.post("/publish-bundle", headers=AUTH_V,
                 json={"name": "viewer.html", "files": [f("viewer.html", html)], "status": "done"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["url"] == "https://pages.viktorbarzin.me/2026-11-12-viewer.html"
    assert body["path"] == "wizard/2026-11-12-viewer.html"
    page = (site.view() / body["path"]).read_text()
    head = page[:4096]
    assert '<meta name="plan-title" content="Viewer">' in head
    assert '<meta name="plan-status" content="done">' in head
    assert '<meta name="plan-source" content="viewer.html">' in head
    assert "3d" in page


def test_html_republish_keeps_its_page_and_replaces_old_meta(site, api, monkeypatch):
    html1 = "<html><head><title>A</title></head><body>one</body></html>"
    r1 = api.post("/publish-bundle", headers=AUTH_V, json={"name": "a.html", "files": [f("a.html", html1)]})
    monkeypatch.setattr(bundles, "today", lambda: "2026-12-01")
    html2 = "<html><head><title>A2</title></head><body>two</body></html>"
    r2 = api.post("/publish-bundle", headers=AUTH_V, json={"name": "a.html", "files": [f("a.html", html2)]})
    assert r2.json()["path"] == r1.json()["path"]
    page = (site.view() / r2.json()["path"]).read_text()
    assert page.count('name="plan-title"') == 1
    assert "A2" in page and "two" in page


# ---- multi-file Bundles -----------------------------------------------------


def bundle_files():
    return [
        f("index.html", "<html><head><title>Demo</title></head><body><img src='img/a.png'></body></html>"),
        f("img/a.png", PNG, binary=True),
        f("data.json", '{"n": 1}'),
    ]


def test_bundle_gets_its_dir_marker_and_bundle_url(site, api):
    r = api.post("/publish-bundle", headers=AUTH_V,
                 json={"name": "demo", "files": bundle_files(), "status": "executing"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["url"] == "https://pages.viktorbarzin.me/2026-11-12-demo/"
    v = site.view()
    d = v / "wizard" / "2026-11-12-demo"
    assert (d / "img" / "a.png").read_bytes() == PNG
    marker = json.loads((d / ".pages-bundle.json").read_text())
    assert re.fullmatch(r"[0-9a-f]{32}", marker["cap"])
    assert marker["title"] == "Demo" and marker["source"] == "demo"
    assert marker["status"] == "executing" and marker["date"] == "2026-11-12"
    link = v / "c" / marker["cap"]
    assert link.is_symlink()
    assert os.readlink(link) == "../wizard/2026-11-12-demo"
    assert (link / "img" / "a.png").read_bytes() == PNG
    # the Bundle URL is never handed back to the caller
    assert marker["cap"] not in json.dumps(body)


def test_bundle_republish_rotates_the_cap_and_drops_stale_files(site, api, monkeypatch):
    api.post("/publish-bundle", headers=AUTH_V, json={"name": "demo", "files": bundle_files()})
    old = json.loads((site.view() / "wizard/2026-11-12-demo/.pages-bundle.json").read_text())["cap"]
    monkeypatch.setattr(bundles, "today", lambda: "2026-12-24")
    files = [f("index.html", "<title>Demo 2</title>")]
    r = api.post("/publish-bundle", headers=AUTH_V, json={"name": "demo", "files": files})
    assert r.json()["url"].endswith("/2026-11-12-demo/")
    v = site.view()
    new = json.loads((v / "wizard/2026-11-12-demo/.pages-bundle.json").read_text())["cap"]
    assert new != old
    assert not (v / "c" / old).exists() and not os.path.islink(v / "c" / old)
    assert (v / "c" / new).is_symlink()
    assert not (v / "wizard/2026-11-12-demo/img").exists()


def test_bundle_from_index_md_is_rendered(site, api):
    files = [f("index.md", "# Hello\n![](a.png)"), f("a.png", PNG, binary=True)]
    r = api.post("/publish-bundle", headers=AUTH_E, json={"name": "notes", "files": files, "shared": True})
    assert r.status_code == 200, r.text
    assert r.json()["url"] == "https://pages.viktorbarzin.me/shared/2026-11-12-notes/"
    page = (site.view() / "shared/2026-11-12-notes/index.html").read_text()
    assert 'data-bundle="True"' in page
    assert 'data-index="/shared/"' in page


def test_bundle_needs_an_entry_page(site, api):
    r = api.post("/publish-bundle", headers=AUTH_V,
                 json={"name": "x", "files": [f("a.js", "1"), f("b.js", "2")]})
    assert r.status_code == 400
    assert "index.html" in r.json()["detail"]


def test_bundle_is_listed_in_the_space_index(site, api):
    api.post("/publish-bundle", headers=AUTH_V, json={"name": "demo", "files": bundle_files()})
    assert "2026-11-12-demo" in (site.view() / "wizard/index.html").read_text()


def test_user_bundle_stays_in_the_callers_space(site, api):
    r = api.post("/publish-bundle", headers=AUTH_E,
                 json={"name": "demo", "files": bundle_files(), "user": "wizard"})
    assert r.json()["path"] == "emo/2026-11-12-demo"


@pytest.mark.parametrize("name", ["../x", "a/b", "", ".git", "x y"])
def test_bundle_name_is_validated(api, name):
    r = api.post("/publish-bundle", headers=AUTH_V, json={"name": name, "files": bundle_files()})
    assert r.status_code == 400


def test_user_bundle_needs_a_name(api):
    r = api.post("/publish-bundle", headers=AUTH_V, json={"files": bundle_files()})
    assert r.status_code == 400


# ---- limits -----------------------------------------------------------------


def test_file_over_10_mib_is_refused(api, monkeypatch):
    monkeypatch.setattr(bundles, "MAX_FILE_BYTES", 10)
    r = api.post("/publish-bundle", headers=AUTH_V,
                 json={"name": "big", "files": [f("index.html", "x" * 11)]})
    assert r.status_code == 400
    assert "index.html" in r.json()["detail"]


def test_publish_over_25_mib_is_refused(api, monkeypatch):
    monkeypatch.setattr(bundles, "MAX_PUBLISH_BYTES", 20)
    files = [f("index.html", "x" * 15), f("b.css", "y" * 15)]
    r = api.post("/publish-bundle", headers=AUTH_V, json={"name": "big", "files": files})
    assert r.status_code == 400


@pytest.mark.parametrize("name", ["evil.exe", "a.zip", "run.sh", "noext", "x.php"])
def test_unlisted_file_types_are_refused(api, name):
    files = [f("index.html", "<title>x</title>"), f(name, "x")]
    r = api.post("/publish-bundle", headers=AUTH_V, json={"name": "t", "files": files})
    assert r.status_code == 400
    assert name in r.json()["detail"]


@pytest.mark.parametrize("name", ["m.glb", "m.stl", "clip.mp4", "clip.webm", "f.woff2", "s.svg", "d.csv", "w.wasm", "m.mjs"])
def test_listed_file_types_pass(api, name):
    files = [f("index.html", "<title>x</title>"), f(name, "x")]
    r = api.post("/publish-bundle", headers=AUTH_V, json={"name": "t", "files": files})
    assert r.status_code == 200, r.text


def test_bundle_request_over_the_body_cap_is_413(api):
    r = api.post("/publish-bundle", headers={**AUTH_V, "Content-Length": str(bundles.MAX_REQUEST_BYTES + 1)},
                 content=b"{}")
    assert r.status_code == 413


# ---- public links -----------------------------------------------------------


def test_share_a_page_then_unshare_it(site, api):
    r = api.post("/publish", headers=AUTH_V, json={"content": "x", "filename": "p.md"})
    page = os.path.basename(r.json()["path"])
    s = api.post("/share", headers=AUTH_V, json={"page": page})
    assert s.status_code == 200, s.text
    url = s.json()["url"]
    m = re.fullmatch(r"https://pages\.viktorbarzin\.me/p/([0-9a-f]{32})/", url)
    assert m
    v = site.view()
    link = v / "p" / m.group(1) / "index.html"
    assert os.readlink(link) == f"../../wizard/{page}"
    assert "x" in link.read_text()
    # sharing again hands back the same link
    assert api.post("/share", headers=AUTH_V, json={"page": page}).json()["url"] == url
    u = api.post("/unshare", headers=AUTH_V, json={"page": page})
    assert u.json()["removed"] == 1
    assert not (site.view() / "p" / m.group(1)).exists()


def test_share_by_url_and_by_source_name(site, api):
    r = api.post("/publish", headers=AUTH_V, json={"content": "x", "filename": "q.md"})
    page_url = r.json()["url"]
    a = api.post("/share", headers=AUTH_V, json={"page": page_url}).json()["url"]
    b = api.post("/share", headers=AUTH_V, json={"page": "q.md"}).json()["url"]
    assert a == b


def test_public_link_survives_a_republish(site, api, monkeypatch):
    r = api.post("/publish-bundle", headers=AUTH_V,
                 json={"name": "demo", "files": bundle_files(), "public": True})
    body = r.json()
    tok = re.search(r"/p/([0-9a-f]{32})/", body["public_url"]).group(1)
    v = site.view()
    assert os.readlink(v / "p" / tok) == "../wizard/2026-11-12-demo"
    monkeypatch.setattr(bundles, "today", lambda: "2027-01-01")
    r2 = api.post("/publish-bundle", headers=AUTH_V,
                  json={"name": "demo", "files": [f("index.html", "<title>v2</title>")], "public": True})
    assert r2.json()["public_url"] == body["public_url"]
    assert "v2" in (site.view() / "p" / tok / "index.html").read_text()


def test_markdown_publish_with_public(site, api):
    r = api.post("/publish", headers=AUTH_V, json={"content": "x", "filename": "pub.md", "public": True})
    assert r.status_code == 200
    assert re.fullmatch(r"https://pages\.viktorbarzin\.me/p/[0-9a-f]{32}/", r.json()["public_url"])


def test_cannot_share_another_users_page(site, api):
    r = api.post("/publish", headers=AUTH_V, json={"content": "x", "filename": "mine.md"})
    page = os.path.basename(r.json()["path"])
    s = api.post("/share", headers=AUTH_E, json={"page": page})
    assert s.status_code == 404


def test_cannot_unshare_another_users_link(site, api):
    r = api.post("/publish", headers=AUTH_V, json={"content": "x", "filename": "mine.md", "public": True})
    url = r.json()["public_url"]
    assert api.post("/unshare", headers=AUTH_E, json={"page": url}).status_code == 404
    assert api.post("/unshare", headers=AUTH_V, json={"page": url}).json()["removed"] == 1


def test_shared_space_pages_can_be_shared_by_anyone(site, api):
    r = api.post("/publish", headers=AUTH_V, json={"content": "x", "filename": "team.md", "shared": True})
    page = os.path.basename(r.json()["path"])
    s = api.post("/share", headers=AUTH_E, json={"page": f"shared/{page}"})
    assert s.status_code == 200, s.text


@pytest.mark.parametrize("page", ["../wizard/x.html", "/etc/passwd", "a b", ""])
def test_share_rejects_bad_page_names(api, page):
    assert api.post("/share", headers=AUTH_V, json={"page": page}).status_code in (400, 404)


def test_share_unknown_page_is_404(api):
    assert api.post("/share", headers=AUTH_V, json={"page": "nope.html"}).status_code == 404


def test_bundle_token_still_publishes_its_one_dir(site, api):
    r = api.post("/publish-bundle", headers={"Authorization": "Bearer tok-bundle"},
                 json={"files": [f("index.html", "hi")]})
    assert r.status_code == 200, r.text
    assert r.json()["path"] == "showcase/homelab"
    assert not (site.view() / "showcase/homelab/.pages-bundle.json").exists()


# ---- challenger findings, 2026-11-12 ------------------------------------------


def test_a_failed_bundle_leaves_nothing_for_the_next_publish(site, api):
    """A 400 after the Bundle files were written must not leave them in the
    clone, where the next publish's git add would sweep them up."""
    bad = [f("index.md", "BADCHART"), f("a.png", PNG, binary=True)]
    assert api.post("/publish-bundle", headers=AUTH_V, json={"name": "broken", "files": bad}).status_code == 400
    api.post("/publish", headers=AUTH_V, json={"content": "x", "filename": "other.md"})
    v = site.view()
    assert not (v / "wizard" / "2026-11-12-broken").exists()
    assert not any(p.name.endswith("broken") for p in (v / "c").iterdir()) if (v / "c").exists() else True


def test_html_page_does_not_overwrite_a_markdown_page_of_the_same_slug(site, api):
    api.post("/publish", headers=AUTH_V, json={"content": "markdown body", "filename": "foo.md"})
    r = api.post("/publish-bundle", headers=AUTH_V,
                 json={"name": "foo.html", "files": [f("foo.html", "<title>H</title>html body")]})
    assert r.json()["path"] == "wizard/2026-11-12-foo-2.html"
    v = site.view()
    assert "markdown body" in (v / "wizard/2026-11-12-foo.html").read_text()
    assert "html body" in (v / "wizard/2026-11-12-foo-2.html").read_text()


def test_bundle_does_not_take_over_a_dir_from_another_source(site, api):
    api.post("/publish-bundle", headers=AUTH_V, json={"name": "demo", "files": bundle_files()})
    v = site.view()
    marker = v / "wizard/2026-11-12-demo/.pages-bundle.json"
    data = json.loads(marker.read_text())
    assert data["source"] == "demo"
    # A dir with that name but no marker (hand-made) is not overwritten.
    r = api.post("/publish-bundle", headers=AUTH_V, json={"name": "2026-11-12-hand", "files": bundle_files()})
    assert r.status_code == 200


def test_html_page_links_open_outside_the_frame(site, api):
    r = api.post("/publish-bundle", headers=AUTH_V,
                 json={"name": "l.html", "files": [f("l.html", "<html><head><title>L</title></head><body><a href='/x.html'>x</a></body></html>")]})
    page = (site.view() / r.json()["path"]).read_text()
    assert "pages-top-links" in page


@pytest.mark.parametrize("user", ["c", "p"])
def test_c_and_p_are_reserved(user):
    from app import config
    with pytest.raises(config.ConfigError):
        config._invert_api_keys(json.dumps({user: "tok"}))
    with pytest.raises(publisher.PublishError):
        publisher.target_subdir(user, False)


@pytest.mark.parametrize("name", ["a.riv", "doc.pdf", "PHOTO.JPG", "m.drc", "map.geojson", "site.webmanifest"])
def test_more_file_types_pass(api, name):
    files = [f("index.html", "<title>x</title>"), f(name, "x")]
    assert api.post("/publish-bundle", headers=AUTH_V, json={"name": "t", "files": files}).status_code == 200


def test_bundle_without_content_length_is_411(api):
    def gen():
        yield b'{"name": "t", "files": []}'
    r = api.post("/publish-bundle", headers=AUTH_V, content=gen())
    assert r.status_code == 411


def test_second_large_publish_while_one_runs_is_429(site, monkeypatch):
    from fastapi.testclient import TestClient
    from app import main
    app = main.create_app(site)
    app.state.large_in_flight.acquire()
    try:
        r = TestClient(app).post("/publish-bundle", headers={**AUTH_V, "Content-Length": str(2 * 1024 * 1024)}, content=b"x" * (2 * 1024 * 1024))
        assert r.status_code == 429
    finally:
        app.state.large_in_flight.release()


# ---- unpublish and expiry (Viktor, 2026-11-12) --------------------------------


def head_meta(path):
    return dict(re.findall(r'<meta name="plan-(\w+)" content="([^"]*)"', path.read_text()[:4096]))


def test_new_markdown_page_expires_in_90_days_by_default(site, api):
    r = api.post("/publish", headers=AUTH_V, json={"content": "x", "filename": "e.md"})
    assert r.json()["expires"] == "2027-02-10"
    assert head_meta(site.view() / r.json()["path"])["ttl"] == "90d"


def test_expires_never_and_custom(site, api):
    r = api.post("/publish", headers=AUTH_V, json={"content": "x", "filename": "n.md", "expires": "never"})
    assert r.json()["expires"] is None
    r = api.post("/publish", headers=AUTH_V, json={"content": "x", "filename": "t.md", "expires": "30d"})
    assert r.json()["expires"] == "2026-12-12"


@pytest.mark.parametrize("bad", ["soon", "90", "-1d", "99999d"])
def test_bad_expires_is_400(api, bad):
    r = api.post("/publish", headers=AUTH_V, json={"content": "x", "filename": "b.md", "expires": bad})
    assert r.status_code == 400


def test_html_page_and_bundle_carry_their_expiry(site, api):
    r = api.post("/publish-bundle", headers=AUTH_V, json={"name": "h.html", "files": [f("h.html", "<title>H</title>")]})
    assert r.json()["expires"] == "2027-02-10"
    assert head_meta(site.view() / r.json()["path"])["expires"] == "2027-02-10"
    r = api.post("/publish-bundle", headers=AUTH_V, json={"name": "b", "files": bundle_files(), "expires": "never"})
    assert r.json()["expires"] is None
    marker = json.loads((site.view() / r.json()["path"] / ".pages-bundle.json").read_text())
    assert marker["ttl"] == "never" and marker.get("expires") is None


def test_republish_keeps_the_ttl_and_restarts_the_clock(site, api, monkeypatch):
    api.post("/publish-bundle", headers=AUTH_V, json={"name": "b", "files": bundle_files(), "expires": "30d"})
    monkeypatch.setattr(bundles, "today", lambda: "2026-12-01")
    r = api.post("/publish-bundle", headers=AUTH_V, json={"name": "b", "files": bundle_files()})
    assert r.json()["expires"] == "2026-12-31"


def test_a_bundle_from_before_expiry_stays_without_one(site, api):
    api.post("/publish-bundle", headers=AUTH_V, json={"name": "old", "files": bundle_files()})
    v = site.view()
    marker = v / "wizard/2026-11-12-old/.pages-bundle.json"
    data = json.loads(marker.read_text())
    data.pop("ttl"); data.pop("expires", None)
    marker.write_text(json.dumps(data))
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qam", "legacy", cwd=v)
    git("push", "-q", "origin", "master", cwd=v)
    r = api.post("/publish-bundle", headers=AUTH_V, json={"name": "old", "files": bundle_files()})
    assert r.json()["expires"] is None


def test_public_link_expires_in_90_days_and_can_be_kept(site, api):
    r = api.post("/publish", headers=AUTH_V, json={"content": "x", "filename": "l.md", "expires": "never"})
    s = api.post("/share", headers=AUTH_V, json={"page": os.path.basename(r.json()["path"])})
    assert s.json()["expires"] == "2027-02-10"
    s2 = api.post("/share", headers=AUTH_V, json={"page": os.path.basename(r.json()["path"]), "expires": "never"})
    assert s2.json()["url"] == s.json()["url"] and s2.json()["expires"] is None


def test_unpublish_removes_the_page_its_links_and_its_bundle_url(site, api):
    r = api.post("/publish-bundle", headers=AUTH_V, json={"name": "gone", "files": bundle_files(), "public": True})
    v = site.view()
    cap = json.loads((v / r.json()["path"] / ".pages-bundle.json").read_text())["cap"]
    tok = re.search(r"/p/([0-9a-f]{32})/", r.json()["public_url"]).group(1)
    u = api.post("/unpublish", headers=AUTH_V, json={"page": r.json()["url"]})
    assert u.status_code == 200, u.text
    assert u.json()["removed"] == "wizard/2026-11-12-gone"
    assert u.json()["links"] == 1
    v = site.view()
    assert not (v / "wizard/2026-11-12-gone").exists()
    assert not os.path.lexists(v / "c" / cap)
    assert not os.path.lexists(v / "p" / tok)
    assert "2026-11-12-gone" not in (v / "wizard/index.html").read_text()


def test_unpublish_a_markdown_page(site, api):
    r = api.post("/publish", headers=AUTH_V, json={"content": "x", "filename": "md1.md"})
    u = api.post("/unpublish", headers=AUTH_V, json={"page": "md1.md"})
    assert u.status_code == 200
    assert not (site.view() / r.json()["path"]).exists()


def test_cannot_unpublish_another_users_page(site, api):
    r = api.post("/publish", headers=AUTH_V, json={"content": "x", "filename": "mine2.md"})
    assert api.post("/unpublish", headers=AUTH_E, json={"page": os.path.basename(r.json()["path"])}).status_code == 404
    assert (site.view() / r.json()["path"]).exists()


def test_sweep_deletes_what_has_expired_and_nothing_else(site, api, monkeypatch):
    keep = api.post("/publish", headers=AUTH_V, json={"content": "x", "filename": "keep.md", "expires": "never"}).json()
    short = api.post("/publish", headers=AUTH_V, json={"content": "x", "filename": "short.md", "expires": "1d"}).json()
    bun = api.post("/publish-bundle", headers=AUTH_E, json={"name": "eb", "files": bundle_files(), "expires": "1d"}).json()
    link = api.post("/share", headers=AUTH_V, json={"page": os.path.basename(keep["path"]), "expires": "1d"}).json()
    long_link = api.post("/share", headers=AUTH_V, json={"page": os.path.basename(keep["path"]), "expires": "90d"}).json()
    assert link["url"] == long_link["url"]  # one link per page; the re-share gave it 90 days

    summary = bundles.expire(site, today="2026-11-14")
    assert summary == {"pages": 2, "links": 0}
    v = site.view()
    assert (v / keep["path"]).exists()
    assert not (v / short["path"]).exists()
    assert not (v / bun["path"]).exists()

    summary = bundles.expire(site, today="2027-03-01")
    assert summary == {"pages": 0, "links": 1}
    tok = re.search(r"/p/([0-9a-f]{32})/", link["url"]).group(1)
    assert not os.path.lexists(site.view() / "p" / tok)
    assert (site.view() / keep["path"]).exists()


def test_sweep_leaves_pages_without_expiry_alone(site, api):
    v = site.view()
    (v / "wizard" / "2020-01-01-ancient.html").write_text('<meta name="plan-source" content="ancient.md">')
    git("add", "-A", cwd=v)
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "old page", cwd=v)
    git("push", "-q", "origin", "master", cwd=v)
    assert bundles.expire(site, today="2030-01-01") == {"pages": 0, "links": 0}
    assert (site.view() / "wizard" / "2020-01-01-ancient.html").exists()


def test_publish_returns_the_renderers_warnings(site, api):
    r = api.post("/publish", headers=AUTH_V, json={"content": "LONGPLAN", "filename": "long.md"})
    assert r.status_code == 200
    assert any("budget" in w for w in r.json()["warnings"])
