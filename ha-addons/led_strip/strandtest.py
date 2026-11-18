#!/usr/bin/env python3
# rpi_ws281x library strandtest example
# Author: Tony DiCola (tony@tonydicola.com)
#
# Direct port of the Arduino NeoPixel library strandtest example.  Showcases
# various animations on a strip of NeoPixels.

import argparse
import math
import random
import time
from enum import Enum

from rpi_ws281x import *

# LED strip configuration:
LED_COUNT = 150  # Number of LED pixels.
#LED_PIN = 18  # GPIO pin connected to the pixels (18 uses PWM!).
LED_PIN = 10  # GPIO pin connected to the pixels (10 uses SPI /dev/spidev0.0).
LED_FREQ_HZ = 800000  # LED signal frequency in hertz (usually 800khz)
LED_DMA = 11  # DMA channel to use for generating signal (try 10)
#LED_BRIGHTNESS = 255  # Set to 0 for darkest and 255 for brightest
LED_BRIGHTNESS = 102  # Set to 0 for darkest and 255 for brightest
LED_INVERT = False  # True to invert the signal (when using NPN transistor level shift)
LED_CHANNEL = 0  # set to '1' for GPIOs 13, 19, 41, 45 or 53


# Define functions which animate LEDs in various ways.
def colorWipe(strip, color, wait_ms=50):
    """Wipe color across display a pixel at a time."""
    for i in range(strip.numPixels()):
        strip.setPixelColor(i, color)
        strip.show()
        time.sleep(wait_ms / 1000.0)


def theaterChase(strip, color, wait_ms=50, iterations=10):
    """Movie theater light style chaser animation."""
    for j in range(iterations):
        for q in range(3):
            for i in range(0, strip.numPixels(), 3):
                strip.setPixelColor(i + q, color)
            strip.show()
            time.sleep(wait_ms / 1000.0)
            for i in range(0, strip.numPixels(), 3):
                strip.setPixelColor(i + q, 0)


def wheel(pos):
    """Generate rainbow colors across 0-255 positions."""
    if pos < 85:
        return Color(pos * 3, 255 - pos * 3, 0)
    elif pos < 170:
        pos -= 85
        return Color(255 - pos * 3, 0, pos * 3)
    else:
        pos -= 170
        return Color(0, pos * 3, 255 - pos * 3)


def bumbum(pos):
    if pos <= 170:
        return Color(int((255 - pos) / 2), 0, int(pos / 2))
    else:
        pos -= 170
        return Color(0, int((pos * 3) / 2), int((255 - pos * 3) / 2))


def rainbow(strip, wait_ms=20, iterations=1):
    """Draw rainbow that fades across all pixels at once."""
    for j in range(256 * iterations):
        for i in range(strip.numPixels()):
            strip.setPixelColor(i, wheel((i + j) & 255))
        strip.show()
        time.sleep(wait_ms / 1000.0)


def rainbowCycle(strip, wait_ms=20, iterations=5):
    """Draw rainbow that uniformly distributes itself across all pixels."""
    for j in range(256 * iterations):
        for i in range(strip.numPixels()):
            strip.setPixelColor(
                i, wheel((int(i * 256 / strip.numPixels()) + j) & 255)
            )
        strip.show()
        time.sleep(wait_ms / 1000.0)


def theaterChaseRainbow(strip, wait_ms=50):
    """Rainbow movie theater light style chaser animation."""
    for j in range(256):
        for q in range(3):
            for i in range(0, strip.numPixels(), 3):
                strip.setPixelColor(i + q, wheel((i + j) % 255))
            strip.show()
            time.sleep(wait_ms / 1000.0)
            for i in range(0, strip.numPixels(), 3):
                strip.setPixelColor(i + q, 0)


def jik_tak(strip, wait_ms=1, iterations=1):
    """Draw jik-tak pattern."""
    for j in range(256 * iterations):
        for i in range(int(strip.numPixels() / 2)):
            strip.setPixelColor(i, bumbum((i + j) & 255))
            strip.setPixelColor(strip.numPixels() - i, bumbum((i + j) & 255))
        strip.show()
        time.sleep(wait_ms / 1000.0)


def draw_star(strip, offset, star_len):
    for i in range(offset, offset + star_len):
        strip.setPixelColor(i, Color(255, 255, 255))
        strip.show()
    return offset, star_len + offset


