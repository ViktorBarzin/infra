---
name: home-assistant
description: |
  Control Home Assistant smart home devices and automations. Use when:
  (1) User asks to turn on/off lights, switches, or devices,
  (2) User asks about the state of sensors, devices, or entities,
  (3) User says "turn on the lights", "set temperature", "lock the door",
  (4) User asks to run a scene or script,
  (5) User asks "what devices are on?" or "is the door locked?",
  (6) User mentions smart home, IoT, or home automation.
  There are TWO Home Assistant deployments: ha-london (default) and ha-sofia.
  Always use Home Assistant for smart home control.
author: Claude Code
version: 2.1.0
date: 2026-06-24
---

# Home Assistant Control

## Problem
Need to control smart home devices, check sensor states, or run automations via Home Assistant.

## Context / Trigger Conditions
- User asks to control lights, switches, covers, climate, etc.
- User asks about device states ("is the light on?", "what's the temperature?")
- User wants to run a scene or script
- User mentions turning things on/off
- User asks about smart home devices

## Deployments

There are **two** Home Assistant instances:

| Instance | URL | SSH | Default? |
|----------|-----|-----|----------|
| **ha-london** | `https://ha-london.viktorbarzin.me` | `ssh hassio@192.168.8.103` | Yes |
| **ha-sofia** | `https://ha-sofia.viktorbarzin.me` | `ssh vbarzin@192.168.1.8` | No |

- **Default**: ha-london (use unless user specifies "sofia" or "ha-sofia")
- **Aliases**: "ha" or "HA" = ha-london. "ha sofia" or "ha-sofia" = ha-sofia.

## Prerequisites
- Python 3 with `requests` package available (installed via PYTHONPATH or system packages)
- Environment variables for each instance:
  - **ha-london**: `HOME_ASSISTANT_URL` and `HOME_ASSISTANT_TOKEN`
  - **ha-sofia**: `HOME_ASSISTANT_SOFIA_URL` and `HOME_ASSISTANT_SOFIA_TOKEN`
  - If those env vars aren't set (e.g. you're not in the infra repo / Claude venv), don't hand-roll a `kubectl | base64 | jq` token pipeline — use the global **`homelab` CLI** instead (on `$PATH` in any directory):

## homelab CLI (preferred — works from any directory)
- **Token**: `homelab ha token [--instance sofia|london]` resolves the long-lived API token live from the cluster. Use it directly in curl: `curl -H "Authorization: Bearer $(homelab ha token)" https://ha-sofia.viktorbarzin.me/api/states`. (The `home-assistant-sofia.py` script also auto-falls-back to this when its env var is unset.)
- **Host shell** (ha-sofia): `homelab ha ssh -- <cmd>` runs a command on the HA host with deterministic non-interactive ssh (no host-key prompt) — e.g. `homelab ha ssh -- "sudo docker ps"`, `homelab ha ssh -- "cat /config/configuration.yaml"`. Replaces bespoke `ssh -o StrictHostKeyChecking=no …` invocations.
- **Cluster metrics/logs** (not HA-specific): prefer `homelab metrics query "<promql>"` / `homelab logs query "<logql>"` over hand-rolled `curl …/api/v1/query`, and `homelab claim`/`release` over calling `scripts/presence` directly.

## API Control

### Scripts

| Instance | Script |
|----------|--------|
| ha-london | `.claude/home-assistant.py` |
| ha-sofia | `.claude/home-assistant-sofia.py` |

### Execution Pattern (CRITICAL)
Run the scripts directly with python3 (env vars are set in the environment):

```bash
# ha-london (default)
python3 .claude/home-assistant.py [command] [options]

# ha-sofia
python3 .claude/home-assistant-sofia.py [command] [options]
```

### Available Commands

#### List Entities
```bash
# List all entities
python .claude/home-assistant.py list

# List by domain
python .claude/home-assistant.py list --domain light
python .claude/home-assistant.py list --domain switch
python .claude/home-assistant.py list --domain sensor
python .claude/home-assistant.py list --domain climate
python .claude/home-assistant.py list --domain cover

# JSON output
python .claude/home-assistant.py list --json
```

#### Search Entities
```bash
# Search by name or ID
python .claude/home-assistant.py search "living room"
python .claude/home-assistant.py search "temperature"
python .claude/home-assistant.py search "door"
```

#### Get Entity State
```bash
python .claude/home-assistant.py state light.living_room
python .claude/home-assistant.py state sensor.temperature
python .claude/home-assistant.py state --json light.living_room
```

