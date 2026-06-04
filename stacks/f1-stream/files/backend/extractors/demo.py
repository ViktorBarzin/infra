"""Demo extractor - returns hardcoded test streams for framework testing.

This extractor exists purely for testing the extraction pipeline end-to-end.
It does NOT connect to any real streaming site. Disable it in production by
removing its registration from __init__.py or setting DEMO_EXTRACTOR_ENABLED=false.
"""

import logging
import os

from backend.extractors.base import BaseExtractor
from backend.extractors.models import ExtractedStream

logger = logging.getLogger(__name__)

# Set DEMO_EXTRACTOR_ENABLED=false to disable this extractor
DEMO_ENABLED = os.getenv("DEMO_EXTRACTOR_ENABLED", "true").lower() in ("true", "1", "yes")


class DemoExtractor(BaseExtractor):
    """Demo extractor that returns hardcoded test streams.

    Use this to verify the extraction framework works end-to-end without
    needing a real streaming site. The streams are publicly available HLS
    test streams from Apple and others.
    """

    @property
    def site_key(self) -> str:
        return "demo"

    @property
    def site_name(self) -> str:
        return "Demo (Test Streams)"

    async def extract(self) -> list[ExtractedStream]:
        """Return hardcoded test streams for framework testing."""
        if not DEMO_ENABLED:
            logger.info("[demo] Demo extractor is disabled via DEMO_EXTRACTOR_ENABLED")
            return []

        logger.info("[demo] Returning demo test streams")

        streams = [
            ExtractedStream(
                url="https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8",
                site_key=self.site_key,
                site_name=self.site_name,
                quality="720p",
                title="Big Buck Bunny (Test Stream)",
                is_live=False,
            ),
            ExtractedStream(
                url="https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8",
                site_key=self.site_key,
                site_name=self.site_name,
                quality="1080p",
                title="Apple Bipbop (Test Stream)",
                is_live=False,
            ),
            ExtractedStream(
                url="https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8",
                site_key=self.site_key,
                site_name=self.site_name,
                quality="1080p",
                title="Tears of Steel (Test Stream)",
                is_live=False,
            ),
        ]

        # Optionally run health checks on the demo streams
        for stream in streams:
            stream.is_live = await self.health_check(stream.url)

        return streams
