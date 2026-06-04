"""TimStreams extractor - fetches F1 streams from the TimStreams JSON API.

Returns embed URLs from hmembeds.one for iframe playback.
The public API at stra.viaplus.site/main requires no authentication
and returns all events/channels across Events, Replays, and 24/7 categories.
"""

import logging

import httpx

from backend.extractors.base import BaseExtractor
from backend.extractors.models import ExtractedStream

logger = logging.getLogger(__name__)

API_URL = "https://stra.viaplus.site/main"
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/120.0.0.0 Safari/537.36"
)

# Direct F1 keyword matches (case-insensitive)
F1_KEYWORDS = {"formula 1", "formula one", "f1", "sky sports f1", "dazn f1"}
# "Grand prix" is F1-related only if non-F1 motorsport keywords are absent
GP_KEYWORD = "grand prix"
# Exclude these motorsport series when matching on "grand prix"
NON_F1_KEYWORDS = {
    "motogp", "moto gp", "moto2", "moto3", "motoe",
    "indycar", "indy car", "nascar",
    "rally", "wrc", "wec", "lemans", "le mans",
    "superbike", "dtm", "supercars",
}

# 24/7 channels that should always be included (embed hashes on hmembeds.one)
ALWAYS_INCLUDE_HASHES = {
    "888520f36cd94c5da4c71fddc1a5fc9b",  # Sky Sports F1
    "fc3a54634d0867b0c02ee3223292e7c6",  # DAZN F1
}


def _is_f1_event(name: str) -> bool:
    """Check if an event/channel is Formula 1 related by name.

    Returns True when the name contains a direct F1 keyword, or contains
    "grand prix" without non-F1 series keywords.

    Note: The TimStreams API genre field (genre=2) covers ALL sports channels,
    not just motorsport, so we rely solely on name-based matching.
    """
    lower = name.lower()

    # Direct F1 keyword match
    if any(kw in lower for kw in F1_KEYWORDS):
        return True

    # Grand prix without competing series
    if GP_KEYWORD in lower and not any(kw in lower for kw in NON_F1_KEYWORDS):
        return True

    return False


def _extract_embed_hash(url: str) -> str | None:
    """Extract the hash from an hmembeds.one embed URL.

    Expected format: https://hmembeds.one/embed/{hash}
    Returns the hash string, or None if the URL is not in the expected format.
    """
    if not url:
        return None
    # Handle both with and without trailing slash
    url = url.rstrip("/")
    prefix = "https://hmembeds.one/embed/"
    alt_prefix = "http://hmembeds.one/embed/"
    if url.startswith(prefix):
        return url[len(prefix):] or None
    if url.startswith(alt_prefix):
        return url[len(alt_prefix):] or None
    return None


def _is_always_include(url: str) -> bool:
    """Check if a stream URL is one of the always-include 24/7 channels."""
    embed_hash = _extract_embed_hash(url)
    return embed_hash in ALWAYS_INCLUDE_HASHES if embed_hash else False


class TimStreamsExtractor(BaseExtractor):
    """Extracts embed URLs from TimStreams' public JSON API.

    The API at stra.viaplus.site/main returns a JSON array of categories,
    each containing events with stream URLs pointing to hmembeds.one embeds.
    """

    @property
    def site_key(self) -> str:
        return "timstreams"

    @property
    def site_name(self) -> str:
        return "TimStreams"

    async def extract(self) -> list[ExtractedStream]:
        """Fetch F1 events/channels and return embed URLs for iframe playback."""
        streams: list[ExtractedStream] = []
        seen_urls: set[str] = set()

        try:
            async with httpx.AsyncClient(
                timeout=15.0,
                follow_redirects=True,
                headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
            ) as client:
                resp = await client.get(API_URL)
                if resp.status_code != 200:
                    logger.warning(
                        "[timstreams] API returned HTTP %d", resp.status_code
                    )
                    return []

                data = resp.json()
                if not isinstance(data, list):
                    logger.warning("[timstreams] Unexpected API response type: %s", type(data).__name__)
                    return []

                logger.info("[timstreams] API returned %d categorie(s)", len(data))

                for category in data:
                    category_name = category.get("category", "Unknown")
                    events = category.get("events", [])
                    if not isinstance(events, list):
                        continue

                    for event in events:
                        event_name = event.get("name", "Unknown")
                        event_streams = event.get("streams", [])

                        if not isinstance(event_streams, list) or not event_streams:
                            continue

                        # Check if any stream URL matches an always-include channel
                        always_include = any(
                            _is_always_include(s.get("url", ""))
                            for s in event_streams
                        )

                        # Filter: must be F1-related or an always-include channel
                        if not always_include and not _is_f1_event(event_name):
                            continue

                        for stream_info in event_streams:
                            stream_name = stream_info.get("name", "")
                            stream_url = stream_info.get("url", "")

                            if not stream_url:
                                continue

                            # Deduplicate by URL
                            if stream_url in seen_urls:
                                continue
                            seen_urls.add(stream_url)

                            # Build a descriptive title
                            title = event_name
                            if stream_name and stream_name.lower() != event_name.lower():
                                title = f"{event_name} - {stream_name}"
                            if category_name:
                                title = f"[{category_name}] {title}"

                            streams.append(
                                ExtractedStream(
                                    url=stream_url,
                                    site_key=self.site_key,
                                    site_name=self.site_name,
                                    quality="",
                                    title=title,
                                    stream_type="embed",
                                    embed_url=stream_url,
                                )
                            )

        except httpx.TimeoutException:
            logger.warning("[timstreams] API request timed out")
        except Exception:
            logger.exception("[timstreams] Failed to fetch from API")

        logger.info("[timstreams] Extracted %d stream(s)", len(streams))
        return streams
