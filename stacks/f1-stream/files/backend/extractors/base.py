"""Base class for all site-specific stream extractors."""

import logging
from abc import ABC, abstractmethod

import httpx

from backend.extractors.models import ExtractedStream

logger = logging.getLogger(__name__)


class BaseExtractor(ABC):
    """Abstract base class for site-specific stream extractors.

    To create a new extractor:
    1. Create a new file in backend/extractors/
    2. Subclass BaseExtractor
    3. Implement site_key, site_name, and extract()
    4. Register it in backend/extractors/__init__.py
    """

    @property
    @abstractmethod
    def site_key(self) -> str:
        """Unique identifier for this site (e.g., 'sportsurge').

        Must be lowercase, alphanumeric with hyphens/underscores only.
        Used as the cache key and in API responses.
        """

    @property
    @abstractmethod
    def site_name(self) -> str:
        """Human-readable name (e.g., 'SportSurge').

        Displayed in the UI and API responses.
        """

    @abstractmethod
    async def extract(self) -> list[ExtractedStream]:
        """Extract stream URLs from this site.

        Returns a list of ExtractedStream objects. Each represents a
        discovered stream URL. The extractor should set url, quality,
        and title fields; site_key, site_name, and extracted_at are
        auto-populated if left empty.

        Implementations should:
        - Use httpx for HTTP requests
        - Handle their own errors gracefully (log and return empty list)
        - Set quality when detectable from the source
        - Set title to something descriptive
        """

    async def health_check(self, url: str) -> bool:
        """Verify a URL is live (HEAD request, check for m3u8 content).

        Sends a HEAD request and checks:
        1. HTTP 200 response
        2. Content-Type suggests HLS/media content (if available)

        Returns True if the URL appears to be a live stream.
        """
        try:
            async with httpx.AsyncClient(
                timeout=10.0,
                follow_redirects=True,
                headers={"User-Agent": "Mozilla/5.0"},
            ) as client:
                response = await client.head(url)

                if response.status_code != 200:
                    logger.debug(
                        "[%s] Health check failed for %s: HTTP %d",
                        self.site_key,
                        url,
                        response.status_code,
                    )
                    return False

                content_type = response.headers.get("content-type", "").lower()
                # m3u8 streams typically have these content types
                live_indicators = [
                    "application/vnd.apple.mpegurl",
                    "application/x-mpegurl",
                    "video/",
                    "audio/",
                    "octet-stream",
                ]

                # If content-type is present and doesn't look like media,
                # the URL might not be a stream. But some servers don't set
                # content-type properly for HEAD, so we still return True
                # if content-type is missing or generic.
                if content_type and not any(ind in content_type for ind in live_indicators):
                    # Content type present but doesn't look like media.
                    # Could still be valid (some servers return text/plain for m3u8).
                    if "text/" in content_type or "html" in content_type:
                        logger.debug(
                            "[%s] Health check suspect for %s: content-type=%s",
                            self.site_key,
                            url,
                            content_type,
                        )
                        return False

                return True

        except httpx.TimeoutException:
            logger.debug("[%s] Health check timed out for %s", self.site_key, url)
            return False
        except httpx.HTTPError as e:
            logger.debug("[%s] Health check error for %s: %s", self.site_key, url, e)
            return False
        except Exception:
            logger.exception("[%s] Unexpected error during health check for %s", self.site_key, url)
            return False
