"""Stream health checker - verifies extracted streams are live and responsive.

Performs GET requests against m3u8 URLs to verify they contain valid HLS
playlists (#EXTM3U header), measures response times for quality ranking,
and supports concurrent checking of multiple streams.
"""

import asyncio
import logging
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from urllib.parse import urljoin

import httpx

logger = logging.getLogger(__name__)

# How long to wait for a single health check (seconds)
HEALTH_CHECK_TIMEOUT = 10.0

# Maximum bytes to read when verifying m3u8 content
# We only need to see the #EXTM3U header and a few lines
MAX_CONTENT_BYTES = 8192

# User-Agent to send with health check requests
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/120.0.0.0 Safari/537.36"
)


@dataclass
class StreamHealth:
    """Result of a single stream health check."""

    url: str
    is_live: bool
    response_time_ms: int  # Lower = better quality indicator
    checked_at: str = field(
        default_factory=lambda: datetime.now(timezone.utc).isoformat()
    )
    error: str = ""  # Error message if not live
    bitrate: int = 0  # Bitrate in bps if detectable from playlist

    def to_dict(self) -> dict:
        """Serialize to a plain dictionary for JSON responses."""
        return {
            "url": self.url,
            "is_live": self.is_live,
            "response_time_ms": self.response_time_ms,
            "checked_at": self.checked_at,
            "error": self.error,
            "bitrate": self.bitrate,
        }


def _extract_bitrate(content: str) -> int:
    """Try to extract bitrate from m3u8 playlist content.

    Looks for BANDWIDTH= in #EXT-X-STREAM-INF tags. Returns the highest
    bitrate found, or 0 if none detected.
    """
    max_bitrate = 0
    for line in content.splitlines():
        if "BANDWIDTH=" in line:
            try:
                # Parse BANDWIDTH=<number> from the tag
                for part in line.split(","):
                    part = part.strip()
                    if part.startswith("BANDWIDTH="):
                        bw = int(part.split("=", 1)[1])
                        max_bitrate = max(max_bitrate, bw)
            except (ValueError, IndexError):
                continue
    return max_bitrate


