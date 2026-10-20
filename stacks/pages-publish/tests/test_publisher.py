import base64
import os

import pytest

from app import publisher
from tests.conftest import make_cfg


# ---- slug sanitization (security-critical) --------------------------------


@pytest.mark.parametrize(
    "bad",
    [
        "../x",
        "../../etc/passwd",
        "a/b",
        "a/../b",
        "/etc/passwd",
        "",
        "   ",
        ".",
        "..",
        "..md",  # -> "." after stripping trailing .md
        "foo bar",
        "foo\tbar",
        "foo\n",
        "café",  # non-ascii
        "a\\b",
        # path-bearing names are rejected outright, never basenamed to the leaf
        "/tmp/whatever/2026-01-01-x.md",
        "some/dir/plan.md",
    ],
)
def test_sanitize_slug_rejects(bad):
    with pytest.raises(publisher.PublishError):
        publisher.sanitize_slug(bad)


@pytest.mark.parametrize(
    "filename,expected",
    [
        ("2026-07-27-foo.md", "2026-07-27-foo"),
        ("foo.md", "foo"),
        ("foo", "foo"),
        ("my_plan.v2.md", "my_plan.v2"),
        ("A-B_c.1", "A-B_c.1"),
    ],
)
def test_sanitize_slug_accepts(filename, expected):
    assert publisher.sanitize_slug(filename) == expected


# ---- target dir -----------------------------------------------------------


def test_target_subdir_user_vs_shared():
    assert publisher.target_subdir("wizard", False) == "pages/wizard"
    assert publisher.target_subdir("emo", False) == "pages/emo"
    # shared wins regardless of user
    assert publisher.target_subdir("wizard", True) == "pages/shared"
    assert publisher.target_subdir("emo", True) == "pages/shared"


# ---- status ---------------------------------------------------------------


def test_validate_status():
    for s in publisher.STATUSES:
        assert publisher.validate_status(s) == s
    with pytest.raises(publisher.PublishError):
        publisher.validate_status("bogus")


# ---- url derivation -------------------------------------------------------


def test_derive_url(tmp_path):
    cfg = make_cfg(str(tmp_path))
    assert (
        publisher.derive_url(cfg, "/repo/pages/wizard/2026-07-27-foo.html", False)
        == "https://pages.viktorbarzin.me/2026-07-27-foo.html"
    )
    assert (
        publisher.derive_url(cfg, "/repo/pages/shared/2026-07-27-foo.html", True)
        == "https://pages.viktorbarzin.me/shared/2026-07-27-foo.html"
    )


# ---- render_page seam -----------------------------------------------------


class _Proc:
    def __init__(self, rc=0, out="", err=""):
        self.returncode = rc
        self.stdout = out
        self.stderr = err


def test_render_page_uses_last_stdout_line_and_builds_cmd(tmp_path, monkeypatch):
    cfg = make_cfg(str(tmp_path))
    captured = {}

    def fake_run(cmd, **kw):
        captured["cmd"] = cmd
        return _Proc(out="noise\n/repo/pages/wizard/2026-07-27-foo.html\n")

    monkeypatch.setattr(publisher, "_run", fake_run)
    out = publisher.render_page(cfg, "/tmp/x/foo.md", "/repo/pages/wizard", "draft")
    assert out == "/repo/pages/wizard/2026-07-27-foo.html"
    assert captured["cmd"] == [
        "/usr/bin/python3",
        "/repo/pages/tools/render.py",
        "/tmp/x/foo.md",
        "--pages-dir",
        "/repo/pages/wizard",
        "--status",
        "draft",
    ]


def test_render_page_raises_on_nonzero(tmp_path, monkeypatch):
    cfg = make_cfg(str(tmp_path))
    monkeypatch.setattr(publisher, "_run", lambda cmd, **kw: _Proc(rc=1, err="boom"))
    with pytest.raises(publisher.RenderError):
        publisher.render_page(cfg, "/tmp/x/foo.md", "/repo/pages/wizard", "draft")


# ---- git seams ------------------------------------------------------------


def _dispatch(fake_map):
    """Build a fake _run that returns a _Proc based on the git subcommand."""

    def fake_run(cmd, **kw):
        fake_run.calls.append((cmd, kw.get("env") or {}))
        for key, proc in fake_map.items():
            if key in cmd:
                return proc() if callable(proc) else proc
        return _Proc()

    fake_run.calls = []
    return fake_run


