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

The patterns are `rainbow`, `rainbow_cycle`, `theater_chase_rainbow`,
`jik_tak`, `color_wipe` and `theater_chase`. The last two use the colour.
`falling_stars` is left out because it is unfinished.

The add-on gets `/dev/spidev0.0`, `/dev/gpiomem` (rpi_ws281x sets the MOSI pin
function through it) and the device tree (`devicetree: true`). Docker hides
`/proc/device-tree`, so the Dockerfile points rpi_ws281x's board check at
`/device-tree` before it builds the library.

The HA side is `packages/livia.yaml` in the ha-london-config repo:

- a `rest` sensor `sensor.livia_state` polls the state every 30 seconds;
- `script.livia_set` turns the plug on before a change and off after "off";
- the template light `light.livia` has brightness, colour and the patterns as
  effects.

## Change and deploy

```sh
cd ha-addons/led_strip
python3 -m unittest test_server   # state logic and process handling, no hardware
./deploy.sh                       # copies to /addons/led_strip, installs, updates or rebuilds
```

Bump `version` in `config.yaml` for every change. Then `deploy.sh` runs an
update instead of a rebuild. The build compiles rpi_ws281x on the Pi, which
takes a few minutes.

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
`toggle-led/`. This copy differs in two places: `LED_PIN = 10`, and a
`--brightness` flag.
