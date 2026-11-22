"""Listen to what the Pi plays and turn it into Levels for the music patterns.

The radio plays on the VLC add-on, which sends it to the Pi's sound system
(PulseAudio in the Supervisor's audio plugin) and on to the Logitech Z537 over
Bluetooth. This add-on has `audio: true`, so `parec` can record the monitor of
the default output: the same sound, just before it leaves the Pi.

The speaker plays that sound later than the Pi sends it, because Bluetooth
buffers it. `Delayed` holds the Levels back by the add-on option
music_delay_ms, so the lights land on the beat the room hears.
"""

import subprocess
import threading
import time
from collections import deque
from collections.abc import Callable

import numpy as np

from patterns import BANDS, SILENCE, Levels

RATE = 16000  # samples a second; enough for treble up to 8 kHz
HOP = RATE // 30  # new samples per frame, 30 frames a second
WINDOW = 1024  # samples per spectrum, 64 ms
EDGES = np.geomspace(40, 7600, BANDS + 1)  # band edges in Hz, spaced like hearing
RANGE_DB = 36.0  # how far below a band's recent peak still shows as lit
FLOOR_DB = -60.0  # quieter than this is silence, however long it lasts
PEAK_FALL_DB = 0.05  # how fast a band's remembered peak falls, per frame

_HANN = np.hanning(WINDOW).astype(np.float32)
_FREQS = np.fft.rfftfreq(WINDOW, 1 / RATE)
_BINS = [(_FREQS >= lo) & (_FREQS < hi) for lo, hi in zip(EDGES, EDGES[1:])]


def band_power(window: np.ndarray) -> np.ndarray:
    """Mean power per band of one window of samples (floats from -1 to 1)."""
    spectrum = np.abs(np.fft.rfft(window[-WINDOW:] * _HANN[-len(window):])) ** 2 / WINDOW
    return np.array([spectrum[b].mean() if b.any() else 0.0 for b in _BINS])


def db(power: np.ndarray | float) -> np.ndarray:
    return 10 * np.log10(np.asarray(power) + 1e-12)


class Analyser:
    """Turns hops of samples into Levels, adjusting to the music's loudness."""

    def __init__(self) -> None:
        self.window = np.zeros(WINDOW, dtype=np.float32)
        self.peak = np.full(BANDS, FLOOR_DB)
        self.level_peak = FLOOR_DB
        self.bass_avg = 0.0
        self.beat = 0.0
        self.since_beat = 99

    def step(self, hop: np.ndarray) -> Levels:
        self.window = np.concatenate([self.window[len(hop):], hop.astype(np.float32)])
        power = band_power(self.window)
        loud = db(power)
        self.peak = np.maximum(np.maximum(self.peak - PEAK_FALL_DB, loud), FLOOR_DB)
        bands = np.clip((loud - (self.peak - RANGE_DB)) / RANGE_DB, 0, 1)
        bands[loud < FLOOR_DB] = 0.0

        level_db = float(db(float(np.mean(self.window[-HOP:] ** 2))))
        self.level_peak = max(self.level_peak - PEAK_FALL_DB, level_db, FLOOR_DB)
        level = 0.0 if level_db < FLOOR_DB else min(1.0, max(0.0, (level_db - (self.level_peak - RANGE_DB)) / RANGE_DB))

        # A beat: bass power jumps well above its recent average.
        bass = float(power[0] + power[1])
        self.since_beat += 1
        if (bass > 1.8 * self.bass_avg and db(bass) > FLOOR_DB + 10 and self.since_beat > 6):
            self.beat = 1.0
            self.since_beat = 0
        else:
            self.beat *= 0.8
            if self.beat < 0.01:
                self.beat = 0.0
        self.bass_avg = 0.9 * self.bass_avg + 0.1 * bass
        return Levels(tuple(float(b) for b in bands), level, self.beat)


class Delayed:
    """Hands out Levels `delay` seconds after they were heard."""

    def __init__(self, delay: float, now: Callable[[], float] = time.monotonic) -> None:
        self.delay = delay
        self.now = now
        self.queue: deque[tuple[float, Levels]] = deque()
        self.current = SILENCE
        self.lock = threading.Lock()

    def put(self, levels: Levels) -> None:
        with self.lock:
            self.queue.append((self.now(), levels))

    def get(self) -> Levels:
        with self.lock:
            ripe = self.now() - self.delay
            while self.queue and self.queue[0][0] <= ripe:
                self.current = self.queue.popleft()[1]
            return self.current


PAREC = ["parec", "--device=@DEFAULT_MONITOR@", "--raw", "--format=s16le",
         f"--rate={RATE}", "--channels=1", "--latency-msec=30"]


class Feed:
    """Records the Pi's output with parec in a thread; `levels` is the listener."""

    def __init__(self, delay: float) -> None:
        self.delayed = Delayed(delay)
        self.running = True
        self.thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self.thread.start()

    def levels(self, t: float) -> Levels:
        return self.delayed.get()

    def _run(self) -> None:
        while self.running:
            try:
                proc = subprocess.Popen(PAREC, stdout=subprocess.PIPE)
            except OSError as e:
                print("music: cannot start parec:", e, flush=True)
                time.sleep(5)
                continue
            analyser = Analyser()
            assert proc.stdout is not None
            while self.running:
                data = proc.stdout.read(HOP * 2)
                if len(data) < HOP * 2:
                    break
                hop = np.frombuffer(data, dtype="<i2").astype(np.float32) / 32768
                self.delayed.put(analyser.step(hop))
            proc.kill()
            self.delayed.put(SILENCE)
            if self.running:
                print("music: parec stopped, starting it again", flush=True)
                time.sleep(2)
