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


def test_session_id_is_this_claude_sessions_own_id(monkeypatch):
    """Each Claude session exports its own id to the Bash tool, so two
    sessions of one user never share an id (and never release each other's
    claims). The user@host prefix keeps the board readable."""
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)
    monkeypatch.setenv("CLAUDE_CODE_SESSION_ID", "15aba44f-f368-4b06-9bdd-30115cd22824")
    presence = _load_module()
    user, host, sid = presence.get_session_id().split("@")
    assert user == getpass.getuser()
    assert host
    assert sid == "15aba44f-f368-4b06-9bdd-30115cd22824"


def test_explicit_claude_session_id_wins(monkeypatch):
    monkeypatch.setenv("CLAUDE_SESSION_ID", "wizard@devvm@pinned")
    monkeypatch.setenv("CLAUDE_CODE_SESSION_ID", "15aba44f-f368-4b06-9bdd-30115cd22824")
    presence = _load_module()
    assert presence.get_session_id() == "wizard@devvm@pinned"


def test_outside_claude_the_id_is_one_shot(monkeypatch):
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)
    monkeypatch.delenv("CLAUDE_CODE_SESSION_ID", raising=False)
    presence = _load_module()
    a, b = presence.get_session_id(), presence.get_session_id()
    assert a != b
    assert a.startswith(f"{getpass.getuser()}@")


# ---- hooks -----------------------------------------------------------------

def _stub_presence(tmp_path):
    """A presence stand-in that records the session it was run for and its
    arguments, one line per call."""
    log = tmp_path / "calls.log"
    stub = tmp_path / "presence-stub"
    stub.write_text(
        "#!/bin/sh\n"
        f'echo "${{CLAUDE_CODE_SESSION_ID:-none}} $*" >> "{log}"\n'
    )
    stub.chmod(0o755)
    return stub, log


def _run_hook(name, home, stub, session_id=None, env_extra=None):
    """Runs a hook the way Claude Code does: hook input as JSON on stdin."""
    env = {
        "PATH": os.environ["PATH"],
        "HOME": str(home),
        "PRESENCE_BIN": str(stub),
    }
    env.update(env_extra or {})
    payload = {"hook_event_name": name, "cwd": str(home)}
    if session_id is not None:
        payload["session_id"] = session_id
    return subprocess.run([str(HERE / f"presence-{name}")], env=env,
                          input=json.dumps(payload),
                          capture_output=True, text=True, timeout=10)


def _calls(log):
    return log.read_text().splitlines() if log.exists() else []


A = "aaaaaaaa-0000-4000-8000-000000000001"
B = "bbbbbbbb-0000-4000-8000-000000000002"


@pytest.fixture
def home(tmp_path):
    h = tmp_path / "home"
    h.mkdir()
    return h


def test_heartbeat_uses_the_session_id_from_hook_input_and_is_throttled(tmp_path, home):
    stub, log = _stub_presence(tmp_path)
    assert _run_hook("heartbeat", home, stub, A).returncode == 0
    assert _run_hook("heartbeat", home, stub, A).returncode == 0
    assert _calls(log) == [f"{A} heartbeat"]


def test_release_releases_all_of_this_sessions_claims(tmp_path, home):
    stub, log = _stub_presence(tmp_path)
    assert _run_hook("release", home, stub, A).returncode == 0
    assert _calls(log) == [f"{A} release --all-mine"]


def test_two_interleaved_sessions_keep_their_own_claims(tmp_path, home):
    """Session A claims and works; session B starts and works too. A's
    heartbeat must keep extending A, and B finishing a turn must release
    only B. With one shared session file, B starting took over A's id."""
    stub, log = _stub_presence(tmp_path)
    _run_hook("heartbeat", home, stub, A)
    _run_hook("heartbeat", home, stub, B)   # not throttled by A's stamp
    _run_hook("release", home, stub, B)     # B's turn ends
    # A's next heartbeat, past the throttle window
    for stamp in (home / ".cache/claude-presence").glob(f"heartbeat-{A}"):
        os.utime(stamp, (0, 0))
    _run_hook("heartbeat", home, stub, A)
    assert _calls(log) == [
        f"{A} heartbeat",
        f"{B} heartbeat",
        f"{B} release --all-mine",
        f"{A} heartbeat",
    ]


def test_hook_input_beats_an_inherited_session_env(tmp_path, home):
    """A subagent or child process may inherit another session's id in its
    environment; the hook input names the session the event belongs to."""
    stub, log = _stub_presence(tmp_path)
    _run_hook("release", home, stub, A, {"CLAUDE_CODE_SESSION_ID": B})
    assert _calls(log) == [f"{A} release --all-mine"]


def test_hooks_fall_back_to_the_session_env(tmp_path, home):
    stub, log = _stub_presence(tmp_path)
    _run_hook("release", home, stub, None, {"CLAUDE_CODE_SESSION_ID": B})
    assert _calls(log) == [f"{B} release --all-mine"]


def test_hooks_do_nothing_without_a_session(tmp_path, home):
    stub, log = _stub_presence(tmp_path)
    for hook in ("heartbeat", "release"):
        assert _run_hook(hook, home, stub).returncode == 0
    assert not log.exists()


def test_hooks_ignore_a_session_id_that_is_not_a_plain_token(tmp_path, home):
    stub, log = _stub_presence(tmp_path)
    for hook in ("heartbeat", "release"):
        assert _run_hook(hook, home, stub, "../../etc/x").returncode == 0
    assert not log.exists()
    assert not (tmp_path / "etc").exists()


def test_hooks_never_fail_when_presence_is_missing(tmp_path, home):
    missing = tmp_path / "no-such-presence"
    for hook in ("heartbeat", "release"):
        assert _run_hook(hook, home, missing, A).returncode == 0


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
