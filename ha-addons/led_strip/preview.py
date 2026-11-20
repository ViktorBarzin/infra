#!/usr/bin/env python3
"""Draw each pattern in patterns.py as a looping animated WebP, for the dashboard.

    python3 preview.py OUTDIR [--count 150] [--seconds 5]

Runs on the devvm (needs Pillow), not on the Pi. deploy.sh copies OUTDIR to
/homeassistant/www/livia/, which Home Assistant serves as /local/livia/.
The strip is drawn as one row of glowing LEDs, the same order as the real one:
LED 1 on the left.
"""

import argparse
import itertools
import random
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

import patterns

WIDTH, HEIGHT, MARGIN, STRIP_Y = 480, 108, 8, 82
BACKGROUND = (14, 15, 20)
FPS = 20
COLOUR = (255, 140, 20)  # the colour patterns are shown in amber


def frames_at_fps(pattern: patterns.Pattern, n: int, seconds: float) -> list[patterns.Pixels]:
    """Sample the pattern every 1/FPS seconds, as the strip would show it."""
    total = int(seconds * FPS)

    def forever() -> patterns.Frames:  # as play.py does: start again when it ends
        for seed in itertools.count(7):
            yield from pattern.frames(n, COLOUR, random.Random(seed))

    out: list[patterns.Pixels] = []
    shown_until = 0.0
    for pixels, delay in forever():
        if delay is None:  # still: one image, or the animation ending on it
            return out + [pixels] * (total - len(out)) if out else [pixels]
        shown_until += delay
        while len(out) < total and len(out) / FPS < shown_until:
            out.append(pixels)
        if len(out) >= total:
            return out
    return out


def caption(pattern: patterns.Pattern) -> Image.Image:
    """The background with the pattern's name and what it looks like."""
    image = Image.new("RGB", (WIDTH, HEIGHT), BACKGROUND)
    d = ImageDraw.Draw(image)
    d.text((MARGIN + 4, 8), pattern.title, fill=(240, 240, 240), font=ImageFont.load_default(24))
    d.text((MARGIN + 4, 38), pattern.about, fill=(150, 155, 165), font=ImageFont.load_default(15))
    return image


def render(base: Image.Image, pixels: patterns.Pixels) -> Image.Image:
    """One frame: each LED a short bar of light with a soft halo, like the diffused strip."""
    n = len(pixels)
    pitch = (WIDTH - 2 * MARGIN) / n
    top, bottom = STRIP_Y - 8, STRIP_Y + 8
    leds = Image.new("RGB", (WIDTH, HEIGHT), (0, 0, 0))
    d = ImageDraw.Draw(leds)
    for i, rgb in enumerate(pixels):
        x = MARGIN + pitch * i
        d.rectangle((x + pitch * 0.12, top, x + pitch * 0.88, bottom), fill=rgb)
    halo = leds.filter(ImageFilter.GaussianBlur(8)).point(lambda v: min(255, v * 2))
    return ImageChops.add(ImageChops.add(base, halo), leds)


def write(pattern: patterns.Pattern, out: Path, n: int, seconds: float) -> Path:
    base = caption(pattern)
    images = [render(base, p) for p in frames_at_fps(pattern, n, seconds)]
    path = out / f"{pattern.name}.webp"
    images[0].save(path, save_all=True, append_images=images[1:], duration=1000 // FPS,
                   loop=0, quality=70, method=4)
    return path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("out", type=Path)
    parser.add_argument("--count", type=int, default=150)
    parser.add_argument("--seconds", type=float, default=5.0)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    for pattern in patterns.PATTERNS.values():
        path = write(pattern, args.out, args.count, args.seconds)
        print(f"{path} {path.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
