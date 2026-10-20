import base64
import os

import pytest

AUTH_V = {"Authorization": "Bearer tok-viktor"}  # -> user "wizard"
AUTH_E = {"Authorization": "Bearer tok-emo"}  # -> user "emo"


# (e) /health — no auth, 200
def test_health_no_auth(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


# (a) unknown token -> 401
def test_unknown_token_401(client):
    r = client.post(
        "/publish",
        headers={"Authorization": "Bearer nope"},
        json={"content": "# Hi", "filename": "x.md"},
    )
    assert r.status_code == 401
    assert "render" not in client.calls  # never reached the pipeline


def test_missing_token_401(client):
    r = client.post("/publish", json={"content": "# Hi", "filename": "x.md"})
    assert r.status_code == 401


# (b) slug sanitization rejects traversal / separators / empty -> 400
@pytest.mark.parametrize("bad", ["../x", "../../etc/passwd", "a/b", "", "..", "foo bar.md"])
def test_slug_rejected_400(client, bad):
    r = client.post("/publish", headers=AUTH_V, json={"content": "# Hi", "filename": bad})
    assert r.status_code == 400
    assert "render" not in client.calls  # rejected before any write


def test_bad_status_400(client):
    r = client.post(
        "/publish",
        headers=AUTH_V,
        json={"content": "# Hi", "filename": "foo.md", "status": "bogus"},
    )
    assert r.status_code == 400


# (c) shared=true targets pages/shared
def test_shared_targets_pages_shared(client):
    r = client.post(
        "/publish",
        headers=AUTH_V,
        json={"content": "# Hi", "filename": "2026-07-27-foo.md", "shared": True},
    )
    assert r.status_code == 200
    body = r.json()
    assert body["path"].startswith("pages/shared/")
    assert body["url"].startswith("https://pages.viktorbarzin.me/shared/")
    assert client.calls["commit"]["subdir"] == "pages/shared"
    assert client.calls["render"]["abs_target"].endswith("/pages/shared")


# (d) resolved user comes from the token, not the body
def test_resolved_user_from_token_not_body(client):
    # The body tries to claim a different user; the token maps to "wizard".
    r = client.post(
        "/publish",
        headers=AUTH_V,
        json={
            "content": "# Hi",
            "filename": "2026-07-27-foo.md",
            "user": "emo",  # ignored — no such field, identity is the token
            "shared": False,
        },
    )
    assert r.status_code == 200
    assert client.calls["commit"]["user"] == "wizard"
    assert client.calls["commit"]["subdir"] == "pages/wizard"
    assert client.calls["render"]["abs_target"].endswith("/pages/wizard")


def test_non_shared_url_path_and_content(client):
    r = client.post(
        "/publish",
        headers=AUTH_E,
        json={"content": "# Hello world", "filename": "2026-07-27-foo.md"},
    )
    assert r.status_code == 200
    body = r.json()
    assert body["url"] == "https://pages.viktorbarzin.me/2026-07-27-foo.html"
    assert body["path"] == "pages/emo/2026-07-27-foo.html"
    # the raw markdown reached the renderer's temp file unchanged
    assert client.calls["render"]["content"] == "# Hello world"
    assert client.calls["render"]["status"] == "draft"
    assert client.calls["commit"]["status"] == "draft"


def test_status_flows_through(client):
    r = client.post(
        "/publish",
        headers=AUTH_V,
        json={"content": "# Hi", "filename": "p.md", "status": "executing"},
    )
    assert r.status_code == 200
    assert client.calls["render"]["status"] == "executing"
    assert client.calls["commit"]["status"] == "executing"


def test_missing_body_fields_422(client):
    # content + filename are required by the schema
    r = client.post("/publish", headers=AUTH_V, json={"content": "# Hi"})
    assert r.status_code == 422


# ---- /preview: same auth and validation, no git ---------------------------


@pytest.fixture
def preview_calls(client, monkeypatch):
    """Stub the preview pipeline and record what the endpoint passed it."""
    from app import publisher

    seen = {}

    def fake_render_preview(_cfg, *, user, content, filename, status, shared):
        seen.update(
            user=user, content=content, filename=filename, status=status, shared=shared
        )
        return {"filename": "2026-07-27-foo.html", "html": "<h1>hi</h1>", "assets": {}}

    monkeypatch.setattr(publisher, "render_preview", fake_render_preview)
    return seen


def test_preview_unknown_token_401(client, preview_calls):
    r = client.post(
        "/preview",
        headers={"Authorization": "Bearer nope"},
        json={"content": "# Hi", "filename": "x.md"},
    )
    assert r.status_code == 401
    assert preview_calls == {}


def test_preview_missing_token_401(client, preview_calls):
    r = client.post("/preview", json={"content": "# Hi", "filename": "x.md"})
    assert r.status_code == 401
    assert preview_calls == {}


def test_preview_returns_page_and_assets(client, preview_calls):
    r = client.post(
        "/preview",
        headers=AUTH_E,
        json={"content": "# Hi", "filename": "2026-07-27-foo.md", "status": "done"},
    )
    assert r.status_code == 200
    assert r.json() == {
        "filename": "2026-07-27-foo.html",
        "html": "<h1>hi</h1>",
        "assets": {},
    }
    assert preview_calls["status"] == "done"


def test_preview_user_comes_from_the_token_not_the_body(client, preview_calls):
    r = client.post(
        "/preview",
        headers=AUTH_E,
        json={"content": "# Hi", "filename": "x.md", "user": "wizard"},
    )
    assert r.status_code == 200
    assert preview_calls["user"] == "emo"


def test_preview_never_publishes(client, preview_calls):
    client.post("/preview", headers=AUTH_E, json={"content": "# Hi", "filename": "x.md"})
    assert "commit" not in client.calls
    assert "push" not in client.calls


@pytest.mark.parametrize("bad", ["../x", "a/b", "", "foo bar.md"])
def test_preview_slug_rejected_400(client, bad):
    r = client.post("/preview", headers=AUTH_V, json={"content": "# Hi", "filename": bad})
    assert r.status_code == 400
    assert "commit" not in client.calls


def test_preview_bad_status_400(client):
    r = client.post(
        "/preview",
        headers=AUTH_V,
        json={"content": "# Hi", "filename": "x.md", "status": "bogus"},
    )
    assert r.status_code == 400


# ---- /publish-bundle: a separate token map, raw files, no render ----------

AUTH_B = {"Authorization": "Bearer tok-bundle"}  # -> ("showcase", "homelab")


def _bundle(*files):
    return {"files": [dict(f) for f in files]}


INDEX = {"path": "index.html", "content": "<h1>hi</h1>"}


def test_bundle_token_rejected_on_publish(client):
    r = client.post(
        "/publish", headers=AUTH_B, json={"content": "# Hi", "filename": "x.md"}
    )
    assert r.status_code == 401
    assert "render" not in client.calls


def test_bundle_token_rejected_on_preview(client):
    r = client.post(
        "/preview", headers=AUTH_B, json={"content": "# Hi", "filename": "x.md"}
    )
    assert r.status_code == 401


def test_api_token_rejected_on_publish_bundle(client):
    r = client.post("/publish-bundle", headers=AUTH_V, json=_bundle(INDEX))
    assert r.status_code == 401
    assert "commit_bundle" not in client.calls


def test_publish_bundle_unknown_token_401(client):
    r = client.post(
        "/publish-bundle",
        headers={"Authorization": "Bearer nope"},
        json=_bundle(INDEX),
    )
    assert r.status_code == 401


def test_publish_bundle_missing_token_401(client):
    r = client.post("/publish-bundle", json=_bundle(INDEX))
    assert r.status_code == 401


def test_publish_bundle_writes_files_and_returns_url(client, cfg):
    png = bytes(range(256))
    r = client.post(
        "/publish-bundle",
        headers=AUTH_B,
        json=_bundle(
            INDEX,
            {"path": "assets/app.js", "content": "console.log(1)", "encoding": "utf-8"},
            {
                "path": "og.png",
                "content": base64.b64encode(png).decode(),
                "encoding": "base64",
            },
        ),
    )
    assert r.status_code == 200
    assert r.json() == {
        "url": "https://pages.viktorbarzin.me/homelab/",
        "path": "pages/showcase/homelab",
        "committed": True,
        "files": 3,
    }
    root = os.path.join(cfg.repo_dir, "pages", "showcase", "homelab")
    with open(os.path.join(root, "og.png"), "rb") as f:
        assert f.read() == png
    with open(os.path.join(root, "assets", "app.js"), encoding="utf-8") as f:
        assert f.read() == "console.log(1)"
    assert client.calls["commit_bundle"] == {
        "subdir": "pages/showcase/homelab",
        "user": "showcase",
        "slug": "homelab",
    }
    assert client.calls["push"] == {"user": "showcase"}


def test_publish_bundle_identity_ignores_the_body(client, cfg):
    body = _bundle(INDEX)
    body.update(user="wizard", slug="evil")
    r = client.post("/publish-bundle", headers=AUTH_B, json=body)
    assert r.status_code == 200
    assert r.json()["path"] == "pages/showcase/homelab"
    assert not os.path.exists(os.path.join(cfg.repo_dir, "pages", "wizard"))


@pytest.mark.parametrize(
    "bad",
    [
        "../x.html",
        "a/../../x.html",
        "/etc/passwd",
        "a//b.html",
        "a/",
        "",
        ".",
        "..",
        ".git/config",
        "foo bar.html",
        "a\\b.html",
        "a/b/c/d.html",  # deeper than the bundle allows
    ],
)
def test_publish_bundle_rejects_bad_paths_400(client, cfg, bad):
    r = client.post(
        "/publish-bundle",
        headers=AUTH_B,
        json=_bundle(INDEX, {"path": bad, "content": "x"}),
    )
    assert r.status_code == 400
    assert "commit_bundle" not in client.calls
    assert not os.path.exists(os.path.join(cfg.repo_dir, "pages", "showcase"))


def test_publish_bundle_rejects_empty_file_set_400(client):
    r = client.post("/publish-bundle", headers=AUTH_B, json={"files": []})
    assert r.status_code == 400


def test_publish_bundle_rejects_bad_base64_400(client):
    r = client.post(
        "/publish-bundle",
        headers=AUTH_B,
        json=_bundle({"path": "og.png", "content": "not base64!!", "encoding": "base64"}),
    )
    assert r.status_code == 400


def test_publish_bundle_rejects_unknown_encoding_422(client):
    r = client.post(
        "/publish-bundle",
        headers=AUTH_B,
        json=_bundle({"path": "a.txt", "content": "x", "encoding": "latin-1"}),
    )
    assert r.status_code == 422
