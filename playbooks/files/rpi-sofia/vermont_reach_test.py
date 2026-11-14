"""Tests for vermont_reach: run with `python3 -m unittest vermont_reach_test` from this directory."""
import unittest
from datetime import datetime, timedelta

import vermont_reach as vr

T0 = datetime(2026, 11, 14, 0, 0, 2)


def obs(**kw):
    base = {"nvr_lan": True, "nvr_cloud": True, "acs_lan": True, "acs_cloud": True,
            "port8000": True, "disk": "ok",
            "channels": {"1": {"ip": "192.168.1.51", "online": True},
                         "2": {"ip": "192.168.1.52", "online": True}}}
    base.update(kw)
    return base


def run(state, sequence, start=T0, step=timedelta(minutes=5)):
    """Feed observations one run at a time; return all notifications with run index."""
    out = []
    for i, o in enumerate(sequence):
        state, notes = vr.evaluate(state, o, start + i * step)
        out += [(i, n) for n in notes]
    return state, out


class ParseTest(unittest.TestCase):
    def test_ezviz(self):
        self.assertFalse(vr.parse_ezviz("<EZVIZ><registerStatus>false</registerStatus></EZVIZ>"))
        self.assertTrue(vr.parse_ezviz("<registerStatus>true</registerStatus>"))
        self.assertIsNone(vr.parse_ezviz("<EZVIZ/>"))

    def test_disk(self):
        self.assertEqual(vr.parse_disk("<status>ok</status><status>idle</status>"), "ok")
        self.assertEqual(vr.parse_disk("<status>ok</status><status>error</status>"), "error")
        self.assertIsNone(vr.parse_disk("<hddList/>"))

    def test_channels_excludes_pi(self):
        xml = ('<InputProxyChannelStatusList xmlns="http://www.hikvision.com/ver20/XMLSchema">'
               '<InputProxyChannelStatus><id>1</id><sourceInputPortDescriptor>'
               '<ipAddress>192.168.1.51</ipAddress></sourceInputPortDescriptor>'
               '<online>false</online></InputProxyChannelStatus>'
               '<InputProxyChannelStatus><id>28</id><online>false</online></InputProxyChannelStatus>'
               '</InputProxyChannelStatusList>')
        self.assertEqual(vr.parse_channels(xml), {"1": {"ip": "192.168.1.51", "online": False}})

    def test_log(self):
        xml = ("<logDescriptor><metaId>log.hikvision.com/Exception/hdError</metaId>"
               "<StartDateTime>2026-11-14T00:01:12Z</StartDateTime><ipAddress>::</ipAddress>"
               "</logDescriptor>")
        self.assertEqual(vr.parse_log(xml), [{"time": "2026-11-14T00:01:12", "kind": "hdError",
                                              "ip": "::", "channel": ""}])


class InternetTest(unittest.TestCase):
    def test_all_outside_paths_down_means_internet_down(self):
        self.assertFalse(vr.derive_internet(obs(nvr_cloud=False, acs_cloud=False, port8000=False)))

    def test_one_path_up_means_internet_up(self):
        self.assertTrue(vr.derive_internet(obs(nvr_cloud=False, acs_cloud=False, port8000=True)))

    def test_nvr_dead_does_not_fake_an_internet_outage(self):
        self.assertTrue(vr.derive_internet(obs(nvr_lan=False, nvr_cloud=None, port8000=False)))

    def test_nothing_reachable_is_unknown(self):
        self.assertIsNone(vr.derive_internet(obs(nvr_lan=False, acs_lan=False, port8000=False)))


