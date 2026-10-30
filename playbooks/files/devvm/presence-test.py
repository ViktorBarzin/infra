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


def test_release_single_label(fake_db, capsys):
    presence = _load_module()
    fake_db.execute.return_value = 1
    rc = presence.main(["release", "node:k8s-node1"])
    assert rc == 0
    last = fake_db.execute.call_args_list[-1]
    assert "DELETE" in last.args[0].upper()
    assert "node:k8s-node1" in last.args[1]
    assert "released node:k8s-node1" in capsys.readouterr().out


def test_release_all_mine(fake_db):
    presence = _load_module()
    rc = presence.main(["release", "--all-mine"])
    assert rc == 0
    last = fake_db.execute.call_args_list[-1]
    assert "DELETE" in last.args[0].upper()
    assert "wizard@devvm@testtest" in last.args[1]


def test_release_of_a_label_this_id_does_not_hold_fails_and_names_the_holder(fake_db, capsys):
    """Release used to exit 0 and print nothing when it matched no row, so a
    caller could not tell that the claim was still there."""
    presence = _load_module()
    fake_db.execute.return_value = 0
    fake_db.fetchall.return_value = [
        {"session_id": f"{getpass.getuser()}@devvm@shell-1234abcd",
         "user": getpass.getuser(), "host": "devvm"},
    ]
    rc = presence.main(["release", "infra:t"])
    err = capsys.readouterr().err
    assert rc == 1
    assert "no claim on infra:t" in err
    assert "wizard@devvm@testtest" in err
    assert f"CLAUDE_SESSION_ID={getpass.getuser()}@devvm@shell-1234abcd presence release infra:t" in err


def test_plain_shell_release_drops_this_users_plain_shell_claim(fake_db, monkeypatch, capsys):
    """Outside Claude every run gets a new one-shot id, so the id that claimed
    is gone by the time release runs. A plain-shell release therefore drops
    the same OS user's plain-shell claim on that label on this host."""
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)
    monkeypatch.delenv("CLAUDE_CODE_SESSION_ID", raising=False)
    presence = _load_module()
    fake_db.execute.side_effect = [0, 1]
    rc = presence.main(["release", "infra:t"])
    assert rc == 0
    sql, params = fake_db.execute.call_args_list[-1].args
    assert "DELETE" in sql.upper() and "LIKE" in sql.upper()
    assert "infra:t" in params
    assert getpass.getuser() in params
    assert any(isinstance(x, str) and x.endswith("@shell-%") for x in params)
    assert "released infra:t" in capsys.readouterr().out


def test_plain_shell_release_never_drops_a_claude_sessions_claim(fake_db, monkeypatch, capsys):
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)
    monkeypatch.delenv("CLAUDE_CODE_SESSION_ID", raising=False)
    presence = _load_module()
    fake_db.execute.side_effect = [0, 0, 1]
    fake_db.fetchall.return_value = [
        {"session_id": f"{getpass.getuser()}@devvm@15aba44f-f368-4b06-9bdd-30115cd22824",
         "user": getpass.getuser(), "host": "devvm"},
    ]
    rc = presence.main(["release", "service:android-emulator"])
    assert rc == 1
    deletes = [c for c in fake_db.execute.call_args_list if "DELETE" in c.args[0].upper()]
    assert all("LIKE" in c.args[0].upper() or c.args[1][0].split("@")[2].startswith("shell-")
               for c in deletes)
    assert "15aba44f-f368-4b06-9bdd-30115cd22824" in capsys.readouterr().err


def test_plain_shell_ids_are_marked_as_shell_ids(monkeypatch):
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)
    monkeypatch.delenv("CLAUDE_CODE_SESSION_ID", raising=False)
    presence = _load_module()
    assert presence.get_session_id().split("@")[2].startswith("shell-")


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