def _subcmds(fake):
    return [c[0] for c in fake.calls]


# ---- sync_to_master ------------------------------------------------------


def test_sync_to_master_fetches_resets_and_lands_on_a_branch(tmp_path, monkeypatch):
    cfg = make_cfg(str(tmp_path))
    fake = _dispatch({})
    monkeypatch.setattr(publisher, "_run", fake)
    publisher.sync_to_master(cfg)
    cmds = _subcmds(fake)
    assert any("fetch" in c for c in cmds)
    assert any("reset" in c and "--hard" in c for c in cmds)
    # back onto a real branch — a detached HEAD is what made the 2026-08-17
    # wedge unreadable
    assert any("checkout" in c and "-B" in c and "master" in c for c in cmds)


def test_sync_to_master_never_rebases_or_pulls(tmp_path, monkeypatch):
    """The regression guard: rebase is what wedged the clone permanently.

    A conflicting `git pull --rebase` stops mid-rebase, leaving
    .git/rebase-merge behind, and every later pull then fails with "there is
    already a rebase-merge directory" -> HTTP 500 for every user until the pod
    is replaced. Landing on master by reset cannot conflict.
    """
    cfg = make_cfg(str(tmp_path))
    fake = _dispatch({})
    monkeypatch.setattr(publisher, "_run", fake)
    publisher.sync_to_master(cfg)
    cmds = _subcmds(fake)
    assert not any("pull" in c for c in cmds)
    # the only permitted mention of rebase is abandoning a stale one
    assert all("--abort" in c for c in cmds if "rebase" in c)


def test_sync_to_master_abandons_interrupted_rebase(tmp_path, monkeypatch):
    """A pod that inherited a stale rebase must self-heal, not stay wedged."""
    cfg = make_cfg(str(tmp_path))
    (tmp_path / ".git" / "rebase-merge").mkdir(parents=True)
    fake = _dispatch({})
    monkeypatch.setattr(publisher, "_run", fake)
    publisher.sync_to_master(cfg)
    cmds = _subcmds(fake)
    assert any("rebase" in c and "--abort" in c for c in cmds)


def test_sync_to_master_skips_abort_when_no_stale_state(tmp_path, monkeypatch):
    cfg = make_cfg(str(tmp_path))
    (tmp_path / ".git").mkdir()
    fake = _dispatch({})
    monkeypatch.setattr(publisher, "_run", fake)
    publisher.sync_to_master(cfg)
    assert not any("rebase" in c for c in _subcmds(fake))


@pytest.mark.parametrize("failing", ["fetch", "reset", "checkout"])
def test_sync_to_master_raises_on_git_failure(tmp_path, monkeypatch, failing):
    cfg = make_cfg(str(tmp_path))
    fake = _dispatch({failing: _Proc(rc=1, err="boom")})
    monkeypatch.setattr(publisher, "_run", fake)
    with pytest.raises(publisher.RenderError):
        publisher.sync_to_master(cfg)


def test_sync_to_master_passes_deploy_key_to_fetch(tmp_path, monkeypatch):
    """Without GIT_SSH_COMMAND the fetch cannot authenticate at all."""
    cfg = make_cfg(str(tmp_path))
    fake = _dispatch({})
    monkeypatch.setattr(publisher, "_run", fake)
    publisher.sync_to_master(cfg)
    fetch_env = next(env for cmd, env in fake.calls if "fetch" in cmd)
    assert cfg.deploy_key_path in fetch_env["GIT_SSH_COMMAND"]


# ---- stage_and_commit / push_to_master -----------------------------------


def test_stage_and_commit_commits_and_reports_true(tmp_path, monkeypatch):
    cfg = make_cfg(str(tmp_path))
    fake = _dispatch({"status": _Proc(out=" M pages/wizard/x.html")})
    monkeypatch.setattr(publisher, "_run", fake)
    assert publisher.stage_and_commit(cfg, "pages/wizard", "foo", "wizard", "draft")
    cmds = _subcmds(fake)
    assert any("add" in c for c in cmds)
    assert any("commit" in c for c in cmds)


