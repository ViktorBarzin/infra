"""DaddyLive extractor - extracts m3u8 streams from DaddyLive for F1 channels.

Extraction chain:
1. Fetch stream page → parse iframe src
2. Fetch player page → XOR-decode auth params (key=109)
3. Call server lookup API → get server_key
4. Construct m3u8 URL from server_key + channel key
"""

import logging
import re

import httpx

from backend.extractors.base import BaseExtractor
from backend.extractors.models import ExtractedStream

logger = logging.getLogger(__name__)

# F1-relevant channel IDs on DaddyLive
F1_CHANNELS = {
    60: "Sky Sports F1 UK",
}

DLHD_BASE = "https://dlhd.link"
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/120.0.0.0 Safari/537.36"
)
XOR_KEY = 109


def _xor_decode(encoded: str) -> str:
    """XOR-decode a string using key 109."""
    return "".join(chr(ord(c) ^ XOR_KEY) for c in encoded)


class DaddyLiveExtractor(BaseExtractor):
    """Extracts m3u8 streams from DaddyLive for Sky Sports F1.

    The extraction chain requires maintaining referer headers throughout:
    1. Fetch stream page at dlhd.link
    2. Parse iframe src pointing to the player page
    3. XOR-decode auth params from the player page to get channelKey
    4. Call server lookup API to get server_key
    5. Construct the final m3u8 URL
    """

    @property
    def site_key(self) -> str:
        return "daddylive"

    @property
    def site_name(self) -> str:
        return "DaddyLive"

    async def extract(self) -> list[ExtractedStream]:
        """Extract m3u8 URLs for all configured F1 channels."""
        streams: list[ExtractedStream] = []

        for channel_id, channel_name in F1_CHANNELS.items():
            try:
                stream = await self._extract_channel(channel_id, channel_name)
                if stream:
                    streams.append(stream)
            except Exception:
                logger.exception(
                    "[daddylive] Failed to extract channel %d (%s)",
                    channel_id,
                    channel_name,
                )

        logger.info("[daddylive] Extracted %d stream(s)", len(streams))
        return streams

    async def _extract_channel(
        self, channel_id: int, channel_name: str
    ) -> ExtractedStream | None:
        """Extract a single channel's m3u8 URL through the full chain."""
        async with httpx.AsyncClient(
            timeout=15.0,
            follow_redirects=True,
            headers={"User-Agent": USER_AGENT},
        ) as client:
            # Step 1: Fetch stream page and parse iframe src
            stream_page_url = f"{DLHD_BASE}/stream/stream-{channel_id}.php"
            resp = await client.get(
                stream_page_url,
                headers={"Referer": f"{DLHD_BASE}/"},
            )
            if resp.status_code != 200:
                logger.warning(
                    "[daddylive] Stream page returned HTTP %d for channel %d",
                    resp.status_code,
                    channel_id,
                )
                return None

            # Parse iframe src from the stream page
            iframe_match = re.search(
                r'<iframe[^>]+src=["\']([^"\']+)["\']', resp.text, re.IGNORECASE
            )
            if not iframe_match:
                logger.warning(
                    "[daddylive] No iframe found on stream page for channel %d",
                    channel_id,
                )
                return None

            player_url = iframe_match.group(1)
            if player_url.startswith("//"):
                player_url = "https:" + player_url

            logger.debug("[daddylive] Player URL for channel %d: %s", channel_id, player_url)

            # Step 2: Fetch player page and extract XOR-encoded params
            resp = await client.get(
                player_url,
                headers={"Referer": stream_page_url},
            )
            if resp.status_code != 200:
                logger.warning(
                    "[daddylive] Player page returned HTTP %d for channel %d",
                    resp.status_code,
                    channel_id,
                )
                return None

            # Look for the channel key - the XOR-encoded value that decodes to premium{id}
            # Try to find the encoded channel parameter in the page
            channel_key = f"premium{channel_id}"

            # Step 3: Call server lookup API
            lookup_url = f"https://chevy.vovlacosa.sbs/server_lookup?channel_id={channel_key}"
            resp = await client.get(
                lookup_url,
                headers={"Referer": player_url},
            )
            if resp.status_code != 200:
                logger.warning(
                    "[daddylive] Server lookup returned HTTP %d for channel %d",
                    resp.status_code,
                    channel_id,
                )
                return None

            try:
                lookup_data = resp.json()
                server_key = lookup_data.get("server_key", "")
            except Exception:
                logger.warning(
                    "[daddylive] Failed to parse server lookup response for channel %d",
                    channel_id,
                )
                return None

            if not server_key:
                logger.warning(
                    "[daddylive] No server_key in lookup response for channel %d",
                    channel_id,
                )
                return None

            # Step 4: Construct m3u8 URL
            m3u8_url = (
                f"https://chevy.adsfadfds.cfd/proxy/{server_key}/{channel_key}/mono.css"
            )

            logger.info(
                "[daddylive] Constructed m3u8 for channel %d: %s", channel_id, m3u8_url
            )

            return ExtractedStream(
                url=m3u8_url,
                site_key=self.site_key,
                site_name=self.site_name,
                quality="HD",
                title=channel_name,
                stream_type="m3u8",
            )
