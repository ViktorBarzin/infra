"""F1 Streams - FastAPI backend with schedule and stream extraction services."""

import logging
from contextlib import asynccontextmanager

from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger
from apscheduler.triggers.interval import IntervalTrigger
from fastapi import FastAPI

from backend.extractors import create_extraction_service
from backend.schedule import ScheduleService

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)

schedule_service = ScheduleService()
extraction_service = create_extraction_service()
scheduler = AsyncIOScheduler()


async def _scheduled_refresh() -> None:
    """Callback for APScheduler daily schedule refresh."""
    logger.info("Running scheduled schedule refresh...")
    await schedule_service.refresh()


async def _scheduled_extraction() -> None:
    """Callback for APScheduler stream extraction.

    Adjusts its own interval based on whether a session is currently live:
    - During a live session: reschedule to every 5 minutes
    - Otherwise: reschedule to every 30 minutes
    """
    logger.info("Running scheduled extraction...")
    await extraction_service.run_extraction()

    # Check if any session is currently live and adjust polling interval
    schedule_data = schedule_service.get_schedule()
    is_live = False
    for race in schedule_data.get("races", []):
        for session in race.get("sessions", []):
            if session.get("status") == "live":
                is_live = True
                break
        if is_live:
            break

    # Update the extraction job interval based on live status
    job = scheduler.get_job("stream_extraction")
    if job:
        current_interval = getattr(job.trigger, "interval_length", None)
        desired_interval = 300 if is_live else 1800  # 5 min or 30 min

        if current_interval != desired_interval:
            interval_minutes = 5 if is_live else 30
            scheduler.reschedule_job(
                "stream_extraction",
                trigger=IntervalTrigger(minutes=interval_minutes),
            )
            logger.info(
                "Extraction interval adjusted to %d minutes (live=%s)",
                interval_minutes,
                is_live,
            )


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup and shutdown lifecycle handler."""
    # Startup: load schedule and start background scheduler
    await schedule_service.initialize()

    # Run initial extraction
    logger.info("Running initial stream extraction...")
    await extraction_service.run_extraction()

    # Schedule daily schedule refresh
    scheduler.add_job(
        _scheduled_refresh,
        trigger=CronTrigger(hour=3, minute=0, timezone="UTC"),
        id="daily_schedule_refresh",
        name="Refresh F1 schedule daily at 03:00 UTC",
        replace_existing=True,
    )

    # Schedule periodic stream extraction (default: every 30 minutes)
    scheduler.add_job(
        _scheduled_extraction,
        trigger=IntervalTrigger(minutes=30),
        id="stream_extraction",
        name="Extract streams from all registered sites",
        replace_existing=True,
    )

    scheduler.start()
    logger.info("APScheduler started - schedule refresh at 03:00 UTC, extraction every 30m")

    yield

    # Shutdown
    scheduler.shutdown(wait=False)
    logger.info("APScheduler shut down")


app = FastAPI(title="F1 Streams", lifespan=lifespan)


# --- Health & Info ---


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/")
async def root():
    return {"service": "f1-streams", "version": "3.0.0"}


# --- Schedule ---


@app.get("/schedule")
async def get_schedule():
    """Return the F1 race schedule for the current season with session statuses."""
    return schedule_service.get_schedule()


@app.post("/schedule/refresh")
async def refresh_schedule():
    """Manually trigger a schedule refresh from the jolpica API."""
    await schedule_service.refresh()
    return {"status": "refreshed"}


# --- Streams & Extraction ---


@app.get("/streams")
async def get_streams():
    """Return all currently cached streams from all extractors."""
    streams = extraction_service.get_streams()
    return {
        "streams": streams,
        "count": len(streams),
    }


@app.get("/extractors")
async def get_extractors():
    """List registered extractors and their current status."""
    return extraction_service.get_status()


@app.post("/extract")
async def trigger_extraction():
    """Manually trigger an extraction run across all registered extractors."""
    await extraction_service.run_extraction()
    status = extraction_service.get_status()
    return {
        "status": "extraction_complete",
        "streams_found": status["total_cached_streams"],
        "extractors_run": len(status["extractors"]),
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