def test_stage_and_commit_reports_false_when_nothing_changed(tmp_path, monkeypatch):
    cfg = make_cfg(str(tmp_path))
    fake = _dispatch({"status": _Proc(out="")})
    monkeypatch.setattr(publisher, "_run", fake)
    assert not publisher.stage_and_commit(cfg, "pages/wizard", "foo", "wizard", "draft")
    assert not any("commit" in c for c in _subcmds(fake))


def test_stage_and_commit_status_is_scoped_to_the_target_dir(tmp_path, monkeypatch):
    """An unrelated change elsewhere in the clone is not this page's change."""
    cfg = make_cfg(str(tmp_path))
    fake = _dispatch({"status": _Proc(out=" M pages/emo/x.html")})
    monkeypatch.setattr(publisher, "_run", fake)
    publisher.stage_and_commit(cfg, "pages/emo", "foo", "emo", "draft")
    status_cmd = next(cmd for cmd in _subcmds(fake) if "status" in cmd)
    assert "pages/emo/" in status_cmd


def test_stage_and_commit_raises_on_commit_failure(tmp_path, monkeypatch):
    cfg = make_cfg(str(tmp_path))
    fake = _dispatch({"status": _Proc(out=" M x"), "commit": _Proc(rc=1, err="nope")})
    monkeypatch.setattr(publisher, "_run", fake)
    with pytest.raises(publisher.RenderError):
        publisher.stage_and_commit(cfg, "pages/wizard", "foo", "wizard", "draft")


def test_push_to_master_reports_failure_with_stderr(tmp_path, monkeypatch):
    cfg = make_cfg(str(tmp_path))
    fake = _dispatch({"push": _Proc(rc=1, err="non-fast-forward")})
    monkeypatch.setattr(publisher, "_run", fake)
    ok, err = publisher.push_to_master(cfg, "wizard")
    assert not ok
    assert "non-fast-forward" in err


def test_commit_author_is_user_committer_is_service(tmp_path, monkeypatch):
    cfg = make_cfg(str(tmp_path))
    fake = _dispatch({"status": _Proc(out=" M x")})
    monkeypatch.setattr(publisher, "_run", fake)
    publisher.stage_and_commit(cfg, "pages/emo", "foo", "emo", "approved")
    envs = [c[1] for c in fake.calls]
    assert any(e.get("GIT_AUTHOR_NAME") == "emo" for e in envs)
    assert any(e.get("GIT_AUTHOR_EMAIL") == "emo@viktorbarzin.me" for e in envs)
    assert all(
        e.get("GIT_COMMITTER_NAME") == "pages-publish" for e in envs if "GIT_SSH_COMMAND" in e
    )


# ---- publish retry loop --------------------------------------------------


def _stub_pipeline(monkeypatch, push_results):
    """Stub publish()'s collaborators; record the order they run in."""
    seen = {"sync": 0, "render": 0, "commit": 0, "push": 0}

    monkeypatch.setattr(publisher, "ensure_repo", lambda _c: None)

    def fake_sync(_cfg):
        seen["sync"] += 1

    def fake_render(_cfg, md_path, abs_target, status):
        seen["render"] += 1
        return f"{abs_target}/2026-08-17-foo.html"

    def fake_commit(_cfg, subdir, slug, user, status):
        seen["commit"] += 1
        return True

    def fake_push(_cfg, user):
        seen["push"] += 1
        return push_results.pop(0)

    monkeypatch.setattr(publisher, "sync_to_master", fake_sync)
    monkeypatch.setattr(publisher, "render_page", fake_render)
    monkeypatch.setattr(publisher, "stage_and_commit", fake_commit)
    monkeypatch.setattr(publisher, "push_to_master", fake_push)
    return seen


def test_publish_re_renders_onto_fresh_master_after_a_lost_race(tmp_path, monkeypatch):
    """A rejected push re-syncs and re-renders instead of rebasing.

    The page is a pure function of its markdown, so re-rendering on top of
    current master is idempotent — which is why this needs no conflict
    resolution and cannot wedge.
    """
    cfg = make_cfg(str(tmp_path))
    seen = _stub_pipeline(monkeypatch, [(False, "non-fast-forward"), (True, "")])
    out = publisher.publish(
        cfg, user="emo", content="# hi", filename="foo.md", status="draft"
    )
    assert seen == {"sync": 2, "render": 2, "commit": 2, "push": 2}
    assert out["url"] == "https://pages.viktorbarzin.me/2026-08-17-foo.html"


