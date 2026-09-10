import pytest

from app import config


def make_cfg(repo_dir: str) -> config.Config:
    return config.Config(
        key_map={"tok-viktor": "wizard", "tok-emo": "emo"},
        repo_dir=repo_dir,
        deploy_key_path="/etc/pages-deploy/id_ed25519",
        render_script="/repo/pages/tools/render.py",
        render_dir_flag="--pages-dir",
        repo_url="git@github.com:ViktorBarzin/monorepo.git",
        base_url="https://pages.viktorbarzin.me",
        committer_name="pages-publish",
        committer_email="pages-publish@viktorbarzin.me",
        author_email_domain="viktorbarzin.me",
        python_bin="/usr/bin/python3",
    )


@pytest.fixture
def cfg(tmp_path):
    return make_cfg(str(tmp_path))


@pytest.fixture
def client(cfg, monkeypatch):
    """TestClient with the render + git seams stubbed.

    sanitize_slug / validate_status / target_subdir and the URL/path derivation
    run for real; only the subprocess-backed render + git steps are faked, so
    the auth + validation + path-shaping behaviour is exercised end to end.
    """
    from fastapi.testclient import TestClient

    from app import main, publisher

    calls: dict[str, dict] = {}

    def fake_ensure_repo(_cfg):
        calls["ensure"] = {}

    def fake_render_page(_cfg, md_path, abs_target, status):
        with open(md_path, encoding="utf-8") as f:
            content = f.read()
        calls["render"] = {
            "md_path": md_path,
            "abs_target": abs_target,
            "status": status,
            "content": content,
        }
        return f"{abs_target}/2026-07-27-foo.html"

    def fake_sync_to_master(_cfg):
        calls["sync"] = {}

    def fake_stage_and_commit(_cfg, subdir, slug, user, status):
        calls["commit"] = {
            "subdir": subdir,
            "slug": slug,
            "user": user,
            "status": status,
        }
        return True

    def fake_push_to_master(_cfg, user):
        calls["push"] = {"user": user}
        return True, ""

    monkeypatch.setattr(publisher, "ensure_repo", fake_ensure_repo)
    monkeypatch.setattr(publisher, "sync_to_master", fake_sync_to_master)
    monkeypatch.setattr(publisher, "render_page", fake_render_page)
    monkeypatch.setattr(publisher, "stage_and_commit", fake_stage_and_commit)
    monkeypatch.setattr(publisher, "push_to_master", fake_push_to_master)

    test_client = TestClient(main.create_app(cfg))
    test_client.calls = calls
    return test_client