#### Control Entities
```bash
# Turn on/off
python .claude/home-assistant.py on light.living_room
python .claude/home-assistant.py off switch.tv
python .claude/home-assistant.py toggle light.bedroom

# Set values
python .claude/home-assistant.py set light.living_room 75        # brightness %
python .claude/home-assistant.py set climate.thermostat 22       # temperature
python .claude/home-assistant.py set cover.blinds 50             # position %
python .claude/home-assistant.py set input_number.volume 80      # numeric value
python .claude/home-assistant.py set input_boolean.away_mode on  # boolean
python .claude/home-assistant.py set input_select.mode "Night"   # select option
```

#### Run Scenes and Scripts
```bash
# Activate a scene
python .claude/home-assistant.py scene movie_night
python .claude/home-assistant.py scene scene.good_morning

# Run a script
python .claude/home-assistant.py script bedtime_routine
python .claude/home-assistant.py script script.welcome_home
```

#### Call Any Service
```bash
# Generic service call
python .claude/home-assistant.py service light turn_on --entity light.kitchen --data '{"brightness": 255}'
python .claude/home-assistant.py service climate set_hvac_mode --entity climate.living_room --data '{"hvac_mode": "heat"}'
python .claude/home-assistant.py service media_player play_media --entity media_player.tv --data '{"media_content_id": "...", "media_content_type": "video"}'
```

#### List Services
```bash
# List all available services
python .claude/home-assistant.py services

# Filter by domain
python .claude/home-assistant.py services --domain light
python .claude/home-assistant.py services --domain climate
```

#### Send Notifications
```bash
python .claude/home-assistant.py notify "Door left open!"
python .claude/home-assistant.py notify "Motion detected" --title "Security Alert"
python .claude/home-assistant.py notify "Hello" --target notify.mobile_app
```

## SSH Access (ha-sofia only)

ha-sofia supports SSH for direct configuration management.

### Connection
```bash
ssh vbarzin@192.168.1.8
```

### Configuration Path
```
/config/
```

### Common SSH Tasks
```bash
# Read configuration
ssh vbarzin@192.168.1.8 "cat /config/configuration.yaml"

# Check HA logs (note: live log is inside HA Core container, not always accessible)
ssh vbarzin@192.168.1.8 "tail -50 /config/home-assistant.log.1"

# List config files
ssh vbarzin@192.168.1.8 "ls /config/*.yaml"

# Read automations/scenes/scripts
ssh vbarzin@192.168.1.8 "cat /config/automations.yaml"
ssh vbarzin@192.168.1.8 "cat /config/scenes.yaml"
ssh vbarzin@192.168.1.8 "cat /config/scripts.yaml"

# Check secrets (keys only, not values)
ssh vbarzin@192.168.1.8 "cat /config/secrets.yaml"
```

### SSH Limitations
- The SSH add-on runs in a separate container — `ha core logs` returns 401
- Docker socket is not accessible — can't use `docker logs`
- Live `home-assistant.log` may not be visible (written inside HA Core container)
- Rotated logs (`.log.1`, `.log.old`) are accessible

## Complete Example

To turn on the living room light on ha-london:
```bash
python3 .claude/home-assistant.py on light.living_room
```

To check ha-sofia configuration:
```bash
ssh vbarzin@ha-sofia.viktorbarzin.lan "cat /config/configuration.yaml"
```

## Common Entity Domains

| Domain | Description | Common Actions |
|--------|-------------|----------------|
| `light` | Lights | on, off, toggle, set brightness |
| `switch` | Switches | on, off, toggle |
| `sensor` | Sensors | state (read-only) |
| `binary_sensor` | Binary sensors | state (read-only) |
| `climate` | Thermostats | set temperature, set mode |
| `cover` | Blinds/covers | open, close, set position |
| `lock` | Locks | lock, unlock |
| `media_player` | Media devices | play, pause, volume |
| `input_boolean` | Helper toggles | on, off |
| `input_number` | Helper numbers | set value |
| `input_select` | Helper dropdowns | select option |
| `script` | Scripts | run |
| `scene` | Scenes | activate |
| `automation` | Automations | trigger, on, off |

## Verification
- Commands print confirmation message on success
- Use `state` command to verify entity changed
- Exit code 0 = success, 1 = error

## Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `HOME_ASSISTANT_URL and HOME_ASSISTANT_TOKEN must be set` | Env vars not set | Ensure `HOME_ASSISTANT_URL` and `HOME_ASSISTANT_TOKEN` are in the environment |
| `404 Not Found` | Entity doesn't exist | Use `search` command to find correct entity ID |
| `401 Unauthorized` | Token invalid/expired | Generate new long-lived token in HA |
| `Connection refused` | HA not reachable | Check URL and network connectivity |

## Notes

1. **Entity IDs are case-sensitive** - use `search` to find exact IDs
2. **Token must have sufficient permissions** - ensure token has access to all entities
3. **Some entities require specific data** - use `services` command to see required fields
4. **Two instances**: ha-london (default, K8s), ha-sofia (SSH + API)
5. **ha-sofia SSH**: Uses default SSH key, user `vbarzin`, resolve DNS via `192.168.1.2`. Only reachable from local Sofia network (not remotely).

---

## ha-sofia Knowledge Map

### Overview
- **1,087 entities** across 29 domains, **128 devices**, **13 areas**, **43 automations**
- **Location**: Sofia, Bulgaria (Вермонт / Vermont neighborhood)
- **4 tracked people**: Viktor Barzin, Emil Barzin, Valia Barzina, MQTT

### Key Systems

#### 1. Heating & Gas Boiler (EMS-ESP)
- Buderus/Bosch gas boiler via EMS-ESP integration
- Entities: `sensor.boiler_*`, `number.boiler_*`, `switch.boiler_*`
- DHW (hot water), heating curves, burner stats, gas metering
- Outside temp: `sensor.boiler_outside_temperature`

#### 2. Climate / Thermostats (4 rooms + bathroom)
| Room | Entity | Bulgarian |
|------|--------|-----------|
| Children's room | `climate.thermostat_children_room` | Детска |
| Office | `climate.thermostat_office_room` | Кабинет |
| Living room | `climate.thermostat_living_room` | Хол |
| Master bedroom | `climate.thermostat_master_bedroom` | род. Спалня |
| Bathroom (Valchedram) | `climate.bania_vlchedrm` | Баня Вълчедръм |

#### 3. Solar / Photovoltaic (Solarman)
- Inverter: `sensor.fv_b_*` (FV = фотоволтаици)
- Battery, grid/self-use EMS mode, solar forecast
- Energy totals tracked per grid/inverter

#### 4. ATS (Automatic Transfer Switch)
- Grid ↔ inverter switching: `sensor.ats_*`
- Load power, grid/inverter voltage, energy totals

#### 5. Security / Alarm (Paradox EVOHD+)
- 3 alarm partitions: Apartment, Garage, Valchedram
- PIR zones, door contacts, tamper sensors, PGMs for garage doors/doorbells

#### 6. Cameras / NVR / Frigate
- Hikvision NVR (DS-7632NXI) with 9 cameras
- Frigate NVR with object detection:
  - **Vermont** (home): cameras 10, 15, 16 — car/plate recognition
  - **Valchedram** (country): cameras 1, 2 — person detection
  - Object tracking: vehicles (Emo Skoda), cats (Мичка)

#### 7. Smart Appliances (Home Connect / Bosch-Siemens)
| Appliance | Entity prefix | Bulgarian |
|-----------|--------------|-----------|
| Dishwasher | `*.miialna_mashina_*` | Миялна машина |
| Washing machine | `*.peralnia_*` | Пералня (with i-Dos) |
| Dryer | `*.sushilnia_*` | Сушилня |

#### 8. LED Strip Controllers (6-channel each)
- Kitchen upper/lower: `light.kukhnia_*_socket_1-6`
- Children's wardrobe: `light.led_detska_garderob_socket_1-6`
- Hall wardrobe: `light.led_garderob_khol_socket_1-6`
- Corridor wardrobe: `light.led_garderob_koridor_socket_1-6` (offline)
- Master bedroom wardrobe: `light.led_garderob_rod_spalnia_socket_1-6` (offline)

#### 9. Media
- Sony BRAVIA XR-65A80L (AirPlay + DLNA)
- Marantz ND8006 (AirPlay + DLNA)

#### 10. Networking
- TP-Link Archer AX6000 (main router)
- TP-Link Archer MR200 (LTE backup)

#### 11. UPS
- `sensor.ups_*` — battery, load, voltage, remaining time

#### 12. Ventilation (Pax BLE)
- `sensor.ventilator_mokro_2_*` — bathroom fan with humidity/light sensors

#### 13. Synology NAS
- **NAS_Barzini**: CPU 2%, Memory 26%, 2 drives (39C/41C)
- Volume 1: 87.2% used (5.02 TB), status "attention"
- DSM update available