def test_a_subagent_gets_its_own_id_under_its_session(monkeypatch):
    """Subagents inherit the parent's CLAUDE_CODE_SESSION_ID, so without the
    agent id two sibling subagents shared one identity and never saw each
    other's claims as conflicts. The PreToolUse hook exports
    PRESENCE_AGENT_ID into a subagent's presence commands."""
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)
    monkeypatch.setenv("CLAUDE_CODE_SESSION_ID", "15aba44f-f368-4b06-9bdd-30115cd22824")
    monkeypatch.setenv("PRESENCE_AGENT_ID", "acfc4fcfcf26fae85")
    presence = _load_module()
    user, host, sid = presence.get_session_id().split("@")
    assert sid == "15aba44f-f368-4b06-9bdd-30115cd22824/acfc4fcfcf26fae85"
    assert presence.parent_session_id() == f"{user}@{host}@15aba44f-f368-4b06-9bdd-30115cd22824"


def test_an_agent_id_that_is_not_a_plain_token_is_ignored(monkeypatch):
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)
    monkeypatch.setenv("CLAUDE_CODE_SESSION_ID", "15aba44f-f368-4b06-9bdd-30115cd22824")
    monkeypatch.setenv("PRESENCE_AGENT_ID", "../x y")
    presence = _load_module()
    assert presence.get_session_id().endswith("@15aba44f-f368-4b06-9bdd-30115cd22824")
    assert presence.parent_session_id() is None


def test_sibling_subagents_see_each_others_claims_as_conflicts(fake_db, monkeypatch):
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)
    monkeypatch.setenv("CLAUDE_CODE_SESSION_ID", "15aba44f-f368-4b06-9bdd-30115cd22824")
    monkeypatch.setenv("PRESENCE_AGENT_ID", "aaaa1111")
    presence = _load_module()
    presence.main(["claim", "service:android-emulator", "--purpose", "e2e"])
    select = [c for c in fake_db.execute.call_args_list if "SELECT" in c.args[0].upper()][-1]
    assert "session_id    != %s" in select.args[0] or "session_id != %s" in select.args[0]
    assert select.args[1][1].endswith("/aaaa1111")


def test_a_subagents_heartbeat_also_extends_its_parents_claims(fake_db, monkeypatch):
    """The parent waits on its subagents and makes no tool calls meanwhile, so
    its own heartbeat does not run; its claims must not lapse under it."""
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)
    monkeypatch.setenv("CLAUDE_CODE_SESSION_ID", "15aba44f-f368-4b06-9bdd-30115cd22824")
    monkeypatch.setenv("PRESENCE_AGENT_ID", "aaaa1111")
    presence = _load_module()
    assert presence.main(["heartbeat"]) == 0
    params = fake_db.execute.call_args_list[-1].args[1]
    assert any(str(p).endswith("@15aba44f-f368-4b06-9bdd-30115cd22824") for p in params)
    assert any(str(p).endswith("/aaaa1111") for p in params)


def test_connect_timeout_is_well_inside_the_hooks_3s_budget(fake_db):
    import pymysql
    presence = _load_module()
    presence.main(["heartbeat"])
    kwargs = pymysql.connect.call_args.kwargs
    assert kwargs["connect_timeout"] <= 1
    assert kwargs["read_timeout"] <= 1 and kwargs["write_timeout"] <= 1


def test_an_unreachable_db_fails_fast_and_exits_zero(tmp_path):
    """192.0.2.1 is TEST-NET-1: packets to it are dropped, never refused, so
    this is the "Dolt is down" case the hooks must survive inside 3 s."""
    import time
    env = dict(os.environ, PRESENCE_DSN="mysql://beads@192.0.2.1:3306/beads",
               CLAUDE_SESSION_ID="wizard@devvm@offline")
    for verb in (["heartbeat"], ["release", "--all-mine"]):
        t = time.monotonic()
        r = subprocess.run([str(SCRIPT), *verb], env=env, capture_output=True, text=True, timeout=10)
        took = time.monotonic() - t
        assert r.returncode == 0, r.stderr
        assert took < 2.0, f"{verb} took {took:.2f}s"
        assert "dolt unreachable" in r.stderr


def test_a_query_error_after_connecting_is_a_warning_not_a_traceback(fake_db, capsys):
    import pymysql
    fake_db.execute.side_effect = pymysql.err.OperationalError(2013, "Lost connection")
    presence = _load_module()
    assert presence.main(["heartbeat"]) == 0
    assert "dolt unreachable" in capsys.readouterr().err


# ---- hooks -----------------------------------------------------------------