class EvaluateTest(unittest.TestCase):
    def test_single_bad_run_sends_nothing(self):
        _, notes = run({}, [obs(), obs(port8000=False), obs()])
        self.assertEqual(notes, [])

    def test_two_bad_runs_notify_once_then_recover_with_duration(self):
        seq = [obs()] + [obs(port8000=False)] * 4 + [obs()]
        _, notes = run({}, seq)
        self.assertEqual([(i, n["kind"], n["state"]) for i, n in notes],
                         [(2, "port8000", "down"), (5, "port8000", "up")])
        self.assertIn("14.11.2026 00:05:02", notes[0][1]["message"])
        self.assertIn("след 20м", notes[1][1]["message"])

    def test_internet_outage_is_one_message_not_four(self):
        down = obs(nvr_cloud=False, acs_cloud=False, port8000=False)
        _, notes = run({}, [obs(), down, down, down, obs()])
        self.assertEqual([(n["kind"], n["state"]) for _, n in notes],
                         [("internet", "down"), ("internet", "up")])

    def test_midnight_outage_points_at_the_fee(self):
        down = obs(nvr_cloud=False, acs_cloud=False, port8000=False)
        _, notes = run({}, [down, down], start=datetime(2026, 11, 14, 0, 1))
        self.assertIn("таксата", notes[0][1]["message"])

    def test_device_still_out_after_internet_returns_is_reported(self):
        down = obs(nvr_cloud=False, acs_cloud=False, port8000=False)
        acs_late = obs(acs_cloud=False)
        _, notes = run({}, [down, down, acs_late, acs_late, obs()])
        self.assertEqual([(i, n["kind"], n["state"]) for i, n in notes],
                         [(1, "internet", "down"), (2, "internet", "up"),
                          (3, "acs_cloud", "down"), (4, "acs_cloud", "up")])

    def test_dead_nvr_suppresses_its_cameras_cloud_and_disk(self):
        state, _ = run({}, [obs()])
        dead = obs(nvr_lan=False, nvr_cloud=None, port8000=False, disk=None, channels=None,
                   known_channels=["1", "2"])
        _, notes = run(state, [dead, dead, dead])
        self.assertEqual([n["kind"] for _, n in notes], ["nvr_lan"])

    def test_camera_down_and_back_named(self):
        cam_down = obs(channels={"1": {"ip": "192.168.1.51", "online": False},
                                 "2": {"ip": "192.168.1.52", "online": True}})
        state = {"names": {"1": "Camera 01"}}
        _, notes = run(state, [cam_down, cam_down, obs()])
        self.assertEqual([n["title"] for _, n in notes],
                         ["Камера падна: Camera 01 (канал 1, 192.168.1.51)",
                          "Камерата се върна: Camera 01 (канал 1, 192.168.1.51)"])

    def test_unknown_value_keeps_the_streak(self):
        _, notes = run({}, [obs(disk="error"), obs(disk=None), obs(disk="error")])
        self.assertEqual([n["kind"] for _, n in notes], ["disk"])


class EventsTest(unittest.TestCase):
    def test_first_run_sets_the_mark_without_backlog(self):
        state = {}
        start = vr.log_window_start(state, T0)
        self.assertEqual(start, T0)
        self.assertIsNone(vr.new_events(state, [], T0))
        self.assertEqual(state["log_last"], "2026-11-14T00:00:02")

    def test_noise_is_dropped_and_real_faults_folded(self):
        state = {"log_last": "2026-11-14T00:00:00"}
        entries = [
            {"time": "2026-11-14T00:00:05", "kind": "illlegealAccess", "ip": "1.2.3.4", "channel": ""},
            {"time": "2026-11-14T00:00:06", "kind": "ezvizOffline", "ip": "::", "channel": ""},
            {"time": "2026-11-14T00:00:07", "kind": "hdError", "ip": "", "channel": ""},
            {"time": "2026-11-14T00:00:08", "kind": "recordException", "ip": "", "channel": "3"},
        ]
        ev = vr.new_events(state, entries, T0)
        self.assertEqual(ev["title"], "NVR съобщи за 2 повреди")
        self.assertIn("грешка на диска", ev["message"])
        self.assertIn("грешка при запис, канал 3", ev["message"])

    def test_same_entry_is_not_reported_twice(self):
        state = {"log_last": "2026-11-14T00:00:00"}
        e = [{"time": "2026-11-14T00:00:07", "kind": "hdError", "ip": "", "channel": ""}]
        self.assertIsNotNone(vr.new_events(state, e, T0))
        self.assertIsNone(vr.new_events(state, e, T0 + timedelta(hours=2)))

    def test_same_kind_at_most_once_an_hour(self):
        state = {"log_last": "2026-11-14T00:00:00"}
        first = [{"time": "2026-11-14T00:00:07", "kind": "hdError", "ip": "", "channel": ""}]
        again = [{"time": "2026-11-14T00:10:00", "kind": "hdError", "ip": "", "channel": ""}]
        later = [{"time": "2026-11-14T01:30:00", "kind": "hdError", "ip": "", "channel": ""}]
        self.assertIsNotNone(vr.new_events(state, first, T0))
        self.assertIsNone(vr.new_events(state, again, T0 + timedelta(minutes=10)))
        self.assertIsNotNone(vr.new_events(state, later, T0 + timedelta(minutes=90)))


class FormatTest(unittest.TestCase):
    def test_duration(self):
        self.assertEqual(vr.fmt_duration(42), "42с")
        self.assertEqual(vr.fmt_duration(125), "2м 5с")
        self.assertEqual(vr.fmt_duration(20 * 60), "20м")
        self.assertEqual(vr.fmt_duration(11 * 3600 + 33 * 60), "11ч 33м")
        self.assertEqual(vr.fmt_duration(86400 + 60), "1д 1м")


if __name__ == "__main__":
    unittest.main()
