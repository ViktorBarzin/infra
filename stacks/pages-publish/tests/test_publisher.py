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
