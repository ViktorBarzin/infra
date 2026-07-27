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


# ---- commit_and_push seam -------------------------------------------------


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


def test_commit_and_push_happy_path(tmp_path, monkeypatch):
    cfg = make_cfg(str(tmp_path))
    fake = _dispatch(
        {"status": _Proc(out=" M pages/wizard/x.html"), "push": _Proc()}
    )
    monkeypatch.setattr(publisher, "_run", fake)
    publisher.commit_and_push(cfg, "pages/wizard", "foo", "wizard", "draft")
    subcmds = [c[0] for c in fake.calls]
    assert any("add" in c for c in subcmds)
    assert any("commit" in c for c in subcmds)
    assert sum("push" in c for c in subcmds) == 1


def test_commit_and_push_noop_when_clean(tmp_path, monkeypatch):
    cfg = make_cfg(str(tmp_path))
    fake = _dispatch({"status": _Proc(out="")})  # clean tree
    monkeypatch.setattr(publisher, "_run", fake)
    publisher.commit_and_push(cfg, "pages/wizard", "foo", "wizard", "draft")
    subcmds = [c[0] for c in fake.calls]
    assert not any("commit" in c for c in subcmds)
    assert not any("push" in c for c in subcmds)


def test_commit_and_push_rebase_retry_on_non_ff(tmp_path, monkeypatch):
    cfg = make_cfg(str(tmp_path))
    pushes = [_Proc(rc=1, err="non-fast-forward"), _Proc(rc=0)]
    fake = _dispatch(
        {
            "status": _Proc(out=" M x"),
            "push": lambda: pushes.pop(0),
            "pull": _Proc(rc=0),
        }
    )
    monkeypatch.setattr(publisher, "_run", fake)
    publisher.commit_and_push(cfg, "pages/wizard", "foo", "wizard", "draft")
    subcmds = [c[0] for c in fake.calls]
    assert sum("push" in c for c in subcmds) == 2
    assert sum("pull" in c for c in subcmds) == 1


def test_commit_and_push_gives_up_after_retries(tmp_path, monkeypatch):
    cfg = make_cfg(str(tmp_path))
    fake = _dispatch(
        {
            "status": _Proc(out=" M x"),
            "push": _Proc(rc=1, err="non-fast-forward"),
            "pull": _Proc(rc=0),
        }
    )
    monkeypatch.setattr(publisher, "_run", fake)
    with pytest.raises(publisher.RenderError):
        publisher.commit_and_push(cfg, "pages/wizard", "foo", "wizard", "draft", retries=3)
    subcmds = [c[0] for c in fake.calls]
    assert sum("push" in c for c in subcmds) == 3


def test_commit_author_is_user_committer_is_service(tmp_path, monkeypatch):
    cfg = make_cfg(str(tmp_path))
    fake = _dispatch({"status": _Proc(out=" M x"), "push": _Proc()})
    monkeypatch.setattr(publisher, "_run", fake)
    publisher.commit_and_push(cfg, "pages/emo", "foo", "emo", "approved")
    envs = [c[1] for c in fake.calls]
    assert any(e.get("GIT_AUTHOR_NAME") == "emo" for e in envs)
    assert any(e.get("GIT_AUTHOR_EMAIL") == "emo@viktorbarzin.me" for e in envs)
    assert all(
        e.get("GIT_COMMITTER_NAME") == "pages-publish" for e in envs if "GIT_SSH_COMMAND" in e
    )
