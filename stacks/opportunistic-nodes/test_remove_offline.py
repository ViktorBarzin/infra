"""remove-offline.sh against a fake kubectl.

Run: python3 -m pytest stacks/opportunistic-nodes/test_remove_offline.py
"""

import os
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path

SCRIPT = Path(__file__).parent / "files" / "remove-offline.sh"

# The fake answers the three calls the script makes and logs every call.
FAKE_KUBECTL = """#!/bin/bash
echo "$*" >> "$FAKE_LOG"
case "$*" in
  "get nodes -l node-role.viktorbarzin.me/opportunistic=true -o name")
    for n in $FAKE_NODES; do echo "node/$n"; done ;;
  "get node "*" -o jsonpath="*)
    var="FAKE_READY_${3//-/_}"; echo -n "${!var}" ;;
  "-n kube-node-lease get lease "*)
    var="FAKE_RENEW_${5//-/_}"; [ -n "${!var}" ] || exit 1; echo -n "${!var}" ;;
  "delete node "*) echo "node \\"$3\\" deleted" ;;
  *) echo "unexpected: $*" >&2; exit 2 ;;
esac
"""


def stamp(minutes_ago: float) -> str:
    t = datetime.now(timezone.utc) - timedelta(minutes=minutes_ago)
    return t.strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def run(tmp_path: Path, nodes: dict[str, tuple[str, str | None]]) -> tuple[subprocess.CompletedProcess[str], list[str]]:
    """nodes maps a name to (Ready status, lease renewTime or None for no lease)."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    fake = bin_dir / "kubectl"
    fake.write_text(FAKE_KUBECTL)
    fake.chmod(0o755)
    log = tmp_path / "calls.log"
    env = {
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "FAKE_LOG": str(log),
        "FAKE_NODES": " ".join(nodes),
    }
    for name, (ready, renew) in nodes.items():
        key = name.replace("-", "_")
        env[f"FAKE_READY_{key}"] = ready
        if renew is not None:
            env[f"FAKE_RENEW_{key}"] = renew
    result = subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True)
    calls = log.read_text().splitlines() if log.exists() else []
    return result, calls


def deletes(calls: list[str]) -> list[str]:
    return [c for c in calls if c.startswith("delete node")]


def test_silent_for_20_minutes_is_removed(tmp_path: Path) -> None:
    result, calls = run(tmp_path, {"dell-worker": ("Unknown", stamp(20))})
    assert result.returncode == 0, result.stderr
    assert deletes(calls) == ["delete node dell-worker --wait=false"]


def test_silent_for_10_minutes_stays(tmp_path: Path) -> None:
    result, calls = run(tmp_path, {"dell-worker": ("Unknown", stamp(10))})
    assert result.returncode == 0, result.stderr
    assert deletes(calls) == []


def test_ready_node_stays_even_with_an_old_lease(tmp_path: Path) -> None:
    result, calls = run(tmp_path, {"dell-worker": ("True", stamp(60))})
    assert result.returncode == 0, result.stderr
    assert deletes(calls) == []


def test_not_ready_but_kubelet_heartbeating_stays(tmp_path: Path) -> None:
    # Ready=False with a fresh lease: kubelet runs (for example CNI not up).
    # Deleting it would leave a running kubelet without a Node object.
    result, calls = run(tmp_path, {"dell-worker": ("False", stamp(1))})
    assert result.returncode == 0, result.stderr
    assert deletes(calls) == []


def test_missing_lease_stays(tmp_path: Path) -> None:
    result, calls = run(tmp_path, {"dell-worker": ("Unknown", None)})
    assert result.returncode == 0, result.stderr
    assert deletes(calls) == []


def test_no_opportunistic_nodes_does_nothing(tmp_path: Path) -> None:
    result, calls = run(tmp_path, {})
    assert result.returncode == 0, result.stderr
    assert deletes(calls) == []


def test_each_node_decided_on_its_own(tmp_path: Path) -> None:
    result, calls = run(
        tmp_path,
        {"dell-worker": ("Unknown", stamp(30)), "other-laptop": ("True", stamp(0))},
    )
    assert result.returncode == 0, result.stderr
    assert deletes(calls) == ["delete node dell-worker --wait=false"]
