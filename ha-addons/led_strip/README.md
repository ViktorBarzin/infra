# LED strip add-on (ha-london)

This Home Assistant OS add-on drives the "Livia" LED strip in London. It runs
`strandtest.py`, the rpi_ws281x example script that rpi-london ran from
`led.service` until its SD card died on 2026-10-13. Home Assistant shows the
strip as `light.livia`, and the London Alexa knows it as "Livia".

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

`server.py` listens on port 8099 on the Supervisor network only, as
`http://local-led-strip:8099`:

- `GET /state` returns `on`, `pattern`, `brightness` (1-255), `rgb` and `running`.
- `POST /state` takes any of `on`, `pattern`, `brightness` and `rgb`. A change
  without `on` turns the strip on. A colour sent while a rainbow pattern runs
  switches to `color_wipe`.

Each change stops `strandtest.py` with SIGINT, so `-c` clears the strip. Then
the server starts it again with the new flags, as rpi-london's Flask page did.
The state is saved in `/data/state.json`, and the add-on restores it when it
starts.

The patterns:

| kind | patterns |
|---|---|
| from the original script | `rainbow`, `rainbow_cycle`, `theater_chase_rainbow`, `jik_tak`, `color_wipe`, `theater_chase` |
| flags, scrolling with a cloth ripple | `flag_bg`, `flag_ro`, `flag_uk` |
| scenes | `fire`, `ocean`, `police`, `candy_cane` |
| in the chosen colour | `color_wipe`, `theater_chase`, `comet`, `scanner`, `breathe`, `twinkle` |
| setup | `ruler` |

`falling_stars` is left out because it is unfinished. A colour sent while a
pattern without a colour runs switches to `color_wipe`.

The add-on gets `/dev/spidev0.0`, `/dev/gpiomem` (rpi_ws281x sets the MOSI pin
function through it) and the device tree (`devicetree: true`). Docker hides
`/proc/device-tree`, so the Dockerfile points rpi_ws281x's board check at
`/device-tree` before it builds the library.

The HA side is `packages/livia.yaml` in the ha-london-config repo:

- a `rest` sensor `sensor.livia_state` polls the state every 30 seconds;
- `script.livia_set` turns the plug on before a change and off after "off";
- the template light `light.livia` has brightness, colour and the patterns as
  effects;
- the automation `livia_stop_when_unpowered` stops the output whenever
  `switch.livia` is not on.

Never drive the strip while its 5 V supply is off. A WS2812 strip without
power draws current through the data line from the Pi's GPIO, which loads
the Pi's 3.3 V rail. On 2026-11-18 the Livia plug went offline while the
add-on kept sending, and ha-london froze three times until the add-on was
stopped. The automation checks on every plug change and once a minute.

The dashboard `livia-strip` (sidebar "Livia") has the light with brightness
and favourite colours, a "Pick any colour" button that opens the colour
wheel, preset colours, one button per pattern, and the plug.

## Change and deploy

```sh
cd ha-addons/led_strip
python3 -m unittest test_server test_patterns   # state logic, process handling and every pattern, no hardware
```

1. Bump `version` in `config.yaml`. The Supervisor pulls `<image>:<version>`.
2. Land the change on master. GitHub Actions
   (`.github/workflows/build-ha-addon-led-strip.yml`) builds the arm64 image
   and pushes `ghcr.io/viktorbarzin/ha-addon-led-strip:<version>` (public).
3. Run `./deploy.sh`. It waits for that tag, copies `config.yaml` and the
   sources to `/addons/led_strip`, then has the Supervisor install or update
   the add-on.

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

`running: true` with `on: true` means strandtest is sending frames. The SPI
counters prove it: `/sys/class/spi_master/spi0/statistics/messages` on the host
rises by about 30 a second during a rainbow.

## The original

rpi-london's home directory is kept at `/srv/nfs/london-pi/` on the Proxmox
host. It holds the original `strandtest.py`, `led.service` and the Flask page
`toggle-led/`. This copy uses `LED_PIN = 10`, adds `--brightness` and
`--count` flags, and adds the patterns marked as added in the file.
