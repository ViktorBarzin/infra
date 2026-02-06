#!/usr/bin/env python3
"""
Nextcloud CalDAV Calendar Script
Queries and creates calendar events.
"""

import argparse
import json
import os
import sys
import uuid
from datetime import datetime, timedelta
from urllib.parse import urljoin

try:
    import caldav
    from icalendar import Calendar, Event, vText
except ImportError:
    print("ERROR: Required packages not installed. Run:")
    print("  pip install caldav icalendar")
    sys.exit(1)

# Configuration from environment variables
NEXTCLOUD_URL = os.environ.get("NEXTCLOUD_URL", "https://nextcloud.viktorbarzin.me")
CALDAV_URL = f"{NEXTCLOUD_URL}/remote.php/dav"
USERNAME = os.environ.get("NEXTCLOUD_USER")
APP_PASSWORD = os.environ.get("NEXTCLOUD_APP_PASSWORD")

if not USERNAME or not APP_PASSWORD:
    print("ERROR: NEXTCLOUD_USER and NEXTCLOUD_APP_PASSWORD environment variables must be set.")
    print("These should be set when activating the Claude venv (~/.venvs/claude)")
    sys.exit(1)


def get_client():
    """Create CalDAV client connection."""
    return caldav.DAVClient(
        url=CALDAV_URL,
        username=USERNAME,
        password=APP_PASSWORD
    )


def list_calendars():
    """List all available calendars."""
    client = get_client()
    principal = client.principal()
    calendars = principal.calendars()

    result = []
    for cal in calendars:
        result.append({
            "name": cal.name,
            "url": str(cal.url)
        })
    return result


def get_events(calendar_name=None, start_date=None, end_date=None, days=7):
    """Get events from calendar(s) within a date range."""
    client = get_client()
    principal = client.principal()
    calendars = principal.calendars()

    if start_date is None:
        start_date = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
    if end_date is None:
        end_date = start_date + timedelta(days=days)

    all_events = []

    for cal in calendars:
        if calendar_name and cal.name.lower() != calendar_name.lower():
            continue

        try:
            events = cal.search(start=start_date, end=end_date, expand=True)

            for event in events:
                try:
                    ical = Calendar.from_ical(event.data)
                    for component in ical.walk():
                        if component.name == "VEVENT":
                            event_data = {
                                "calendar": cal.name,
                                "summary": str(component.get("summary", "No title")),
                                "start": None,
                                "end": None,
                                "location": str(component.get("location", "")) or None,
                                "description": str(component.get("description", "")) or None,
                                "all_day": False
                            }

                            dtstart = component.get("dtstart")
                            dtend = component.get("dtend")

                            if dtstart:
                                dt = dtstart.dt
                                if hasattr(dt, 'hour'):
                                    event_data["start"] = dt.strftime("%Y-%m-%d %H:%M")
                                else:
                                    event_data["start"] = dt.strftime("%Y-%m-%d")
                                    event_data["all_day"] = True

                            if dtend:
                                dt = dtend.dt
                                if hasattr(dt, 'hour'):
                                    event_data["end"] = dt.strftime("%Y-%m-%d %H:%M")
                                else:
                                    event_data["end"] = dt.strftime("%Y-%m-%d")

                            all_events.append(event_data)
                except Exception as e:
                    pass  # Skip malformed events

        except Exception as e:
            print(f"Warning: Could not fetch from {cal.name}: {e}", file=sys.stderr)

    # Sort by start date
    all_events.sort(key=lambda x: x["start"] or "")
    return all_events


def create_event(summary, start_time, end_time=None, calendar_name="Personal",
                 location=None, description=None, all_day=False):
    """Create a new calendar event."""
    client = get_client()
    principal = client.principal()
    calendars = principal.calendars()

    # Find the target calendar
    target_cal = None
    for cal in calendars:
        if cal.name.lower() == calendar_name.lower():
            target_cal = cal
            break

    if not target_cal:
        # Try partial match
        for cal in calendars:
            if calendar_name.lower() in cal.name.lower():
                target_cal = cal
                break

    if not target_cal:
        raise ValueError(f"Calendar '{calendar_name}' not found. Available: {[c.name for c in calendars]}")

    # Create the event
    cal = Calendar()
    cal.add('prodid', '-//Claude Calendar Script//viktorbarzin.me//')
    cal.add('version', '2.0')

    event = Event()
    event.add('summary', summary)
    event.add('uid', str(uuid.uuid4()))
    event.add('dtstamp', datetime.now())

    if all_day:
        event.add('dtstart', start_time.date())
        if end_time:
            event.add('dtend', end_time.date())
        else:
            event.add('dtend', (start_time + timedelta(days=1)).date())
    else:
        event.add('dtstart', start_time)
        if end_time:
            event.add('dtend', end_time)
        else:
            # Default to 1 hour duration
            event.add('dtend', start_time + timedelta(hours=1))

    if location:
        event.add('location', location)
    if description:
        event.add('description', description)

    cal.add_component(event)

    # Save to calendar
    target_cal.save_event(cal.to_ical().decode('utf-8'))

    return {
        "status": "created",
        "summary": summary,
        "calendar": target_cal.name,
        "start": start_time.strftime("%Y-%m-%d %H:%M") if not all_day else start_time.strftime("%Y-%m-%d"),
        "end": end_time.strftime("%Y-%m-%d %H:%M") if end_time and not all_day else None
    }


