import itertools
import random
import unittest

import numpy as np

import music
import patterns

RATE = music.RATE


def tone(freq: float, seconds: float, amp: float = 0.5) -> np.ndarray:
    t = np.arange(int(RATE * seconds)) / RATE
    return (amp * np.sin(2 * np.pi * freq * t)).astype(np.float32)


def snare_hit(seconds: float = 0.1, amp: float = 0.5) -> np.ndarray:
    """A snare-like crack: noise with no bass, the part above 800 Hz."""
    rng = np.random.default_rng(7)
    noise = rng.standard_normal(int(RATE * seconds))
    spectrum = np.fft.rfft(noise)
    spectrum[np.fft.rfftfreq(len(noise), 1 / RATE) < 800] = 0
    crack = np.fft.irfft(spectrum, len(noise))
    return (amp * crack / np.abs(crack).max()).astype(np.float32)


def rests(seconds: float) -> np.ndarray:
    return np.zeros(int(RATE * seconds), dtype=np.float32)


def onsets(values: list[float]) -> int:
    """How many times a falling flash value jumps back to 1."""
    return sum(1 for a, b in zip([0.0] + values, values) if b == 1.0 and a < 1.0)


def feed(analyser: music.Analyser, signal: np.ndarray) -> list[patterns.Levels]:
    """Run a signal through the analyser hop by hop, as the capture thread does."""
    out = []
    for start in range(0, len(signal) - music.HOP + 1, music.HOP):
        out.append(analyser.step(signal[start:start + music.HOP]))
    return out


class BandTest(unittest.TestCase):
    def test_a_low_tone_lands_in_a_bass_band(self):
        window = tone(80, music.WINDOW / RATE)
        power = music.band_power(window)
        self.assertEqual(len(power), patterns.BANDS)
        self.assertLessEqual(int(np.argmax(power)), 1)

    def test_a_high_tone_lands_in_a_treble_band(self):
        window = tone(5000, music.WINDOW / RATE)
        self.assertGreaterEqual(int(np.argmax(music.band_power(window))), patterns.BANDS - 2)

    def test_bands_are_ordered_bass_to_treble(self):
        edges = music.EDGES
        self.assertEqual(len(edges), patterns.BANDS + 1)
        self.assertTrue(all(a < b for a, b in zip(edges, edges[1:])))
        self.assertLessEqual(edges[-1], RATE / 2)


class AnalyserTest(unittest.TestCase):
    def test_a_steady_tone_lights_its_band_and_not_the_others(self):
        levels = feed(music.Analyser(), tone(80, 2.0))[-1]
        self.assertGreater(levels.bands[0] + levels.bands[1], 0.8)
        self.assertLess(max(levels.bands[5:]), 0.2)
        self.assertGreater(levels.level, 0.5)

    def test_silence_stays_dark(self):
        levels = feed(music.Analyser(), np.zeros(RATE * 2, dtype=np.float32))[-1]
        self.assertEqual(max(levels.bands), 0.0)
        self.assertEqual(levels.level, 0.0)
        self.assertEqual(levels.beat, 0.0)

    def test_music_fades_out_after_it_stops(self):
        analyser = music.Analyser()
        feed(analyser, tone(200, 2.0))
        levels = feed(analyser, np.zeros(RATE, dtype=np.float32))[-1]
        self.assertLess(max(levels.bands), 0.05)

    def test_bass_hits_are_beats(self):
        hit = np.concatenate([tone(60, 0.1, amp=0.8), np.zeros(int(RATE * 0.4), dtype=np.float32)])
        signal = np.concatenate([hit] * 8)
        beats = [lv.beat for lv in feed(music.Analyser(), signal)]
        flashes = sum(1 for a, b in zip(beats, beats[1:]) if b == 1.0 and a < 1.0)
        self.assertGreaterEqual(flashes, 5)

    def test_a_steady_tone_is_not_a_beat(self):
        beats = [lv.beat for lv in feed(music.Analyser(), tone(60, 3.0))]
        self.assertLess(max(beats[-30:]), 0.5)

    def test_cracks_are_snares_and_not_kicks(self):
        cracks = np.concatenate([np.concatenate([snare_hit(), rests(0.4)])] * 8)
        signal = cracks + tone(60, len(cracks) / RATE, amp=0.2)  # a steady bass line under them
        levels = feed(music.Analyser(), signal)[14:]  # after the averages settle
        self.assertGreaterEqual(onsets([lv.snare for lv in levels]), 6)
        self.assertEqual(onsets([lv.beat for lv in levels]), 0)

    def test_bass_hits_are_not_snares(self):
        hit = np.concatenate([tone(60, 0.1, amp=0.8), rests(0.4)])
        levels = feed(music.Analyser(), np.concatenate([hit] * 8))
        self.assertEqual(onsets([lv.snare for lv in levels]), 0)

    def test_kick_and_snare_in_turn_give_both(self):
        bar = np.concatenate([tone(60, 0.1, amp=0.8), rests(0.4), snare_hit(), rests(0.4)])
        levels = feed(music.Analyser(), np.concatenate([bar] * 6))
        self.assertGreaterEqual(onsets([lv.beat for lv in levels]), 4)
        self.assertGreaterEqual(onsets([lv.snare for lv in levels]), 4)

    def test_steady_noise_is_not_a_snare(self):
        levels = feed(music.Analyser(), snare_hit(seconds=3.0, amp=0.3))
        self.assertLess(max(lv.snare for lv in levels[-30:]), 0.5)

    def test_silence_has_no_snare(self):
        levels = feed(music.Analyser(), rests(2.0))
        self.assertEqual(max(lv.snare for lv in levels), 0.0)


