"""The Livia strip's patterns, as plain Python with no hardware.

A pattern is a generator. It takes the strip length, the chosen colour and a
random generator, and yields frames: (pixels, delay). `pixels` holds one
(r, g, b) per LED and `delay` is the time in seconds until the next frame.
A delay of None means the frame is still: the runner keeps it on the strip
and the pattern is finished. A generator that ends otherwise starts again.

play.py sends the frames to the strip, preview.py draws them into the
preview images on the dashboard, and server.py takes the list of names from
PATTERNS below. To add a pattern, write the generator and add one entry to
PATTERNS; the tests, the previews and the dashboard pick it up.
"""

import math
import random
import time
from collections.abc import Callable, Iterator
from dataclasses import dataclass

RGB = tuple[int, int, int]
Pixels = list[RGB]
Frame = tuple[Pixels, float | None]
Frames = Iterator[Frame]

BLACK: RGB = (0, 0, 0)
WHITE: RGB = (255, 255, 255)


# --- helpers -----------------------------------------------------------------


def scale(rgb: RGB, k: float) -> RGB:
    """The colour at brightness k, from 0 (off) to 1 (as given)."""
    k = max(0.0, min(1.0, k))
    return int(rgb[0] * k), int(rgb[1] * k), int(rgb[2] * k)


def mix(a: RGB, b: RGB, k: float) -> RGB:
    """The colour k of the way from a to b."""
    k = max(0.0, min(1.0, k))
    return (int(a[0] + (b[0] - a[0]) * k), int(a[1] + (b[1] - a[1]) * k),
            int(a[2] + (b[2] - a[2]) * k))


def add(a: RGB, b: RGB) -> RGB:
    """Two lights on one LED."""
    return min(255, a[0] + b[0]), min(255, a[1] + b[1]), min(255, a[2] + b[2])


def wheel(pos: int) -> RGB:
    """The rainbow, as 256 steps from red to green to blue and back to red."""
    pos &= 255
    if pos < 85:
        return pos * 3, 255 - pos * 3, 0
    if pos < 170:
        pos -= 85
        return 255 - pos * 3, 0, pos * 3
    pos -= 170
    return 0, pos * 3, 255 - pos * 3


def hue(h: float) -> RGB:
    """A fully saturated colour, h from 0 to 1 around the colour circle."""
    return wheel(int(h * 256) % 256)


def solid(n: int, rgb: RGB) -> Pixels:
    return [rgb] * n


def glow(pixels: Pixels, pos: float, rgb: RGB, radius: float) -> None:
    """Add a soft spot of light centred at pos (in LEDs) to pixels."""
    n = len(pixels)
    lo, hi = max(0, int(pos - radius)), min(n - 1, int(pos + radius) + 1)
    for i in range(lo, hi + 1):
        d = abs(i - pos)
        if d < radius:
            pixels[i] = add(pixels[i], scale(rgb, (1 - d / radius) ** 1.5))


# --- the original strandtest patterns ----------------------------------------


def rainbow(n: int, colour: RGB, rng: random.Random) -> Frames:
    for j in range(256):
        yield [wheel(i + j) for i in range(n)], 0.02


