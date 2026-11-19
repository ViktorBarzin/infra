import json
import tempfile
import unittest
from pathlib import Path

import server


class MergeTest(unittest.TestCase):
    def test_turn_off_keeps_pattern_and_brightness(self):
        state = server.merge(server.DEFAULT_STATE, {"on": True, "pattern": "jik_tak"})
        state = server.merge(state, {"on": False})
        self.assertEqual(state["on"], False)
        self.assertEqual(state["pattern"], "jik_tak")
        self.assertEqual(state["brightness"], 102)

    def test_any_change_without_on_turns_the_light_on(self):
        state = server.merge(server.DEFAULT_STATE, {"brightness": 40})
        self.assertTrue(state["on"])
        self.assertEqual(state["brightness"], 40)

    def test_colour_on_a_rainbow_pattern_switches_to_color_wipe(self):
        state = server.merge(server.DEFAULT_STATE, {"rgb": [255, 0, 0]})
        self.assertEqual(state["pattern"], "color_wipe")
        self.assertEqual(state["rgb"], [255, 0, 0])

    def test_colour_keeps_a_colour_pattern(self):
        state = server.merge(server.DEFAULT_STATE, {"pattern": "theater_chase"})
        state = server.merge(state, {"rgb": [0, 0, 255]})
        self.assertEqual(state["pattern"], "theater_chase")

    def test_rejects_unknown_pattern(self):
        with self.assertRaises(ValueError):
            server.merge(server.DEFAULT_STATE, {"pattern": "falling_stars"})

    def test_rejects_bad_brightness_and_colour(self):
        for change in ({"brightness": 0}, {"brightness": 256}, {"brightness": "x"},
                       {"rgb": [1, 2]}, {"rgb": [0, 0, 300]}, {"on": "yes"}):
            with self.assertRaises(ValueError, msg=change):
                server.merge(server.DEFAULT_STATE, change)

    def test_rejects_unknown_keys(self):
        with self.assertRaises(ValueError):
            server.merge(server.DEFAULT_STATE, {"speed": 3})


class CommandTest(unittest.TestCase):
    def test_rainbow_passes_no_colour(self):
        state = server.merge(server.DEFAULT_STATE, {"on": True})
        argv = server.command(state)
        self.assertIn("-c", argv)
        self.assertEqual(argv[argv.index("-s") + 1], "rainbow")
        self.assertEqual(argv[argv.index("--colors") + 1], "")
        self.assertEqual(argv[argv.index("--brightness") + 1], "102")

    def test_colour_pattern_passes_strandtest_colour_format(self):
        state = server.merge(server.DEFAULT_STATE, {"pattern": "color_wipe", "rgb": [10, 20, 30]})
        argv = server.command(state)
        self.assertEqual(argv[argv.index("--colors") + 1], "r=10,g=20,b=30")


