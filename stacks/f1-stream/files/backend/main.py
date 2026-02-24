"""F1 Streams - FastAPI backend with schedule, stream extraction, health checking, HLS proxy, and token refresh."""

import logging
import os
from contextlib import asynccontextmanager

from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger
from apscheduler.triggers.interval import IntervalTrigger
from fastapi import FastAPI, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from starlette.responses import Response, StreamingResponse

from backend.extractors import create_extraction_service
from backend.proxy import proxy_playlist, relay_stream
from backend.schedule import ScheduleService
from backend.token_refresh import TokenRefreshManager

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)

schedule_service = ScheduleService()
extraction_service = create_extraction_service()
token_refresh_manager = TokenRefreshManager(extraction_service)
scheduler = AsyncIOScheduler()


# --- Pydantic models for request bodies ---


class ActivateStreamRequest(BaseModel):
    """Request body for POST /streams/activate."""

    url: str
    site_key: str = ""


class DeactivateStreamRequest(BaseModel):
    """Request body for POST /streams/deactivate."""

    url: str


# --- Scheduled callbacks ---


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


async def _scheduled_token_refresh() -> None:
    """Callback for APScheduler token refresh.

    Only performs work when there are active streams. Re-runs extractors
    to get fresh CDN tokens for streams being actively watched.
    """
    if not token_refresh_manager.has_active_streams:
        return

    logger.info("Running scheduled token refresh...")
    try:
        await token_refresh_manager.refresh_active_streams()
    except Exception:
        logger.exception("Token refresh failed (non-fatal)")


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

    # Schedule token refresh every 4 minutes (safe margin for 5-min CDN tokens).
    # The callback is a no-op when there are no active streams.
    scheduler.add_job(
        _scheduled_token_refresh,
        trigger=IntervalTrigger(minutes=4),
        id="token_refresh",
        name="Refresh CDN tokens for active streams",
        replace_existing=True,
    )

    scheduler.start()
    logger.info(
        "APScheduler started - schedule refresh at 03:00 UTC, extraction every 30m, token refresh every 4m"
    )

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
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["Range", "Content-Type"],
    expose_headers=["Content-Range", "Content-Length", "Content-Type"],
)


# --- Health & Info ---


@app.get("/health")
async def health():
    return {"status": "ok"}


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


@app.post("/streams/activate")
async def activate_stream(body: ActivateStreamRequest):
    """Mark a stream as actively being watched.

    When a stream is active, the token refresh manager will periodically
    re-run the extractor that found it to get fresh CDN tokens before
    they expire.

    If site_key is not provided, attempts to look it up from the cached
    streams.

    Body:
        {"url": "https://...", "site_key": "optional-site-key"}
    """
    url = body.url
    site_key = body.site_key

    # If site_key not provided, try to look it up from cached streams
    if not site_key:
        for streams in extraction_service._cache.values():
            for stream in streams:
                if stream.url == url:
                    site_key = stream.site_key
                    break
            if site_key:
                break

    if not site_key:
        return {
            "status": "error",
            "detail": "Could not determine site_key for this URL. Provide it explicitly.",
        }

    token_refresh_manager.mark_stream_active(url, site_key)
    return {
        "status": "activated",
        "url": url,
        "site_key": site_key,
        "active_count": len(token_refresh_manager.get_active_streams()),
    }


@app.post("/streams/deactivate")
async def deactivate_stream(body: DeactivateStreamRequest):
    """Mark a stream as no longer being watched.

    Stops the token refresh manager from refreshing CDN tokens for this stream.

    Body:
        {"url": "https://..."}
    """
    token_refresh_manager.mark_stream_inactive(body.url)
    return {
        "status": "deactivated",
        "url": body.url,
        "active_count": len(token_refresh_manager.get_active_streams()),
    }


@app.get("/streams/active")
async def get_active_streams():
    """List currently active streams with their refresh status.

    Returns all streams that are being actively watched, including
    their current (potentially refreshed) URLs and refresh counts.
    """
    active = token_refresh_manager.get_active_streams()
    return {
        "streams": active,
        "count": len(active),
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
    quality: int | None = Query(
        None,
        description="0-based quality variant index (0=highest bandwidth). "
        "Only applies to master playlists.",
    ),
):
    """Proxy an upstream m3u8 playlist with URI rewriting.

    Fetches the upstream m3u8 playlist, rewrites all URIs to route through
    our /proxy (for sub-playlists) and /relay (for segments) endpoints,
    and returns the rewritten playlist.

    The `url` parameter must be base64url-encoded to avoid URL encoding issues.

    If `quality` is specified and the upstream is a master playlist (with
    multiple quality variants), the proxy will fetch the selected variant's
    media playlist directly instead of returning the master playlist.
    Quality index 0 = highest bandwidth, 1 = second highest, etc.

    Examples:
        GET /proxy?url=aHR0cHM6Ly9leGFtcGxlLmNvbS9zdHJlYW0ubTN1OA
        GET /proxy?url=aHR0cHM6Ly9leGFtcGxlLmNvbS9zdHJlYW0ubTN1OA&quality=0
    """
    # Check if we have a fresher URL from token refresh
    fresh_url = token_refresh_manager.get_fresh_url(url)
    if fresh_url != url:
        logger.info("Using refreshed URL from token manager")

    proxy_base = _get_proxy_base(request)
    rewritten = await proxy_playlist(fresh_url, proxy_base, quality=quality)

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


# --- Frontend Static Files ---
# Mount the SvelteKit static build AFTER all API routes so API endpoints take priority.
# SvelteKit adapter-static with ssr=false produces {page}.html files and a fallback index.html.
# Starlette StaticFiles(html=True) only checks {path}/index.html, not {path}.html.
# We use a catch-all route to handle both patterns and the SPA fallback.
_frontend_dir = os.path.realpath(os.path.join(os.path.dirname(__file__), "..", "frontend", "build"))
if os.path.exists(_frontend_dir):
    from starlette.responses import FileResponse, HTMLResponse

    _fallback_path = os.path.join(_frontend_dir, "index.html")

    @app.get("/{path:path}")
    async def serve_frontend(path: str):
        """Serve SvelteKit frontend files with SPA fallback."""
        for candidate in [
            os.path.join(_frontend_dir, path),
            os.path.join(_frontend_dir, f"{path}.html"),
            os.path.join(_frontend_dir, path, "index.html"),
        ]:
            real = os.path.realpath(candidate)
            if real.startswith(_frontend_dir) and os.path.isfile(real):
                return FileResponse(real)
        # SPA fallback for client-side routing
        if os.path.isfile(_fallback_path):
            return FileResponse(_fallback_path)
        return Response(content="Not Found", status_code=404)

    logger.info("Serving frontend from %s", _frontend_dir)
else:
    # Fallback root when no frontend build exists
    @app.get("/")
    async def root():
        return {"service": "f1-streams", "version": "5.0.0"}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