def falling_stars(strip, wait_ms=50, star_len=10):

    num_stars = 1
    max_stars = 10
    lists_to_draw = [list(range(star_len))]
    num_pixels = int(strip.numPixels())
    while True:
        for tick in range(num_pixels):
            print(tick)
            print(lists_to_draw)
            for l in lists_to_draw:
                # draw l
                # for el in l:
                #     strip.setPixelColor(el + tick, Color(255, 255, 255))
                #     time.sleep(wait_ms / 1000.0)
                # +1 all elements
                for idx, v in enumerate(l):
                    l[idx] = (v + 1) % num_pixels
                    strip.setPixelColor(l[idx], Color(255, 255, 255))
                strip.show()
                strip.setPixelColor(l[0], Color(0, 0, 0))
            time.sleep(wait_ms / 1000.0)

            if lists_to_draw[-1][
                -1] - star_len >= star_len * 3 and num_stars < max_stars:
                num_stars += 1
                lists_to_draw.append(list(range(star_len)))

        #     start, end = draw_star(strip, i + offset, star_len)
        #     strip.setPixelColor(start, Color(0, 0, 0))

        #     for star_id in range(num_stars):
        #         for star_idx in range(star_len):
        #             strip.setPixelColor(
        #                 star_idx + px_id + star_id * gap_to_next,
        #                 Color(255, 255, 255)
        #             )
        #             strip.show()
        #             time.sleep(wait_ms / 1000.0)
        #         if num_stars < max_stars:
        #             num_stars += 1

    # for i in range(num_stars):
    #     if num_stars < max_stars:
    #         num_stars += 1
    #         _draw_star(
    #             strip,
    #             0 + i * gap_to_next,
    #             star_len,
    #         )
    #         print('AAA')
    # print(start, end)
    # return
    # if i - gap_to_next > 0:
    #     start, end = draw_star(strip, i, star_len)
    #     strip.setPixelColor(start, Color(0, 0, 0))


def _draw_star(strip, offset, star_len, wait_ms=50):
    for i in range(int(strip.numPixels())):
        start, end = draw_star(strip, i + offset, star_len)
        strip.setPixelColor(start, Color(0, 0, 0))
    time.sleep(wait_ms / 1000.0)


# --- Patterns added for Livia on ha-london (2026-11) -------------------------
# Each one draws a single cycle and returns, like the ones above; the main loop
# repeats it. They work on any strip length.


def rgb_of(color):
    """Split a Color() value into (r, g, b)."""
    return (color >> 16) & 255, (color >> 8) & 255, color & 255


def scaled(rgb, k):
    """Color() of an (r, g, b) tuple scaled by k (0..1)."""
    k = max(0.0, min(1.0, k))
    return Color(int(rgb[0] * k), int(rgb[1] * k), int(rgb[2] * k))


FLAGS = {
    "bg": [(255, 255, 255), (0, 150, 110), (214, 38, 18)],
    "ro": [(0, 43, 127), (252, 209, 22), (206, 17, 38)],
    "uk": [(1, 33, 105), (255, 255, 255), (200, 16, 46), (255, 255, 255)],
}


