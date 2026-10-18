# ADR-0036: Wine apps use TigerVNC for the remote display, chosen by benchmark

- Status: accepted
- Date: 2026-10-18
- Related: ADR-0035, `images/wine-app/`, `modules/kubernetes/wine_app/`, `stacks/ivms/`, `stacks/proxy/files/broker/broker.py`

## Context

Emil reported that iVMS in the cluster works but the screen feels laggy. The
first version of the `wine-app` image (ADR-0035) drew the desktop with Xvfb
and served it with x11vnc started with `-noxdamage`, which makes x11vnc find
changes by comparing the screen against its last copy rather than being told
what changed. The browser side was Debian bookworm's noVNC 1.3.0.

An earlier session had picked neko (WebRTC video) as the best remote display
for the proxy browsers (`stacks/proxy`), so the question was which option is
best for a Windows admin app. Viktor asked for all of them to be measured, and
for the result to decide the display used for Wine apps from now on.

## What we measured

A throwaway namespace (`wine-bench`, deleted afterwards) ran each option with
the same 1600x900 test window: a list of text rows, a 300x300 block that flips
black and white on each click, and a button that starts a bar moving across a
strip every 16 ms. Google Chrome ran headless in a pod on k8s-node2 and
measured each option running on k8s-node3, over the pod network:

- **Latency**: time from the browser receiving a mouse press to the block's
  new colour showing in the viewer, 50 clicks. The viewer is sampled once per
  animation frame (canvas) or once per decoded frame (video), so the numbers
  include up to one frame of sampling delay.
- **Smoothness**: distinct bar positions shown per second while the bar moves.
- **Cost**: the candidate pod's CPU and outgoing bandwidth from its cgroup and
  interface counters, idle (viewer connected, nothing moving) and while
  scrolling.

| option | latency p50 | p95 | fps while scrolling | CPU idle | CPU scrolling | bandwidth scrolling | memory |
|---|---|---|---|---|---|---|---|
| x11vnc `-noxdamage` + noVNC 1.3 (before) | 56 ms | 89 ms | 36 | 0.08 | 0.29 | 37 kbit/s | 607 MiB |
| x11vnc `-wait 5 -defer 5` + noVNC 1.6 | 45 ms | 61 ms | 54 | 0.07 | 0.20 | 57 kbit/s | 624 MiB |
| **TigerVNC Xvnc 1.12 + noVNC 1.6** | **29 ms** | **38 ms** | **59** | **0.00** | **0.11** | **97 kbit/s** | **603 MiB** |
| KasmVNC (linuxserver image) | 55 ms | 96 ms | 23 | 0.00 | 0.13 | 40 kbit/s | 303 MiB |
| neko 3.1.4, VP8 on CPU, 60 fps | 144 ms | 170 ms | 25 | 1.41 | 1.52 | 2.1 Mbit/s | 244 MiB |
| neko 3.1.4, x264 on CPU, 60 fps | 164 ms | 211 ms | 25 | 1.80 | 1.48 | 2.1 Mbit/s | 181 MiB |
| neko 3.1.4, VP8 on CPU, 30 fps | 154 ms | 176 ms | 24 | 1.58 | 1.73 | 2.1 Mbit/s | 558 MiB |
| neko 3.1.4, x264 on CPU, 30 fps | 146 ms | 169 ms | 24 | 1.54 | 1.69 | 2.1 Mbit/s | 179 MiB |
| neko 3.2.0, NVENC on the T4, 60 fps | 161 ms | 212 ms | 31 | 1.47 | 1.53 | 4.3 Mbit/s | 225 MiB |

CPU is in cores. Memory includes the test window and its Debian packages, so it
compares the options with each other, not with iVMS. The neko memory figures
vary with which pod image ran; they are not a property of the encoder.

Through Cloudflare, a request on an already-open connection took 68 ms against
23 ms direct (median of 10, 2026-10-18), so the public path adds about 45 ms
to each round trip for the VNC options, whose updates travel over the
WebSocket. neko's video goes over WebRTC directly or through the TURN relay,
not through Cloudflare, so its numbers are close to what a remote user sees.
TigerVNC through Cloudflare is therefore about 75 ms, still about half of
neko's direct figure.

## Decision

The `wine-app` image uses TigerVNC's `Xvnc` as the X server and VNC server,
with noVNC 1.6.0 from upstream (pinned by sha256) in the browser. Xvnc keeps
the screen itself, so it sends exactly the regions that changed, without
polling. It had the lowest latency, the highest frame rate and the lowest CPU
of everything measured, and it needs nothing outside the pod: the ingress,
the Wake gate, the viewer counting on `:5900` and the readiness probe stay as
they are. iVMS moved to it in the same change.

## Consequences

- Wine apps keep the noVNC page and the same URLs. noVNC 1.6 is a newer
  version of the same viewer.
- Xvnc understands the X extensions xdotool and xprintidle use, so install
  scripts and the idle signal keep working (checked with a full iVMS install
  on the new image before the switch).
- neko is not a better fit for a Windows admin app. Its latency was about five
  times TigerVNC's, and it encodes a constant video stream even when nothing
  moves, about 1.5 cores and 2 Mbit/s per open viewer. It remains the display
  for the proxy browsers, which show video and moving web pages, where the
  trade-off is different. These numbers do not settle that case.
- KasmVNC used half the memory but was no faster than the old setup and
  showed fewer frames.

## Open questions

- The latency was measured in-cluster with headless Chrome decoding video in
  software. A desktop browser with hardware decoding may show neko somewhat
  faster. The gap to TigerVNC is large enough that we do not expect it to
  change the decision.
- neko's own tuning (a lower playout delay, a smaller jitter buffer) was not
  tried.
- Phone viewing was not measured; noVNC scales the 1600x900 desktop to the
  screen as before.

## Found along the way

The T4's driver (595.91.07 on 2026-10-18) rejects every preset of the older
GStreamer `nvh264enc` element ("Selected preset not supported"), so a neko
pipeline using `nvh264enc preset=2` sends no video. The proxy browsers use
that pipeline. On neko 3.2.0 the newer element works:
`nvcudah264enc preset=p1 tune=ultra-low-latency`.