def test_publish_gives_up_after_attempts(tmp_path, monkeypatch):
    cfg = make_cfg(str(tmp_path))
    seen = _stub_pipeline(monkeypatch, [(False, "non-fast-forward")] * 3)
    with pytest.raises(publisher.RenderError):
        publisher.publish(
            cfg, user="emo", content="# hi", filename="foo.md", attempts=3
        )
    assert seen["push"] == 3
    assert seen["sync"] == 3


def test_publish_returns_url_when_content_already_published(tmp_path, monkeypatch):
    """Re-publishing identical markdown is a no-op that still returns the URL."""
    cfg = make_cfg(str(tmp_path))
    seen = _stub_pipeline(monkeypatch, [])
    monkeypatch.setattr(
        publisher, "stage_and_commit", lambda *a, **k: False
    )
    out = publisher.publish(cfg, user="emo", content="# hi", filename="foo.md")
    assert seen["push"] == 0
    assert out["path"] == "pages/emo/2026-08-17-foo.html"


def test_publish_syncs_before_rendering(tmp_path, monkeypatch):
    """Render must see current master, or the regenerated index drops pages."""
    cfg = make_cfg(str(tmp_path))
    order = []
    monkeypatch.setattr(publisher, "ensure_repo", lambda _c: None)
    monkeypatch.setattr(
        publisher, "sync_to_master", lambda _c: order.append("sync")
    )
    monkeypatch.setattr(
        publisher,
        "render_page",
        lambda _c, m, t, s: (order.append("render"), f"{t}/x.html")[1],
    )
    monkeypatch.setattr(publisher, "stage_and_commit", lambda *a, **k: True)
    monkeypatch.setattr(publisher, "push_to_master", lambda *a, **k: (True, ""))
    publisher.publish(cfg, user="emo", content="# hi", filename="foo.md")
    assert order == ["sync", "render"]


# ---- preview (render without publishing) ----------------------------------


def _preview_cfg(tmp_path, monkeypatch, html, assets=None):
    """A cfg whose repo has a pages/assets/ tree, with git + render stubbed."""
    cfg = make_cfg(str(tmp_path))
    assets_dir = tmp_path / "pages" / "assets"
    assets_dir.mkdir(parents=True)
    for name, body in (assets or {}).items():
        (assets_dir / name).write_text(body, encoding="utf-8")

    calls = {"ensure": 0, "sync": 0, "render": None}

    def fake_ensure_repo(_cfg):
        calls["ensure"] += 1

    def fake_sync(_cfg):
        calls["sync"] += 1

    def fake_render(_cfg, md_path, abs_target, status):
        calls["render"] = {"abs_target": abs_target, "status": status}
        with open(md_path, encoding="utf-8") as f:
            calls["render"]["content"] = f.read()
        out = os.path.join(abs_target, "2026-07-27-foo.html")
        with open(out, "w", encoding="utf-8") as f:
            f.write(html)
        return out

    monkeypatch.setattr(publisher, "ensure_repo", fake_ensure_repo)
    monkeypatch.setattr(publisher, "sync_to_master", fake_sync)
    monkeypatch.setattr(publisher, "render_page", fake_render)
    return cfg, calls


def test_preview_returns_the_page_and_only_the_assets_it_links(tmp_path, monkeypatch):
    html = '<link rel="stylesheet" href="/assets/page.css"><h1>hi</h1>'
    cfg, calls = _preview_cfg(
        tmp_path,
        monkeypatch,
        html,
        {"page.css": "body{}", "mermaid.min.js": "// 3.5MB in real life"},
    )

    out = publisher.render_preview(
        cfg, user="emo", content="# hi\n", filename="2026-07-27-foo.md", status="done"
    )

    assert out["filename"] == "2026-07-27-foo.html"
    assert out["html"] == html
    # page.css is linked, mermaid.min.js is not — a doc with no diagram must not
    # drag 3.5MB of javascript through the API
    assert out["assets"] == {"assets/page.css": "body{}"}
    assert calls["render"]["status"] == "done"
    assert calls["render"]["content"] == "# hi\n"