#### 14. Printer
- **HP ColorLaserJet M253-M254**: Black 49%, Cyan 88%, Magenta 91%, Yellow 90%

#### 15. Dell R730 Server (via iDRAC)
- CPU temp 57C, Power 192W, Inlet 24C, Exhaust 29C
- Tesla T4 GPU: 41C, 4% util, 4183MB VRAM, 32W

#### 16. Other Devices
- **Dehumidifier** (Tuya): `humidifier.arete_*`
- **Robot vacuum** (Rumi): `vacuum.rumi` — docked, 100% battery, 227 missions
- **Tuya lights**: `light.krushka_*` (4 bulbs, currently offline)
- **AC unit** (MELCloud): `climate.klimatik` — off, 23C
- **Mistral AI**: Conversation integration (Devstral 2)

### Integrations
HACS, ESPHome, Frigate, Home Connect, Paradox (PAI), Solarman, Pax BLE, Hikvision, InfluxDB, Mosquitto MQTT, Node-RED, Music Assistant, Zigbee2MQTT, Spook, Xtend Tuya, MELCloud, Synology DSM, HP Printer (IPP)

### Add-ons
Advanced SSH, File Editor, Studio Code Server, InfluxDB, Mosquitto, Node-RED, Frigate, PAI, Music Assistant, ESPHome, Ookla Speedtest, HA USB/IP Client, **Home Assistant Version Control**

### Version Control (Git Config Tracking)
- **Add-on**: Home Assistant Version Control v1.2.0 (slug: `4ab554b2_home-assistant-version-control`)
- **Add-on repo**: `https://github.com/saihgupr/ha-addons`
- **What it does**: Auto-tracks every config file change via git. File watcher (inotify) detects changes, debounces (5s default), commits automatically.
- **Tracked files**: `.yaml`, `.yml`, `.json`, `.conf`, `.sh`, `.py` + `.storage/` (lovelace dashboards, entity/device registries, config entries)
- **Excluded**: `secrets.yaml`, database files (`.db`), logs, `__pycache__`, binary files
- **Git repo**: `/homeassistant/.git` (owned by root; SSH user needs `git config --global --add safe.directory /homeassistant`)
- **GitHub remote**: `https://github.com/ViktorBarzin/ha-sofia-config` (private). Auth token from Vault `secret/viktor` key `github_pat`. Cloud sync pushes hourly.
- **Web UI**: Sidebar → "Version Control", or Settings → Add-ons → HA Version Control → Open Web UI. Ingress URL: `/api/hassio_ingress/PYR_EdVzPtzZdRnGjrhI3qbGogCVJ18FrtOg6oaBf-w/`
- **Features**: Browse commit history with diffs, restore individual files or full config to any point, delete recovery, smart reloads after restore
- **API**: `POST /api/git/add-all-and-commit` (manual backup), `GET /api/git/history` (commit log), `POST /api/restore-file` (restore single file), `POST /api/restore-commit` (full rollback)
- **SSH git access**: `ssh vbarzin@192.168.1.8 'git -C /homeassistant log --oneline -10'`

### Music Assistant (MASS)
- **Addon slug**: `d5369777_music_assistant`
- **Version**: 2.7.8
- **Web UI**: `http://192.168.1.8:8095`
- **Container name**: `addon_d5369777_music_assistant`
- **Providers**: Spotify (OAuth PKCE + librespot), TuneIn Radio, RadioBrowser, BBC Sounds, Radio Paradise, Filesystem (remote share)
- **Player providers**: UPnP/DLNA, AirPlay, Sendspin (port 8927)
- **Registered players**: Marantz ND8006 (DLNA + AirPlay), Sony BRAVIA XR-65A80L (AirPlay), Web (Chrome)
- **Librespot cache**: `/data/.cache/spotify--5s3mSP8y/credentials.json` (inside addon container)
- **Troubleshooting**: See skill `music-assistant-librespot-wrong-account` for Spotify playback failures
- **SSH addon access to container**: `sudo curl -s --unix-socket /run/docker.sock http://localhost/containers/<id>/exec` (requires sudo)

### Zones
- **Вермонт** (Vermont) — Home
- **Вълчедръм** (Valchedram) — Country house

