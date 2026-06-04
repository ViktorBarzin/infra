"""Token refresh manager - keeps CDN tokens fresh for active streams.

CDN tokens embedded in stream URLs expire after 5-30 minutes. During a 2+ hour
F1 session, URLs must be refreshed before they expire. This manager periodically
re-runs the extractor that found each active stream to get a fresh URL with a
new CDN token.

Usage:
    1. When a user starts watching, call mark_stream_active(url, site_key)
    2. The background scheduler calls refresh_active_streams() every 4 minutes
    3. The proxy calls get_fresh_url(url) to resolve the latest URL
    4. When the user stops watching, call mark_stream_inactive(url)
"""

import logging
from dataclasses import dataclass
from datetime import datetime, timezone

logger = logging.getLogger(__name__)


@dataclass
class ActiveStream:
    """Tracks a stream that a user is currently watching.

    The original_url is the URL the user initially activated. After a token
    refresh, current_url may differ (new CDN token, different edge server, etc.)
    but the original_url remains the key for lookups.
    """

    original_url: str
    current_url: str  # May differ from original after refresh
    site_key: str
    last_refreshed: str
    refresh_count: int = 0
    last_error: str = ""

    def to_dict(self) -> dict:
        """Serialize to a plain dictionary for JSON responses."""
        return {
            "original_url": self.original_url,
            "current_url": self.current_url,
            "site_key": self.site_key,
            "last_refreshed": self.last_refreshed,
            "refresh_count": self.refresh_count,
            "last_error": self.last_error,
        }