def test_preview_carries_mermaid_when_the_page_asks_for_it(tmp_path, monkeypatch):
    html = '<script src="/assets/mermaid.min.js"></script><pre class="mermaid">x</pre>'
    cfg, _ = _preview_cfg(
        tmp_path, monkeypatch, html, {"page.css": "body{}", "mermaid.min.js": "MERMAID"}
    )

    out = publisher.render_preview(
        cfg, user="emo", content="# d\n", filename="d.md"
    )

    assert out["assets"] == {"assets/mermaid.min.js": "MERMAID"}


def test_preview_renders_outside_the_clone(tmp_path, monkeypatch):
    """The render must not land in <repo>/pages/<user>/.

    An untracked page left there is staged by the NEXT publish's
    `git add -- pages/<user>/` and pushed as part of someone else's page.
    """
    cfg, calls = _preview_cfg(tmp_path, monkeypatch, "<h1>x</h1>")

    publisher.render_preview(cfg, user="emo", content="# x\n", filename="x.md")

    target = calls["render"]["abs_target"]
    assert not target.startswith(cfg.repo_dir)
    assert not os.path.exists(os.path.join(cfg.repo_dir, "pages", "emo"))


def test_preview_syncs_before_rendering(tmp_path, monkeypatch):
    # The renderer and the stylesheet both live in the clone, so a preview of
    # stale master would show a page the site would not serve.
    cfg, calls = _preview_cfg(tmp_path, monkeypatch, "<h1>x</h1>")

    publisher.render_preview(cfg, user="emo", content="# x\n", filename="x.md")

    assert calls["ensure"] == 1
    assert calls["sync"] == 1


def test_preview_never_commits_or_pushes(tmp_path, monkeypatch):
    cfg, _ = _preview_cfg(tmp_path, monkeypatch, "<h1>x</h1>")

    def explode(*a, **k):  # pragma: no cover - the assertion is that it is unused
        raise AssertionError("preview must not touch git history")

    monkeypatch.setattr(publisher, "stage_and_commit", explode)
    monkeypatch.setattr(publisher, "push_to_master", explode)

    publisher.render_preview(cfg, user="emo", content="# x\n", filename="x.md")


@pytest.mark.parametrize("bad", ["../x", "a/b", "", "café"])
def test_preview_rejects_a_bad_filename(tmp_path, monkeypatch, bad):
    cfg, _ = _preview_cfg(tmp_path, monkeypatch, "<h1>x</h1>")
    with pytest.raises(publisher.PublishError):
        publisher.render_preview(cfg, user="emo", content="# x\n", filename=bad)


def test_preview_rejects_a_bad_status(tmp_path, monkeypatch):
    cfg, _ = _preview_cfg(tmp_path, monkeypatch, "<h1>x</h1>")
    with pytest.raises(publisher.PublishError):
        publisher.render_preview(
            cfg, user="emo", content="# x\n", filename="x.md", status="bogus"
        )


def test_collect_assets_skips_a_missing_file(tmp_path, monkeypatch):
    # An unstyled preview beats a 500: the caller still gets to look at the page.
    cfg, _ = _preview_cfg(tmp_path, monkeypatch, "<h1>x</h1>", {})
    assets = publisher.collect_assets(cfg, '<link href="/assets/gone.css">')
    assert assets == {}


# ---- bundles (raw multi-file publish) -------------------------------------


def _f(path, content="x", encoding="utf-8"):
    return {"path": path, "content": content, "encoding": encoding}


@pytest.mark.parametrize(
    "path",
    ["index.html", "assets/app.js", "a/b/c.css", "og.png", "data.v2.json", "A-B_c"],
)
def test_validate_bundle_files_accepts(path):
    out = publisher.validate_bundle_files([_f(path, "hi")])
    assert out == [(path, b"hi")]


@pytest.mark.parametrize(
    "path",
    [
        "",
        ".",
        "..",
        "../x",
        "a/../b",
        "a/..b/c",  # '..' anywhere, as sanitize_slug
        "/abs",
        "a//b",
        "a/",
        "./a",
        ".git/config",
        ".hidden",
        "a/.htaccess",
        "foo bar",
        "a\\b",
        "café.html",
        "a/b/c/d",
    ],
)
def test_validate_bundle_files_rejects_paths(path):
    with pytest.raises(publisher.PublishError):
        publisher.validate_bundle_files([_f(path)])


