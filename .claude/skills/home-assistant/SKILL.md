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
  Always use Home Assistant for smart home control.
author: Claude Code
version: 1.0.0
date: 2025-01-25
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

## Prerequisites
- Remote executor must be running (Python commands require remote execution)
- The `~/.venvs/claude` virtualenv must have `requests` package installed
- Environment variables `HOME_ASSISTANT_URL` and `HOME_ASSISTANT_TOKEN` must be set in the venv activation script

## Solution

### Script Location
```
/home/wizard/code/infra/.claude/home-assistant.py
```

### Execution Pattern (CRITICAL)
Always use the remote executor with venv activation to get environment variables:

```bash
source ~/.venvs/claude/bin/activate && cd /home/wizard/code/infra && python .claude/home-assistant.py [command] [options]
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

## Complete Example via Remote Executor

To turn on the living room light:

1. Write command to remote executor:
```bash
# Using Write tool to write to cmd_input.txt:
source ~/.venvs/claude/bin/activate && cd /home/wizard/code/infra && python .claude/home-assistant.py on light.living_room
```

2. Wait and check status:
```bash
sleep 2 && cat /System/Volumes/Data/mnt/wizard/code/infra/.claude/cmd_status.txt
```

3. Read output:
```bash
cat /System/Volumes/Data/mnt/wizard/code/infra/.claude/cmd_output.txt
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
4. **HA URL**: `https://ha-london.viktorbarzin.me`
