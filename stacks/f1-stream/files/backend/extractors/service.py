"""Extraction service - manages extraction lifecycle: polling, caching, serving."""

import logging
from datetime import datetime, timezone

from backend.extractors.models import ExtractedStream
from backend.extractors.registry import ExtractorRegistry

logger = logging.getLogger(__name__)


class ExtractionService:
    """Manages the extraction lifecycle: polling, caching, and serving results.

    Extraction runs on a background schedule (via APScheduler), never on
    client request path. Results are cached in memory, keyed by site_key.
    """

    def __init__(self, registry: ExtractorRegistry) -> None:
        self._registry = registry
        # Cache: site_key -> list of ExtractedStream
        self._cache: dict[str, list[ExtractedStream]] = {}
        self._last_run: str | None = None
        self._last_run_stream_count: int = 0

    async def run_extraction(self) -> None:
        """Run all extractors and cache their results.

        This is called by the background scheduler. Each extractor's
        results replace its previous cache entry entirely.
        """
        logger.info("Starting extraction run...")
        start = datetime.now(timezone.utc)

        streams = await self._registry.extract_all()

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

        elapsed = (datetime.now(timezone.utc) - start).total_seconds()
        logger.info(
            "Extraction run complete: %d stream(s) from %d extractor(s) in %.1fs",
            len(streams),
            len(new_cache),
            elapsed,
        )

    def get_streams(self) -> list[dict]:
        """Return all cached streams as a flat list of dicts.

        Returns:
            List of serialized ExtractedStream dicts from all extractors.
        """
        all_streams: list[dict] = []
        for streams in self._cache.values():
            all_streams.extend(s.to_dict() for s in streams)
        return all_streams

    def get_streams_for_session(self, session_type: str) -> list[dict]:
        """Return cached streams filtered/annotated for a specific session type.

        Currently returns all streams (extractors don't yet differentiate by
        session type). This method exists as a hook for future filtering,
        e.g., some extractors might only have race streams but not FP streams.

        Args:
            session_type: The F1 session type (e.g., "race", "qualifying", "fp1").

        Returns:
            List of serialized ExtractedStream dicts.
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
            extractor_statuses.append(
                {
                    "site_key": key,
                    "site_name": info["site_name"],
                    "cached_streams": len(cached),
                }
            )

        return {
            "extractors": extractor_statuses,
            "total_cached_streams": sum(
                len(streams) for streams in self._cache.values()
            ),
            "last_run": self._last_run,
            "last_run_stream_count": self._last_run_stream_count,
        }