def test_validate_bundle_files_rejects_empty_set():
    with pytest.raises(publisher.PublishError):
        publisher.validate_bundle_files([])


def test_validate_bundle_files_rejects_duplicates():
    with pytest.raises(publisher.PublishError):
        publisher.validate_bundle_files([_f("a.html"), _f("a.html")])


def test_validate_bundle_files_rejects_file_dir_clash():
    """'a' as a file and as the parent of 'a/b' cannot both be written."""
    with pytest.raises(publisher.PublishError):
        publisher.validate_bundle_files([_f("a"), _f("a/b.html")])


def test_validate_bundle_files_decodes_base64():
    raw = b"\x89PNG\r\n\x1a\n\x00\xff"
    out = publisher.validate_bundle_files(
        [_f("og.png", base64.b64encode(raw).decode(), "base64")]
    )
    assert out == [("og.png", raw)]


def test_validate_bundle_files_rejects_bad_base64():
    with pytest.raises(publisher.PublishError):
        publisher.validate_bundle_files([_f("og.png", "@@@not-b64", "base64")])


def test_validate_bundle_files_rejects_unknown_encoding():
    with pytest.raises(publisher.PublishError):
        publisher.validate_bundle_files([_f("a.txt", "x", "latin-1")])


def test_validate_bundle_files_caps_file_count(monkeypatch):
    monkeypatch.setattr(publisher, "MAX_BUNDLE_FILES", 3)
    publisher.validate_bundle_files([_f(f"{i}.html") for i in range(3)])
    with pytest.raises(publisher.PublishError):
        publisher.validate_bundle_files([_f(f"{i}.html") for i in range(4)])


def test_validate_bundle_files_caps_total_bytes(monkeypatch):
    monkeypatch.setattr(publisher, "MAX_BUNDLE_BYTES", 10)
    publisher.validate_bundle_files([_f("a", "12345"), _f("b", "12345")])
    with pytest.raises(publisher.PublishError):
        publisher.validate_bundle_files([_f("a", "12345"), _f("b", "123456")])


def test_bundle_subdir_rejects_unsafe_segments():
    assert publisher.bundle_subdir("showcase", "homelab") == "pages/showcase/homelab"
    for user, slug in [("..", "x"), ("a/b", "x"), ("x", ".."), ("x", ""), ("shared", "x")]:
        with pytest.raises(publisher.PublishError):
            publisher.bundle_subdir(user, slug)


def test_stage_and_commit_bundle_stages_deletions_scoped(tmp_path, monkeypatch):
    cfg = make_cfg(str(tmp_path))
    fake = _dispatch({"status": _Proc(out=" D pages/showcase/homelab/old.js")})
    monkeypatch.setattr(publisher, "_run", fake)
    assert publisher.stage_and_commit_bundle(
        cfg, "pages/showcase/homelab", "showcase", "homelab"
    )
    cmds = _subcmds(fake)
    add = next(c for c in cmds if "add" in c)
    assert "-A" in add and add[-1] == "pages/showcase/homelab/"
    status = next(c for c in cmds if "status" in c)
    assert status[-1] == "pages/showcase/homelab/"
    commit = next(c for c in cmds if "commit" in c)
    assert "pages: publish bundle showcase/homelab" in commit
    envs = [e for c, e in fake.calls if "commit" in c]
    assert envs[0]["GIT_AUTHOR_NAME"] == "showcase"


def test_stage_and_commit_bundle_false_when_unchanged(tmp_path, monkeypatch):
    cfg = make_cfg(str(tmp_path))
    fake = _dispatch({"status": _Proc(out="")})
    monkeypatch.setattr(publisher, "_run", fake)
    assert not publisher.stage_and_commit_bundle(
        cfg, "pages/showcase/homelab", "showcase", "homelab"
    )
    assert not any("commit" in c for c in _subcmds(fake))