class StreamHealthChecker:
    """Background health checker for extracted streams.

    Verifies streams are live by performing a partial GET on the m3u8 URL,
    checking for valid HLS content (#EXTM3U header), and measuring response
    time as a quality indicator.
    """

    def __init__(self, timeout: float = HEALTH_CHECK_TIMEOUT) -> None:
        self._timeout = timeout

    async def check_stream(self, url: str) -> StreamHealth:
        """Check if a stream URL is live by doing a partial GET on the m3u8.

        Verification steps:
        1. GET the m3u8 URL (not just HEAD - need to verify playlist content)
        2. Check if response contains #EXTM3U header
        3. Measure response time as a quality indicator
        4. Extract bitrate info if available

        Args:
            url: The m3u8 stream URL to check.

        Returns:
            StreamHealth with is_live, response_time_ms, checked_at, and
            optional bitrate and error information.
        """
        start_time = time.monotonic()
        checked_at = datetime.now(timezone.utc).isoformat()

        try:
            async with httpx.AsyncClient(
                timeout=self._timeout,
                follow_redirects=True,
                headers={
                    "User-Agent": USER_AGENT,
                    "Accept": "*/*",
                },
            ) as client:
                # Use a partial GET with Range header to limit download
                # but fall back to reading limited bytes if Range not supported
                response = await client.get(
                    url,
                    headers={"Range": f"bytes=0-{MAX_CONTENT_BYTES - 1}"},
                )

                elapsed_ms = int((time.monotonic() - start_time) * 1000)

                # Accept 200 (full content) or 206 (partial content)
                if response.status_code not in (200, 206):
                    return StreamHealth(
                        url=url,
                        is_live=False,
                        response_time_ms=elapsed_ms,
                        checked_at=checked_at,
                        error=f"HTTP {response.status_code}",
                    )

                content = response.text[:MAX_CONTENT_BYTES]

                # Verify it's a valid HLS playlist
                if "#EXTM3U" not in content:
                    return StreamHealth(
                        url=url,
                        is_live=False,
                        response_time_ms=elapsed_ms,
                        checked_at=checked_at,
                        error="Response does not contain #EXTM3U header",
                    )

                # Extract bitrate info if available
                bitrate = _extract_bitrate(content)

                # If this is a master playlist, validate at least one variant
                if "#EXT-X-STREAM-INF:" in content:
                    variant_ok = await self._check_first_variant(
                        content, url, client
                    )
                    if not variant_ok:
                        return StreamHealth(
                            url=url,
                            is_live=False,
                            response_time_ms=elapsed_ms,
                            checked_at=checked_at,
                            bitrate=bitrate,
                            error="Master playlist OK but variant playlists are unreachable",
                        )

                return StreamHealth(
                    url=url,
                    is_live=True,
                    response_time_ms=elapsed_ms,
                    checked_at=checked_at,
                    bitrate=bitrate,
                )

        except httpx.TimeoutException:
            elapsed_ms = int((time.monotonic() - start_time) * 1000)
            logger.debug("Health check timed out for %s", url)
            return StreamHealth(
                url=url,
                is_live=False,
                response_time_ms=elapsed_ms,
                checked_at=checked_at,
                error="Timeout",
            )
        except httpx.HTTPError as e:
            elapsed_ms = int((time.monotonic() - start_time) * 1000)
            logger.debug("Health check HTTP error for %s: %s", url, e)
            return StreamHealth(
                url=url,
                is_live=False,
                response_time_ms=elapsed_ms,
                checked_at=checked_at,
                error=f"HTTP error: {e}",
            )
        except Exception as e:
            elapsed_ms = int((time.monotonic() - start_time) * 1000)
            logger.exception("Unexpected error during health check for %s", url)
            return StreamHealth(
                url=url,
                is_live=False,
                response_time_ms=elapsed_ms,
                checked_at=checked_at,
                error=f"Unexpected error: {e}",
            )

    async def _check_first_variant(
        self, content: str, base_url: str, client: httpx.AsyncClient
    ) -> bool:
        """Check that at least one variant playlist in a master playlist is reachable.

        Extracts the first variant URI from a master playlist and does a HEAD
        request to verify it returns 200/206. This catches streams where the
        master playlist is valid but all variant playlists are 404.

        Args:
            content: The master playlist text content.
            base_url: The URL of the master playlist (for resolving relative URIs).
            client: An existing httpx client to reuse.

        Returns:
            True if at least one variant is reachable, False otherwise.
        """
        lines = content.splitlines()
        for i, line in enumerate(lines):
            if not line.strip().startswith("#EXT-X-STREAM-INF:"):
                continue
            # Next non-empty, non-comment line is the variant URI
            for j in range(i + 1, len(lines)):
                variant_uri = lines[j].strip()
                if variant_uri and not variant_uri.startswith("#"):
                    # Resolve relative URI
                    if not variant_uri.startswith(("http://", "https://")):
                        variant_uri = urljoin(base_url, variant_uri)
                    try:
                        resp = await client.head(variant_uri)
                        if resp.status_code in (200, 206):
                            return True
                        # HEAD might not be supported, try GET
                        resp = await client.get(
                            variant_uri,
                            headers={"Range": f"bytes=0-{MAX_CONTENT_BYTES - 1}"},
                        )
                        if resp.status_code in (200, 206):
                            return True
                        logger.debug(
                            "Variant playlist %s returned HTTP %d",
                            variant_uri, resp.status_code,
                        )
                    except Exception as e:
                        logger.debug(
                            "Variant check failed for %s: %s", variant_uri, e
                        )
                    # Only check the first variant
                    return False
        # No variants found (shouldn't happen if #EXT-X-STREAM-INF was detected)
        return True

    async def check_all(
        self, streams: list[dict],
    ) -> dict[str, StreamHealth]:
        """Check all streams concurrently, return health map keyed by URL.

        Args:
            streams: List of stream dicts (must have a "url" key).

        Returns:
            Dictionary mapping stream URL to its StreamHealth result.
        """
        urls = [s["url"] for s in streams if "url" in s]

        if not urls:
            return {}

        logger.info("Running health checks on %d stream(s)...", len(urls))

        # Run all checks concurrently
        tasks = [self.check_stream(url) for url in urls]
        results = await asyncio.gather(*tasks, return_exceptions=True)

        health_map: dict[str, StreamHealth] = {}
        for url, result in zip(urls, results):
            if isinstance(result, Exception):
                logger.error("Health check task failed for %s: %s", url, result)
                health_map[url] = StreamHealth(
                    url=url,
                    is_live=False,
                    response_time_ms=0,
                    error=f"Task error: {result}",
                )
            else:
                health_map[url] = result

        live_count = sum(1 for h in health_map.values() if h.is_live)
        logger.info(
            "Health checks complete: %d/%d streams are live",
            live_count,
            len(health_map),
        )

        return health_map
