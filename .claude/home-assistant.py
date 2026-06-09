#!/usr/bin/env python3
"""
Home Assistant API Script
Control and query Home Assistant entities.
"""

import argparse
import json
import os
import sys
from urllib.parse import urljoin

try:
    import requests
except ImportError:
    print("ERROR: Required package not installed. Run:")
    print("  pip install requests")
    sys.exit(1)

# Configuration from environment variables
HA_URL = os.environ.get("HOME_ASSISTANT_URL", "").rstrip("/")
HA_TOKEN = os.environ.get("HOME_ASSISTANT_TOKEN")

if not HA_URL or not HA_TOKEN:
    print("ERROR: HOME_ASSISTANT_URL and HOME_ASSISTANT_TOKEN environment variables must be set.")
    print("These should be set when activating the Claude venv (~/.venvs/claude)")
    sys.exit(1)

HEADERS = {
    "Authorization": f"Bearer {HA_TOKEN}",
    "Content-Type": "application/json",
}


def api_get(endpoint):
    """Make GET request to HA API."""
    url = f"{HA_URL}/api/{endpoint}"
    response = requests.get(url, headers=HEADERS, timeout=30)
    response.raise_for_status()
    return response.json()


def api_post(endpoint, data=None):
    """Make POST request to HA API."""
    url = f"{HA_URL}/api/{endpoint}"
    response = requests.post(url, headers=HEADERS, json=data or {}, timeout=30)
    response.raise_for_status()
    return response.json() if response.text else {}


def get_states():
    """Get all entity states."""
    return api_get("states")


def get_state(entity_id):
    """Get state of a specific entity."""
    return api_get(f"states/{entity_id}")


def get_services():
    """Get all available services."""
    return api_get("services")


def call_service(domain, service, entity_id=None, data=None):
    """Call a Home Assistant service."""
    payload = data or {}
    if entity_id:
        payload["entity_id"] = entity_id
    return api_post(f"services/{domain}/{service}", payload)


def list_entities(domain_filter=None, area_filter=None):
    """List all entities, optionally filtered by domain or area."""
    states = get_states()
    entities = []

    for state in states:
        entity_id = state["entity_id"]
        domain = entity_id.split(".")[0]

        if domain_filter and domain != domain_filter:
            continue

        entities.append({
            "entity_id": entity_id,
            "state": state["state"],
            "friendly_name": state["attributes"].get("friendly_name", entity_id),
            "domain": domain,
        })

    # Sort by domain, then entity_id
    entities.sort(key=lambda x: (x["domain"], x["entity_id"]))
    return entities


def turn_on(entity_id):
    """Turn on an entity."""
    domain = entity_id.split(".")[0]
    return call_service(domain, "turn_on", entity_id)


def turn_off(entity_id):
    """Turn off an entity."""
    domain = entity_id.split(".")[0]
    return call_service(domain, "turn_off", entity_id)


def toggle(entity_id):
    """Toggle an entity."""
    domain = entity_id.split(".")[0]
    return call_service(domain, "toggle", entity_id)


def set_value(entity_id, value):
    """Set value for input entities (input_number, input_text, etc.)."""
    domain = entity_id.split(".")[0]

    if domain == "input_number":
        return call_service(domain, "set_value", entity_id, {"value": float(value)})
    elif domain == "input_text":
        return call_service(domain, "set_value", entity_id, {"value": str(value)})
    elif domain == "input_boolean":
        if value.lower() in ("true", "on", "1", "yes"):
            return turn_on(entity_id)
        else:
            return turn_off(entity_id)
    elif domain == "input_select":
        return call_service(domain, "select_option", entity_id, {"option": str(value)})
    elif domain == "light":
        # Assume value is brightness percentage
        return call_service(domain, "turn_on", entity_id, {"brightness_pct": int(value)})
    elif domain == "climate":
        return call_service(domain, "set_temperature", entity_id, {"temperature": float(value)})
    elif domain == "cover":
        return call_service(domain, "set_cover_position", entity_id, {"position": int(value)})
    else:
        print(f"Warning: set_value not implemented for domain '{domain}'", file=sys.stderr)
        return {}


def run_script(script_id):
    """Run a script."""
    if not script_id.startswith("script."):
        script_id = f"script.{script_id}"
    return call_service("script", "turn_on", script_id)


def run_scene(scene_id):
    """Activate a scene."""
    if not scene_id.startswith("scene."):
        scene_id = f"scene.{scene_id}"
    return call_service("scene", "turn_on", scene_id)


def send_notification(message, title=None, target="notify"):
    """Send a notification."""
    data = {"message": message}
    if title:
        data["title"] = title
    return call_service("notify", target, data=data)


def format_entities(entities, output_format="text"):
    """Format entities for display."""
    if output_format == "json":
        return json.dumps(entities, indent=2)

    if not entities:
        return "No entities found."

    lines = []
    current_domain = None

    for entity in entities:
        if entity["domain"] != current_domain:
            current_domain = entity["domain"]
            lines.append(f"\n## {current_domain}")

        state = entity["state"]
        name = entity["friendly_name"]
        eid = entity["entity_id"]

        # Color-code common states
        if state in ("on", "home", "open", "playing"):
            state_display = f"[ON] {state}"
        elif state in ("off", "away", "closed", "idle", "paused"):
            state_display = f"[--] {state}"
        elif state == "unavailable":
            state_display = "[??] unavailable"
        else:
            state_display = state

        lines.append(f"- {name}: {state_display}")
        lines.append(f"  `{eid}`")

    return "\n".join(lines)