def _stub_bundle_pipeline(tmp_path, monkeypatch, push_results, commit=True):
    """Stub git; each sync puts master's copy of the bundle back on disk."""
    target = tmp_path / "pages" / "showcase" / "homelab"
    seen = {"sync": 0, "commit": 0, "push": 0, "on_disk_at_commit": []}

    monkeypatch.setattr(publisher, "ensure_repo", lambda _c: None)

    def fake_sync(_cfg):
        seen["sync"] += 1
        (target / "old").mkdir(parents=True, exist_ok=True)
        (target / "old" / "stale.js").write_text("stale")
        (target / "index.html").write_text("master's index")

    def fake_commit(_cfg, subdir, user, slug):
        seen["commit"] += 1
        seen["on_disk_at_commit"].append(
            sorted(str(p.relative_to(target)) for p in target.rglob("*") if p.is_file())
        )
        return commit

    def fake_push(_cfg, user):
        seen["push"] += 1
        return push_results.pop(0)

    monkeypatch.setattr(publisher, "sync_to_master", fake_sync)
    monkeypatch.setattr(publisher, "stage_and_commit_bundle", fake_commit)
    monkeypatch.setattr(publisher, "push_to_master", fake_push)
    return target, seen


def test_publish_bundle_replaces_the_dir_dropping_stale_files(tmp_path, monkeypatch):
    cfg = make_cfg(str(tmp_path))
    target, seen = _stub_bundle_pipeline(tmp_path, monkeypatch, [(True, "")])
    out = publisher.publish_bundle(
        cfg,
        user="showcase",
        slug="homelab",
        files=[_f("index.html", "new"), _f("assets/app.js", "js")],
    )
    assert out == {
        "url": "https://pages.viktorbarzin.me/homelab/",
        "path": "pages/showcase/homelab",
        "committed": True,
        "files": 2,
    }
    assert seen["on_disk_at_commit"] == [["assets/app.js", "index.html"]]
    assert (target / "index.html").read_text() == "new"
    assert not (target / "old").exists()


def test_publish_bundle_rewrites_after_a_lost_race(tmp_path, monkeypatch):
    cfg = make_cfg(str(tmp_path))
    target, seen = _stub_bundle_pipeline(
        tmp_path, monkeypatch, [(False, "non-fast-forward"), (True, "")]
    )
    publisher.publish_bundle(
        cfg, user="showcase", slug="homelab", files=[_f("index.html", "new")]
    )
    assert (seen["sync"], seen["commit"], seen["push"]) == (2, 2, 2)
    # the second attempt rewrote the bundle over the master that won
    assert seen["on_disk_at_commit"] == [["index.html"], ["index.html"]]
    assert (target / "index.html").read_text() == "new"


def test_publish_bundle_gives_up_after_attempts(tmp_path, monkeypatch):
    cfg = make_cfg(str(tmp_path))
    _, seen = _stub_bundle_pipeline(
        tmp_path, monkeypatch, [(False, "non-fast-forward")] * 3
    )
    with pytest.raises(publisher.RenderError):
        publisher.publish_bundle(
            cfg, user="showcase", slug="homelab", files=[_f("a.html")], attempts=3
        )
    assert seen["push"] == 3


def test_publish_bundle_unchanged_returns_without_pushing(tmp_path, monkeypatch):
    cfg = make_cfg(str(tmp_path))
    _, seen = _stub_bundle_pipeline(tmp_path, monkeypatch, [], commit=False)
    out = publisher.publish_bundle(
        cfg, user="showcase", slug="homelab", files=[_f("index.html")]
    )
    assert out["committed"] is False
    assert seen["push"] == 0


def test_publish_bundle_validates_before_touching_the_repo(tmp_path, monkeypatch):
    cfg = make_cfg(str(tmp_path))
    _, seen = _stub_bundle_pipeline(tmp_path, monkeypatch, [])
    with pytest.raises(publisher.PublishError):
        publisher.publish_bundle(
            cfg, user="showcase", slug="homelab", files=[_f("../escape")]
        )
    assert seen["sync"] == 0


def test_publish_bundle_refuses_a_symlinked_target(tmp_path, monkeypatch):
    """A symlink committed at pages/<user>/ must not redirect the rmtree."""
    cfg = make_cfg(str(tmp_path))
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "keep.txt").write_text("keep")
    (tmp_path / "pages").mkdir()
    (tmp_path / "pages" / "showcase").symlink_to(outside)
    monkeypatch.setattr(publisher, "ensure_repo", lambda _c: None)
    monkeypatch.setattr(publisher, "sync_to_master", lambda _c: None)
    with pytest.raises(publisher.PublishError):
        publisher.publish_bundle(
            cfg, user="showcase", slug="homelab", files=[_f("index.html")]
        )
    assert (outside / "keep.txt").read_text() == "keep"
