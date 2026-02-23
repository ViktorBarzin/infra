"""F1 Schedule Service - fetches, caches, and serves the F1 race calendar."""

import json
import logging
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import httpx

logger = logging.getLogger(__name__)

JOLPICA_API_URL = "https://api.jolpi.ca/ergast/f1/current.json"
SCHEDULE_PATH = Path(os.getenv("SCHEDULE_PATH", "/data/schedule.json"))
STALE_THRESHOLD = timedelta(hours=24)

# Typical session durations in minutes
SESSION_DURATIONS = {
    "fp1": 60,
    "fp2": 60,
    "fp3": 60,
    "qualifying": 60,
    "sprint_qualifying": 30,
    "sprint": 30,
    "race": 120,
}


def _parse_session_datetime(session: dict[str, str] | None) -> str | None:
    """Parse a session dict with 'date' and 'time' fields into an ISO 8601 UTC string."""
    if not session or "date" not in session or "time" not in session:
        return None
    # Time format from API: "14:30:00Z"
    time_str = session["time"].rstrip("Z")
    return f"{session['date']}T{time_str}+00:00"


def _parse_race(race: dict[str, Any]) -> dict[str, Any]:
    """Transform a raw jolpica/Ergast race object into our internal format."""
    circuit = race.get("Circuit", {})
    location = circuit.get("Location", {})

    # Build session list
    sessions = []

    # Map API keys to our session types, in chronological order for a race weekend
    session_map = [
        ("FirstPractice", "fp1", "FP1"),
        ("SecondPractice", "fp2", "FP2"),
        ("ThirdPractice", "fp3", "FP3"),
        ("SprintQualifying", "sprint_qualifying", "Sprint Qualifying"),
        ("SprintShootout", "sprint_qualifying", "Sprint Qualifying"),
        ("Sprint", "sprint", "Sprint"),
        ("Qualifying", "qualifying", "Qualifying"),
    ]

    seen_types = set()
    for api_key, session_type, display_name in session_map:
        if api_key in race and session_type not in seen_types:
            dt_str = _parse_session_datetime(race[api_key])
            if dt_str:
                sessions.append(
                    {
                        "type": session_type,
                        "name": display_name,
                        "start_utc": dt_str,
                        "duration_minutes": SESSION_DURATIONS.get(session_type, 60),
                    }
                )
                seen_types.add(session_type)

    # Race session itself (date and time are top-level)
    race_dt = _parse_session_datetime({"date": race.get("date", ""), "time": race.get("time", "")})
    if race_dt:
        sessions.append(
            {
                "type": "race",
                "name": "Race",
                "start_utc": race_dt,
                "duration_minutes": SESSION_DURATIONS["race"],
            }
        )

    # Sort sessions chronologically
    sessions.sort(key=lambda s: s["start_utc"])

    return {
        "round": int(race.get("round", 0)),
        "race_name": race.get("raceName", ""),
        "circuit": circuit.get("circuitName", ""),
        "circuit_id": circuit.get("circuitId", ""),
        "country": location.get("country", ""),
        "locality": location.get("locality", ""),
        "date": race.get("date", ""),
        "url": race.get("url", ""),
        "sessions": sessions,
    }


def _compute_session_status(session: dict[str, Any], now: datetime) -> str:
    """Determine if a session is 'past', 'live', or 'upcoming'."""
    try:
        start = datetime.fromisoformat(session["start_utc"])
    except (ValueError, KeyError):
        return "upcoming"

    duration = timedelta(minutes=session.get("duration_minutes", 60))
    end = start + duration

    if now >= end:
        return "past"
    elif now >= start:
        return "live"
    else:
        return "upcoming"


class ScheduleService:
    """Manages the F1 schedule: fetching, caching, and serving."""

    def __init__(self) -> None:
        self._schedule: dict[str, Any] | None = None

    async def fetch_schedule(self) -> dict[str, Any]:
        """Fetch the current season schedule from the jolpica API."""
        logger.info("Fetching F1 schedule from jolpica API...")
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.get(JOLPICA_API_URL)
            response.raise_for_status()
            data = response.json()

        race_table = data.get("MRData", {}).get("RaceTable", {})
        season = race_table.get("season", "")
        raw_races = race_table.get("Races", [])

        races = [_parse_race(r) for r in raw_races]

        schedule = {
            "season": season,
            "fetched_at": datetime.now(timezone.utc).isoformat(),
            "races": races,
        }

        self._schedule = schedule
        logger.info("Fetched schedule for %s season: %d races", season, len(races))
        return schedule

    def load_from_disk(self) -> bool:
        """Load schedule from NFS-backed JSON file. Returns True if loaded successfully."""
        if not SCHEDULE_PATH.exists():
            logger.info("No cached schedule found at %s", SCHEDULE_PATH)
            return False

        try:
            with open(SCHEDULE_PATH, "r") as f:
                self._schedule = json.load(f)
            logger.info("Loaded cached schedule from %s", SCHEDULE_PATH)
            return True
        except (json.JSONDecodeError, OSError) as e:
            logger.warning("Failed to load cached schedule: %s", e)
            return False

    def save_to_disk(self) -> None:
        """Persist current schedule to NFS-backed JSON file."""
        if not self._schedule:
            logger.warning("No schedule data to save")
            return

        try:
            SCHEDULE_PATH.parent.mkdir(parents=True, exist_ok=True)
            with open(SCHEDULE_PATH, "w") as f:
                json.dump(self._schedule, f, indent=2)
            logger.info("Saved schedule to %s", SCHEDULE_PATH)
        except OSError as e:
            logger.error("Failed to save schedule to disk: %s", e)

    def is_stale(self) -> bool:
        """Check if the cached schedule data is older than the stale threshold."""
        if not self._schedule:
            return True

        fetched_at_str = self._schedule.get("fetched_at")
        if not fetched_at_str:
            return True

        try:
            fetched_at = datetime.fromisoformat(fetched_at_str)
            return datetime.now(timezone.utc) - fetched_at > STALE_THRESHOLD
        except ValueError:
            return True

    def get_schedule(self) -> dict[str, Any]:
        """Return the current schedule with computed session statuses."""
        if not self._schedule:
            return {"season": "", "races": [], "error": "No schedule data available"}

        now = datetime.now(timezone.utc)
        races = []

        for race in self._schedule.get("races", []):
            sessions = []
            for session in race.get("sessions", []):
                sessions.append(
                    {
                        **session,
                        "status": _compute_session_status(session, now),
                    }
                )

            races.append(
                {
                    **race,
                    "sessions": sessions,
                }
            )

        return {
            "season": self._schedule.get("season", ""),
            "fetched_at": self._schedule.get("fetched_at", ""),
            "races": races,
        }

    async def refresh(self) -> None:
        """Fetch fresh schedule and persist to disk. Falls back to cached data on error."""
        try:
            await self.fetch_schedule()
            self.save_to_disk()
        except httpx.HTTPError as e:
            logger.error("Failed to refresh schedule from API: %s", e)
            if not self._schedule:
                logger.warning("No cached data available either - schedule will be empty")
        except Exception:
            logger.exception("Unexpected error during schedule refresh")

    async def initialize(self) -> None:
        """Load from disk on startup and refresh if stale."""
        self.load_from_disk()
        if self.is_stale():
            await self.refresh()
