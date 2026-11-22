#!/usr/bin/env python3
"""Play one pattern from patterns.py on the WS2812 strip until SIGINT.

    play.py --pattern rainbow [--rgb 255,0,0] [--brightness 102] [--count 150]

server.py starts this and stops it with SIGINT, which clears the strip.
A still frame (delay None) is sent again once a second rather than at the
animation rate. That heals a frame the strip misread within a second, and it
sends far fewer frames for the strip to misread.
"""

import argparse
import random
import time
from collections.abc import Callable, Iterable
from typing import Protocol

import patterns

# LED strip configuration (rpi_ws281x):
LED_PIN = 10  # GPIO10 = SPI MOSI (/dev/spidev0.0), header pin 19
LED_FREQ_HZ = 800000
LED_DMA = 11
LED_INVERT = False
LED_CHANNEL = 0
HOLD_REFRESH = 1.0  # seconds between sends of a still frame


class Strip(Protocol):
    def setPixelColor(self, n: int, color: int) -> None: ...
    def show(self) -> None: ...


# The colours in patterns.py and from Home Assistant are screen colours. A
# screen darkens mid values along a gamma curve; a WS2812 gives light in
# direct proportion to the value sent. Without this table, mid values are too
# bright on the strip: Romania's blue shows light and Bulgaria's green shows
# teal. 2.2 is the usual screen gamma. 0 and 255 stay the same.
GAMMA_EXPONENT = 2.2
GAMMA = [round(255 * (v / 255) ** GAMMA_EXPONENT) for v in range(256)]


def color(rgb: patterns.RGB) -> int:
    """rpi_ws281x's Color(r, g, b) after gamma, without importing the library."""
    return (GAMMA[rgb[0]] << 16) | (GAMMA[rgb[1]] << 8) | GAMMA[rgb[2]]


def draw(strip: Strip, pixels: patterns.Pixels) -> None:
    for i, rgb in enumerate(pixels):
        strip.setPixelColor(i, color(rgb))
    strip.show()


def play(strip: Strip, frames: Callable[[], Iterable[patterns.Frame]],
         sleep: Callable[[float], None] = time.sleep, limit: int | None = None) -> int:
    """Draw frames forever, starting the pattern again when it ends.

    Returns the number of frames sent when `limit` (for tests) is reached.
    """
    sent = 0
    while True:
        played = 0
        for pixels, delay in frames():
            played += 1
            while True:
                draw(strip, pixels)
                sent += 1
                if limit is not None and sent >= limit:
                    return sent
                if delay is not None:
                    sleep(delay)
                    break
                sleep(HOLD_REFRESH)
        if played == 0:
            raise ValueError("pattern yielded no frames")


def parse_rgb(text: str) -> patterns.RGB:
    parts = [int(p) for p in text.split(",")]
    if len(parts) != 3 or not all(0 <= p <= 255 for p in parts):
        raise argparse.ArgumentTypeError("rgb is three numbers from 0 to 255, like 255,120,0")
    return parts[0], parts[1], parts[2]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--pattern", required=True, choices=sorted(patterns.PATTERNS))
    parser.add_argument("--rgb", type=parse_rgb, default=(176, 143, 18))
    parser.add_argument("--brightness", type=int, default=102, help="1 to 255")
    parser.add_argument("--count", type=int, default=150, help="LEDs on the strip")
    parser.add_argument("--music-delay-ms", type=int, default=0,
                        help="how long music patterns wait for the Bluetooth speaker")
    args = parser.parse_args()

    from rpi_ws281x import Adafruit_NeoPixel  # only on the Pi

    strip = Adafruit_NeoPixel(args.count, LED_PIN, LED_FREQ_HZ, LED_DMA, LED_INVERT,
                              args.brightness, LED_CHANNEL)
    strip.begin()
    pattern = patterns.PATTERNS[args.pattern]
    if pattern.music:
        import music  # numpy and parec, only for the music patterns

        feed = music.Feed(args.music_delay_ms / 1000)
        feed.start()
        patterns.listen = feed.levels
    rng = random.Random()
    try:
        play(strip, lambda: pattern.frames(args.count, args.rgb, rng))
    except KeyboardInterrupt:
        pass
    finally:
        draw(strip, patterns.solid(args.count, patterns.BLACK))


if __name__ == "__main__":
    main()