def flag(strip, colours, band=10, wait_ms=40, frames=None):
    """Bands of a flag's colours scroll along the strip and ripple like cloth."""
    n = strip.numPixels()
    period = band * len(colours)
    for t in range(frames or period * 2):
        for i in range(n):
            pos = (i + t // 2) % period
            ripple = 0.6 + 0.4 * math.sin(2 * math.pi * (i / 25.0 - t / 30.0))
            strip.setPixelColor(i, scaled(colours[pos // band], ripple))
        strip.show()
        time.sleep(wait_ms / 1000.0)


def flag_bg(strip):
    flag(strip, FLAGS["bg"])


def flag_ro(strip):
    flag(strip, FLAGS["ro"])


def flag_uk(strip):
    flag(strip, FLAGS["uk"], band=8)


def comet(strip, color, tail=20, wait_ms=15):
    """A bright head runs the length of the strip with a fading tail."""
    n = strip.numPixels()
    rgb = rgb_of(color)
    for head in range(n + tail):
        for i in range(n):
            d = head - i
            strip.setPixelColor(i, scaled(rgb, (1 - d / tail) ** 2) if 0 <= d < tail else 0)
        strip.show()
        time.sleep(wait_ms / 1000.0)


def scanner(strip, color, eye=6, wait_ms=12):
    """A Larson scanner: an eye sweeps back and forth, leaving a short glow."""
    n = strip.numPixels()
    rgb = rgb_of(color)
    path = list(range(n)) + list(range(n - 2, 0, -1))
    for centre in path or [0]:
        for i in range(n):
            strip.setPixelColor(i, scaled(rgb, 1 - abs(i - centre) / eye) if abs(i - centre) < eye else 0)
        strip.show()
        time.sleep(wait_ms / 1000.0)


def breathe(strip, color, steps=100, wait_ms=25):
    """The whole strip fades in and out slowly."""
    rgb = rgb_of(color)
    for s in range(steps):
        k = 0.03 + 0.97 * (1 - math.cos(2 * math.pi * s / steps)) / 2
        c = scaled(rgb, k)
        for i in range(strip.numPixels()):
            strip.setPixelColor(i, c)
        strip.show()
        time.sleep(wait_ms / 1000.0)


def twinkle(strip, color, frames=200, wait_ms=30):
    """Stars in the colour appear at random and fade out."""
    n = strip.numPixels()
    rgb = rgb_of(color)
    level = [0.0] * n
    for _ in range(frames):
        for _ in range(max(1, n // 40)):
            level[random.randrange(n)] = 1.0
        for i in range(n):
            strip.setPixelColor(i, scaled(rgb, level[i]))
            level[i] *= 0.88
        strip.show()
        time.sleep(wait_ms / 1000.0)


def fire(strip, frames=300, cooling=55, sparking=120, wait_ms=20):
    """Flickering flames rising from the start of the strip (Fire2012)."""
    n = strip.numPixels()
    heat = [0] * n
    for _ in range(frames):
        for i in range(n):
            heat[i] = max(0, heat[i] - random.randint(0, cooling * 10 // n + 2))
        for i in range(n - 1, 1, -1):
            heat[i] = (heat[i - 1] + 2 * heat[i - 2]) // 3
        if random.randint(0, 255) < sparking:
            y = random.randint(0, min(6, n - 1))
            heat[y] = min(255, heat[y] + random.randint(160, 255))
        for i in range(n):
            h = heat[i] * 191 // 255
            ramp = (h & 63) << 2
            if h > 127:
                c = Color(255, 255, ramp)
            elif h > 63:
                c = Color(255, ramp, 0)
            else:
                c = Color(ramp, 0, 0)
            strip.setPixelColor(i, c)
        strip.show()
        time.sleep(wait_ms / 1000.0)


def police(strip, wait_ms=60):
    """Red and blue halves flash in turn, twice each."""
    n = strip.numPixels()
    half = max(1, n // 2)
    for colour, lit in ((Color(255, 0, 0), range(half)), (Color(0, 0, 255), range(half, n) if n > 1 else range(n))):
        for _ in range(2):
            for i in range(n):
                strip.setPixelColor(i, colour if i in lit else 0)
            strip.show()
            time.sleep(wait_ms / 1000.0)
            for i in range(n):
                strip.setPixelColor(i, 0)
            strip.show()
            time.sleep(wait_ms / 1000.0)


def ocean(strip, frames=300, wait_ms=30):
    """Slow blue and teal waves that roll along the strip."""
    n = strip.numPixels()
    for t in range(frames):
        for i in range(n):
            a = math.sin(i / 9.0 + t / 14.0)
            b = math.sin(i / 23.0 - t / 21.0)
            k = 0.35 + 0.65 * (a + b + 2) / 4
            strip.setPixelColor(i, scaled((0, int(90 + 80 * (b + 1) / 2), 255), k))
        strip.show()
        time.sleep(wait_ms / 1000.0)


def candy_cane(strip, band=6, wait_ms=60):
    """Red and white stripes march along the strip."""
    n = strip.numPixels()
    for t in range(band * 2):
        for i in range(n):
            red = ((i + t) // band) % 2 == 0
            strip.setPixelColor(i, Color(255, 0, 0) if red else Color(255, 255, 255))
        strip.show()
        time.sleep(wait_ms / 1000.0)


def ruler(strip):
    """Count the strip: LED 1 blue, every 10th red, every 50th green, the rest dim."""
    for i in range(strip.numPixels()):
        k = i + 1
        if k == 1:
            c = Color(0, 0, 255)
        elif k % 50 == 0:
            c = Color(0, 255, 0)
        elif k % 10 == 0:
            c = Color(255, 0, 0)
        else:
            c = Color(12, 12, 12)
        strip.setPixelColor(i, c)
    strip.show()
    time.sleep(1)


class Pattern(Enum):
    color_wipe = "color_wipe"
    theater_chase = "theater_chase"
    rainbow = "rainbow"
    rainbow_cycle = "rainbow_cycle"
    theater_chase_rainbow = "theater_chase_rainbow"
    jik_tak = "jik_tak"
    falling_stars = "falling_stars"
    flag_bg = "flag_bg"
    flag_ro = "flag_ro"
    flag_uk = "flag_uk"
    comet = "comet"
    scanner = "scanner"
    breathe = "breathe"
    twinkle = "twinkle"
    fire = "fire"
    police = "police"
    ocean = "ocean"
    candy_cane = "candy_cane"
    ruler = "ruler"


def run_pattern(pattern_name: Pattern, *args) -> None:
    args = [a for a in args if a is not None]
    if pattern_name is Pattern.color_wipe:
        return colorWipe(*args)
    if pattern_name is Pattern.theater_chase:
        return theaterChase(*args)
    if pattern_name is Pattern.rainbow:
        return rainbow(*args)
    if pattern_name is Pattern.rainbow_cycle:
        return rainbowCycle(*args)
    if pattern_name is Pattern.theater_chase_rainbow:
        return theaterChaseRainbow(*args)
    if pattern_name is Pattern.jik_tak:
        return jik_tak(*args)
    if pattern_name is Pattern.falling_stars:
        return falling_stars(*args)
    added = {
        Pattern.flag_bg: flag_bg, Pattern.flag_ro: flag_ro, Pattern.flag_uk: flag_uk,
        Pattern.comet: comet, Pattern.scanner: scanner, Pattern.breathe: breathe,
        Pattern.twinkle: twinkle, Pattern.fire: fire, Pattern.police: police,
        Pattern.ocean: ocean, Pattern.candy_cane: candy_cane, Pattern.ruler: ruler,
    }
    if pattern_name in added:
        return added[pattern_name](*args)


def get_rgb_values(arg: str):
    """arg in the format 'r=10,g=20,b=20', order does not matter"""
    split = arg.split(',')
    for s in split:
        if s.startswith('r='):
            r = int(s.split('=')[1])
        elif s.startswith('g='):
            g = int(s.split('=')[1])
        elif s.startswith('b='):
            b = int(s.split('=')[1])
    return r, g, b


# Main program logic follows:
if __name__ == '__main__':
    # Process arguments
    parser = argparse.ArgumentParser()
    parser.add_argument(
        '-c', '--clear', action='store_true', help='clear the display on exit'
    )
    parser.add_argument(
        '-s',
        '--strategies',
        default="rainbow",
        help='comma separated list of strategies to run'
    )
    parser.add_argument(
        '--colors',
        default="",
        help=
        'format: "r=10,g=20,b=30;r=23,g=30,b=30". Need to be of same length as strategies. Empty r,g,b combos are ignored'
    )
    parser.add_argument(
        '-n',
        '--count',
        type=int,
        default=LED_COUNT,
        help='number of LEDs on the strip'
    )
    parser.add_argument(
        '-b',
        '--brightness',
        type=int,
        default=LED_BRIGHTNESS,
        help='0 for darkest, 255 for brightest'
    )
    args = parser.parse_args()

    if len(args.strategies.split(',')) != len(args.colors.split(';')):
        raise ValueError(
            f'Strategies must have an equivalent number of colors. Got "{args.strategies}" and "{args.colors}"'
        )

    # Create NeoPixel object with appropriate configuration.
    strip = Adafruit_NeoPixel(
        args.count, LED_PIN, LED_FREQ_HZ, LED_DMA, LED_INVERT, args.brightness,
        LED_CHANNEL
    )
    # Intialize the library (must be called once before other functions).
    strip.begin()

    print('Press Ctrl-C to quit.')
    if not args.clear:
        print('Use "-c" argument to clear LEDs on exit')

    split_colors = args.colors.split(';')
    # import ipdb
    # ipdb.set_trace()
    try:
        while True:
            for i, strategy in enumerate(args.strategies.split(',')):
                pattern_args = None
                if split_colors[i]:
                    r, g, b = get_rgb_values(split_colors[i])
                    pattern_args = Color(r, g, b)

                run_pattern(
                    Pattern(strategy),
                    strip,
                    pattern_args,
                )
            # golden
            # colorWipe(strip, Color(176, 143, 18))
            # print('Color wipe animations.')
            # colorWipe(strip, Color(255, 0, 0))  # Red wipe
            # colorWipe(strip, Color(0, 0, 255))  # Blue wipe
            # colorWipe(strip, Color(0, 255, 0))  # Green wipe
            # print('Theater chase animations.')
            # theaterChase(strip, Color(127, 127, 127))  # White theater chase
            # theaterChase(strip, Color(127, 0, 0))  # Red theater chase
            # theaterChase(strip, Color(0, 127, 0))  # Blue theater chase
            # print('Rainbow animations.')
            # rainbow(strip)
            # rainbowCycle(strip)
            # theaterChaseRainbow(strip)
            # print('Jik-Tak animations.')
            # jik_tak(strip)

    except KeyboardInterrupt:
        if args.clear:
            colorWipe(strip, Color(0, 0, 0), 10)
    else:
        colorWipe(strip, Color(0, 0, 0), 10)
