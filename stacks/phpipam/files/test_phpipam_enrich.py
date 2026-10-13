"""Unit tests for phpipam_enrich.py.

Run with: cd infra/stacks/phpipam/files && python3 -m unittest test_phpipam_enrich
"""
import datetime as dt
import importlib.util
import sys
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location("phpipam_enrich", Path(__file__).parent / "phpipam_enrich.py")
pe = importlib.util.module_from_spec(_spec)
sys.modules["phpipam_enrich"] = pe
_spec.loader.exec_module(pe)

NOW = dt.datetime(2026, 10, 13, 12, 0, 0)


def fake_oui(mac):
    return {"78:8c:b5": "TP-Link Corporation Limited", "00:50:56": "VMware, Inc.",
            "b8:27:eb": "Raspberry Pi Foundation"}.get(mac[:8])


class OuiTests(unittest.TestCase):
    def test_cases(self):
        for mac, want in [
            ("78:8c:b5:74:30:11", "TP-Link Corporation Limited"),
            ("da:15:00:00:00:01", "private MAC"),   # locally administered bit set
            ("52:9f:c2:9a:64:ab", "private MAC"),
            ("00:11:22:33:44:55", None),           # globally unique but not in the registry
            ("", None),
        ]:
            with self.subTest(mac=mac):
                self.assertEqual(pe.oui_vendor(mac, fake_oui), want)


class HaTests(unittest.TestCase):
    def test_registry_by_mac(self):
        devices = [
            {"manufacturer": "TP-Link", "model": "KP115(UK)", "model_id": None, "sw_version": "1.0.18",
             "connections": [["mac", "78:8C:B5:74:30:11"]]},
            {"manufacturer": "iRobot", "model": "s910840", "model_id": "S9+", "sw_version": "x" * 300,
             "connections": [["mac", "50:14:79:76:c6:eb"], ["zigbee", "abc"]]},
            {"manufacturer": "Sun", "model": "Moon", "connections": [["zigbee", "00:11"]]},
            {"manufacturer": None, "model": None, "sw_version": None, "connections": [["mac", "00:00:00:00:00:01"]]},
            # A router integration's client list: placeholders, not data.
            {"manufacturer": "Unknown", "model": "WiFi Device", "sw_version": None,
             "connections": [["mac", "b8:27:eb:de:b2:36"]]},
        ]
        got = pe.ha_by_mac(devices)
        self.assertEqual(got["78:8c:b5:74:30:11"], pe.Info(vendor="TP-Link", model="KP115(UK)", os="1.0.18"))
        self.assertEqual(got["50:14:79:76:c6:eb"].model, "s910840 (S9+)")
        self.assertEqual(len(got["50:14:79:76:c6:eb"].os), 128)
        self.assertNotIn("00:00:00:00:00:01", got)
        self.assertNotIn("b8:27:eb:de:b2:36", got)
        self.assertEqual(len(got), 2)


class ProxmoxTests(unittest.TestCase):
    def test_vm_nics(self):
        vms = [
            {"vmid": 200, "name": "k8s-master", "cpus": 8, "maxmem": 16 * 2**30,
             "config": {"net0": "virtio=00:50:56:B0:A1:39,bridge=vmbr1,tag=20", "ostype": "l26"}},
            {"vmid": 101, "name": "pfsense", "cpus": 4, "maxmem": 4 * 2**30,
             "config": {"net0": "virtio=BC:24:11:D7:3F:BA,bridge=vmbr0", "net1": "e1000=BC:24:11:48:40:B9,bridge=vmbr1",
                        "ostype": "other", "template": 0}},
            {"vmid": 1000, "name": "tmpl", "cpus": 2, "maxmem": 2**30,
             "config": {"net0": "virtio=BC:24:11:00:00:01,bridge=vmbr0", "template": 1}},
        ]
        got = pe.proxmox_by_mac(vms)
        self.assertEqual(got["00:50:56:b0:a1:39"],
                         pe.Info(vendor="Proxmox VE", model="VM 200 k8s-master: 8 vCPU, 16 GiB", os="Linux"))
        self.assertEqual(got["bc:24:11:48:40:b9"].model, "VM 101 pfsense: 4 vCPU, 4 GiB")
        self.assertEqual(got["bc:24:11:48:40:b9"].os, None)
        self.assertNotIn("bc:24:11:00:00:01", got)


