#!/usr/bin/env python3
"""Tests for presence and its three Claude Code hooks.

Run them by hand from the infra repo (needs pytest and pymysql, both present
on the devvm):

    python3 -m pytest -q playbooks/files/devvm/presence-test.py

presence talks to the beads MySQL; the tests replace pymysql.connect with a
mock, so they never reach it. The hook tests run the real hook scripts against
a stub presence and a throwaway $HOME.
"""
import getpass
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path
from unittest.mock import MagicMock

import pytest

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "presence"


@pytest.fixture
def fake_db(monkeypatch):
    """Mocks pymysql.connect to return a MagicMock cursor we can inspect."""
    conn = MagicMock(name="conn")
    cur = MagicMock(name="cur")
    conn.cursor.return_value.__enter__.return_value = cur
    cur.fetchall.return_value = []

    import pymysql
    monkeypatch.setattr(pymysql, "connect", MagicMock(return_value=conn))
    monkeypatch.setenv("CLAUDE_SESSION_ID", "wizard@devvm@testtest")
    return cur

def test_help_lists_subcommands():
    """--help should list all supported subcommands."""
    result = subprocess.run(
        [str(SCRIPT), "--help"], capture_output=True, text=True
    )
    assert result.returncode == 0
    for verb in ("claim", "heartbeat", "release", "list", "peek"):
        assert verb in result.stdout


def _load_module():
    # SCRIPT has no .py extension, so we need an explicit SourceFileLoader.
    loader = importlib.machinery.SourceFileLoader("presence", str(SCRIPT))
    spec = importlib.util.spec_from_loader("presence", loader)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["presence"] = mod
    spec.loader.exec_module(mod)
    return mod


def test_claim_inserts_row(fake_db):
    presence = _load_module()
    rc = presence.main(["claim", "node:k8s-node1", "--purpose", "GPU upgrade"])
    assert rc == 0
    # First call: insert/upsert; second: read existing other-session claims
    sql_calls = [c.args[0] for c in fake_db.execute.call_args_list]
    assert any("INSERT" in s.upper() or "REPLACE" in s.upper() for s in sql_calls)
    assert any("SELECT" in s.upper() for s in sql_calls)


def test_claim_reports_other_session_conflict(fake_db, capsys):
    presence = _load_module()
    # Simulate one OTHER session already holding the label
    fake_db.fetchall.return_value = [
        {
            "session_id": "emo@laptop@aaaaaaaa",
            "purpose": "tcpdump on uplink",
            "claimed_at": "2026-05-17 14:10:00.000",
            "user": "emo",
            "host": "laptop",
        }
    ]
    rc = presence.main(["claim", "node:k8s-node1", "--purpose", "GPU upgrade"])
    out = capsys.readouterr().out
    assert rc == 0
    assert "emo@laptop@aaaaaaaa" in out
    assert "tcpdump on uplink" in out


def test_peek_shows_all_active_claims_for_resource(fake_db, capsys):
    presence = _load_module()
    fake_db.fetchall.return_value = [
        {
            "session_id": "wizard@devvm@bbbbbbbb",
            "purpose": "GPU driver upgrade",
            "claimed_at": "2026-05-17 14:32:00.000",
            "expires_at": "2026-05-17 14:47:00.000",
            "user": "wizard",
            "host": "devvm",
        }
    ]
    rc = presence.main(["peek", "node:k8s-node1"])
    out = capsys.readouterr().out
    assert rc == 0
    assert "wizard@devvm@bbbbbbbb" in out
    assert "GPU driver upgrade" in out


def test_peek_empty_resource_prints_no_active_claim(fake_db, capsys):
    presence = _load_module()
    fake_db.fetchall.return_value = []
    rc = presence.main(["peek", "node:k8s-node99"])
    out = capsys.readouterr().out
    assert rc == 0
    assert "no active claim" in out.lower()


def test_list_all_shows_only_active(fake_db, capsys):
    presence = _load_module()
    fake_db.fetchall.return_value = [
        {
            "session_id": "wizard@devvm@xxxxxxxx",
            "resource_label": "stack:gpu-operator",
            "purpose": "rebuild driver",
            "claimed_at": "2026-05-17 14:00:00.000",
            "expires_at": "2026-05-17 14:15:00.000",
            "user": "wizard",
            "host": "devvm",
        }
    ]
    rc = presence.main(["list", "--all"])
    out = capsys.readouterr().out
    assert rc == 0
    assert "stack:gpu-operator" in out
    assert "wizard@devvm@xxxxxxxx" in out


def test_list_mine_filters_to_current_session(fake_db, monkeypatch):
    presence = _load_module()
    presence.main(["list", "--mine"])
    sql = fake_db.execute.call_args_list[-1].args[0]
    assert "session_id" in sql
    assert "expires_at" in sql