def _stub_presence(tmp_path):
    """A presence stand-in that records the session it was run for and its
    arguments, one line per call."""
    log = tmp_path / "calls.log"
    stub = tmp_path / "presence-stub"
    stub.write_text(
        "#!/bin/sh\n"
        f'echo "${{CLAUDE_CODE_SESSION_ID:-none}} ${{PRESENCE_AGENT_ID:+agent=$PRESENCE_AGENT_ID }}$*" >> "{log}"\n'
    )
    stub.chmod(0o755)
    return stub, log


def _run_hook(name, home, stub, session_id=None, env_extra=None, agent_id=None, payload_extra=None):
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
    if agent_id is not None:
        payload["agent_id"] = agent_id
        payload["agent_type"] = "general-purpose"
    payload.update(payload_extra or {})
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


def test_a_subagents_heartbeat_runs_as_that_subagent_with_its_own_throttle(tmp_path, home):
    stub, log = _stub_presence(tmp_path)
    _run_hook("heartbeat", home, stub, A)
    _run_hook("heartbeat", home, stub, A, agent_id="aaaa1111")
    _run_hook("heartbeat", home, stub, A, agent_id="bbbb2222")
    _run_hook("heartbeat", home, stub, A, agent_id="aaaa1111")   # throttled
    assert _calls(log) == [
        f"{A} heartbeat",
        f"{A} agent=aaaa1111 heartbeat",
        f"{A} agent=bbbb2222 heartbeat",
    ]


def test_subagent_stop_releases_only_that_subagents_claims(tmp_path, home):
    stub, log = _stub_presence(tmp_path)
    _run_hook("release", home, stub, A, agent_id="aaaa1111",
              payload_extra={"hook_event_name": "SubagentStop"})
    assert _calls(log) == [f"{A} agent=aaaa1111 release --all-mine"]


def test_the_main_agents_hooks_ignore_an_inherited_agent_env(tmp_path, home):
    stub, log = _stub_presence(tmp_path)
    _run_hook("release", home, stub, A, {"PRESENCE_AGENT_ID": "stale"})
    assert _calls(log) == [f"{A} release --all-mine"]


def _tag(home, payload):
    env = {"PATH": os.environ["PATH"], "HOME": str(home)}
    r = subprocess.run([str(HERE / "presence-tag-agent")], env=env, input=json.dumps(payload),
                       capture_output=True, text=True, timeout=10)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout) if r.stdout.strip() else None


def _bash_payload(command, agent_id="aaaa1111"):
    p = {"session_id": A, "hook_event_name": "PreToolUse", "tool_name": "Bash",
         "tool_input": {"command": command, "description": "claim it", "timeout": 5000}}
    if agent_id is not None:
        p["agent_id"] = agent_id
        p["agent_type"] = "general-purpose"
    return p


def test_tag_agent_exports_the_agent_id_into_a_subagents_presence_command(home):
    out = _tag(home, _bash_payload('presence claim service:android-emulator --purpose "e2e"'))
    spec = out["hookSpecificOutput"]
    assert spec["hookEventName"] == "PreToolUse"
    assert "permissionDecision" not in spec   # never approves anything
    assert spec["updatedInput"] == {
        "command": 'export PRESENCE_AGENT_ID=aaaa1111\npresence claim service:android-emulator --purpose "e2e"',
        "description": "claim it",
        "timeout": 5000,
    }


def test_tag_agent_covers_homelab_verbs_that_claim(home):
    out = _tag(home, _bash_payload("cd ~/code/infra && homelab claim infra:x --purpose y"))
    assert out["hookSpecificOutput"]["updatedInput"]["command"].startswith("export PRESENCE_AGENT_ID=aaaa1111\n")


def test_tag_agent_leaves_other_commands_alone(home):
    assert _tag(home, _bash_payload("ls -la")) is None


def test_tag_agent_leaves_the_main_agent_alone(home):
    assert _tag(home, _bash_payload("presence list", agent_id=None)) is None


def test_tag_agent_ignores_an_agent_id_that_is_not_a_plain_token(home):
    assert _tag(home, _bash_payload("presence list", agent_id="x; rm -rf /")) is None


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
