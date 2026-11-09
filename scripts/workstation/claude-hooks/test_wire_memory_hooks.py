"""Tests for wire-memory-hooks.py: retired hooks are pruned, live ones wired once."""
import json
import pathlib
import subprocess
import sys

SCRIPT = pathlib.Path(__file__).resolve().parent / "wire-memory-hooks.py"


def run(home: pathlib.Path) -> dict:
    (home / ".claude").mkdir(exist_ok=True)  # the provisioner creates it before wiring
    subprocess.run([sys.executable, str(SCRIPT), str(home)], check=True, capture_output=True)
    return json.loads((home / ".claude" / "settings.json").read_text())


def commands(settings: dict) -> list[str]:
    return [h["command"] for groups in settings.get("hooks", {}).values() for g in groups for h in g["hooks"]]


def write_settings(home: pathlib.Path, settings: dict) -> None:
    (home / ".claude").mkdir(parents=True, exist_ok=True)
    (home / ".claude" / "settings.json").write_text(json.dumps(settings))


def test_memory_recall_hook_is_pruned(tmp_path):
    recall = f"python3 {tmp_path}/.claude/hooks/homelab-memory-recall.py"
    write_settings(tmp_path, {"hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": recall}]}]}})
    assert not any("homelab-memory-recall.py" in c for c in commands(run(tmp_path)))


def test_memory_recall_hook_is_not_added_to_fresh_settings(tmp_path):
    cmds = commands(run(tmp_path))
    assert not any("homelab-memory-recall.py" in c for c in cmds)
    assert any("auto-learn.py" in c for c in cmds)


def test_unrelated_hooks_survive(tmp_path):
    mine = "/usr/local/bin/my-own-hook"
    write_settings(tmp_path, {"hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": mine}]}]}})
    assert mine in commands(run(tmp_path))


def test_second_run_changes_nothing(tmp_path):
    first = run(tmp_path)
    assert run(tmp_path) == first
