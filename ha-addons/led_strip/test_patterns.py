import itertools
import json
import random
import time
import unittest

import dashboard
import patterns
import play

FRAMES = 400  # enough to see rockets, drops and flakes appear


def take(name, n, colour=(0, 255, 0), count=FRAMES, seed=1):
    gen = patterns.PATTERNS[name].frames(n, colour, random.Random(seed))
    return list(itertools.islice(gen, count))


class FakeStrip:
    def __init__(self, n):
        self.pixels = [0] * n
        self.shows = 0

    def setPixelColor(self, i, color):
        if not 0 <= i < len(self.pixels):
            raise IndexError(i)
        if not 0 <= color <= 0xFFFFFF:
            raise ValueError(hex(color))
        self.pixels[i] = color

    def show(self):
        self.shows += 1


class EveryPatternTest(unittest.TestCase):
    def test_frames_are_valid_and_light_the_strip(self):
        for name in patterns.PATTERNS:
            for n in (150, 7, 1):
                with self.subTest(pattern=name, leds=n):
                    frames = take(name, n)
                    self.assertGreater(len(frames), 0)
                    lit = False
                    for pixels, delay in frames:
                        self.assertEqual(len(pixels), n)
                        for rgb in pixels:
                            self.assertEqual(len(rgb), 3)
                            for c in rgb:
                                self.assertIsInstance(c, int)
                                self.assertTrue(0 <= c <= 255, rgb)
                        lit = lit or any(rgb != (0, 0, 0) for rgb in pixels)
                        self.assertTrue(delay is None or 0 < delay <= 1, delay)
                    self.assertTrue(lit)

    def test_only_the_last_frame_can_be_still(self):
        for name in patterns.PATTERNS:
            with self.subTest(pattern=name):
                frames = take(name, 150)
                self.assertNotIn(None, [delay for _, delay in frames[:-1]])

    def test_colour_patterns_use_the_colour(self):
        for p in patterns.PATTERNS.values():
            if p.colour:
                with self.subTest(pattern=p.name):
                    colours = {rgb for pixels, _ in take(p.name, 150, colour=(0, 0, 200)) for rgb in pixels}
                    self.assertIn((0, 0, 200), colours)
                    self.assertTrue(all(r == 0 and g == 0 for r, g, _ in colours))

    def test_every_pattern_has_a_title_and_a_group(self):
        for p in patterns.PATTERNS.values():
            self.assertTrue(p.title and p.group and p.about, p.name)


