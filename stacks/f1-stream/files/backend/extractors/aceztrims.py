"""Aceztrims extractor - scrapes F1 streaming links from Aceztrims pages.

Parses HTML for iframe button onclick handlers and extracts streams from:
- /iframe1?s=<m3u8_url> → direct m3u8
- https://pooembed.eu/embed/... → embed URL
"""

import logging
import re
from urllib.parse import parse_qs, urlparse

import httpx

from backend.extractors.base import BaseExtractor
from backend.extractors.models import ExtractedStream

logger = logging.getLogger(__name__)

BASE_URL = "https://acestrlms.pages.dev"
# Pages to scrape for streams
F1_PAGES = [
    ("/f1/", "Formula 1"),
]

USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/120.0.0.0 Safari/537.36"
)


class AceztrimsExtractor(BaseExtractor):
    """Extracts streams from Aceztrims pages by parsing HTML for iframe URLs.

    Looks for onclick handlers on buttons/links that open iframes, and
    extracts the stream URLs from them.
    """

    @property
    def site_key(self) -> str:
        return "aceztrims"

    @property
    def site_name(self) -> str:
        return "Aceztrims"

    async def extract(self) -> list[ExtractedStream]:
        """Scrape all configured F1 pages for stream URLs."""
        streams: list[ExtractedStream] = []

        async with httpx.AsyncClient(
            timeout=15.0,
            follow_redirects=True,
            headers={"User-Agent": USER_AGENT},
        ) as client:
            for path, category in F1_PAGES:
                try:
                    page_streams = await self._scrape_page(client, path, category)
                    streams.extend(page_streams)
                except Exception:
                    logger.exception(
                        "[aceztrims] Failed to scrape page %s", path
                    )

        logger.info("[aceztrims] Extracted %d stream(s)", len(streams))
        return streams

    async def _scrape_page(
        self, client: httpx.AsyncClient, path: str, category: str
    ) -> list[ExtractedStream]:
        """Scrape a single page for stream URLs."""
        url = f"{BASE_URL}{path}"
        resp = await client.get(url)
        if resp.status_code != 200:
            logger.warning(
                "[aceztrims] Page %s returned HTTP %d", path, resp.status_code
            )
            return []

        html = resp.text
        streams: list[ExtractedStream] = []
        seen_urls: set[str] = set()

        # Pattern 1: /iframe1?s=<m3u8_url> — direct m3u8
        iframe1_pattern = re.compile(
            r"""['"]((?:https?://[^'"]*)?/iframe1\?s=([^'"&]+))['""]""",
            re.IGNORECASE,
        )
        for match in iframe1_pattern.finditer(html):
            m3u8_url = match.group(2)
            if m3u8_url in seen_urls:
                continue
            seen_urls.add(m3u8_url)

            streams.append(
                ExtractedStream(
                    url=m3u8_url,
                    site_key=self.site_key,
                    site_name=self.site_name,
                    quality="",
                    title=f"{category} Stream",
                    stream_type="m3u8",
                )
            )

        # Pattern 2: embed URLs (pooembed.eu or similar)
        embed_pattern = re.compile(
            r"""['"]((https?://(?:pooembed\.eu|[^'"]*embed)[^'"]*))['"]""",
            re.IGNORECASE,
        )
        for match in embed_pattern.finditer(html):
            embed_url = match.group(1)
            if embed_url in seen_urls:
                continue
            seen_urls.add(embed_url)

            streams.append(
                ExtractedStream(
                    url=embed_url,
                    site_key=self.site_key,
                    site_name=self.site_name,
                    quality="",
                    title=f"{category} Stream (Embed)",
                    stream_type="embed",
                    embed_url=embed_url,
                )
            )

        # Pattern 3: Generic onclick handlers with URLs
        onclick_pattern = re.compile(
            r"""onclick\s*=\s*['"].*?['"]?(https?://[^'")\s]+\.m3u8[^'")\s]*)['"]?""",
            re.IGNORECASE,
        )
        for match in onclick_pattern.finditer(html):
            m3u8_url = match.group(1)
            if m3u8_url in seen_urls:
                continue
            seen_urls.add(m3u8_url)

            streams.append(
                ExtractedStream(
                    url=m3u8_url,
                    site_key=self.site_key,
                    site_name=self.site_name,
                    quality="",
                    title=f"{category} Stream",
                    stream_type="m3u8",
                )
            )

        logger.info(
            "[aceztrims] Found %d stream(s) on %s", len(streams), path
        )
        return streams