def rainbow_cycle(n: int, colour: RGB, rng: random.Random) -> Frames:
    for j in range(256):
        yield [wheel(i * 256 // n + j) for i in range(n)], 0.02


def theater_chase_rainbow(n: int, colour: RGB, rng: random.Random) -> Frames:
    for j in range(256):
        for q in range(3):
            yield [wheel(i - q + j) if i % 3 == q else BLACK for i in range(n)], 0.05


def jik_tak(n: int, colour: RGB, rng: random.Random) -> Frames:
    def bumbum(pos: int) -> RGB:
        pos &= 255
        if pos <= 170:
            return (255 - pos) // 2, 0, pos // 2
        pos -= 170
        return 0, pos * 3 // 2, (255 - pos * 3) // 2

    for j in range(256):
        pixels = solid(n, BLACK)
        for i in range((n + 1) // 2):
            pixels[i] = pixels[n - 1 - i] = bumbum(i + j)
        yield pixels, 0.005


def color_wipe(n: int, colour: RGB, rng: random.Random) -> Frames:
    pixels = solid(n, BLACK)
    for i in range(n):
        pixels[i] = colour
        yield list(pixels), 0.02
    yield pixels, None


def theater_chase(n: int, colour: RGB, rng: random.Random) -> Frames:
    for q in range(3):
        yield [colour if i % 3 == q else BLACK for i in range(n)], 0.05


# --- calm --------------------------------------------------------------------


def aurora(n: int, colour: RGB, rng: random.Random) -> Frames:
    """Green, teal and violet curtains that drift and fold slowly."""
    green, teal, violet = (20, 255, 90), (0, 170, 200), (150, 40, 255)
    t = 0
    while True:
        pixels = []
        for i in range(n):
            x = i / 18.0
            curtain = (math.sin(x * 1.3 + t / 37.0) + math.sin(x * 0.7 - t / 23.0)
                       + 0.6 * math.sin(x * 2.9 + t / 11.0))
            k = max(0.0, (curtain + 0.9) / 3.5) ** 1.4
            shade = (math.sin(i / 40.0 - t / 61.0) + 1) / 2
            base = mix(green, teal, shade * 1.4) if shade < 0.7 else mix(teal, violet, (shade - 0.7) / 0.3)
            pixels.append(scale(base, 0.04 + 0.96 * k))
        yield pixels, 0.03
        t += 1


def ocean(n: int, colour: RGB, rng: random.Random) -> Frames:
    """Slow blue and teal waves that roll along the strip."""
    for t in range(1000):
        pixels = []
        for i in range(n):
            a = math.sin(i / 9.0 + t / 14.0)
            b = math.sin(i / 23.0 - t / 21.0)
            k = 0.35 + 0.65 * (a + b + 2) / 4
            pixels.append(scale((0, int(90 + 80 * (b + 1) / 2), 255), k))
        yield pixels, 0.03


def lava_lamp(n: int, colour: RGB, rng: random.Random) -> Frames:
    """Warm blobs that drift up and down, merge and split."""
    dark, red, orange, yellow = (25, 0, 8), (200, 10, 20), (255, 80, 0), (255, 190, 40)
    blobs = [(rng.uniform(0, 2 * math.pi), rng.uniform(0.6, 1.4), rng.uniform(0.08, 0.14))
             for _ in range(4)]
    t = 0
    while True:
        centres = [(0.5 + 0.45 * math.sin(phase + t * speed / 150.0)) * (n - 1)
                   for phase, speed, _ in blobs]
        pixels = []
        for i in range(n):
            field = 0.0
            for c, (_, _, size) in zip(centres, blobs):
                r = max(1.0, size * n)
                field += r * r / ((i - c) ** 2 + r * r)
            if field < 0.5:
                pixels.append(mix(dark, red, field / 0.5))
            elif field < 0.9:
                pixels.append(mix(red, orange, (field - 0.5) / 0.4))
            else:
                pixels.append(mix(orange, yellow, (field - 0.9) / 0.6))
        yield pixels, 0.04
        t += 1


def plasma(n: int, colour: RGB, rng: random.Random) -> Frames:
    """Smooth colours that flow and mix, like an old screensaver."""
    t = 0
    while True:
        pixels = []
        for i in range(n):
            v = (math.sin(i / 8.0 + t / 10.0) + math.sin(i / 13.0 - t / 7.0)
                 + math.sin((i + t) / 17.0) + math.sin(math.hypot(i - n / 2, t / 3.0) / 6.0))
            pixels.append(hue((v + 4) / 8 + t / 900.0))
        yield pixels, 0.03
        t += 1


def candle(n: int, colour: RGB, rng: random.Random) -> Frames:
    """A warm, gentle flicker, like a row of candles. Calmer than fire."""
    warm, deep = (255, 120, 20), (180, 50, 0)
    level = [0.8] * n
    whole = 0.85
    while True:
        whole += rng.uniform(-0.04, 0.04) + (0.85 - whole) * 0.1
        if rng.random() < 0.02:
            whole -= rng.uniform(0.1, 0.25)  # a draught
        pixels = []
        for i in range(n):
            level[i] += rng.uniform(-0.08, 0.08) + (whole - level[i]) * 0.2
            level[i] = max(0.35, min(1.0, level[i]))
            pixels.append(scale(mix(deep, warm, level[i]), level[i]))
        yield pixels, 0.05


# --- lively ------------------------------------------------------------------


def fire(n: int, colour: RGB, rng: random.Random) -> Frames:
    """Flickering flames rising from the start of the strip (Fire2012)."""
    cooling, sparking = 55, 120
    heat = [0] * n
    while True:
        for i in range(n):
            heat[i] = max(0, heat[i] - rng.randint(0, cooling * 10 // n + 2))
        for i in range(n - 1, 1, -1):
            heat[i] = (heat[i - 1] + 2 * heat[i - 2]) // 3
        if rng.randint(0, 255) < sparking:
            y = rng.randint(0, min(6, n - 1))
            heat[y] = min(255, heat[y] + rng.randint(160, 255))
        pixels = []
        for h in heat:
            h = h * 191 // 255
            ramp = (h & 63) << 2
            if h > 127:
                pixels.append((255, 255, ramp))
            elif h > 63:
                pixels.append((255, ramp, 0))
            else:
                pixels.append((ramp, 0, 0))
        yield pixels, 0.02


def fireworks(n: int, colour: RGB, rng: random.Random) -> Frames:
    """Rockets rise from the start of the strip and burst into colour."""
    palette = [(255, 40, 40), (40, 255, 80), (60, 120, 255), (255, 200, 40),
               (255, 60, 220), (40, 230, 255), (255, 255, 255)]
    rockets: list[list[float]] = []  # [position, speed, burst height]
    sparks: list[tuple[float, float, RGB, int, int]] = []  # pos, speed, colour, age, life
    wait = 0
    while True:
        if wait <= 0 and len(rockets) < 2:
            rockets.append([0.0, rng.uniform(1.6, 2.4) * n / 150 + 0.3,
                            rng.uniform(0.45, 0.85) * (n - 1)])
            wait = rng.randint(25, 70)
        wait -= 1
        pixels = solid(n, BLACK)
        for r in list(rockets):
            r[0] += r[1]
            glow(pixels, r[0], (255, 170, 60), 2.0)
            if r[0] >= r[2]:
                rockets.remove(r)
                c = rng.choice(palette)
                for _ in range(rng.randint(6, 10)):
                    sparks.append((r[0], rng.uniform(-1.0, 1.0) * n / 150 + rng.uniform(-0.2, 0.2),
                                   c, 0, rng.randint(25, 45)))
                glow(pixels, r[0], WHITE, 5.0)
        moved = []
        for pos, speed, c, age, life in sparks:
            if age < life:
                k = 1 - age / life
                glow(pixels, pos, scale(c, k * k), 2.0)
                moved.append((pos + speed * k, speed * 0.97 - 0.01, c, age + 1, life))
        sparks = moved
        yield pixels, 0.02


def bouncing_balls(n: int, colour: RGB, rng: random.Random) -> Frames:
    """Coloured balls dropped on the start of the strip, bouncing with gravity."""
    colours = [(255, 30, 30), (30, 255, 60), (40, 90, 255), (255, 200, 0)]
    gravity, dt = -9.8, 0.02
    start_speed = math.sqrt(-2 * gravity)  # reaches the far end, height 1
    # height (0 = start of the strip, 1 = far end), speed, bounce
    balls = [[1.0 - 0.18 * b, 0.0, 0.92 - 0.04 * b] for b in range(len(colours))]
    while True:
        pixels = solid(n, BLACK)
        for ball, c in zip(balls, colours):
            ball[1] += gravity * dt
            ball[0] += ball[1] * dt
            if ball[0] <= 0:
                ball[0] = 0.0
                ball[1] = -ball[1] * ball[2]
                if ball[1] < 0.6:
                    ball[1] = start_speed * rng.uniform(0.85, 1.0)  # a new throw
            glow(pixels, ball[0] * (n - 1), c, 2.0)
        yield pixels, dt


def police(n: int, colour: RGB, rng: random.Random) -> Frames:
    """Red and blue halves flash in turn, twice each."""
    half = max(1, n // 2)
    red = [(255, 0, 0) if i < half else BLACK for i in range(n)]
    blue = [(0, 0, 255) if i >= half or n == 1 else BLACK for i in range(n)]
    for lit in (red, blue):
        for _ in range(2):
            yield lit, 0.06
            yield solid(n, BLACK), 0.06


def candy_cane(n: int, colour: RGB, rng: random.Random) -> Frames:
    """Red and white stripes march along the strip."""
    band = 6
    for t in range(band * 2):
        yield [(255, 0, 0) if ((i + t) // band) % 2 == 0 else WHITE for i in range(n)], 0.06


# --- shapes ------------------------------------------------------------------

now: Callable[[], float] = time.time  # the clock reads this; tests replace it

PENDULUMS = 10
SAND: RGB = (255, 170, 40)
MESSAGE = "HELLO"
MORSE = {
    "A": ".-", "B": "-...", "C": "-.-.", "D": "-..", "E": ".", "F": "..-.", "G": "--.",
    "H": "....", "I": "..", "J": ".---", "K": "-.-", "L": ".-..", "M": "--", "N": "-.",
    "O": "---", "P": ".--.", "Q": "--.-", "R": ".-.", "S": "...", "T": "-", "U": "..-",
    "V": "...-", "W": ".--", "X": "-..-", "Y": "-.--", "Z": "--..",
}


def heartbeat(n: int, colour: RGB, rng: random.Random) -> Frames:
    """Two pulses, lub-dub, run out from the middle once a second."""
    red, dark = (255, 0, 30), (10, 0, 2)
    centre, reach = (n - 1) / 2, max(1.0, n / 2)
    beats = ((0.0, 1.0), (0.22, 0.7))  # time in the second, strength
    dt = 0.02
    for step in range(50):
        t = step * dt
        pixels = []
        for i in range(n):
            d = abs(i - centre)
            k = 0.0
            for start, strength in beats:
                if t >= start:
                    r = (t - start) / 0.6 * reach
                    k += strength * max(0.0, 1 - r / reach) * math.exp(-((d - r) / 3.0) ** 2)
            pixels.append(add(dark, scale(red, k)))
        yield pixels, dt


def newtons_cradle(n: int, colour: RGB, rng: random.Random) -> Frames:
    """Five steel balls in the middle; the end ones swing out and knock in turn."""
    steel = (200, 205, 220)
    width = max(1, n // 50)
    middle = n // 2
    swing = n * 0.3
    steps, dt = 80, 0.02
    for step in range(steps):
        x = math.sin(2 * math.pi * step / steps)
        pixels = solid(n, BLACK)
        for ball in range(5):
            pos = middle + (ball - 2) * width
            if ball == 0 and x < 0:
                pos += swing * x
            if ball == 4 and x > 0:
                pos += swing * x
            knock = 1.0 if abs(x) < 0.08 and 0 < ball < 4 else 0.75
            glow(pixels, pos, scale(steel, knock), width / 2 + 0.8)
        yield pixels, dt


def pendulum_wave(n: int, colour: RGB, rng: random.Random) -> Frames:
    """Ten pendulums of different lengths drift out of step and back in."""
    lanes = min(PENDULUMS, n)
    lane = n // lanes
    steps, dt = 1000, 0.03  # 30 seconds until they line up again
    for step in range(steps):
        pixels = solid(n, BLACK)
        for k in range(lanes):
            swings = 15 + k  # in 30 seconds
            pos = (lane - 1) * (1 + math.cos(2 * math.pi * swings * step / steps)) / 2
            dots = solid(lane, BLACK)
            glow(dots, pos, hue(k / lanes), 1.6)
            pixels[k * lane:(k + 1) * lane] = dots
        yield pixels, dt


def dna(n: int, colour: RGB, rng: random.Random) -> Frames:
    """Two strands, blue and pink, twist around each other with rungs between."""
    blue, pink, rung = (0, 140, 255), (255, 0, 120), (50, 50, 50)
    t = 0
    while True:
        pixels = []
        for i in range(n):
            twist = math.sin(2 * math.pi * i / 30.0 - t / 8.0)
            a, b = (1 + twist) / 2, (1 - twist) / 2
            rgb = add(scale(blue, a * a), scale(pink, b * b))
            if i % 5 == 0:
                rgb = add(rgb, scale(rung, 1 - abs(twist)))
            pixels.append(rgb)
        yield pixels, 0.04
        t += 1


def hourglass(n: int, colour: RGB, rng: random.Random) -> Frames:
    """Sand trickles from the top half into the bottom half, then the glass turns."""
    glass = (10, 6, 2)
    half = n // 2
    if half == 0:
        yield [SAND], 0.5
        return
    top, pile = half, 0  # grains left on top, grains in the bottom pile
    falling: list[float] = []
    step = 0
    while pile < half:
        if top and step % 3 == 2:
            top -= 1
            falling.append(float(half - 1))
        falling = [g - 2 for g in falling]
        pile += sum(1 for g in falling if g < pile + 1)
        falling = [g for g in falling if g >= pile]
        pixels = solid(n, glass)
        for i in range(pile):
            pixels[i] = SAND
        for i in range(half, half + top):
            pixels[i] = SAND
        for g in falling:
            pixels[int(g)] = SAND
        yield pixels, 0.04
        step += 1
    for _ in range(25):
        yield pixels, 0.04


def clock(n: int, colour: RGB, rng: random.Random) -> Frames:
    """The time along the strip: orange hours, blue minutes, a white second dot."""
    last = n - 1
    marks = solid(n, BLACK)
    for h in range(12):
        marks[round(h / 12 * last)] = (20, 20, 20)
    while True:
        t = now()
        tm = time.localtime(t)
        seconds = tm.tm_sec + t % 1
        pixels = list(marks)
        glow(pixels, (tm.tm_hour % 12 + tm.tm_min / 60) / 12 * last, (255, 90, 0), 4.0)
        glow(pixels, (tm.tm_min + seconds / 60) / 60 * last, (0, 90, 255), 2.5)
        glow(pixels, seconds / 60 * last, (150, 150, 150), 1.2)
        yield pixels, 0.1


def rally(n: int, colour: RGB, rng: random.Random) -> Frames:
    """A ball goes back and forth between two paddles, faster each hit, until one misses."""
    paddle = max(1, min(3, n // 10))
    blue, red, ball = (0, 80, 255), (255, 30, 0), WHITE
    lo, hi = float(paddle), float(n - 1 - paddle)
    if hi <= lo:
        yield solid(n, ball), 0.5
        return
    x, speed = lo, max(0.4, n / 150 * 1.2)
    flash = [0.0, 0.0]  # left, right
    hits = rng.randint(6, 12)
    while True:
        x += speed
        if (speed > 0 and x >= hi) or (speed < 0 and x <= lo):
            side = 1 if speed > 0 else 0
            if hits == 0:
                break
            hits -= 1
            x = hi if side else lo
            speed = -speed * 1.08
            flash[side] = 1.0
        pixels = solid(n, BLACK)
        for i in range(paddle):
            pixels[i] = mix(scale(blue, 0.5), WHITE, flash[0] * 0.6)
            pixels[n - 1 - i] = mix(scale(red, 0.5), WHITE, flash[1] * 0.6)
        glow(pixels, x, ball, 1.8)
        flash = [f * 0.8 for f in flash]
        yield pixels, 0.02
    loser = 1 if speed > 0 else 0  # the ball got past this paddle
    for k in (1.0, 0.0, 1.0, 0.0, 1.0, 0.0):
        pixels = solid(n, BLACK)
        half = range(n // 2, n) if loser else range(0, n // 2 or 1)
        for i in half:
            pixels[i] = scale(red if loser else blue, 0.6 * k)
        yield pixels, 0.12


def morse(text: str) -> str:
    """Text as Morse code: 1 is on and 0 is off for one unit of time."""
    words = []
    for word in text.upper().split():
        letters = ["0".join("1" if s == "." else "111" for s in MORSE[c]) for c in word if c in MORSE]
        words.append("000".join(letters) + "0000000")
    return "".join(words)


def morse_ticker(n: int, colour: RGB, rng: random.Random) -> Frames:
    """A message in Morse code scrolls along the strip, three LEDs per unit."""
    tape = morse(MESSAGE)
    width = 3
    for t in range(len(tape) * width):
        yield [colour if tape[((i + t) // width) % len(tape)] == "1" else BLACK for i in range(n)], 0.04


# --- flags -------------------------------------------------------------------

FLAGS: dict[str, list[RGB]] = {
    "bg": [(255, 255, 255), (0, 150, 110), (214, 38, 18)],
    "ro": [(0, 43, 127), (252, 209, 22), (206, 17, 38)],
    "uk": [(1, 33, 105), (255, 255, 255), (200, 16, 46), (255, 255, 255)],
}


def flag(colours: list[RGB], band: int = 10) -> Callable[[int, RGB, random.Random], Frames]:
    """Bands of a flag's colours scroll along the strip and ripple like cloth."""
    def frames(n: int, colour: RGB, rng: random.Random) -> Frames:
        period = band * len(colours)
        for t in range(period * 2):
            pixels = []
            for i in range(n):
                pos = (i + t // 2) % period
                ripple = 0.6 + 0.4 * math.sin(2 * math.pi * (i / 25.0 - t / 30.0))
                pixels.append(scale(colours[pos // band], ripple))
            yield pixels, 0.04
    return frames


# --- weather -----------------------------------------------------------------


def weather_sun(n: int, colour: RGB, rng: random.Random) -> Frames:
    """Sunny: a warm golden glow with slow bright shimmer."""
    gold, white = (255, 150, 20), (255, 230, 150)
    t = 0
    while True:
        pixels = []
        for i in range(n):
            shimmer = (math.sin(i / 7.0 - t / 9.0) + math.sin(i / 17.0 + t / 23.0) + 2) / 4
            pixels.append(scale(mix(gold, white, shimmer ** 3), 0.55 + 0.45 * shimmer))
        yield pixels, 0.04
        t += 1


def weather_cloud(n: int, colour: RGB, rng: random.Random) -> Frames:
    """Cloudy: soft grey and pale blue patches that drift past."""
    sky, cloud = (25, 45, 90), (170, 175, 190)
    t = 0
    while True:
        pixels = []
        for i in range(n):
            puff = (math.sin(i / 11.0 - t / 30.0) + 0.7 * math.sin(i / 5.0 - t / 19.0)
                    + 0.5 * math.sin(i / 23.0 + t / 47.0))
            pixels.append(mix(sky, cloud, max(0.0, puff / 2.2 + 0.35)))
        yield pixels, 0.04
        t += 1


def weather_rain(n: int, colour: RGB, rng: random.Random) -> Frames:
    """Rain: blue drops fall from the far end of the strip to the start."""
    drops: list[float] = []
    while True:
        if rng.random() < 0.25 * max(1, n / 150):
            drops.append(rng.uniform(n * 0.6, n - 1))
        pixels = solid(n, (0, 8, 30))
        for d in drops:
            for k, tail in enumerate((1.0, 0.45, 0.2, 0.08)):
                i = int(d) + k
                if 0 <= i < n:
                    pixels[i] = add(pixels[i], scale((120, 170, 255), tail))
        drops = [d - 1.3 for d in drops if d - 1.3 >= 0]
        yield pixels, 0.03


def weather_snow(n: int, colour: RGB, rng: random.Random) -> Frames:
    """Snow: white flakes drift slowly down the strip and sparkle."""
    flakes = [(rng.uniform(0, n - 1), rng.uniform(0, 2 * math.pi))  # position, phase
              for _ in range(n // 6)]
    t = 0
    while True:
        if rng.random() < 0.07 * max(1, n / 150):
            flakes.append((float(n - 1), rng.uniform(0, 2 * math.pi)))
        pixels = solid(n, (4, 8, 20))
        for pos, phase in flakes:
            sparkle = 0.55 + 0.45 * math.sin(phase + t / 4.0)
            glow(pixels, pos, scale((220, 230, 255), sparkle), 1.6)
        flakes = [(p - 0.35 - 0.15 * math.sin(ph + t / 9.0), ph) for p, ph in flakes if p > 0]
        yield pixels, 0.04
        t += 1


def weather_storm(n: int, colour: RGB, rng: random.Random) -> Frames:
    """Storm: dark, heavy rain and sudden lightning over part of the strip."""
    rain = weather_rain(n, colour, rng)
    flash: list[RGB] = []
    countdown = rng.randint(40, 120)
    while True:
        pixels, delay = next(rain)
        pixels = [scale(p, 0.6) for p in pixels]
        countdown -= 1
        if countdown <= 0 and not flash:
            lo = rng.randint(0, max(0, n - 1))
            width = max(1, int(n * rng.uniform(0.2, 0.45)))
            bolt = [(lo <= i < lo + width) for i in range(n)]
            flash = [(230, 230, 255) if b else BLACK for b in bolt]
            pattern = [1.0, 0.0, 0.7, 0.3, 0.0]  # a double strike that fades
            for k in pattern:
                yield [add(p, scale(f, k)) for p, f in zip(pixels, flash)], 0.05
            flash = []
            countdown = rng.randint(60, 200)
            continue
        yield pixels, delay


# --- in the chosen colour ----------------------------------------------------


def comet(n: int, colour: RGB, rng: random.Random) -> Frames:
    """A bright head runs the length of the strip with a fading tail."""
    tail = 20
    for head in range(n + tail):
        pixels = []
        for i in range(n):
            d = head - i
            pixels.append(scale(colour, (1 - d / tail) ** 2) if 0 <= d < tail else BLACK)
        yield pixels, 0.015


def scanner(n: int, colour: RGB, rng: random.Random) -> Frames:
    """An eye sweeps back and forth and leaves a short glow."""
    eye = 6
    path = list(range(n)) + list(range(n - 2, 0, -1))
    for centre in path:
        yield [scale(colour, 1 - abs(i - centre) / eye) if abs(i - centre) < eye else BLACK
               for i in range(n)], 0.012


def breathe(n: int, colour: RGB, rng: random.Random) -> Frames:
    """The whole strip fades in and out slowly."""
    steps = 100
    for s in range(steps):
        yield solid(n, scale(colour, 0.03 + 0.97 * (1 - math.cos(2 * math.pi * s / steps)) / 2)), 0.025


def twinkle(n: int, colour: RGB, rng: random.Random) -> Frames:
    """Stars in the colour appear at random and fade out."""
    level = [0.0] * n
    while True:
        for _ in range(max(1, n // 40)):
            level[rng.randrange(n)] = 1.0
        yield [scale(colour, k) for k in level], 0.03
        level = [k * 0.88 for k in level]


# --- setup -------------------------------------------------------------------


def ruler(n: int, colour: RGB, rng: random.Random) -> Frames:
    """Count the strip: LED 1 blue, every 10th red, every 50th green, the rest dim."""
    pixels = []
    for i in range(n):
        k = i + 1
        if k == 1:
            pixels.append((0, 0, 255))
        elif k % 50 == 0:
            pixels.append((0, 255, 0))
        elif k % 10 == 0:
            pixels.append((255, 0, 0))
        else:
            pixels.append((12, 12, 12))
    yield pixels, None


# --- the list ----------------------------------------------------------------


@dataclass(frozen=True)
class Pattern:
    name: str  # the light effect in Home Assistant
    title: str  # the label on the dashboard
    group: str
    about: str
    frames: Callable[[int, RGB, random.Random], Frames]
    colour: bool = False  # uses the colour picked in Home Assistant


PATTERNS: dict[str, Pattern] = {p.name: p for p in [
    Pattern("aurora", "Aurora", "Calm", "Green and violet curtains drifting slowly", aurora),
    Pattern("ocean", "Ocean", "Calm", "Blue and teal waves rolling along", ocean),
    Pattern("lava_lamp", "Lava lamp", "Calm", "Warm blobs drifting, merging and splitting", lava_lamp),
    Pattern("candle", "Candle", "Calm", "Warm, gentle flicker for the evening", candle),
    Pattern("plasma", "Plasma", "Calm", "Smooth colours flowing into each other", plasma),
    Pattern("rainbow", "Rainbow", "Rainbows", "Rainbow colours sliding along", rainbow),
    Pattern("rainbow_cycle", "Rainbow cycle", "Rainbows", "One full rainbow across the strip, turning", rainbow_cycle),
    Pattern("theater_chase_rainbow", "Rainbow chase", "Rainbows", "Rainbow dots marching like cinema lights", theater_chase_rainbow),
    Pattern("jik_tak", "Jik-tak", "Rainbows", "Purple and teal mirrored from both ends, fast", jik_tak),
    Pattern("fire", "Fire", "Lively", "Flames rising from the start of the strip", fire),
    Pattern("fireworks", "Fireworks", "Lively", "Rockets shoot up and burst into colour", fireworks),
    Pattern("bouncing_balls", "Bouncing balls", "Lively", "Four balls bouncing with real gravity", bouncing_balls),
    Pattern("candy_cane", "Candy cane", "Lively", "Red and white stripes marching", candy_cane),
    Pattern("police", "Police", "Lively", "Red and blue halves flashing in turn", police),
    Pattern("heartbeat", "Heartbeat", "Shapes", "A lub-dub pulse from the middle, once a second", heartbeat),
    Pattern("newtons_cradle", "Newton's cradle", "Shapes", "Steel balls knocking, the end ones swing out", newtons_cradle),
    Pattern("pendulum_wave", "Pendulum wave", "Shapes", "Ten pendulums drift out of step and back", pendulum_wave),
    Pattern("dna", "DNA", "Shapes", "Blue and pink strands twisting together", dna),
    Pattern("hourglass", "Hourglass", "Shapes", "Sand trickles to the bottom half, then turns", hourglass),
    Pattern("clock", "Clock", "Shapes", "Orange hours, blue minutes, a white second dot", clock),
    Pattern("rally", "Rally", "Shapes", "A ball between two paddles, faster each hit", rally),
    Pattern("morse", "Morse", "Shapes", "HELLO in Morse code, scrolling in your colour", morse_ticker, colour=True),
    Pattern("flag_bg", "Bulgaria", "Flags", "White, green and red, rippling", flag(FLAGS["bg"])),
    Pattern("flag_ro", "Romania", "Flags", "Blue, yellow and red, rippling", flag(FLAGS["ro"])),
    Pattern("flag_uk", "United Kingdom", "Flags", "Blue, white and red, rippling", flag(FLAGS["uk"], band=8)),
    Pattern("weather_sun", "Sunny", "Weather", "Warm golden shimmer", weather_sun),
    Pattern("weather_cloud", "Cloudy", "Weather", "Grey clouds drifting over blue", weather_cloud),
    Pattern("weather_rain", "Rain", "Weather", "Blue drops falling", weather_rain),
    Pattern("weather_snow", "Snow", "Weather", "White flakes drifting down", weather_snow),
    Pattern("weather_storm", "Storm", "Weather", "Heavy rain with lightning", weather_storm),
    Pattern("color_wipe", "Solid colour", "Your colour", "Fills the strip, then stays still", color_wipe, colour=True),
    Pattern("breathe", "Breathe", "Your colour", "Fades in and out slowly", breathe, colour=True),
    Pattern("twinkle", "Twinkle", "Your colour", "Stars appear and fade", twinkle, colour=True),
    Pattern("comet", "Comet", "Your colour", "A head with a fading tail runs along", comet, colour=True),
    Pattern("scanner", "Scanner", "Your colour", "An eye sweeps back and forth", scanner, colour=True),
    Pattern("theater_chase", "Chase", "Your colour", "Dots marching like cinema lights", theater_chase, colour=True),
    Pattern("ruler", "Ruler", "Setup", "LED 1 blue, every 10th red, every 50th green", ruler),
]}
