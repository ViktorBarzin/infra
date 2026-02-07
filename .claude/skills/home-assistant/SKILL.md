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
version: 2.0.0
date: 2026-02-07
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
| **ha-london** | `https://ha-london.viktorbarzin.me` | N/A (runs on K8s cluster) | Yes |
| **ha-sofia** | `https://ha-sofia.viktorbarzin.me` | `ssh vbarzin@ha-sofia.viktorbarzin.lan` (resolve via `192.168.1.2`) | No |

- **Default**: ha-london (use unless user specifies "sofia" or "ha-sofia")
- **Aliases**: "ha" or "HA" = ha-london. "ha sofia" or "ha-sofia" = ha-sofia.

## Prerequisites
- The `~/.venvs/claude` virtualenv must have `requests` package installed
- Environment variables for each instance must be set in the venv activation script:
  - **ha-london**: `HOME_ASSISTANT_URL` and `HOME_ASSISTANT_TOKEN`
  - **ha-sofia**: `HOME_ASSISTANT_SOFIA_URL` and `HOME_ASSISTANT_SOFIA_TOKEN`

## API Control

### Scripts

| Instance | Script |
|----------|--------|
| ha-london | `.claude/home-assistant.py` |
| ha-sofia | `.claude/home-assistant-sofia.py` |

### Execution Pattern (CRITICAL)
Always activate the venv to get environment variables:

```bash
# ha-london (default)
source ~/.venvs/claude/bin/activate && cd ~/code/infra && python .claude/home-assistant.py [command] [options]

# ha-sofia
source ~/.venvs/claude/bin/activate && cd ~/code/infra && python .claude/home-assistant-sofia.py [command] [options]
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
source ~/.venvs/claude/bin/activate && cd ~/code/infra && python .claude/home-assistant.py on light.living_room
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
| `HOME_ASSISTANT_URL and HOME_ASSISTANT_TOKEN must be set` | Didn't source venv activation | Use `source ~/.venvs/claude/bin/activate && python ...` |
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
Advanced SSH, File Editor, Studio Code Server, InfluxDB, Mosquitto, Node-RED, Frigate, PAI, Music Assistant, ESPHome, Ookla Speedtest, HA USB/IP Client

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
