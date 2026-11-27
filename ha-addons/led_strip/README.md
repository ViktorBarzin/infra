# LED strip add-on (ha-london)

This Home Assistant OS add-on drives the "Livia" LED strip in London. Its
first patterns came from `strandtest.py`, the rpi_ws281x example script that
rpi-london ran from `led.service` until its SD card died on 2026-10-13. Home
Assistant shows the strip as `light.livia`, and the London Alexa knows it as
"Livia".

## Hardware

| item | value |
|---|---|
| strip | 150 WS2812 LEDs, GRB |
| data | GPIO10 (SPI MOSI), header pin 19 |
| ground | header pin 20 |
| power | the strip's own 5 V supply, on the Kasa plug `switch.livia`; not from the Pi |
| boot config | `dtparam=spi=on`, `core_freq=250` in `/mnt/boot/config.txt` |

On a Pi 3 the SPI clock follows the core clock, so `core_freq=250` keeps the
2.4 MHz bit timing steady. SPI mode needs no `/dev/mem` and no audio change,
unlike GPIO18 (PWM), which rpi-london used.

## How it works

| file | what it does |
|---|---|
| `patterns.py` | every pattern, as a generator of frames; no hardware. The list `PATTERNS` gives each one its name, title, group and a one-line description |
| `play.py` | plays one pattern on the strip until SIGINT, then clears it |
| `music.py` | for the music patterns: records the Pi's sound output with `parec` and turns it into band levels with numpy |
| `server.py` | the HTTP control Home Assistant talks to; starts and stops `play.py` |
| `preview.py` | draws each pattern as an animated WebP for the dashboard (devvm only, needs Pillow) |
| `dashboard.py` | rebuilds the pattern sections of the `livia-strip` dashboard from `PATTERNS`, one per group |

A pattern yields `(pixels, delay)` frames, one `(r, g, b)` per LED. A delay of
`None` marks a still frame: `play.py` keeps it and sends it again once a
second, rather than at the animation rate. That heals a frame the strip
misread within a second, and gives the strip far fewer frames to misread.

`server.py` listens on port 8099 on the Supervisor network only, as
`http://local-led-strip:8099`:

