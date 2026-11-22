#!/usr/bin/env python3
"""Unit tests for which nodes scripts/check-node-kubelet-tune reads.

Run: python3 scripts/check_node_kubelet_tune_test.py

An Opportunistic worker (label node-role.viktorbarzin.me/opportunistic=true,
ADR-0045) is offline for days by design. While it is NotReady its kubelet
cannot answer /configz, and counting it as unreachable made the hourly drift
check report "could not check" (K8sNodeDriftCheckFailing). Such a node is
skipped while it is offline and checked like any other node while it is Ready.
"""
import importlib.machinery
import importlib.util
import os
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_loader = importlib.machinery.SourceFileLoader(
    "check_node_kubelet_tune", os.path.join(_HERE, "check-node-kubelet-tune")
)
_spec = importlib.util.spec_from_loader(_loader.name, _loader)
tune = importlib.util.module_from_spec(_spec)
_loader.exec_module(tune)

OPP = "node-role.viktorbarzin.me/opportunistic"


def node(name, ready, labels=None):
    return {
        "metadata": {"name": name, "labels": labels or {}},
        "status": {"conditions": [
            {"type": "MemoryPressure", "status": "False"},
            {"type": "Ready", "status": "True" if ready else "Unknown"},
        ]},
    }


class NodesToCheck(unittest.TestCase):
    def test_offline_opportunistic_node_is_skipped(self):
        nodes = [node("k8s-node1", True), node("dell-worker", False, {OPP: "true"})]
        self.assertEqual(tune.nodes_to_check(nodes), (["k8s-node1"], ["dell-worker"]))

    def test_ready_opportunistic_node_is_checked(self):
        nodes = [node("k8s-node1", True), node("dell-worker", True, {OPP: "true"})]
        self.assertEqual(tune.nodes_to_check(nodes), (["k8s-node1", "dell-worker"], []))

    def test_notready_ordinary_node_is_still_checked(self):
        # A regular node that is down must stay visible as unreachable.
        nodes = [node("k8s-node2", False)]
        self.assertEqual(tune.nodes_to_check(nodes), (["k8s-node2"], []))

    def test_label_with_other_value_does_not_skip(self):
        nodes = [node("k8s-node3", False, {OPP: "false"})]
        self.assertEqual(tune.nodes_to_check(nodes), (["k8s-node3"], []))

    def test_node_without_conditions_counts_as_not_ready(self):
        n = {"metadata": {"name": "dell-worker", "labels": {OPP: "true"}}, "status": {}}
        self.assertEqual(tune.nodes_to_check([n]), ([], ["dell-worker"]))


if __name__ == "__main__":
    unittest.main()
