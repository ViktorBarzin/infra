"""F1 Streams - FastAPI backend with schedule, stream extraction, health checking, and HLS proxy."""

import logging
from contextlib import asynccontextmanager

from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger
from apscheduler.triggers.interval import IntervalTrigger
from fastapi import FastAPI, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from starlette.responses import Response, StreamingResponse

from backend.extractors import create_extraction_service
from backend.proxy import proxy_playlist, relay_stream
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

# --- CORS Middleware ---
# Required for browser-based HLS players to access proxy/relay endpoints
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET", "OPTIONS"],
    allow_headers=["Range"],
    expose_headers=["Content-Range", "Content-Length", "Content-Type"],
)


# --- Health & Info ---


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/")
async def root():
    return {"service": "f1-streams", "version": "4.0.0"}


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
    """Return all currently cached streams that passed health checks.

    Streams are sorted by fallback priority:
    1. Live streams only (is_live=True)
    2. Fastest response time first (lowest response_time_ms)
    """
    streams = extraction_service.get_streams()
    return {
        "streams": streams,
        "count": len(streams),
    }


@app.get("/streams/all")
async def get_all_streams():
    """Return ALL cached streams including unhealthy ones (for debugging).

    Unlike GET /streams, this endpoint includes streams that failed health
    checks. Useful for diagnosing extraction or health check issues.
    """
    streams = extraction_service.get_all_streams_unfiltered()
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
        "live_streams": status["total_live_streams"],
        "extractors_run": len(status["extractors"]),
    }


# --- HLS Proxy ---


def _get_proxy_base(request: Request) -> str:
    """Derive the proxy base URL from the incoming request.

    Uses X-Forwarded-Proto and X-Forwarded-Host headers if present
    (behind a reverse proxy), otherwise falls back to request URL.
    """
    proto = request.headers.get("x-forwarded-proto", request.url.scheme)
    host = request.headers.get("x-forwarded-host", request.url.netloc)
    return f"{proto}://{host}"


@app.get("/proxy")
async def proxy_endpoint(
    request: Request,
    url: str = Query(..., description="Base64url-encoded m3u8 playlist URL"),
):
    """Proxy an upstream m3u8 playlist with URI rewriting.

    Fetches the upstream m3u8 playlist, rewrites all URIs to route through
    our /proxy (for sub-playlists) and /relay (for segments) endpoints,
    and returns the rewritten playlist.

    The `url` parameter must be base64url-encoded to avoid URL encoding issues.

    Example:
        GET /proxy?url=aHR0cHM6Ly9leGFtcGxlLmNvbS9zdHJlYW0ubTN1OA
    """
    proxy_base = _get_proxy_base(request)
    rewritten = await proxy_playlist(url, proxy_base)

    return Response(
        content=rewritten,
        media_type="application/vnd.apple.mpegurl",
        headers={
            "Cache-Control": "no-cache, no-store, must-revalidate",
        },
    )


@app.get("/relay")
async def relay_endpoint(
    request: Request,
    url: str = Query(..., description="Base64url-encoded segment URL"),
):
    """Relay an upstream media segment as a chunked byte stream.

    Fetches the upstream segment (TS, fMP4, init segment, etc.) and streams
    it to the client using chunked transfer encoding. Never buffers the
    full segment in memory.

    The `url` parameter must be base64url-encoded to avoid URL encoding issues.

    Supports HTTP Range requests for seeking.

    Example:
        GET /relay?url=aHR0cHM6Ly9leGFtcGxlLmNvbS9zZWdtZW50LnRz
    """
    range_header = request.headers.get("range")

    stream_gen, headers, status_code = await relay_stream(url, range_header)

    return StreamingResponse(
        stream_gen,
        status_code=status_code,
        headers=headers,
    )


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