class K8sTests(unittest.TestCase):
    def test_node_info(self):
        nodes = {"items": [{
            "metadata": {"name": "k8s-node1", "labels": {"nvidia.com/gpu.product": "Tesla-T4-SHARED"}},
            "status": {
                "addresses": [{"type": "InternalIP", "address": "10.0.20.101"}],
                "capacity": {"cpu": "16", "memory": "49329196Ki"},
                "nodeInfo": {"osImage": "Ubuntu 24.04.4 LTS", "kernelVersion": "6.8.0-117-generic",
                             "kubeletVersion": "v1.35.9"},
            },
        }]}
        got = pe.k8s_by_ip(nodes)
        self.assertEqual(got["10.0.20.101"], pe.Info(
            vendor=None, model="k8s node: 16 vCPU, 47 GiB, GPU Tesla-T4-SHARED",
            os="Ubuntu 24.04.4 LTS, kernel 6.8.0-117-generic, kubelet v1.35.9"))


class MergeTests(unittest.TestCase):
    def test_precedence(self):
        ha = pe.Info("TP-Link", "KP115(UK)", "1.0.18")
        pve = pe.Info("Proxmox VE", "VM 1", "Linux")
        k8s = pe.Info(None, "k8s node", "Ubuntu")
        got = pe.merge(oui="VMware, Inc.", ha=None, proxmox=pve, k8s=k8s)
        self.assertEqual(got, pe.Info(vendor="Proxmox VE", model="k8s node", os="Ubuntu"))
        got = pe.merge(oui="TP-Link Corporation Limited", ha=ha, proxmox=None, k8s=None)
        self.assertEqual(got, ha)
        self.assertEqual(pe.merge(oui="Raspberry Pi Foundation"), pe.Info("Raspberry Pi Foundation", None, None))
        self.assertEqual(pe.merge(), pe.Info(None, None, None))


class FillTests(unittest.TestCase):
    def test_hand_rows_only_get_empty_fields(self):
        current = {"mac": "", "Vendor": "My own vendor", "Model": None, "OS": "", "switch": 0}
        new = {"mac": "aa:bb:cc:dd:ee:ff", "Vendor": "OUI vendor", "Model": "X1", "OS": None, "switch": 7}
        self.assertEqual(pe.field_updates(True, current, new),
                         {"mac": "aa:bb:cc:dd:ee:ff", "Model": "X1", "switch": 7})

    def test_importer_rows_follow_the_sources(self):
        current = {"mac": "aa:bb:cc:dd:ee:ff", "Vendor": "Old", "Model": "X1", "OS": "", "switch": 3}
        new = {"mac": "aa:bb:cc:dd:ee:ff", "Vendor": "New", "Model": "X1", "OS": None, "switch": 3}
        self.assertEqual(pe.field_updates(False, current, new), {"Vendor": "New"})

    def test_nothing_new_means_no_update(self):
        self.assertEqual(pe.field_updates(True, {"mac": "", "Vendor": None}, {"mac": None, "Vendor": None}), {})


class StateTests(unittest.TestCase):
    def test_tags(self):
        recent = NOW - dt.timedelta(hours=1)
        old = NOW - dt.timedelta(hours=30)
        for desc, seen, last, want in [
            ("-- dhcp london --", False, recent, pe.TAG_DHCP),
            ("-- arp sofia --", False, recent, pe.TAG_USED),
            ("-- reservation sofia --", False, old, pe.TAG_RESERVED),
            ("-- k8s lb x/y --", False, recent, pe.TAG_USED),
            ("SONY TV", True, old, pe.TAG_USED),
            ("SONY TV", False, recent, pe.TAG_USED),
            ("SONY TV", False, old, pe.TAG_OFFLINE),
        ]:
            with self.subTest(desc=desc, seen=seen):
                self.assertEqual(pe.state_for(desc, seen, last, NOW), want)


class DevicesTests(unittest.TestCase):
    YAML = """
- name: pve
  type: Server
  location: Sofia
  vendor: Dell
  addresses: [192.168.1.127]
- name: ha-london
  type: Server
  macs: [B8:27:EB:E9:18:92]
"""

    def test_load_and_link(self):
        devices = pe.load_devices(self.YAML)
        self.assertEqual([d.name for d in devices], ["pve", "ha-london"])
        self.assertEqual(devices[1].macs, ("b8:27:eb:e9:18:92",))
        rows = [
            (1, "192.168.1.127", ""),
            (2, "192.168.8.106", "b8:27:eb:e9:18:92"),
            (3, "192.168.8.50", "aa:aa:aa:aa:aa:aa"),
        ]
        self.assertEqual(pe.device_links(devices, rows), {1: "pve", 2: "ha-london"})

    def test_bad_entries_are_rejected(self):
        for text in ("- name: x\n  type: Toaster\n", "- type: Server\n", "- name: a\n  type: Server\n- name: a\n  type: Router\n"):
            with self.subTest(text=text):
                with self.assertRaises(ValueError):
                    pe.load_devices(text)

    def test_the_repo_file_loads(self):
        devices = pe.load_devices((Path(__file__).parent / "devices.yaml").read_text())
        self.assertGreater(len(devices), 20)
        self.assertTrue(all(d.addresses or d.macs for d in devices))


if __name__ == "__main__":
    unittest.main()
