import importlib
import sys
import types
import unittest
from unittest import mock


def Color(red, green, blue, white=0):
    return (white << 24) | (red << 16) | (green << 8) | blue


# strandtest.py does `from rpi_ws281x import *`; give it a stand-in off the Pi.
fake = types.ModuleType("rpi_ws281x")
fake.Color = Color
fake.Adafruit_NeoPixel = object
fake.__all__ = ["Color", "Adafruit_NeoPixel"]
sys.modules.setdefault("rpi_ws281x", fake)
strandtest = importlib.import_module("strandtest")


class FakeStrip:
    def __init__(self, n):
        self.n = n
        self.pixels = [0] * n
        self.shows = 0
        self.lit = 0

    def numPixels(self):
        return self.n

    def setPixelColor(self, i, color):
        if not 0 <= i < self.n:
            raise IndexError(i)
        if not 0 <= color <= 0xFFFFFF:
            raise ValueError(hex(color))
        self.pixels[i] = color

    def getPixelColor(self, i):
        return self.pixels[i]

    def show(self):
        self.shows += 1
        self.lit = max(self.lit, sum(1 for p in self.pixels if p))


NEW_PATTERNS = {
    "flag_bg": (), "flag_ro": (), "flag_uk": (), "fire": (), "police": (),
    "ocean": (), "candy_cane": (), "ruler": (),
    "comet": (Color(0, 255, 0),), "scanner": (Color(255, 0, 0),),
    "breathe": (Color(0, 0, 255),), "twinkle": (Color(255, 255, 255),),
}


class PatternTest(unittest.TestCase):
    def test_every_new_pattern_draws_and_returns(self):
        with mock.patch.object(strandtest.time, "sleep"):
            for name, extra in NEW_PATTERNS.items():
                for n in (150, 7, 1):
                    with self.subTest(pattern=name, leds=n):
                        strip = FakeStrip(n)
                        strandtest.run_pattern(strandtest.Pattern(name), strip, *extra)
                        self.assertGreater(strip.shows, 0)
                        self.assertGreater(strip.lit, 0)

    def test_ruler_marks_every_tenth_and_fiftieth_led(self):
        strip = FakeStrip(150)
        with mock.patch.object(strandtest.time, "sleep"):
            strandtest.ruler(strip)
        self.assertEqual(strip.pixels[0], Color(0, 0, 255))
        self.assertEqual(strip.pixels[9], Color(255, 0, 0))
        self.assertEqual(strip.pixels[49], Color(0, 255, 0))
        self.assertEqual(strip.pixels[149], Color(0, 255, 0))
        self.assertNotIn(strip.pixels[5], (Color(255, 0, 0), Color(0, 255, 0)))

    def test_flag_has_the_flag_colours(self):
        strip = FakeStrip(150)
        with mock.patch.object(strandtest.time, "sleep"):
            strandtest.flag(strip, strandtest.FLAGS["bg"], frames=1)
        hues = {strandtest.rgb_of(p).index(max(strandtest.rgb_of(p))) for p in strip.pixels
                if strandtest.rgb_of(p) != (0, 0, 0) and len(set(strandtest.rgb_of(p))) > 1}
        self.assertEqual(hues, {0, 1})  # red and green bands; white has equal channels


if __name__ == "__main__":
    unittest.main()