- `GET /state` returns `on`, `pattern`, `brightness` (1-255), `rgb`, `running`
  and `patterns`, the list of names (Home Assistant's effect list).
- `POST /state` takes any of `on`, `pattern`, `brightness`, `rgb` and `palette` (the music patterns' colours: `rainbow`, `colour`, `warm` or `cool`). A change
  without `on` turns the strip on. A colour sent while a rainbow pattern runs
  switches to `color_wipe`.

Each change stops `play.py` with SIGINT, which clears the strip. Then the
server starts it again with the new flags, as rpi-london's Flask page did.
The state is saved in `/data/state.json`, and the add-on restores it when it
starts.

Two layers keep the strip running when the Pi runs out of memory. The kernel
kills add-ons first (`oom_score_adj` 200):

| what dies | what brings it back |
|---|---|
| `play.py` alone | `server.py` checks every 5 s and restarts a pattern that died while the light is on; a pattern that keeps dying is retried after 5, 10, 20, 40, then 60 s |
| the whole add-on | the Supervisor watchdog (`watchdog: true`, set by `deploy.sh`) restarts the container, which restores the saved state |
| HA's view of it after a reboot | the automation `livia_reload_state_sensor` in `packages/livia.yaml` reloads the REST sensor when it stays unavailable |

The patterns, by group as on the dashboard:

| group | patterns |
|---|---|
| Calm | `aurora`, `ocean`, `lava_lamp`, `candle`, `plasma` |
| Rainbows | `rainbow`, `rainbow_cycle`, `theater_chase_rainbow`, `jik_tak` (from the original script) |
| Lively | `fire`, `fireworks`, `bouncing_balls`, `candy_cane`, `police` |
| Shapes | `heartbeat`, `newtons_cradle`, `pendulum_wave`, `dna`, `hourglass`, `clock` (local time), `rally`, `morse` ("HELLO", in the chosen colour) |
| Flags, scrolling with a cloth ripple | `flag_bg`, `flag_ro`, `flag_uk` |
| Weather | `weather_sun`, `weather_cloud`, `weather_rain`, `weather_snow`, `weather_storm` |
| In the chosen colour | `color_wipe` (still once filled), `breathe`, `twinkle`, `comet`, `scanner`, `theater_chase` |
| Music, following the radio | `music_spectrum` (spectrum bars), `music_meter` (level meter), `music_pulse` (beat pulse), `music_drums` (kick and snare) |
| Setup | `ruler` (still) |

A colour sent while a pattern without a colour runs switches to `color_wipe`.

Colours everywhere are screen colours (the values a web page would use).
`play.py` gamma-corrects each channel (exponent 2.2, `GAMMA` table) before it
sends a pixel, because the strip's light is linear in the value and a screen's
is not. Without it, mid values are too bright: Romania's blue shows light and
Bulgaria's green shows teal. The previews skip the table, since the screen
applies its own gamma.

To add a pattern, write its generator in `patterns.py` and add it to
`PATTERNS`. The tests, the effect list in Home Assistant, the preview and the
dashboard card follow from that entry when `deploy.sh` runs.

The weather patterns are started by hand. ha-london has no working forecast
source yet: the Met Office integration needs a DataHub key, and the key in
its disabled "Islington" entry is an old DataPoint key that DataHub refuses.

The add-on gets `/dev/spidev0.0`, `/dev/gpiomem` (rpi_ws281x sets the MOSI pin
function through it) and the device tree (`devicetree: true`). Docker hides
`/proc/device-tree`, so the Dockerfile points rpi_ws281x's board check at
`/device-tree` before it builds the library.

The HA side is `packages/livia.yaml` in the ha-london-config repo:

- a `rest` sensor `sensor.livia_state` polls the state every 30 seconds;
- `script.livia_set` turns the plug on before a change and off after "off";
- the template light `light.livia` has brightness, colour and the patterns as
  effects, listed from the sensor's `patterns` attribute;
- the automation `livia_stop_when_unpowered` stops the output whenever
  `switch.livia` is not on.

Never drive the strip while its 5 V supply is off. A WS2812 strip without
power draws current through the data line from the Pi's GPIO, which loads
the Pi's 3.3 V rail. On 2026-11-18 the Livia plug went offline while the
add-on kept sending, and ha-london froze three times until the add-on was
stopped. The automation checks on every plug change and once a minute.

The dashboard `livia-strip` (sidebar "Livia") has the light with brightness
and one row of eight favourite colours, a "Pick any colour" button that opens
the colour wheel, and the plug. The favourites are light.livia's own setting
in the entity registry (long-press a swatch to change it), not part of the
dashboard; eight is what fits in one row on a phone. Its pattern sections are generated by
`dashboard.py`: one section per group, one animated preview per pattern with
its name and a one-line description; a tap starts it. The view is up to four
sections wide with dense placement, so on a computer the groups sit side by
side and on a phone they stack. Edit the rest of the dashboard in Home
Assistant; `deploy.sh` replaces only the pattern sections.

## Music patterns

The four music patterns draw what the Pi plays: the radio on the VLC add-on,
which goes to the Logitech Z537 speaker over Bluetooth
(`docs/architecture/london-site.md`, "Radio"). They cannot hear a film or a
phone that plays to the speaker directly.

| step | how |
|---|---|
| record | The add-on has `audio: true`. `parec` records `@DEFAULT_MONITOR@`, the sound the Pi sends to its default output, as 16 kHz mono. |
| analyse | `music.Analyser` takes 533 new samples 30 times a second and finds the power of 10 bands from 40 Hz to 7.6 kHz in the last 1024 samples. Each band is shown against its own recent peak, so quiet and loud stations both fill the bars. A bass jump of 1.8 times its recent average is a beat (the kick). Three of the four bands from 0.9 to 7.6 kHz jumping to twice their recent average at once is a snare or clap; it may land with a kick, as a clap on 2 and 4 does in dance music. Below -60 dB is silence. |
| wait | `music.Delayed` can hold the levels back by the add-on option `music_delay_ms`, so the lights land on the beat the room hears. The default is 0: on 2026-11-22 Viktor judged the beat pulse in sync at 0 ms on NRJ, and ahead of the kick at 200 ms. Change the option in the add-on's Configuration tab, then restart the add-on: `server.py` reads it at start. |
| colours | The `palette` in the state picks the colours: `rainbow` (each pattern's own look: red to violet bars, a green to red meter, a pulse drifting round the colour circle, a red-orange kick with white-violet snares), `colour` (shades of the picked colour), `warm` (deep red to gold) or `cool` (teal to violet). The music patterns take a colour, so picking one on the colour wheel keeps the music pattern running. |
| draw | `listen` in `patterns.py` gives each frame its levels. Without `music.py` (tests, previews) it is a made-up demo signal. |

Home Assistant starts them from the radio: `packages/radio.yaml` in the
ha-london-config repo, "Follow music".

## Change and deploy

```sh
cd ha-addons/led_strip
python3 -m unittest test_server test_patterns   # state logic, process handling, every pattern, the dashboard; no hardware
```

1. Bump `version` in `config.yaml`. The Supervisor pulls `<image>:<version>`.
2. Land the change on master. GitHub Actions
   (`.github/workflows/build-ha-addon-led-strip.yml`) builds the arm64 image
   and pushes `ghcr.io/viktorbarzin/ha-addon-led-strip:<version>` (public).
3. Run `./deploy.sh`. It waits for that tag, copies `config.yaml` and the
   sources to `/addons/led_strip`, and has the Supervisor install or update
   the add-on. Then it draws the previews into `/homeassistant/www/livia/`
   and rebuilds the dashboard's pattern sections.

Do not let the Pi build the image. On 2026-11-18, compiling rpi_ws281x on
the Pi 3 (903 MB RAM) next to Core froze it until the hardware watchdog reset
it. With `image:` set in `config.yaml`, the Supervisor pulls instead.

The strip length is the add-on option `led_count` (default 150), under
Settings > Add-ons > LED strip > Configuration. The `ruler` pattern helps to
count it: LED 1 is blue, every 10th LED is red and every 50th is green.

## Check it

```sh
homelab ha ssh --instance london -- 'sudo docker exec homeassistant curl -s http://local-led-strip:8099/state'
```

`running: true` with `on: true` means play.py is sending frames. The SPI
counters prove it: `/sys/class/spi_master/spi0/statistics/messages` on the host
rises by about 30 a second during a rainbow.

## The original

rpi-london's home directory is kept at `/srv/nfs/london-pi/` on the Proxmox
host. It holds the original `strandtest.py`, `led.service` and the Flask page
`toggle-led/`. Its `falling_stars` pattern was unfinished and was not carried
over.
