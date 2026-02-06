---
name: nextcloud-calendar
description: |
  Create, list, and query calendar events in Nextcloud via CalDAV. Use when:
  (1) User asks to create a calendar event, (2) User asks what's on their calendar,
  (3) User says "add to calendar" or "schedule", (4) User asks about upcoming events.
  Always use Nextcloud calendar unless user specifies otherwise.
author: Claude Code
version: 1.0.0
date: 2025-01-25
---

# Nextcloud Calendar Management

## Problem
Need to create, query, or manage calendar events in the user's Nextcloud calendar.

## Context / Trigger Conditions
- User asks to create/add a calendar event
- User asks "what's on my calendar?" or similar
- User mentions scheduling something
- User says "remind me" with a date (create calendar event)
- Default calendar is always Nextcloud unless otherwise specified

## Prerequisites
- Remote executor must be running (Python commands require remote execution)
- The `~/.venvs/claude` virtualenv must have `caldav` and `icalendar` packages installed
- Environment variables `NEXTCLOUD_USER` and `NEXTCLOUD_APP_PASSWORD` must be set in the venv activation script

## Solution

### Script Location
```
/home/wizard/code/infra/.claude/calendar-query.py
```

### Execution Pattern (CRITICAL)
Always use the remote executor with venv activation to get environment variables:

```bash
source ~/.venvs/claude/bin/activate && cd /home/wizard/code/infra && python .claude/calendar-query.py [command] [options]
```

### Available Commands

#### List Calendars
```bash
python .claude/calendar-query.py list
```

#### Query Events
```bash
# Today's events
python .claude/calendar-query.py today

# Tomorrow's events
python .claude/calendar-query.py tomorrow

# This week
python .claude/calendar-query.py week

# This month
python .claude/calendar-query.py month

# Custom date range
python .claude/calendar-query.py events --days 14
python .claude/calendar-query.py events --date 2026-04-10

# From specific calendar
python .claude/calendar-query.py today --calendar "Work"
```

#### Create Events
```bash
# All-day event (single day)
python .claude/calendar-query.py create --title "Doctor appointment" --start "2026-03-15" --all-day

# All-day event (multi-day) - end date is EXCLUSIVE
# For April 10-13, use end date April 14
python .claude/calendar-query.py create --title "Vacation" --start "2026-04-10" --end "2026-04-14" --all-day

# Timed event
python .claude/calendar-query.py create --title "Meeting" --start "2026-03-15 14:00" --end "2026-03-15 15:00"

# With location and description
python .claude/calendar-query.py create --title "Lunch" --start "tomorrow 12:00" --location "Cafe" --description "Team lunch"

# Relative dates work
python .claude/calendar-query.py create --title "Call" --start "today 16:00"
python .claude/calendar-query.py create --title "Review" --start "tomorrow 10:00"
```

### Output Formats
```bash
# JSON output (for parsing)
python .claude/calendar-query.py today --json

# Text output (default, human-readable)
python .claude/calendar-query.py week
```

## Complete Example via Remote Executor

To create an event "Team offsite" from March 20-22, 2026:

1. Write command to remote executor:
```bash
echo 'source ~/.venvs/claude/bin/activate && cd /home/wizard/code/infra && python .claude/calendar-query.py create --title "Team offsite" --start "2026-03-20" --end "2026-03-23" --all-day' > /System/Volumes/Data/mnt/wizard/code/infra/.claude/cmd_input.txt
```

2. Wait and check status:
```bash
sleep 3 && cat /System/Volumes/Data/mnt/wizard/code/infra/.claude/cmd_status.txt
```

3. Read output:
```bash
cat /System/Volumes/Data/mnt/wizard/code/infra/.claude/cmd_output.txt
```

## Important Notes

1. **End dates are exclusive** for all-day events (CalDAV standard). To create an event spanning April 10-13, set end to April 14.

2. **Must source venv activation** - Using `~/.venvs/claude/bin/python` directly won't work because environment variables (`NEXTCLOUD_USER`, `NEXTCLOUD_APP_PASSWORD`) are set in the activation script.

3. **No delete/update commands** - The script currently only supports create and query. To modify events, user must do it manually in Nextcloud.

4. **Default calendar** is "Personal" - use `--calendar` flag for others.

## Verification
- For queries: Output shows formatted event list
- For creates: Output shows "Event created: [title]" with calendar name and start date
- Exit code 0 = success, 1 = error (check output for details)

## Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `NEXTCLOUD_USER and NEXTCLOUD_APP_PASSWORD must be set` | Didn't source venv activation | Use `source ~/.venvs/claude/bin/activate && python ...` |
| `Required packages not installed` | caldav/icalendar missing | Run `~/.venvs/claude/bin/pip install caldav icalendar` |
| `Calendar 'X' not found` | Wrong calendar name | Run `list` command to see available calendars |
