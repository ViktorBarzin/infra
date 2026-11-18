#!/usr/bin/env python3
# rpi_ws281x library strandtest example
# Author: Tony DiCola (tony@tonydicola.com)
#
# Direct port of the Arduino NeoPixel library strandtest example.  Showcases
# various animations on a strip of NeoPixels.

import argparse
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


class Pattern(Enum):
    color_wipe = "color_wipe"
    theater_chase = "theater_chase"
    rainbow = "rainbow"
    rainbow_cycle = "rainbow_cycle"
    theater_chase_rainbow = "theater_chase_rainbow"
    jik_tak = "jik_tak"
    falling_stars = "falling_stars"


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
        LED_COUNT, LED_PIN, LED_FREQ_HZ, LED_DMA, LED_INVERT, args.brightness,
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