### Bulgarian ↔ English Room Names
| Bulgarian | English | Entity prefix |
|-----------|---------|---------------|
| Детска | Children's room | `detska` |
| Кабинет | Office | `kabinet` |
| Хол | Living room | `khol` |
| Спалня / род. Спалня | Master bedroom | `rod_spalnia` |
| Кухня | Kitchen | `kukhnia` |
| Коридор | Corridor | `koridor` |
| Баня | Bathroom | `bania` |
| Гараж | Garage | `garaj` |
| Мазе | Basement | `maze` |

---

## ha-london Knowledge Map

### Overview
- **HA Version**: 2026.5.2 on **Home Assistant OS** (HAOS — managed appliance, NOT a `docker run` container). Latest is 2026.6.4 (update available, deliberately not applied).
- **Location**: London, UK
- **Platform**: Raspberry Pi 4, HA OS
- **Access from the Sofia devvm**: london is **remote** — `homelab ha ssh --instance london` generally WON'T connect (ADR-0012). Drive it via the API: `homelab ha token --instance london` + `https://ha-london.viktorbarzin.me/api/...`, and the WebSocket API `wss://ha-london.viktorbarzin.me/api/websocket` for dashboards / config-entries / HACS installs.
- **SSH (only from the London LAN)**: `ssh hassio@192.168.8.103` (requires `sudo` for file access)
- **Config path**: `/config/`
- **3 tracked people**: Viktor Barzin, Anca Milea, Gheorghe Milea
- **Zone**: London (home)

### Dashboards (redesigned 2026-06-24)
**Glossary** (HA terms — keep distinct):
- **Dashboard** = a sidebar entry (Overview, Air Quality, Map). Sidebar *order* is a per-USER frontend preference, not in any dashboard config.
- **View** = a tab inside a dashboard. View order is global (stored in the dashboard config).
- **Card** = a widget inside a view.

- **Overview** (`lovelace`, the default): responsive **sections** views, styled with Mushroom + mini-graph-card.
  - **Home** tab: *Who's home* · *Comfort & Air* (CO₂/temp/humidity/PM2.5/VOC chips + CO₂ and temp/humidity trend graphs + link to Air Quality) · *Cowboy* (battery/range/last-ride) · *Energy* (5 Kasa plugs + power trend) · *Quick actions* (Netflix/Stremio/Night).
  - **More** tab: *Network* (GL-MT6000 router) · *System* (HA version/update, last backup, RPi power) · *Phones*.
- **Air Quality** (`air-quality`): deep-dive (views: Home, Detailed). (`detialed`→`detailed` path typo fixed 2026-06-24.)
- Built via the WS `lovelace/config/save` API (london is remote — no SSH path).

### Key Systems

#### 1. Smart Plugs (TP-Link Kasa) — Energy Monitoring
Named plugs with power/energy tracking:

| Name | Entity | Usage/month | Purpose |
|------|--------|-------------|---------|
| Thor | `switch.thor` | 6.4 kWh | Server/NAS |
| Pikkachu | `switch.pikkachu` | 4.8 kWh | Water cooler |
| Michelle | `switch.emeter_plug` | 0.3 kWh | — |
| Livia | `switch.livia` | 0.07 kWh | — |
| Jinx | `switch.jinx` | 0.02 kWh | — |
| Projector plug | `switch.tapo_p100` | unavailable | Tapo P100 |

#### 2. Air Quality (Apollo AIR-1 via ESPHome)
- `sensor.apollo_air_1_fa2d34_co2`: CO2 level
- `sensor.apollo_air_1_fa2d34_sen55_temperature`: Temperature
- `sensor.apollo_air_1_fa2d34_sen55_humidity`: Humidity
- PM1.0/2.5/4.0/10 particulate sensors
- VOC, NOx, ammonia, CO, ethanol, hydrogen, methane, NO2 gas sensors

#### 3. Cowboy E-Bike (`elsbrock/cowboy-ha`)
Bike named **"Classic Performance"** → entities are `sensor.classic_performance_*` (26 total). The old `sensor.bike_*` names are GONE (they were the dead `jdejaegh` integration).
- `sensor.classic_performance_remaining_battery`: Battery % (was `sensor.bike_state_of_charge`)
- `sensor.classic_performance_remaining_range`: Range km
- `sensor.classic_performance_mileage`: Total km (was `sensor.bike_total_distance`)
- `sensor.classic_performance_saved_co2`: Lifetime CO2 saved (was `sensor.bike_total_co2_saved`)
- Plus `_distance_today`, `_last_trip_*`, `_battery_health`, `device_tracker.classic_performance`, etc.
- **GOTCHA**: live battery/range/mileage read `unknown` while the bike is parked/asleep — Cowboy only reports live SoC when awake (ridden/charging); trip-history + `distance_today` stay live regardless.
- Auth: account **email+password** (no AWS Cognito — that was the dead `jdejaegh`/`cowboybike` lineage). Setup via UI config flow / REST `config_entries/flow`. Creds in Vaultwarden item **"cowboy bike"** (`homelab vault get "cowboy bike"`).