class DelayTest(unittest.TestCase):
    def test_levels_come_out_after_the_delay(self):
        clock = [100.0]
        delayed = music.Delayed(delay=0.2, now=lambda: clock[0])
        loud = patterns.Levels((1.0,) * patterns.BANDS, 1.0, 1.0)
        delayed.put(loud)
        self.assertEqual(delayed.get(), patterns.SILENCE)
        clock[0] += 0.25
        self.assertEqual(delayed.get(), loud)

    def test_the_newest_ripe_levels_win(self):
        clock = [0.0]
        delayed = music.Delayed(delay=0.1, now=lambda: clock[0])
        first = patterns.Levels((0.1,) * patterns.BANDS, 0.1, 0.0)
        second = patterns.Levels((0.9,) * patterns.BANDS, 0.9, 0.0)
        delayed.put(first)
        clock[0] = 0.05
        delayed.put(second)
        clock[0] = 0.12
        self.assertEqual(delayed.get(), first)
        clock[0] = 0.2
        self.assertEqual(delayed.get(), second)


def music_frames(name: str, levels: patterns.Levels, n: int = 150, count: int = 40,
                 palette: str = "rainbow", colour: patterns.RGB = (0, 255, 0)) -> list:
    old, old_palette = patterns.listen, patterns.palette
    patterns.listen = lambda t: levels
    patterns.palette = palette
    try:
        gen = patterns.PATTERNS[name].frames(n, colour, random.Random(1))
        return list(itertools.islice(gen, count))
    finally:
        patterns.listen, patterns.palette = old, old_palette


def lit(rgb: patterns.RGB) -> int:
    return sum(rgb)


LOUD = patterns.Levels((1.0,) * patterns.BANDS, 1.0, 1.0, 1.0)
MUSIC = ("music_spectrum", "music_meter", "music_pulse", "music_drums")


class PaletteTest(unittest.TestCase):
    def lit_pixels(self, name, palette, colour=(0, 255, 0)):
        pixels, _ = music_frames(name, LOUD, palette=palette, colour=colour)[-1]
        return [p for p in pixels if lit(p) > 120]

    def test_palettes_are_listed(self):
        self.assertEqual(patterns.PALETTES, ("rainbow", "colour", "warm", "cool"))

    def test_warm_is_red_to_gold(self):
        for name in MUSIC:
            with self.subTest(pattern=name):
                px = self.lit_pixels(name, "warm")
                self.assertTrue(px)
                self.assertTrue(all(r >= g >= b for r, g, b in px))

    def test_cool_is_teal_to_violet(self):
        for name in MUSIC:
            with self.subTest(pattern=name):
                px = self.lit_pixels(name, "cool")
                self.assertTrue(px)
                self.assertTrue(all(b >= r for r, g, b in px))

    def test_your_colour_uses_only_that_colour(self):
        for name in MUSIC:
            with self.subTest(pattern=name):
                px = self.lit_pixels(name, "colour", colour=(0, 0, 255))
                self.assertTrue(px)
                self.assertTrue(all(r == 0 and g == 0 for r, g, b in px))

    def test_the_patterns_take_a_colour(self):
        self.assertTrue(all(patterns.PATTERNS[n].colour for n in MUSIC))


