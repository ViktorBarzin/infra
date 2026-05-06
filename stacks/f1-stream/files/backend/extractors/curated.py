"""Curated extractor — known-good 24/7 F1 channels via direct embed URLs.

Returns a small, hand-picked list of embed URLs that are reliable enough to
be served as fallback "always-on" streams when the dynamic extractors find
nothing (e.g. between race weekends, when API providers are down).

These are direct embed URLs. The frontend routes them through /embed so the
iframe-stripping proxy bypasses any frame-buster JS in the upstream player.
"""

import logging

from backend.extractors.base import BaseExtractor
from backend.extractors.models import ExtractedStream

logger = logging.getLogger(__name__)


# Curated list. Each entry is a known direct embed URL. These were sourced
# from the timstreams.py ALWAYS_INCLUDE_HASHES list (Sky Sports F1, DAZN F1)
# and are documented as 24/7 channels that play F1 content year-round.
_CURATED_STREAMS = [
    {
        "url": "https://hmembeds.one/embed/888520f36cd94c5da4c71fddc1a5fc9b",
        "title": "Sky Sports F1 (24/7)",
        "quality": "HD",
    },
    {
        "url": "https://hmembeds.one/embed/fc3a54634d0867b0c02ee3223292e7c6",
        "title": "DAZN F1 (24/7)",
        "quality": "HD",
    },
]


class CuratedExtractor(BaseExtractor):
    """Returns curated known-good 24/7 F1 channel embed URLs."""

    @property
    def site_key(self) -> str:
        return "curated"

    @property
    def site_name(self) -> str:
        return "Curated 24/7 Channels"

    async def extract(self) -> list[ExtractedStream]:
        streams = [
            ExtractedStream(
                url=entry["url"],
                site_key=self.site_key,
                site_name=self.site_name,
                quality=entry["quality"],
                title=entry["title"],
                stream_type="embed",
                embed_url=entry["url"],
            )
            for entry in _CURATED_STREAMS
        ]
        logger.info("[curated] Returning %d curated stream(s)", len(streams))
        return streams