#### 4. Uptime Monitoring (UptimeRobot)
- `sensor.blog`: blog uptime
- `sensor.valchedrym`: Valchedram site uptime
- `switch.blog`, `switch.valchedrym`: monitoring toggles

#### 5. Oral-B Toothbrush (BLE)
- `sensor.smart_series_6000_83d3_*`: mode, pressure, sector, time

#### 6. Network Device Tracking (~100 devices)
- Router-based MAC tracking (many unnamed)
- Named: Viktor's iPhone15Pro, Anca's iPhone13Pro, Apple Watch, Amazon Fire, iRobot, Portal, Living-Room TV

#### 7. Media & Entertainment
- Projector + debug bridge: unavailable (Tapo plug off)
- Scripts: `script.start_netflix`, `script.start_stremio`
- Scene: `scene.night` (turns off Livia + Michelle plugs)

### Custom Components (HACS integrations)
- **cowboy** (`elsbrock/cowboy-ha` v1.2.0): Cowboy e-bike — revived 2026-06-24. The old `jdejaegh/home-assistant-cowboy` repo is **dead (404)**; don't chase it.
- **hildebrandglow_dcc**: UK smart meter DCC energy — **DISABLED by user** (config entry `disabled_by: user`), not broken.

### HACS frontend cards (plugins)
- **Mushroom** (`piitaya/lovelace-mushroom`), **mini-graph-card** (`kalkih/mini-graph-card`), **plotly-graph-card** (`dbuezas/lovelace-plotly-graph-card`) — used by the redesigned Overview. Install over WS `hacs/repository/download`; resources auto-register in storage mode.

### Integrations
ESPHome, TP-Link Kasa, Tapo, UptimeRobot, **Cowboy** (elsbrock), Oral-B BLE, Ookla Speedtest (exposes only an `update` entity, no live speed sensors), HACS, OpenRouter (free LLMs), Piper (TTS), Whisper (STT), Android TV/ADB.
- **Disabled by user (NOT broken)**: `met` + `metoffice` (weather — so `weather.*` entities are ABSENT), `roomba` (Rumi vacuum), `hildebrandglow_dcc` (energy).
- **Failing**: `tplink` **Tapo P100** projector plug — `setup_retry`, 403 KLAP handshake from 192.168.8.108 (plug off / firmware). Left as-is.

### AI / Voice Assistants
- 5 free LLM conversation agents: Google Gemma 3 27B, Meta Llama 3.2 3B, Mistral Devstral 2, OpenAI GPT-OSS-20B, Z.AI GLM 4.5 Air
- Local voice: Piper (TTS) + Whisper (STT)
- Google Translate TTS

### Automations (10)
- Water cooler on/off scheduling (07:00 on, 00:30 off)
- Michelle plug auto-off when idle (<70W)
- Apollo AIR-1 RGB LED: CO2 indicator (on in morning, off at 22:00)
- Cowboy e-bike low battery notification (ntfy + iPhone push)
- Anca arrival/departure notifications
- Night scene: turns off Livia + Michelle

### Platform (HAOS — ignore any legacy `docker run` snippet)
ha-london runs **Home Assistant OS** (managed appliance), NOT a hand-run Docker container. There is no `docker run homeassistant/home-assistant` to manage. Install HACS components over the WebSocket API (`hacs/repository/download` with the repo's HACS id), then restart via `POST /api/services/homeassistant/restart` — a HAOS restart drops automations for ~1–2 min and resets `sensor.uptime` (use that as the "back up" marker).

### SSH Access
```bash
# Read config
ssh hassio@192.168.8.103 "sudo cat /config/configuration.yaml"

# Check logs
ssh hassio@192.168.8.103 "sudo docker logs homeassistant --tail 50"

# Restart HA via API (preferred)
curl -s -X POST "http://192.168.8.103:8123/api/services/homeassistant/restart" \
  -H "Authorization: Bearer ${HOME_ASSISTANT_LONDON_TOKEN}"

# View Docker logs
ssh hassio@192.168.8.103 "sudo docker logs homeassistant --tail 50"
```
