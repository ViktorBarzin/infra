#!/usr/bin/env python3
"""Unit tests for auto-learn.py's store path (Stop hook, ADR-0007).

Focus: the exact argv handed to `homelab memory store` — the fleet deploys
hooks and the CLI on different clocks (hooks: hourly reconcile; CLI: rebuilt by
the same reconcile only on a VERSION change, and never when go is absent), so
a hook newer than the binary is a real state. A pre-v0.13.0 `memory store`
silently swallows `--link`'s VALUE into the stored CONTENT ("<part> part-of:77"
— durable pollution, exit 0), which is why --link is capability-gated.

Pure python: subprocess is mocked — no network, no real CLI. Run:

    cd scripts/workstation/claude-hooks && python3 -m pytest test_auto_learn_hook.py -q
"""

import importlib.util
import json
import pathlib
import types

import pytest

_HOOK_PATH = pathlib.Path(__file__).resolve().parent / "auto-learn.py"
_spec = importlib.util.spec_from_file_location("auto_learn", _HOOK_PATH)
hook = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hook)

CATEGORY_MAP = {
    "correction": "preferences",
    "preference": "preferences",
    "decision": "decisions",
    "fact": "facts",
}

# Verbatim usage lines: v0.12.0 (deployed today) has no --link; v0.13.0 does.
V012_STORE_USAGE = (
    'homelab: usage: homelab memory store "<content>" [--category C] '
    "[--tags ...] [--keywords ...] [--importance 0.5] [--sensitive]\n"
)
V013_STORE_USAGE = (
    'homelab: usage: homelab memory store "<content>" [--category C] '
    "[--tags ...] [--keywords ...] [--importance 0.5] [--sensitive] "
    "[--link type:id ...]\n"
)


class FakeCLI:
    """Dispatches mocked `homelab memory store [--help]` invocations."""

    def __init__(self, store_usage=V013_STORE_USAGE, first_id=77, probe_exc=None):
        self.calls = []
        self.store_usage = store_usage
        self.next_id = first_id
        self.probe_exc = probe_exc

    def run(self, cmd, **kwargs):
        self.calls.append(list(cmd))
        if cmd[1:4] == ["memory", "store", "--help"]:
            if self.probe_exc is not None:
                raise self.probe_exc
            return types.SimpleNamespace(returncode=1, stdout="", stderr=self.store_usage)
        if cmd[1:3] == ["memory", "store"]:
            mid, self.next_id = self.next_id, self.next_id + 1
            return types.SimpleNamespace(
                returncode=0, stdout=json.dumps({"id": mid, "status": "stored"}) + "\n",
                stderr="")
        raise AssertionError(f"unexpected homelab invocation: {cmd}")

    @property
    def stores(self):
        """The real store calls (probe --help invocations excluded)."""
        return [c for c in self.calls
                if c[1:3] == ["memory", "store"] and c[3:4] != ["--help"]]

    @property
    def probes(self):
        return [c for c in self.calls if c[1:4] == ["memory", "store", "--help"]]


@pytest.fixture()
def cli(monkeypatch, tmp_path):
    fake = FakeCLI()
    monkeypatch.setattr(hook, "_LINK_SUPPORT", None)  # reset the probe memo
    monkeypatch.setattr(hook, "_homelab_path", lambda: "/usr/local/bin/homelab")
    monkeypatch.setattr(hook, "ERRORS_LOG", str(tmp_path / "errors.log"))
    monkeypatch.setattr(hook.subprocess, "run", fake.run)
    monkeypatch.delenv("CLAUDE_MEMORY_API_KEY", raising=False)
    monkeypatch.setenv("MEMORY_API_KEY", "test-key")
    return fake


def _errors_log(module):
    p = pathlib.Path(module.ERRORS_LOG)
    return p.read_text() if p.exists() else ""


def _event(content="hub summary", parts=(), **extra):
    e = {"type": "fact", "content": content, "importance": 0.7,
         "expanded_keywords": "alpha beta gamma delta epsilon",
         "supersedes": None, "parts": list(parts)}
    e.update(extra)
    return e


# ------------------------------------------------------------ argv contract