def test_heartbeat_extends_all_my_claims(fake_db):
    presence = _load_module()
    rc = presence.main(["heartbeat"])
    assert rc == 0
    sql = fake_db.execute.call_args_list[-1].args[0]
    assert "UPDATE" in sql.upper()
    assert "expires_at" in sql
    assert "session_id" in sql


def test_release_single_label(fake_db):
    presence = _load_module()
    rc = presence.main(["release", "node:k8s-node1"])
    assert rc == 0
    last = fake_db.execute.call_args_list[-1]
    assert "DELETE" in last.args[0].upper()
    assert "node:k8s-node1" in last.args[1]


def test_release_all_mine(fake_db):
    presence = _load_module()
    rc = presence.main(["release", "--all-mine"])
    assert rc == 0
    last = fake_db.execute.call_args_list[-1]
    assert "DELETE" in last.args[0].upper()
    assert "wizard@devvm@testtest" in last.args[1]


def test_list_json_emits_array(fake_db, capsys):
    presence = _load_module()
    fake_db.fetchall.return_value = [
        {
            "session_id": "wizard@devvm@yyyyyyyy",
            "resource_label": "stack:gpu-operator",
            "purpose": "rebuild driver",
            "claimed_at": "2026-05-17 14:00:00.000",
            "expires_at": "2026-05-17 14:15:00.000",
            "user": "wizard",
            "host": "devvm",
        }
    ]
    rc = presence.main(["--json", "list", "--all"])
    out = capsys.readouterr().out
    assert rc == 0
    payload = json.loads(out)
    assert isinstance(payload, list)
    assert payload[0]["resource_label"] == "stack:gpu-operator"


def test_claim_returns_zero_when_db_unreachable(monkeypatch, capsys):
    monkeypatch.setenv("CLAUDE_SESSION_ID", "wizard@devvm@offlineee")
    monkeypatch.setenv("PRESENCE_DSN", "mysql://beads@127.0.0.1:1/beads")
    presence = _load_module()
    rc = presence.main(["claim", "node:nowhere", "--purpose", "test"])
    err = capsys.readouterr().err
    assert rc == 0
    assert "dolt unreachable" in err


def test_session_id_comes_from_the_users_state_dir(tmp_path, monkeypatch):
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)
    monkeypatch.setenv("PRESENCE_STATE_DIR", str(tmp_path))
    (tmp_path / "current.session").write_text("emo@devvm@12345678")
    presence = _load_module()
    assert presence.get_session_id() == "emo@devvm@12345678"


# ---- hooks -----------------------------------------------------------------

def _stub_presence(tmp_path):
    """A presence stand-in that records its arguments and session id."""
    log = tmp_path / "calls.log"
    stub = tmp_path / "presence-stub"
    stub.write_text(
        "#!/bin/sh\n"
        f'echo "$CLAUDE_SESSION_ID $*" >> "{log}"\n'
    )
    stub.chmod(0o755)
    return stub, log


def _run_hook(name, home, stub):
    env = {
        "PATH": os.environ["PATH"],
        "HOME": str(home),
        "PRESENCE_BIN": str(stub),
    }
    return subprocess.run([str(HERE / f"presence-{name}")], env=env,
                          capture_output=True, text=True, timeout=10)


def test_session_start_writes_a_per_user_id_under_home(tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    stub, _ = _stub_presence(tmp_path)
    assert _run_hook("session-start", home, stub).returncode == 0
    sid = (home / ".cache/claude-presence/current.session").read_text()
    user, host, rand = sid.split("@")
    assert user == getpass.getuser()
    assert host and len(rand) == 8


def test_heartbeat_uses_the_session_id_and_is_throttled(tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    stub, log = _stub_presence(tmp_path)
    _run_hook("session-start", home, stub)
    sid = (home / ".cache/claude-presence/current.session").read_text()
    assert _run_hook("heartbeat", home, stub).returncode == 0
    assert _run_hook("heartbeat", home, stub).returncode == 0
    assert log.read_text().splitlines() == [f"{sid} heartbeat"]


def test_release_releases_all_of_this_sessions_claims(tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    stub, log = _stub_presence(tmp_path)
    _run_hook("session-start", home, stub)
    sid = (home / ".cache/claude-presence/current.session").read_text()
    assert _run_hook("release", home, stub).returncode == 0
    assert log.read_text().splitlines() == [f"{sid} release --all-mine"]


def test_hooks_do_nothing_without_a_session(tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    stub, log = _stub_presence(tmp_path)
    for hook in ("heartbeat", "release"):
        assert _run_hook(hook, home, stub).returncode == 0
    assert not log.exists()


def test_hooks_never_fail_when_presence_is_missing(tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    missing = tmp_path / "no-such-presence"
    _run_hook("session-start", home, missing)
    for hook in ("heartbeat", "release"):
        assert _run_hook(hook, home, missing).returncode == 0


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
