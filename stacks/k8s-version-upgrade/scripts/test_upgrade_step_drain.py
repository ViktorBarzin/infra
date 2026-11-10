"""drain_node() cordons before it deletes anything, and leaves CNPG alone.

Run: pytest stacks/k8s-version-upgrade/scripts/test_upgrade_step_drain.py

On 2026-11-02 predrain_unstick deleted the CNPG primary 7 s before node5 was
cordoned. The pod was recreated on a schedulable node and CNPG had to fail
over instead of switching over, which put every Postgres app into a crash
loop. CNPG switches over by itself once the primary's node is unschedulable,
so its PDBs must not be force-deleted.

The test extracts the two shell functions from upgrade-step.sh and runs them
in bash against a stub kubectl that records every call.
"""
import json
import pathlib
import re
import subprocess

SCRIPT = (pathlib.Path(__file__).parent / "upgrade-step.sh").read_text()

PDBS = {
    "items": [
        {   # single-replica app: blocks drain, must be deleted
            "metadata": {"namespace": "anubis", "name": "anubis"},
            "spec": {"selector": {"matchLabels": {"app": "anubis"}}},
            "status": {"disruptionsAllowed": 0},
        },
        {   # CNPG primary PDB: CNPG switches over on cordon, must be left alone
            "metadata": {"namespace": "dbaas", "name": "pg-cluster-v18-primary"},
            "spec": {"selector": {"matchLabels": {
                "cnpg.io/cluster": "pg-cluster-v18",
                "cnpg.io/instanceRole": "primary"}}},
            "status": {"disruptionsAllowed": 0},
        },
        {   # has headroom: not touched
            "metadata": {"namespace": "traefik", "name": "traefik"},
            "spec": {"selector": {"matchLabels": {"app": "traefik"}}},
            "status": {"disruptionsAllowed": 1},
        },
    ]
}

STUB = """#!/bin/bash
echo "$*" >> "$CALLS"
case "$*" in
  "get pdb -A -o json") cat "$PDB_JSON" ;;
  *"get pods"*"app=anubis"*) echo "pod/anubis-1" ;;
  *"get pods"*"cnpg.io/cluster=pg-cluster-v18"*) echo "pod/pg-cluster-v18-1" ;;
esac
exit 0
"""


def function(name: str) -> str:
    match = re.search(rf"^{name}\(\) \{{\n.*?^\}}\n", SCRIPT, re.S | re.M)
    assert match, f"{name}() missing from upgrade-step.sh"
    return match.group(0)


def run_drain(tmp_path: pathlib.Path) -> list[str]:
    stub = tmp_path / "kubectl"
    stub.write_text(STUB)
    stub.chmod(0o755)
    (tmp_path / "pdb.json").write_text(json.dumps(PDBS))
    calls = tmp_path / "calls"
    calls.touch()
    body = function("predrain_unstick") + function("drain_node") + 'drain_node k8s-node5\n'
    subprocess.run(
        ["bash", "-c", body],
        check=True,
        timeout=30,
        env={"PATH": "/usr/bin:/bin", "KUBECTL": str(stub),
             "CALLS": str(calls), "PDB_JSON": str(tmp_path / "pdb.json")},
    )
    return calls.read_text().splitlines()


def test_cordon_comes_before_any_delete(tmp_path):
    calls = run_drain(tmp_path)
    cordon = [i for i, c in enumerate(calls) if c == "cordon k8s-node5"]
    deletes = [i for i, c in enumerate(calls) if " delete " in f" {c} "]
    assert cordon, calls
    assert deletes, calls
    assert cordon[0] < deletes[0], calls


def test_single_replica_pdb_pod_is_deleted(tmp_path):
    calls = run_drain(tmp_path)
    assert any("delete pod/anubis-1" in c for c in calls), calls


def test_cnpg_pods_are_left_to_cnpg_switchover(tmp_path):
    calls = run_drain(tmp_path)
    assert not any("pg-cluster-v18" in c for c in calls if "delete" in c), calls
    assert not any("cnpg.io/cluster" in c for c in calls), calls


def test_drain_still_runs(tmp_path):
    calls = run_drain(tmp_path)
    assert any(c.startswith("drain k8s-node5 ") for c in calls), calls