class NewPatternTest(unittest.TestCase):
    def test_new_colour_patterns_get_the_colour(self):
        for pattern in ("comet", "scanner", "breathe", "twinkle"):
            state = server.merge(server.DEFAULT_STATE, {"pattern": pattern, "rgb": [1, 2, 3]})
            argv = server.command(state)
            self.assertEqual(argv[argv.index("--colors") + 1], "r=1,g=2,b=3", pattern)

    def test_colour_on_a_flag_switches_to_color_wipe(self):
        state = server.merge(server.DEFAULT_STATE, {"pattern": "flag_bg"})
        self.assertEqual(server.merge(state, {"rgb": [9, 9, 9]})["pattern"], "color_wipe")

    def test_led_count_is_passed_through(self):
        state = server.merge(server.DEFAULT_STATE, {"on": True})
        argv = server.command(state, count=163)
        self.assertEqual(argv[argv.index("--count") + 1], "163")

    def test_led_count_from_options_with_fallback(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "options.json"
            self.assertEqual(server.led_count(path), 150)
            path.write_text(json.dumps({"led_count": 163}))
            self.assertEqual(server.led_count(path), 163)
            path.write_text(json.dumps({"led_count": 0}))
            self.assertEqual(server.led_count(path), 150)


class PersistTest(unittest.TestCase):
    def test_round_trip_and_fallback(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "state.json"
            self.assertEqual(server.load(path), server.DEFAULT_STATE)
            state = server.merge(server.DEFAULT_STATE, {"pattern": "jik_tak"})
            server.save(path, state)
            self.assertEqual(server.load(path), state)
            path.write_text("not json")
            self.assertEqual(server.load(path), server.DEFAULT_STATE)
            path.write_text(json.dumps({"on": True, "pattern": "nope"}))
            self.assertEqual(server.load(path), server.DEFAULT_STATE)


FAKE_STRANDTEST = """
import signal, sys, time
print("fake", sys.argv[1:], flush=True)
try:
    while True:
        time.sleep(0.05)
except KeyboardInterrupt:
    sys.exit(0)
"""


class StripProcessTest(unittest.TestCase):
    def test_start_switch_and_stop(self):
        with tempfile.TemporaryDirectory() as d:
            fake = Path(d) / "strandtest.py"
            fake.write_text(FAKE_STRANDTEST)
            original = server.SCRIPT
            server.SCRIPT = fake
            try:
                strip = server.Strip(Path(d) / "state.json")
                strip.start()
                self.assertFalse(strip.running())
                strip.change({"on": True})
                first = strip.proc
                self.assertTrue(strip.running())
                strip.change({"pattern": "jik_tak"})
                self.assertIsNot(strip.proc, first)
                self.assertIsNotNone(first.returncode)
                self.assertTrue(strip.running())
                strip.change({"on": False})
                self.assertFalse(strip.running())
                restored = server.Strip(Path(d) / "state.json")
                self.assertEqual(restored.state["pattern"], "jik_tak")
                self.assertFalse(restored.state["on"])
                strip.shutdown()
            finally:
                server.SCRIPT = original


class KeepAliveTest(unittest.TestCase):
    def test_restarts_a_pattern_that_died_while_on_and_not_while_off(self):
        with tempfile.TemporaryDirectory() as d:
            fake = Path(d) / "strandtest.py"
            fake.write_text(FAKE_STRANDTEST)
            original = server.SCRIPT
            server.SCRIPT = fake
            try:
                strip = server.Strip(Path(d) / "state.json")
                strip.change({"on": True})
                first = strip.proc
                first.kill()  # what the OOM killer does
                first.wait()
                self.assertFalse(strip.running())
                self.assertTrue(strip.keep_alive(now=1000.0))
                self.assertTrue(strip.running())
                self.assertIsNot(strip.proc, first)
                # alive: nothing to do
                self.assertFalse(strip.keep_alive(now=1001.0))
                strip.change({"on": False})
                self.assertFalse(strip.keep_alive(now=2000.0))
                self.assertFalse(strip.running())
                strip.shutdown()
            finally:
                server.SCRIPT = original

    def test_backs_off_when_the_pattern_keeps_dying(self):
        with tempfile.TemporaryDirectory() as d:
            fake = Path(d) / "strandtest.py"
            fake.write_text("import sys; sys.exit(1)\n")
            original = server.SCRIPT
            server.SCRIPT = fake
            try:
                strip = server.Strip(Path(d) / "state.json")
                strip.change({"on": True})
                strip.proc.wait()
                self.assertTrue(strip.keep_alive(now=100.0))
                strip.proc.wait()
                # died again at once: the next restart waits
                self.assertFalse(strip.keep_alive(now=101.0))
                self.assertTrue(strip.keep_alive(now=100.0 + server.MAX_BACKOFF))
                strip.shutdown()
            finally:
                server.SCRIPT = original


if __name__ == "__main__":
    unittest.main()