class PatternTest(unittest.TestCase):
    def test_ruler_marks_every_tenth_and_fiftieth_led_and_is_still(self):
        (pixels, delay), = take("ruler", 150)
        self.assertIsNone(delay)
        self.assertEqual(pixels[0], (0, 0, 255))
        self.assertEqual(pixels[9], (255, 0, 0))
        self.assertEqual(pixels[49], (0, 255, 0))
        self.assertEqual(pixels[149], (0, 255, 0))
        self.assertEqual(pixels[5], (12, 12, 12))

    def test_solid_colour_fills_then_stays_still(self):
        frames = take("color_wipe", 10, colour=(9, 8, 7))
        self.assertEqual(len(frames), 11)
        self.assertEqual(frames[0][0][:2], [(9, 8, 7), (0, 0, 0)])
        self.assertEqual(frames[-1], ([(9, 8, 7)] * 10, None))

    def test_flag_has_the_flag_colours(self):
        pixels, _ = take("flag_bg", 150, count=1)[0]
        hues = {rgb.index(max(rgb)) for rgb in pixels if len(set(rgb)) > 1}
        self.assertEqual(hues, {0, 1})  # red and green bands; white has equal channels

    def test_jik_tak_is_mirrored(self):
        for n in (150, 7):
            pixels, _ = take("jik_tak", n, count=1)[0]
            self.assertEqual(pixels, pixels[::-1])

    def test_storm_has_lightning(self):
        brightest = max(max(sum(rgb) for rgb in pixels) for pixels, _ in take("weather_storm", 150, count=600))
        self.assertGreater(brightest, 600)

    def test_bouncing_balls_reach_both_ends(self):
        lit = {i for pixels, _ in take("bouncing_balls", 150, count=600)
               for i, rgb in enumerate(pixels) if sum(rgb) > 200}
        self.assertIn(0, lit)
        self.assertGreater(max(lit), 120)

    def test_heartbeat_is_mirrored_around_the_middle(self):
        for n in (150, 7):
            for pixels, _ in take("heartbeat", n, count=60):
                self.assertEqual(pixels, pixels[::-1])

    def test_heartbeat_beats_once_a_second(self):
        beat = list(patterns.heartbeat(150, (0, 0, 0), random.Random()))
        self.assertAlmostEqual(sum(delay for _, delay in beat), 1.0)

    def test_newtons_cradle_swings_one_end_at_a_time(self):
        n = 150
        middle = n // 2
        for pixels, _ in take("newtons_cradle", n, count=300):
            self.assertGreater(sum(pixels[middle]), 0)  # the balls in the middle never move
            left = any(sum(rgb) for rgb in pixels[:middle - 20])
            right = any(sum(rgb) for rgb in pixels[middle + 20:])
            self.assertFalse(left and right)

    def test_pendulum_wave_starts_and_ends_in_step(self):
        frames = list(patterns.pendulum_wave(150, (0, 0, 0), random.Random()))
        lane = 150 // patterns.PENDULUMS

        def offsets(pixels):
            return {max(range(lane), key=lambda i: sum(pixels[k * lane + i])) for k in range(patterns.PENDULUMS)}
        self.assertEqual(len(offsets(frames[0][0])), 1)
        self.assertGreater(len(offsets(frames[len(frames) // 10][0])), 3)  # out of step soon after

    def test_dna_has_two_strands(self):
        pixels, _ = take("dna", 150, count=1)[0]
        self.assertTrue(any(b > r for r, g, b in pixels))
        self.assertTrue(any(r > b for r, g, b in pixels))

    def test_hourglass_moves_the_sand_from_the_top_to_the_bottom(self):
        frames = take("hourglass", 150, count=100000)
        first, last = frames[0][0], frames[-1][0]
        sand = patterns.SAND
        self.assertTrue(all(rgb == sand for rgb in first[75:]))
        self.assertNotIn(sand, first[:75])
        self.assertTrue(all(rgb == sand for rgb in last[:75]))
        self.assertNotIn(sand, last[76:])
        counts = {sum(rgb == sand for rgb in pixels) for pixels, _ in frames}
        self.assertLessEqual(max(counts) - min(counts), 3)  # grains in flight only

    def test_clock_hands_point_at_the_time(self):
        half_past_three = time.mktime((2026, 1, 1, 3, 30, 0, 0, 0, -1))  # local time
        try:
            patterns.now = lambda: half_past_three
            pixels, _ = take("clock", 121, count=1)[0]
        finally:
            patterns.now = time.time
        hour = max(range(121), key=lambda i: pixels[i][0] - pixels[i][2])
        minute = max(range(121), key=lambda i: pixels[i][2] - pixels[i][0])
        self.assertAlmostEqual(hour, 35, delta=2)  # 3.5 of 12 hours
        self.assertAlmostEqual(minute, 60, delta=2)  # 30 of 60 minutes

    def test_rally_ball_reaches_both_paddles(self):
        lit = {i for pixels, _ in take("rally", 150, count=1500)
               for i, rgb in enumerate(pixels) if rgb[0] > 150 and rgb[1] > 150 and rgb[2] > 150}
        self.assertLess(min(lit), 8)
        self.assertGreater(max(lit), 141)

    def test_morse_code(self):
        self.assertEqual(patterns.morse("SOS"), "1010100011101110111000101010000000")
        self.assertEqual(patterns.morse("E E"), "1000000010000000")


class PlayTest(unittest.TestCase):
    def test_draws_frames_and_restarts_a_pattern_that_ends(self):
        strip = FakeStrip(7)
        sleeps = []
        sent = play.play(strip, lambda: patterns.PATTERNS["police"].frames(7, (0, 0, 0), random.Random()),
                         sleep=sleeps.append, limit=20)
        self.assertEqual(sent, 20)
        self.assertEqual(strip.shows, 20)  # police has 8 frames, so it ran again
        self.assertEqual(sleeps, [0.06] * 19)

    def test_still_frame_is_resent_once_a_second(self):
        strip = FakeStrip(150)
        sleeps = []
        play.play(strip, lambda: patterns.PATTERNS["ruler"].frames(150, (0, 0, 0), random.Random()),
                  sleep=sleeps.append, limit=5)
        self.assertEqual(sleeps, [play.HOLD_REFRESH] * 4)
        self.assertEqual(strip.pixels[0], 0x0000FF)
        self.assertEqual(strip.pixels[9], 0xFF0000)

    def test_rgb_argument(self):
        self.assertEqual(play.parse_rgb("255,0,9"), (255, 0, 9))
        for bad in ("1,2", "0,0,256", "a,b,c"):
            with self.assertRaises(Exception):
                play.parse_rgb(bad)


class DashboardTest(unittest.TestCase):
    def config(self):
        return {"views": [{"max_columns": 2, "sections": [
            {"type": "grid", "cards": [{"type": "tile", "entity": "light.livia"}]},
            {"type": "grid", "cards": [{"type": "button", "tap_action": {"data": {"effect": "rainbow"}}}]},
            {"type": "grid", "cards": [{"type": "button", "tap_action": {"data": {"effect": "fire"}}}]},
            {"type": "grid", "cards": [{"type": "markdown"}]},
        ]}]}

    def test_one_section_per_group_in_place_of_the_old_ones(self):
        view = dashboard.updated(self.config(), "9.9.9")["views"][0]
        groups = list(dict.fromkeys(p.group for p in patterns.PATTERNS.values()))
        sections = view["sections"]
        self.assertEqual(sections[0]["cards"], [{"type": "tile", "entity": "light.livia"}])
        self.assertEqual(sections[-1]["cards"], [{"type": "markdown"}])
        middle = sections[1:-1]
        self.assertEqual([s["cards"][0]["heading"] for s in middle], groups)
        effects = [c["tap_action"]["data"]["effect"] for s in middle for c in s["cards"] if c["type"] == "picture"]
        self.assertEqual(effects, list(patterns.PATTERNS))
        self.assertIn("/local/livia/aurora.webp?v=9.9.9", [c.get("image") for s in middle for c in s["cards"]])
        self.assertEqual(view["max_columns"], 4)
        self.assertTrue(view["dense_section_placement"])

    def test_running_twice_changes_nothing(self):
        once = dashboard.updated(self.config(), "1")
        self.assertEqual(dashboard.updated(json.loads(json.dumps(once)), "1"), once)

    def test_adds_the_sections_when_missing(self):
        config = {"views": [{"sections": [{"type": "grid", "cards": []}]}]}
        groups = {p.group for p in patterns.PATTERNS.values()}
        self.assertEqual(len(dashboard.updated(config, "1")["views"][0]["sections"]), 1 + len(groups))


if __name__ == "__main__":
    unittest.main()