def search_entities(query):
    """Search entities by name or ID."""
    query = query.lower()
    states = get_states()
    matches = []

    for state in states:
        entity_id = state["entity_id"]
        friendly_name = state["attributes"].get("friendly_name", "").lower()

        if query in entity_id.lower() or query in friendly_name:
            matches.append({
                "entity_id": entity_id,
                "state": state["state"],
                "friendly_name": state["attributes"].get("friendly_name", entity_id),
                "domain": entity_id.split(".")[0],
            })

    matches.sort(key=lambda x: (x["domain"], x["entity_id"]))
    return matches


def main():
    parser = argparse.ArgumentParser(description="Control Home Assistant")
    subparsers = parser.add_subparsers(dest="command", help="Command to run")

    # List command
    list_parser = subparsers.add_parser("list", help="List entities")
    list_parser.add_argument("--domain", "-d", help="Filter by domain (light, switch, sensor, etc.)")
    list_parser.add_argument("--json", action="store_true", help="Output as JSON")

    # Search command
    search_parser = subparsers.add_parser("search", help="Search entities")
    search_parser.add_argument("query", help="Search query")
    search_parser.add_argument("--json", action="store_true", help="Output as JSON")

    # State command
    state_parser = subparsers.add_parser("state", help="Get entity state")
    state_parser.add_argument("entity_id", help="Entity ID")
    state_parser.add_argument("--json", action="store_true", help="Output as JSON")

    # On command
    on_parser = subparsers.add_parser("on", help="Turn on entity")
    on_parser.add_argument("entity_id", help="Entity ID")

    # Off command
    off_parser = subparsers.add_parser("off", help="Turn off entity")
    off_parser.add_argument("entity_id", help="Entity ID")

    # Toggle command
    toggle_parser = subparsers.add_parser("toggle", help="Toggle entity")
    toggle_parser.add_argument("entity_id", help="Entity ID")

    # Set command
    set_parser = subparsers.add_parser("set", help="Set entity value")
    set_parser.add_argument("entity_id", help="Entity ID")
    set_parser.add_argument("value", help="Value to set")

    # Script command
    script_parser = subparsers.add_parser("script", help="Run a script")
    script_parser.add_argument("script_id", help="Script ID (with or without 'script.' prefix)")

    # Scene command
    scene_parser = subparsers.add_parser("scene", help="Activate a scene")
    scene_parser.add_argument("scene_id", help="Scene ID (with or without 'scene.' prefix)")

    # Service command
    service_parser = subparsers.add_parser("service", help="Call a service")
    service_parser.add_argument("domain", help="Service domain")
    service_parser.add_argument("service", help="Service name")
    service_parser.add_argument("--entity", "-e", help="Entity ID")
    service_parser.add_argument("--data", "-d", help="JSON data")

    # Services list command
    services_parser = subparsers.add_parser("services", help="List available services")
    services_parser.add_argument("--domain", "-d", help="Filter by domain")
    services_parser.add_argument("--json", action="store_true", help="Output as JSON")

    # Notify command
    notify_parser = subparsers.add_parser("notify", help="Send notification")
    notify_parser.add_argument("message", help="Notification message")
    notify_parser.add_argument("--title", "-t", help="Notification title")
    notify_parser.add_argument("--target", default="notify", help="Notification target (default: notify)")

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    try:
        if args.command == "list":
            entities = list_entities(domain_filter=args.domain)
            output_format = "json" if args.json else "text"
            print(format_entities(entities, output_format))

        elif args.command == "search":
            entities = search_entities(args.query)
            output_format = "json" if args.json else "text"
            print(format_entities(entities, output_format))

        elif args.command == "state":
            state = get_state(args.entity_id)
            if args.json:
                print(json.dumps(state, indent=2))
            else:
                print(f"Entity: {state['entity_id']}")
                print(f"State: {state['state']}")
                print(f"Name: {state['attributes'].get('friendly_name', 'N/A')}")
                if state['attributes']:
                    print("Attributes:")
                    for key, value in state['attributes'].items():
                        if key != 'friendly_name':
                            print(f"  {key}: {value}")

        elif args.command == "on":
            turn_on(args.entity_id)
            print(f"Turned on: {args.entity_id}")

        elif args.command == "off":
            turn_off(args.entity_id)
            print(f"Turned off: {args.entity_id}")

        elif args.command == "toggle":
            toggle(args.entity_id)
            print(f"Toggled: {args.entity_id}")

        elif args.command == "set":
            set_value(args.entity_id, args.value)
            print(f"Set {args.entity_id} to {args.value}")

        elif args.command == "script":
            run_script(args.script_id)
            print(f"Ran script: {args.script_id}")

        elif args.command == "scene":
            run_scene(args.scene_id)
            print(f"Activated scene: {args.scene_id}")

        elif args.command == "service":
            data = json.loads(args.data) if args.data else None
            call_service(args.domain, args.service, args.entity, data)
            print(f"Called {args.domain}.{args.service}")

        elif args.command == "services":
            services = get_services()
            if args.domain:
                services = [s for s in services if s["domain"] == args.domain]

            if args.json:
                print(json.dumps(services, indent=2))
            else:
                for svc in services:
                    print(f"\n## {svc['domain']}")
                    for name, info in svc["services"].items():
                        desc = info.get("description", "")
                        print(f"- {name}: {desc[:60]}...")

        elif args.command == "notify":
            send_notification(args.message, args.title, args.target)
            print(f"Sent notification: {args.message[:50]}...")

    except requests.exceptions.HTTPError as e:
        print(f"HTTP Error: {e}", file=sys.stderr)
        print(f"Response: {e.response.text}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
