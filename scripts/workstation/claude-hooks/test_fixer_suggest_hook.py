"""Tests for fixer-suggest.py — the PostToolUse(Bash) access-wall reminder.

Two properties matter more than coverage here. **Precision**: a hook that fires
on ordinary output gets ignored, and then it will not be read on the day it
matters — so the negative cases are as load-bearing as the positive ones.
**Harmlessness**: a hook that can wedge a session is worse than no hook, so
malformed input must exit 0 silently.
"""
import json
import os
import subprocess
import sys
import tempfile

import pytest

HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixer-suggest.py")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
_mod = __import__("importlib").import_module("importlib.util")
_spec = _mod.spec_from_file_location("fixer_suggest", HOOK)
fixer_suggest = _mod.module_from_spec(_spec)
_spec.loader.exec_module(fixer_suggest)


def run(payload: dict, session: str | None = None) -> str:
    """Run the hook as the harness does and return stdout."""
    body = dict(payload)
    body.setdefault("session_id", session or tempfile.mktemp(prefix="sess"))
    proc = subprocess.run(
        [sys.executable, HOOK], input=json.dumps(body),
        text=True, capture_output=True, timeout=15,
    )
    assert proc.returncode == 0, proc.stderr
    return proc.stdout.strip()


def bash(stdout: str = "", stderr: str = "") -> dict:
    return {
        "tool_name": "Bash",
        "tool_input": {"command": "kubectl get secret -n immich"},
        "tool_response": {"stdout": stdout, "stderr": stderr},
    }


# --------------------------------------------------------------------------- #
# Fires on real access walls — the exact strings emo's transcripts contain.
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize("text,kind", [
    ('Error from server (Forbidden): secrets is forbidden', "kubectl RBAC"),
    ('secrets is forbidden: User "emo" cannot list resource "secrets" '
     'in API group "" in the namespace "immich"', "kubectl RBAC"),
    ('cannot create resource "pods" in API group ""', "kubectl RBAC"),
    ("sudo: a password is required", "sudo"),
    ("Error making API request. Code: 403. Errors: permission denied", "Vault 403"),
    ("HTTP/2 403 Forbidden", "HTTP 403"),
])
def test_a_real_denial_is_recognised(text, kind):
    assert fixer_suggest.find_denial(text) == kind


def test_a_denial_produces_the_reminder():
    out = run(bash(stderr='Error from server (Forbidden): secrets is forbidden'))
    body = json.loads(out)["hookSpecificOutput"]
    assert body["hookEventName"] == "PostToolUse"
    ctx = body["additionalContext"]
    assert "`broken`" in ctx and "file-issue" in ctx
    assert "File it yourself" in ctx
    assert "`change`" in ctx  # the other half of the choice is offered too


def test_stdout_is_scanned_as_well_as_stderr():
    assert run(bash(stdout='cannot get resource "externalsecrets"')) != ""


# --------------------------------------------------------------------------- #
# Precision — the cases that must NOT fire.
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize("text", [
    "",
    "all good, 3 pods running",
    "cp: cannot stat 'x': No such file or directory",
    "fatal: repository not found",
    "error: exit status 1",
    "403 items processed",
    "bash: ./script.sh: Permission denied",          # a file mode, not an account wall
    "chmod: changing permissions of 'f': Permission denied",
])
def test_ordinary_output_does_not_fire(text):
    assert fixer_suggest.find_denial(text) is None
    assert run(bash(stdout=text)) == ""


def test_a_bare_permission_denied_is_not_enough():
    """Deliberate: it is usually a file mode. Crying wolf costs more than the
    one real case it would have caught."""
    assert fixer_suggest.find_denial("Permission denied") is None


def test_vault_permission_denied_does_fire():
    """The same words WITH a Vault context are a policy refusal."""
    assert fixer_suggest.find_denial(
        "* permission denied\nURL: GET https://vault.../v1/secret/data/viktor"
    ) == "Vault policy"


def test_other_tools_are_ignored():
    payload = {"tool_name": "Read", "tool_response": {"stdout": "Error from server (Forbidden)"}}
    assert run(payload) == ""


# --------------------------------------------------------------------------- #
# Quiet after the first couple.
# --------------------------------------------------------------------------- #
def test_it_stops_after_two_reminders_in_one_session():
    session = tempfile.mktemp(prefix="sess-quiet")
    denial = bash(stderr="Error from server (Forbidden)")
    assert run(denial, session) != ""
    assert run(denial, session) != ""
    assert run(denial, session) == ""   # third is silence


def test_a_different_session_starts_fresh():
    denial = bash(stderr="Error from server (Forbidden)")
    a, b = tempfile.mktemp(prefix="s-a"), tempfile.mktemp(prefix="s-b")
    run(denial, a); run(denial, a); assert run(denial, a) == ""
    assert run(denial, b) != ""


# --------------------------------------------------------------------------- #
# Harmlessness.
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize("raw", ["", "not json", "[]", "null", '{"tool_name": "Bash"}'])
def test_malformed_input_exits_quietly(raw):
    proc = subprocess.run([sys.executable, HOOK], input=raw, text=True,
                          capture_output=True, timeout=15)
    assert proc.returncode == 0
    assert proc.stdout.strip() == ""


def test_a_string_tool_response_is_handled():
    payload = {"tool_name": "Bash", "session_id": tempfile.mktemp(prefix="s-str"),
               "tool_response": "Error from server (Forbidden)"}
    assert run(payload) != ""
