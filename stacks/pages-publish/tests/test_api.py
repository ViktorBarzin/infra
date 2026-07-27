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
