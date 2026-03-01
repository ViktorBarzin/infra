"""Extraction service - manages extraction lifecycle: polling, caching, health checking, serving."""

import logging
from datetime import datetime, timezone

from backend.extractors.models import ExtractedStream
from backend.extractors.registry import ExtractorRegistry
from backend.health import StreamHealthChecker

logger = logging.getLogger(__name__)


class ExtractionService:
    """Manages the extraction lifecycle: polling, caching, health checking, and serving.

    Extraction runs on a background schedule (via APScheduler), never on
    client request path. After extraction, health checks verify each stream
    is live. Results are cached in memory, keyed by site_key.

    GET /streams only returns streams that passed health checks, sorted by:
    1. is_live (live streams first)
    2. response_time_ms (fastest first)
    """

    def __init__(self, registry: ExtractorRegistry) -> None:
        self._registry = registry
        # Cache: site_key -> list of ExtractedStream
        self._cache: dict[str, list[ExtractedStream]] = {}
        self._last_run: str | None = None
        self._last_run_stream_count: int = 0
        self._health_checker = StreamHealthChecker()

    async def run_extraction(self) -> None:
        """Run all extractors, health-check results, and cache them.

        This is called by the background scheduler. Each extractor's
        results replace its previous cache entry entirely. After extraction,
        health checks are run to verify streams are live and measure
        response times.
        """
        logger.info("Starting extraction run...")
        start = datetime.now(timezone.utc)

        streams = await self._registry.extract_all()

        # Run health checks on all extracted streams
        if streams:
            # Separate m3u8 streams (need health check) from embed streams (skip)
            m3u8_streams = [s for s in streams if s.stream_type != "embed"]
            embed_streams = [s for s in streams if s.stream_type == "embed"]

            # Mark embed streams as live (no health check possible for iframes)
            for stream in embed_streams:
                stream.is_live = True
                stream.response_time_ms = 0
                stream.checked_at = start.isoformat()

            # Health-check only m3u8 streams
            if m3u8_streams:
                stream_dicts = [s.to_dict() for s in m3u8_streams]
                health_map = await self._health_checker.check_all(stream_dicts)

                for stream in m3u8_streams:
                    health = health_map.get(stream.url)
                    if health:
                        stream.is_live = health.is_live
                        stream.response_time_ms = health.response_time_ms
                        stream.checked_at = health.checked_at
                        if health.bitrate > 0:
                            stream.bitrate = health.bitrate

        # Group streams by site_key and update cache
        new_cache: dict[str, list[ExtractedStream]] = {}
        for stream in streams:
            new_cache.setdefault(stream.site_key, []).append(stream)

        # Replace cache for extractors that returned results.
        # Clear cache for extractors that returned nothing (site went down, etc.)
        for extractor_info in self._registry.list_extractors():
            key = extractor_info["site_key"]
            if key in new_cache:
                self._cache[key] = new_cache[key]
            else:
                # Extractor returned nothing - clear its cache
                self._cache.pop(key, None)

        self._last_run = start.isoformat()
        self._last_run_stream_count = len(streams)

        live_count = sum(
            1 for streams_list in self._cache.values()
            for s in streams_list if s.is_live
        )
        elapsed = (datetime.now(timezone.utc) - start).total_seconds()
        logger.info(
            "Extraction run complete: %d stream(s) from %d extractor(s) in %.1fs (%d live)",
            len(streams),
            len(new_cache),
            elapsed,
            live_count,
        )

    def get_streams(self) -> list[dict]:
        """Return all cached streams as a sorted list of dicts.

        Only returns streams that passed health checks (is_live=True).
        Sorted by fallback priority:
        1. is_live (live streams first) - filters to live only
        2. response_time_ms (fastest first)

        Returns:
            List of serialized ExtractedStream dicts from all extractors,
            filtered to live-only and sorted by response time.
        """
        all_streams: list[ExtractedStream] = []
        for streams in self._cache.values():
            all_streams.extend(streams)

        # Sort by fallback priority: live first, then fastest response
        all_streams.sort(
            key=lambda s: (not s.is_live, s.response_time_ms)
        )

        # Only return live streams to clients
        live_streams = [s for s in all_streams if s.is_live]
        return [s.to_dict() for s in live_streams]

    def get_all_streams_unfiltered(self) -> list[dict]:
        """Return ALL cached streams including unhealthy ones.

        Used for debugging and status endpoints. Sorted by fallback priority
        but includes streams that failed health checks.

        Returns:
            List of all serialized ExtractedStream dicts.
        """
        all_streams: list[ExtractedStream] = []
        for streams in self._cache.values():
            all_streams.extend(streams)

        # Sort by fallback priority: live first, then fastest response
        all_streams.sort(
            key=lambda s: (not s.is_live, s.response_time_ms)
        )

        return [s.to_dict() for s in all_streams]

    def get_streams_for_session(self, session_type: str) -> list[dict]:
        """Return cached streams filtered/annotated for a specific session type.

        Currently returns all live streams (extractors don't yet differentiate by
        session type). This method exists as a hook for future filtering,
        e.g., some extractors might only have race streams but not FP streams.

        Args:
            session_type: The F1 session type (e.g., "race", "qualifying", "fp1").

        Returns:
            List of serialized ExtractedStream dicts (live only, sorted).
        """
        # For now, all streams are potentially relevant to any session.
        # Future extractors may tag streams with session types, at which
        # point this method will filter accordingly.
        streams = self.get_streams()
        logger.debug(
            "Returning %d stream(s) for session type '%s'",
            len(streams),
            session_type,
        )
        return streams

    def get_status(self) -> dict:
        """Return extraction service status for the /extractors endpoint."""
        extractor_list = self._registry.list_extractors()
        extractor_statuses = []

        for info in extractor_list:
            key = info["site_key"]
            cached = self._cache.get(key, [])
            live_count = sum(1 for s in cached if s.is_live)
            extractor_statuses.append(
                {
                    "site_key": key,
                    "site_name": info["site_name"],
                    "cached_streams": len(cached),
                    "live_streams": live_count,
                }
            )

        total_cached = sum(len(streams) for streams in self._cache.values())
        total_live = sum(
            1 for streams in self._cache.values()
            for s in streams if s.is_live
        )

        return {
            "extractors": extractor_statuses,
            "total_cached_streams": total_cached,
            "total_live_streams": total_live,
            "last_run": self._last_run,
            "last_run_stream_count": self._last_run_stream_count,
        }