class TokenRefreshManager:
    """Manages background token refresh for active streams.

    When a user is watching a stream, the manager periodically re-runs
    the extractor that found it to get a fresh URL with a new token.
    The fresh URL is stored so the /proxy endpoint can use it on the
    next playlist fetch.
    """

    def __init__(self, extraction_service) -> None:
        """Initialize the token refresh manager.

        Args:
            extraction_service: The ExtractionService instance used to
                re-run extractors and look up streams by site_key.
        """
        # Import here to avoid circular imports at module level
        from backend.extractors.service import ExtractionService

        self._extraction_service: ExtractionService = extraction_service
        self._active_streams: dict[str, ActiveStream] = {}
        self._refresh_interval = 240  # 4 minutes (safe margin for 5-min tokens)

    @property
    def refresh_interval(self) -> int:
        """Refresh interval in seconds."""
        return self._refresh_interval

    @property
    def has_active_streams(self) -> bool:
        """Whether there are any active streams being watched."""
        return len(self._active_streams) > 0

    def mark_stream_active(self, url: str, site_key: str) -> None:
        """Mark a stream as being actively watched.

        If the stream is already active, this is a no-op (idempotent).

        Args:
            url: The stream URL the user is watching.
            site_key: The extractor site_key that found this stream.
        """
        if url in self._active_streams:
            logger.debug("Stream already active: %s", url)
            return

        now = datetime.now(timezone.utc).isoformat()
        self._active_streams[url] = ActiveStream(
            original_url=url,
            current_url=url,
            site_key=site_key,
            last_refreshed=now,
        )
        logger.info(
            "Stream marked active: %s (site_key=%s, total_active=%d)",
            url,
            site_key,
            len(self._active_streams),
        )

    def mark_stream_inactive(self, url: str) -> None:
        """Mark a stream as no longer watched.

        If the stream is not active, this is a no-op.

        Args:
            url: The original stream URL to deactivate.
        """
        removed = self._active_streams.pop(url, None)
        if removed:
            logger.info(
                "Stream marked inactive: %s (was refreshed %d times, total_active=%d)",
                url,
                removed.refresh_count,
                len(self._active_streams),
            )
        else:
            logger.debug("Stream was not active, nothing to deactivate: %s", url)

    async def refresh_active_streams(self) -> None:
        """Re-run extractors for all active streams to get fresh URLs.

        For each active stream, re-runs the extractor that originally found it
        and tries to match the stream in the new results. If a match is found,
        updates the current_url. If not, the previous URL is kept (it may still
        work until its token expires).

        This method is called by the background scheduler every 4 minutes.
        Token refresh failures are logged but never crash the process.
        """
        if not self._active_streams:
            logger.debug("No active streams to refresh")
            return

        logger.info(
            "Refreshing tokens for %d active stream(s)...",
            len(self._active_streams),
        )

        # Group active streams by site_key to avoid re-running the same
        # extractor multiple times
        streams_by_site: dict[str, list[ActiveStream]] = {}
        for stream in self._active_streams.values():
            streams_by_site.setdefault(stream.site_key, []).append(stream)

        now = datetime.now(timezone.utc).isoformat()

        for site_key, active_list in streams_by_site.items():
            try:
                await self._refresh_site(site_key, active_list, now)
            except Exception:
                logger.exception(
                    "Failed to refresh tokens for site_key=%s", site_key
                )
                # Mark the error on all streams from this site
                for stream in active_list:
                    stream.last_error = f"Refresh failed at {now}"

    async def _refresh_site(
        self, site_key: str, active_list: list[ActiveStream], now: str
    ) -> None:
        """Re-run a single extractor and update active streams from its results.

        Args:
            site_key: The extractor's site_key.
            active_list: List of ActiveStream objects from this extractor.
            now: ISO timestamp for this refresh cycle.
        """
        registry = self._extraction_service._registry
        extractor = registry.get(site_key)

        if extractor is None:
            logger.warning(
                "Extractor '%s' not found in registry, skipping refresh",
                site_key,
            )
            for stream in active_list:
                stream.last_error = f"Extractor '{site_key}' not found"
            return

        logger.info(
            "Re-running extractor '%s' for token refresh (%d active stream(s))",
            site_key,
            len(active_list),
        )

        # Re-run the extractor to get fresh URLs
        try:
            fresh_streams = await extractor.extract()
        except Exception as e:
            logger.error(
                "Extractor '%s' failed during token refresh: %s", site_key, e
            )
            for stream in active_list:
                stream.last_error = f"Extraction failed: {e}"
            return

        if not fresh_streams:
            logger.warning(
                "Extractor '%s' returned no streams during token refresh",
                site_key,
            )
            for stream in active_list:
                stream.last_error = "Extractor returned no streams"
            return

        # Build a lookup of fresh URLs by quality+title for matching
        # Since the URL itself changes (new token), we match by metadata
        fresh_by_key: dict[str, str] = {}
        for fs in fresh_streams:
            # Use quality+title as a matching key (these stay the same across refreshes)
            match_key = f"{fs.quality}|{fs.title}"
            fresh_by_key[match_key] = fs.url

        # Also keep all fresh URLs for fallback matching
        all_fresh_urls = [fs.url for fs in fresh_streams]

        for stream in active_list:
            # Try to find the matching stream in fresh results
            # Strategy 1: Match by quality+title
            match_key = self._build_match_key(stream)
            if match_key and match_key in fresh_by_key:
                new_url = fresh_by_key[match_key]
                if new_url != stream.current_url:
                    logger.info(
                        "Token refreshed for stream (quality+title match): %s -> %s",
                        stream.current_url[:80],
                        new_url[:80],
                    )
                    stream.current_url = new_url
                stream.last_refreshed = now
                stream.refresh_count += 1
                stream.last_error = ""
                continue

            # Strategy 2: Match by URL path similarity (ignoring query params / tokens)
            matched_url = self._find_url_by_path(stream.current_url, all_fresh_urls)
            if matched_url:
                if matched_url != stream.current_url:
                    logger.info(
                        "Token refreshed for stream (path match): %s -> %s",
                        stream.current_url[:80],
                        matched_url[:80],
                    )
                    stream.current_url = matched_url
                stream.last_refreshed = now
                stream.refresh_count += 1
                stream.last_error = ""
                continue

            # Strategy 3: If only one fresh stream, assume it's the same
            if len(all_fresh_urls) == 1:
                new_url = all_fresh_urls[0]
                if new_url != stream.current_url:
                    logger.info(
                        "Token refreshed for stream (single result fallback): %s -> %s",
                        stream.current_url[:80],
                        new_url[:80],
                    )
                    stream.current_url = new_url
                stream.last_refreshed = now
                stream.refresh_count += 1
                stream.last_error = ""
                continue

            # No match found - keep the old URL and log
            logger.warning(
                "Could not match active stream to fresh results: %s",
                stream.original_url[:80],
            )
            stream.last_error = "No matching stream in fresh results"

    def _build_match_key(self, stream: ActiveStream) -> str:
        """Build a match key from cached stream metadata.

        Looks up the stream in the extraction service cache to get
        quality and title metadata for matching.

        Returns:
            A match key string, or empty string if metadata not found.
        """
        # Look up the stream in the extraction cache
        cached_streams = self._extraction_service._cache.get(stream.site_key, [])
        for cs in cached_streams:
            if cs.url == stream.current_url or cs.url == stream.original_url:
                return f"{cs.quality}|{cs.title}"
        return ""

    @staticmethod
    def _find_url_by_path(current_url: str, fresh_urls: list[str]) -> str | None:
        """Find a fresh URL that matches the current URL by path (ignoring query params).

        CDN token refreshes typically change query parameters but keep the
        same path structure. This matcher strips query params and compares
        the path component.

        Args:
            current_url: The current (possibly expired) URL.
            fresh_urls: List of fresh URLs to match against.

        Returns:
            The matching fresh URL, or None if no match.
        """
        from urllib.parse import urlparse

        current_parsed = urlparse(current_url)
        current_path = current_parsed.path

        for fresh_url in fresh_urls:
            fresh_parsed = urlparse(fresh_url)
            # Match on host + path (token is typically in query string)
            if (
                fresh_parsed.netloc == current_parsed.netloc
                and fresh_parsed.path == current_path
            ):
                return fresh_url

        return None

    def get_fresh_url(self, original_url: str) -> str:
        """Get the latest URL for a stream (may have changed due to token refresh).

        If the stream is not active or has not been refreshed, returns the
        original URL unchanged.

        Args:
            original_url: The URL to look up (can be the original or any
                previous current_url).

        Returns:
            The most recent URL for this stream.
        """
        # Direct lookup by original URL
        stream = self._active_streams.get(original_url)
        if stream:
            return stream.current_url

        # Also check if the URL matches any current_url (in case the caller
        # is using an intermediate refreshed URL)
        for stream in self._active_streams.values():
            if stream.current_url == original_url:
                return stream.current_url

        # Not an active stream - return as-is
        return original_url

    def get_active_streams(self) -> list[dict]:
        """Return all active streams with their refresh status.

        Returns:
            List of serialized ActiveStream dicts.
        """
        return [stream.to_dict() for stream in self._active_streams.values()]