def test_parts_link_to_hub_when_cli_supports_link(cli):
    hook._store_event(_event(parts=["detail one", "detail two"]), CATEGORY_MAP)
    stores = cli.stores
    assert len(stores) == 3
    assert stores[0][3] == "hub summary"
    assert "--link" not in stores[0]                 # the hub itself is never linked
    for argv, part in zip(stores[1:], ["detail one", "detail two"]):
        assert argv[3] == part                       # content is EXACTLY the part text
        assert argv[argv.index("--link") + 1] == "part-of:77"
    assert _errors_log(hook) == ""


def test_parts_stored_unlinked_when_cli_lacks_link(cli):
    # The pollution scenario: a v0.12.0 binary would store "<part> part-of:77"
    # as content. The gate must keep --link (and the spec) out of the argv
    # entirely, store the still-self-contained parts, and log the degradation.
    cli.store_usage = V012_STORE_USAGE
    hook._store_event(_event(parts=["detail one"]), CATEGORY_MAP)
    stores = cli.stores
    assert len(stores) == 2                          # hub + part still stored
    for argv in stores:
        assert "--link" not in argv
        assert not any("part-of:" in a for a in argv)
    assert "lacks --link" in _errors_log(hook)


def test_probe_failure_never_passes_link(cli):
    cli.probe_exc = OSError("boom")
    hook._store_event(_event(parts=["detail one"]), CATEGORY_MAP)
    assert len(cli.stores) == 2
    for argv in cli.stores:
        assert "--link" not in argv


def test_probe_runs_once_per_process(cli):
    hook._store_event(_event(parts=["p1", "p2"]), CATEGORY_MAP)
    hook._store_event(_event(content="second hub", parts=["p3"]), CATEGORY_MAP)
    assert len(cli.probes) == 1


def test_no_parts_means_no_probe(cli):
    hook._store_event(_event(parts=[]), CATEGORY_MAP)
    assert len(cli.stores) == 1
    assert cli.probes == []


def test_keyless_user_stores_nothing_silently(cli, monkeypatch):
    monkeypatch.delenv("MEMORY_API_KEY", raising=False)
    hook._store_event(_event(parts=["detail one"]), CATEGORY_MAP)
    assert cli.calls == []                           # no store, no probe
    assert _errors_log(hook) == ""


# ------------------------------------------------------- ADR-0007 bound guard

def test_oversize_content_rejected_never_stored(cli):
    hook._store_event(_event(content="x" * (hook.MEMORY_BOUND + 1)), CATEGORY_MAP)
    assert cli.stores == []
    assert "exceeds" in _errors_log(hook)


def test_oversize_part_skipped_others_stored(cli):
    hook._store_event(
        _event(parts=["ok one", "y" * (hook.MEMORY_BOUND + 1), "ok two"]),
        CATEGORY_MAP)
    stores = cli.stores
    assert [argv[3] for argv in stores] == ["hub summary", "ok one", "ok two"]
    assert "part rejected" in _errors_log(hook)


def test_hub_id_unparseable_stores_parts_unlinked(cli, monkeypatch):
    real_run = cli.run

    def run_with_bad_store_output(cmd, **kwargs):
        res = real_run(cmd, **kwargs)
        if cmd[1:3] == ["memory", "store"] and cmd[3:4] != ["--help"]:
            return types.SimpleNamespace(returncode=0, stdout="stored ok\n", stderr="")
        return res

    monkeypatch.setattr(hook.subprocess, "run", run_with_bad_store_output)
    hook._store_event(_event(parts=["detail one"]), CATEGORY_MAP)
    assert len(cli.stores) == 2
    for argv in cli.stores:
        assert "--link" not in argv
    assert "unlinked" in _errors_log(hook)


# ------------------------------------------------------------- error logging

def test_errors_log_rotates_at_size_cap(cli):
    log = pathlib.Path(hook.ERRORS_LOG)
    log.write_text("x" * (hook.ERRORS_LOG_MAX_BYTES + 1))
    hook._log_error("fresh line after rotation")
    assert pathlib.Path(str(log) + ".1").exists()
    text = log.read_text()
    assert "fresh line after rotation" in text
    assert len(text) < 1000
