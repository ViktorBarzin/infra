"""DD12Streams extractor — scrapes inline m3u8 URLs from per-channel pages.

Each DD12 sport page (`/nas`, `/f1`, `/sky`, etc.) renders an iframe to
`/<channel>c1` which 302-redirects to `/new-<channel>/jwplayer`. That
page contains a JW Player setup with the m3u8 URL hard-coded inline:

    playerInstance.setup({
      file: "https://...b-cdn.net/.../master.m3u8",
      ...
    });

The JW Player runtime fails in our cluster (same fingerprint trap as
hmembeds), but we don't need it — the file URL is in the HTML and any
browser with H.264 codecs can play it directly via hls.js.

Channel discovery: probe a known list. New ones can be added by checking
DD12's own homepage / nav.
"""

import logging
import re

import httpx

from backend.extractors.base import BaseExtractor
from backend.extractors.models import ExtractedStream

logger = logging.getLogger(__name__)

BASE = "https://dd12streams.com"
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) "
    "Version/17.4 Safari/605.1.15"
)

# (path, channel_label, title). Add as DD12 surfaces new channels.
CHANNELS = (
    ("nas", "DD12Streams", "NASCAR Cup Series (24/7) — DD12"),
)

_FILE_URL_RE = re.compile(r"""file\s*:\s*["']([^"']+\.m3u8[^"']*)["']""")


class DD12Extractor(BaseExtractor):
    @property
    def site_key(self) -> str:
        return "dd12"

    @property
    def site_name(self) -> str:
        return "DD12Streams"

    async def extract(self) -> list[ExtractedStream]:
        results: list[ExtractedStream] = []
        async with httpx.AsyncClient(
            timeout=15.0,
            follow_redirects=True,
            headers={"User-Agent": USER_AGENT},
        ) as client:
            for path, label, title in CHANNELS:
                try:
                    page_url = f"{BASE}/{path}"
                    resp = await client.get(page_url)
                    if resp.status_code != 200:
                        continue
                    iframe_path = self._extract_iframe(resp.text)
                    if not iframe_path:
                        continue
                    iframe_url = (
                        iframe_path
                        if iframe_path.startswith("http")
                        else f"{BASE}{iframe_path}"
                    )
                    iframe_resp = await client.get(
                        iframe_url, headers={"Referer": page_url}
                    )
                    if iframe_resp.status_code != 200:
                        continue
                    m3u8 = self._find_m3u8(iframe_resp.text)
                    if not m3u8:
                        continue
                    results.append(
                        ExtractedStream(
                            url=m3u8,
                            site_key=self.site_key,
                            site_name=label,
                            quality="",
                            title=title,
                            stream_type="m3u8",
                        )
                    )
                except Exception:
                    logger.debug(
                        "[dd12] /%s extraction failed", path, exc_info=True
                    )
        logger.info("[dd12] Extracted %d stream(s)", len(results))
        return results

    @staticmethod
    def _extract_iframe(html: str) -> str | None:
        m = re.search(
            r'<iframe[^>]+id=["\']vplayer["\'][^>]+src=["\']([^"\']+)["\']',
            html,
        )
        return m.group(1) if m else None

    @staticmethod
    def _find_m3u8(html: str) -> str | None:
        m = _FILE_URL_RE.search(html)
        return m.group(1) if m else None
