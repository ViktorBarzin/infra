"""The upgrade chain leaves Opportunistic workers out (ADR-0045).

Run: pytest stacks/k8s-version-upgrade/scripts/test_upgrade_step_opportunistic.py

An Opportunistic worker (label node-role.viktorbarzin.me/opportunistic=true,
first one dell-worker) is offline for days by design. If the chain counted it,
an offline node would defer every preflight, the worker loop would try to drain
and SSH into it, and postflight would abort on its older kubelet. Such a node is
upgraded by re-running playbooks/physical-node.yml instead.

Every place that lists nodes (`get nodes`, plural) must carry the exclusion.
`get node <name>` reads one named node and is fine. worker_nodes() is also run
against a stub kubectl to check the selector it sends.
"""
import pathlib
import re
import subprocess

HERE = pathlib.Path(__file__).parent
SCRIPT = (HERE / "upgrade-step.sh").read_text()
MAIN_TF = (HERE.parent / "main.tf").read_text()
EXCLUDE = "!node-role.viktorbarzin.me/opportunistic"


def node_listings(text: str) -> list[str]:
    """Each `get nodes` call, joined with its backslash-continued lines."""
    joined = re.sub(r"\\\n\s*", " ", text)
    return [line for line in joined.splitlines()
            if re.search(r"\bget nodes\b", line) and not line.lstrip().startswith("#")]


def test_every_node_listing_in_upgrade_step_excludes_opportunistic():
    calls = node_listings(SCRIPT)
    assert calls, "no `get nodes` calls found; did the script change shape?"
    missing = [c.strip() for c in calls if EXCLUDE not in c]
    assert not missing, "node listings that still count Opportunistic workers:\n" + "\n".join(missing)


def test_version_detection_in_main_tf_excludes_opportunistic():
    calls = node_listings(MAIN_TF)
    assert calls, "no `get nodes` call found in main.tf"
    missing = [c.strip() for c in calls if EXCLUDE not in c]
    assert not missing, "\n".join(missing)


def test_worker_nodes_sends_both_exclusions(tmp_path: pathlib.Path):
    calls = tmp_path / "calls"
    stub = tmp_path / "kubectl"
    stub.write_text('#!/bin/bash\necho "$*" >> "$CALLS"\nprintf "k8s-node2\\nk8s-node1\\n"\n')
    stub.chmod(0o755)
    func = re.search(r"^worker_nodes\(\) \{.*?\}$", SCRIPT, re.S | re.M)
    assert func, "worker_nodes() missing from upgrade-step.sh"
    out = subprocess.run(
        ["bash", "-c", f"KUBECTL={stub}\n{func.group(0)}\nworker_nodes"],
        env={"CALLS": str(calls), "PATH": "/usr/bin:/bin"},
        capture_output=True, text=True, check=True,
    ).stdout
    assert out.split() == ["k8s-node1", "k8s-node2"]
    sent = calls.read_text()
    assert "!node-role.kubernetes.io/control-plane" in sent
    assert EXCLUDE in sent
