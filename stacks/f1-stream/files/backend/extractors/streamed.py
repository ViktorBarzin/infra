"""Streamed.pk extractor - fetches F1/motorsport streams via public JSON API."""

import logging

import httpx

from backend.extractors.base import BaseExtractor
from backend.extractors.models import ExtractedStream

logger = logging.getLogger(__name__)

BASE_URL = "https://streamed.su"
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/120.0.0.0 Safari/537.36"
)


class StreamedExtractor(BaseExtractor):
    """Extracts streams from Streamed.pk's public JSON API.

    Uses two endpoints:
    - GET /api/matches/motor-sports → list of events with sources
    - GET /api/stream/{source}/{id} → embed URL for a specific source
    """

    @property
    def site_key(self) -> str:
        return "streamed"

    @property
    def site_name(self) -> str:
        return "Streamed"

    async def extract(self) -> list[ExtractedStream]:
        """Fetch motorsport events and resolve embed URLs for each source."""
        streams: list[ExtractedStream] = []

        try:
            async with httpx.AsyncClient(
                timeout=15.0,
                follow_redirects=True,
                headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
            ) as client:
                # Get motorsport events
                resp = await client.get(f"{BASE_URL}/api/matches/motor-sports")
                if resp.status_code != 200:
                    logger.warning(
                        "[streamed] Events API returned HTTP %d", resp.status_code
                    )
                    return []

                events = resp.json()
                if not isinstance(events, list):
                    logger.warning("[streamed] Unexpected events response type")
                    return []

                logger.info("[streamed] Found %d motorsport event(s)", len(events))

                for event in events:
                    title = event.get("title", "Unknown Event")
                    sources = event.get("sources", [])
                    if not sources:
                        continue

                    for source_info in sources:
                        source_name = source_info.get("source", "")
                        source_id = source_info.get("id", "")
                        if not source_name or not source_id:
                            continue

                        try:
                            stream_resp = await client.get(
                                f"{BASE_URL}/api/stream/{source_name}/{source_id}"
                            )
                            if stream_resp.status_code != 200:
                                continue

                            stream_data = stream_resp.json()
                            if not isinstance(stream_data, list):
                                stream_data = [stream_data]

                            for item in stream_data:
                                embed_url = item.get("embedUrl", "")
                                if not embed_url:
                                    continue

                                language = item.get("language", "")
                                hd = item.get("hd", False)
                                stream_no = item.get("streamNo", 1)

                                quality = "HD" if hd else "SD"
                                stream_title = f"{title}"
                                if language:
                                    stream_title += f" ({language})"
                                if stream_no > 1:
                                    stream_title += f" #{stream_no}"

                                streams.append(
                                    ExtractedStream(
                                        url=embed_url,
                                        site_key=self.site_key,
                                        site_name=self.site_name,
                                        quality=quality,
                                        title=stream_title,
                                        stream_type="embed",
                                        embed_url=embed_url,
                                    )
                                )
                        except Exception:
                            logger.debug(
                                "[streamed] Failed to fetch stream for %s/%s",
                                source_name,
                                source_id,
                                exc_info=True,
                            )

        except Exception:
            logger.exception("[streamed] Failed to fetch events")

        logger.info("[streamed] Extracted %d stream(s)", len(streams))
        return streams