def format_events(events, output_format="text"):
    """Format events for display."""
    if output_format == "json":
        return json.dumps(events, indent=2)

    if not events:
        return "No events found."

    lines = []
    current_date = None

    for event in events:
        event_date = event["start"][:10] if event["start"] else "Unknown"

        if event_date != current_date:
            current_date = event_date
            try:
                dt = datetime.strptime(event_date, "%Y-%m-%d")
                lines.append(f"\n## {dt.strftime('%A, %B %d, %Y')}")
            except:
                lines.append(f"\n## {event_date}")

        time_str = ""
        if not event["all_day"] and event["start"]:
            time_str = event["start"][11:16]
            if event["end"]:
                time_str += f" - {event['end'][11:16]}"
        else:
            time_str = "All day"

        line = f"- **{event['summary']}** ({time_str})"
        if event["location"]:
            line += f" @ {event['location']}"
        if event["calendar"] != "personal":
            line += f" [{event['calendar']}]"
        lines.append(line)

        if event["description"]:
            # Truncate long descriptions
            desc = event["description"][:200]
            if len(event["description"]) > 200:
                desc += "..."
            lines.append(f"  {desc}")

    return "\n".join(lines)


def parse_date_arg(date_str):
    """Parse flexible date arguments."""
    today = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)

    if date_str == "today":
        return today, today + timedelta(days=1)
    elif date_str == "tomorrow":
        return today + timedelta(days=1), today + timedelta(days=2)
    elif date_str == "week" or date_str == "this week":
        # Start from today, go to end of week (Sunday)
        days_until_sunday = 6 - today.weekday()
        return today, today + timedelta(days=days_until_sunday + 1)
    elif date_str == "next week":
        days_until_next_monday = 7 - today.weekday()
        start = today + timedelta(days=days_until_next_monday)
        return start, start + timedelta(days=7)
    elif date_str == "month" or date_str == "this month":
        return today, today + timedelta(days=30)
    else:
        # Try to parse as a date
        try:
            dt = datetime.strptime(date_str, "%Y-%m-%d")
            return dt, dt + timedelta(days=1)
        except:
            return today, today + timedelta(days=7)


def parse_datetime(dt_str):
    """Parse flexible datetime strings."""
    today = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)

    # Handle relative dates with time
    if dt_str.startswith("today "):
        time_part = dt_str.replace("today ", "")
        try:
            t = datetime.strptime(time_part, "%H:%M")
            return today.replace(hour=t.hour, minute=t.minute)
        except:
            pass

    if dt_str.startswith("tomorrow "):
        time_part = dt_str.replace("tomorrow ", "")
        try:
            t = datetime.strptime(time_part, "%H:%M")
            return (today + timedelta(days=1)).replace(hour=t.hour, minute=t.minute)
        except:
            pass

    # Try full datetime format
    for fmt in ["%Y-%m-%d %H:%M", "%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M", "%Y-%m-%dT%H:%M:%S"]:
        try:
            return datetime.strptime(dt_str, fmt)
        except:
            continue

    # Try date only
    try:
        return datetime.strptime(dt_str, "%Y-%m-%d")
    except:
        pass

    raise ValueError(f"Could not parse datetime: {dt_str}. Use 'YYYY-MM-DD HH:MM' or 'tomorrow HH:MM'")


def main():
    parser = argparse.ArgumentParser(description="Query and manage Nextcloud Calendar")
    parser.add_argument("command", choices=["list", "events", "today", "tomorrow", "week", "month", "create"],
                        help="Command to run")
    parser.add_argument("--calendar", "-c", default="Personal", help="Calendar name (default: Personal)")
    parser.add_argument("--days", "-d", type=int, default=7, help="Number of days to fetch")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    parser.add_argument("--date", help="Specific date (YYYY-MM-DD) or relative (today, tomorrow, week, month)")
    # Create event options
    parser.add_argument("--title", "-t", help="Event title (for create)")
    parser.add_argument("--start", "-s", help="Start time: 'YYYY-MM-DD HH:MM' or 'tomorrow 10:00'")
    parser.add_argument("--end", "-e", help="End time: 'YYYY-MM-DD HH:MM' (optional, defaults to +1 hour)")
    parser.add_argument("--location", "-l", help="Event location")
    parser.add_argument("--description", help="Event description")
    parser.add_argument("--all-day", action="store_true", help="Create all-day event")

    args = parser.parse_args()
    output_format = "json" if args.json else "text"

    try:
        if args.command == "list":
            calendars = list_calendars()
            if output_format == "json":
                print(json.dumps(calendars, indent=2))
            else:
                print("Available calendars:")
                for cal in calendars:
                    print(f"  - {cal['name']}")

        elif args.command == "events":
            if args.date:
                start, end = parse_date_arg(args.date)
            else:
                start = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
                end = start + timedelta(days=args.days)

            events = get_events(
                calendar_name=args.calendar,
                start_date=start,
                end_date=end
            )
            print(format_events(events, output_format))

        elif args.command in ["today", "tomorrow", "week", "month"]:
            start, end = parse_date_arg(args.command)
            events = get_events(
                calendar_name=args.calendar,
                start_date=start,
                end_date=end
            )
            print(format_events(events, output_format))

        elif args.command == "create":
            if not args.title:
                print("ERROR: --title is required for create command", file=sys.stderr)
                sys.exit(1)
            if not args.start:
                print("ERROR: --start is required for create command", file=sys.stderr)
                sys.exit(1)

            # Parse start time
            start_time = parse_datetime(args.start)
            end_time = parse_datetime(args.end) if args.end else None

            result = create_event(
                summary=args.title,
                start_time=start_time,
                end_time=end_time,
                calendar_name=args.calendar,
                location=args.location,
                description=args.description,
                all_day=args.all_day
            )

            if output_format == "json":
                print(json.dumps(result, indent=2))
            else:
                print(f"Event created: {result['summary']}")
                print(f"  Calendar: {result['calendar']}")
                print(f"  Start: {result['start']}")
                if result['end']:
                    print(f"  End: {result['end']}")

    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
