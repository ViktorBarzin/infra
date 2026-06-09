"""Unit tests for slack_notifier classification + state machine.

Run with: cd infra/stacks/kms/files && python3 -m unittest test_slack_notifier
"""
import importlib.util
import os
import unittest
from pathlib import Path

# Load the notifier module from the dashed filename without executing main().
os.environ.setdefault("SLACK_WEBHOOK_URL", "http://example.invalid/webhook")
_spec = importlib.util.spec_from_file_location(
    "slack_notifier", Path(__file__).parent / "slack-notifier.py"
)
nm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(nm)


class ClassifySourceTests(unittest.TestCase):
    def test_pod_cidr_is_internal_pod(self):
        self.assertEqual(nm.classify_source("10.10.107.224"), "internal_pod")
        self.assertEqual(nm.classify_source("10.10.0.1"), "internal_pod")

    def test_cluster_lan_is_cluster_node(self):
        self.assertEqual(nm.classify_source("10.0.20.103"), "cluster_node")
        self.assertEqual(nm.classify_source("10.0.20.200"), "cluster_node")

    def test_unknown_source_is_external(self):
        self.assertEqual(nm.classify_source("8.8.8.8"), "external")
        self.assertEqual(nm.classify_source("203.0.113.42"), "external")

    def test_ipv6_external_default(self):
        self.assertEqual(nm.classify_source("[2001:db8::1]"), "external")


class IsProbeTests(unittest.TestCase):
    def test_open_close_only_is_probe(self):
        self.assertTrue(nm.is_probe({"ip": "10.10.107.224"}))

    def test_application_id_only_is_not_probe(self):
        self.assertFalse(nm.is_probe({"ip": "10.0.20.103", "app": "Windows"}))

    def test_product_only_is_not_probe(self):
        self.assertFalse(nm.is_probe({"ip": "10.0.20.103", "product": "Office 2021"}))

    def test_full_activation_is_not_probe(self):
        state = {
            "ip": "10.0.20.103",
            "app": "Windows",
            "product": "Windows 11 Pro",
            "host": "DESKTOP-X",
            "status": "Notification",
        }
        self.assertFalse(nm.is_probe(state))


class StateMachineTests(unittest.TestCase):
    """Drive the regex parser through real-shaped vlmcsd log blocks."""

    PROBE_BLOCK = [
        "2026-05-10 11:00:00: IPv4 connection accepted: 10.10.107.224:54321.",
        "2026-05-10 11:00:00: IPv4 connection closed: 10.10.107.224:54321.",
    ]

    ACTIVATION_BLOCK = [
        "2026-05-10 11:00:01: IPv4 connection accepted: 10.0.20.103:50001.",
        "2026-05-10 11:00:01: <<< Incoming KMS request",
        "2026-05-10 11:00:01: Application ID    : 55c92734-d682-4d71-983e-d6ec3f16059f (Windows)",
        "2026-05-10 11:00:01: Activation ID (Product): 73111121-5638-40f6-bc11-f1d7b0d64300 (Windows 11 Pro)",
        "2026-05-10 11:00:01: Workstation name  : DESKTOP-MO2323B",
        "2026-05-10 11:00:01: Licensing status  : 2 (Notification)",
        "2026-05-10 11:00:01: IPv4 connection closed: 10.0.20.103:50001.",
    ]

    def _drive(self, lines):
        events = []
        state = {}
        for line in lines:
            state, event = nm.process_line(line, state)
            if event is not None:
                events.append(event)
        return events, state

    def test_probe_block_emits_probe_event(self):
        events, state = self._drive(self.PROBE_BLOCK)
        self.assertEqual(len(events), 1)
        ev = events[0]
        self.assertEqual(ev.kind, "probe")
        self.assertEqual(ev.ip, "10.10.107.224")
        self.assertEqual(state, {})

    def test_activation_block_emits_activation_event(self):
        events, state = self._drive(self.ACTIVATION_BLOCK)
        self.assertEqual(len(events), 1)
        ev = events[0]
        self.assertEqual(ev.kind, "activation")
        self.assertEqual(ev.ip, "10.0.20.103")
        self.assertEqual(ev.product, "Windows 11 Pro")
        self.assertEqual(ev.host, "DESKTOP-MO2323B")
        self.assertEqual(ev.status, "Notification")
        self.assertEqual(state, {})

    def test_interleaved_probe_then_activation(self):
        events, _ = self._drive(self.PROBE_BLOCK + self.ACTIVATION_BLOCK)
        kinds = [e.kind for e in events]
        self.assertEqual(kinds, ["probe", "activation"])

    def test_kubelet_probe_during_long_activation(self):
        """vlmcsd is multi-threaded. While a real KMS RPC's connection
        sits open (Windows holds it ~30s), kubelet's TCP readiness probe
        every 5s opens+closes its own connection. The notifier MUST NOT
        let the probe's OPEN/CLOSE wipe the in-flight activation's state.
        Reproduces the production bug seen on 2026-05-10.
        """
        interleaved = [
            "2026-05-10 13:12:17: IPv4 connection accepted: 192.168.1.230:53140.",
            "2026-05-10 13:12:17: <<< Incoming KMS request",
            "2026-05-10 13:12:17: Licensing status                : 1 (Licensed)",
            "2026-05-10 13:12:17: Application ID                  : 55c92734-d682-4d71-983e-d6ec3f16059f (Windows)",
            "2026-05-10 13:12:17: Activation ID (Product)         : 2de67392-b7a7-462a-b1ca-108dd189f588 (Windows 10 Professional)",
            "2026-05-10 13:12:17: Workstation name                : WIN10Pro-DS32.viktorbarzin.lan",
            # ── kubelet probe arrives mid-flight, MUST NOT clobber 53140's state ──
            "2026-05-10 13:12:19: IPv4 connection accepted: 10.0.20.102:46498.",
            "2026-05-10 13:12:19: IPv4 connection closed: 10.0.20.102:46498.",
            "2026-05-10 13:12:24: IPv4 connection accepted: 10.0.20.102:54454.",
            "2026-05-10 13:12:24: IPv4 connection closed: 10.0.20.102:54454.",
            # ── activation closes 31s after open ──
            "2026-05-10 13:12:48: IPv4 connection closed: 192.168.1.230:53140.",
        ]
        events, _ = self._drive(interleaved)
        kinds = [e.kind for e in events]
        self.assertEqual(kinds, ["probe", "probe", "activation"])
        activation = events[-1]
        self.assertEqual(activation.ip, "192.168.1.230")
        self.assertEqual(activation.product, "Windows 10 Professional")
        self.assertEqual(activation.host, "WIN10Pro-DS32.viktorbarzin.lan")
        self.assertEqual(activation.status, "Licensed")

    def test_orphan_close_no_event(self):
        """If the notifier starts mid-conn, the open was missed but the
        close still fires. We MUST NOT emit an event for that — it would
        show up with empty fields and look like a probe."""
        orphan = [
            "2026-05-10 13:00:00: IPv4 connection closed: 192.168.1.230:55555.",
        ]
        events, _ = self._drive(orphan)
        self.assertEqual(events, [])


if __name__ == "__main__":
    unittest.main()
