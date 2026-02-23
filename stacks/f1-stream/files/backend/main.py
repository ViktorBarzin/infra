"""F1 Streams - FastAPI backend with schedule service."""

import logging
from contextlib import asynccontextmanager

from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger
from fastapi import FastAPI

from backend.schedule import ScheduleService

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)

schedule_service = ScheduleService()
scheduler = AsyncIOScheduler()


async def _scheduled_refresh() -> None:
    """Callback for APScheduler daily refresh."""
    logger.info("Running scheduled schedule refresh...")
    await schedule_service.refresh()


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup and shutdown lifecycle handler."""
    # Startup: load schedule and start background scheduler
    await schedule_service.initialize()

    scheduler.add_job(
        _scheduled_refresh,
        trigger=CronTrigger(hour=3, minute=0, timezone="UTC"),
        id="daily_schedule_refresh",
        name="Refresh F1 schedule daily at 03:00 UTC",
        replace_existing=True,
    )
    scheduler.start()
    logger.info("APScheduler started - daily refresh at 03:00 UTC")

    yield

    # Shutdown
    scheduler.shutdown(wait=False)
    logger.info("APScheduler shut down")


app = FastAPI(title="F1 Streams", lifespan=lifespan)


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/")
async def root():
    return {"service": "f1-streams", "version": "2.0.1"}


@app.get("/schedule")
async def get_schedule():
    """Return the F1 race schedule for the current season with session statuses."""
    return schedule_service.get_schedule()


@app.post("/schedule/refresh")
async def refresh_schedule():
    """Manually trigger a schedule refresh from the jolpica API."""
    await schedule_service.refresh()
    return {"status": "refreshed"}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