class MusicPatternTest(unittest.TestCase):
    def test_the_four_music_patterns_are_listed(self):
        music_group = [p.name for p in patterns.PATTERNS.values() if p.group == "Music"]
        self.assertEqual(music_group, list(MUSIC))
        self.assertTrue(all(patterns.PATTERNS[n].music for n in music_group))

    def test_spectrum_lights_only_the_loud_band(self):
        bands = (1.0,) + (0.0,) * (patterns.BANDS - 1)
        pixels, delay = music_frames("music_spectrum", patterns.Levels(bands, 1.0, 0.0))[-1]
        segment = 150 // patterns.BANDS
        self.assertTrue(all(lit(p) > 100 for p in pixels[:segment - 1]))
        self.assertLess(max(lit(p) for p in pixels[segment * 2:]), 60)
        self.assertIsNotNone(delay)

    def test_spectrum_bass_is_red_and_treble_violet(self):
        loud = patterns.Levels((1.0,) * patterns.BANDS, 1.0, 0.0)
        pixels, _ = music_frames("music_spectrum", loud)[-1]
        r, g, b = pixels[2]
        self.assertGreater(r, max(g, b))
        r, g, b = pixels[-3]
        self.assertGreater(b, g)
        self.assertGreater(r, g)

    def test_meter_grows_from_the_centre(self):
        pixels, _ = music_frames("music_meter", patterns.Levels(patterns.SILENCE.bands, 0.5, 0.0))[-1]
        self.assertGreater(lit(pixels[75]), 100)
        self.assertLess(lit(pixels[0]), 30)
        self.assertLess(lit(pixels[149]), 30)

    def test_pulse_is_bright_on_a_beat_and_dim_without(self):
        bright, _ = music_frames("music_pulse", patterns.Levels(patterns.SILENCE.bands, 0.3, 1.0))[-1]
        dim, _ = music_frames("music_pulse", patterns.SILENCE)[-1]
        self.assertGreater(lit(bright[75]), 3 * lit(dim[75]))

    def test_kick_lights_the_middle_and_not_the_ends(self):
        kick = patterns.Levels(patterns.SILENCE.bands, 0.3, 1.0, 0.0)
        pixels, _ = music_frames("music_drums", kick)[-1]
        self.assertGreater(lit(pixels[75]), 200)
        self.assertLess(lit(pixels[5]), 60)
        self.assertLess(lit(pixels[144]), 60)

    def test_snare_lights_the_ends_and_not_the_middle(self):
        snare = patterns.Levels(patterns.SILENCE.bands, 0.3, 0.0, 1.0)
        pixels, _ = music_frames("music_drums", snare)[-1]
        self.assertGreater(lit(pixels[5]), 200)
        self.assertGreater(lit(pixels[144]), 200)
        self.assertLess(lit(pixels[75]), 60)

    def test_kick_and_snare_have_different_colours(self):
        both = patterns.Levels(patterns.SILENCE.bands, 0.3, 1.0, 1.0)
        for palette in patterns.PALETTES:
            with self.subTest(palette=palette):
                pixels, _ = music_frames("music_drums", both, palette=palette)[-1]
                self.assertNotEqual(pixels[75], pixels[5])

    def test_drums_fade_after_the_hit(self):
        hit = patterns.Levels(patterns.SILENCE.bands, 0.0, 1.0, 1.0)
        old = patterns.listen
        patterns.listen = lambda t: hit if t == 0 else patterns.SILENCE
        try:
            gen = patterns.PATTERNS["music_drums"].frames(150, (0, 255, 0), random.Random(1))
            frames = [pixels for pixels, _ in itertools.islice(gen, 20)]
        finally:
            patterns.listen = old
        for j in (5, 75):
            self.assertLess(lit(frames[-1][j]), lit(frames[0][j]) / 4)

    def test_silence_keeps_a_faint_glow_not_full_light(self):
        for name in MUSIC:
            with self.subTest(pattern=name):
                pixels, _ = music_frames(name, patterns.SILENCE)[-1]
                self.assertLess(max(lit(p) for p in pixels), 80)

    def test_short_strips_work(self):
        loud = patterns.Levels((1.0,) * patterns.BANDS, 1.0, 1.0, 1.0)
        for name in MUSIC:
            for n in (1, 7):
                with self.subTest(pattern=name, leds=n):
                    pixels, _ = music_frames(name, loud, n=n)[-1]
                    self.assertEqual(len(pixels), n)
                    self.assertGreater(max(lit(p) for p in pixels), 0)


if __name__ == "__main__":
    unittest.main()
