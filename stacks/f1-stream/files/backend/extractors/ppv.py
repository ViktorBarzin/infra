"""PPV.to extractor - fetches F1 streams via the public PPV API.

Returns embed URLs (pooembed.eu) for iframe playback.
The API at api.ppv.to/api/streams requires no authentication.
Falls back to api.ppv.st if the primary API is unreachable.
"""

import logging

import httpx

from backend.extractors.base import BaseExtractor
from backend.extractors.models import ExtractedStream

logger = logging.getLogger(__name__)

PRIMARY_API = "https://api.ppv.to/api/streams"
FALLBACK_API = "https://api.ppv.st/api/streams"
EMBED_BASE = "https://pooembed.eu/embed"

USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/120.0.0.0 Safari/537.36"
)

# Category name for motorsport on PPV.to
MOTORSPORT_CATEGORY = "motorsports"

# Only include events matching these keywords (case-insensitive)
F1_KEYWORDS = {"formula 1", "formula one", "f1", "sky sports f1"}
# Grand Prix is shared with MotoGP/IndyCar — only match if no other series keywords
GP_KEYWORD = "grand prix"
NON_F1_KEYWORDS = {
    "motogp", "moto gp", "moto2", "moto3", "motoe",
    "indycar", "indy car", "firestone", "nascar",
    "rally", "wrc", "wec", "lemans", "le mans",
    "superbike", "dtm", "supercars",
}


def _is_f1_stream(name: str, category_name: str = "") -> bool:
    """Check if a stream is Formula 1 related.

    Checks both the stream name and the category name.
    A stream qualifies if:
    - It is in the motorsport category AND matches F1 keywords, OR
    - It matches F1 keywords regardless of category.
    """
    lower_name = name.lower()
    lower_cat = category_name.lower()

    # Reject if it contains non-F1 motorsport keywords
    if any(kw in lower_name for kw in NON_F1_KEYWORDS):
        return False

    # Direct F1 keyword match in the stream name
    if any(kw in lower_name for kw in F1_KEYWORDS):
        return True

    # "grand prix" in the name, only if in motorsports category and no non-F1 keywords
    if GP_KEYWORD in lower_name and MOTORSPORT_CATEGORY in lower_cat:
        return True

    # If the category is motorsport, also check category-level keywords
    if MOTORSPORT_CATEGORY in lower_cat and any(kw in lower_cat for kw in F1_KEYWORDS):
        return True

    return False


class PPVExtractor(BaseExtractor):
    """Extracts embed URLs from PPV.to's public JSON API.

    Uses the endpoint:
    - GET https://api.ppv.to/api/streams -> all streams grouped by category
    - Fallback: https://api.ppv.st/api/streams

    Each stream object contains an `iframe` field with the embed URL,
    or a `uri_name` from which the embed URL can be constructed.
    """

    @property
    def site_key(self) -> str:
        return "ppv"

    @property
    def site_name(self) -> str:
        return "PPV.to"

    async def _fetch_streams(self, client: httpx.AsyncClient) -> dict | None:
        """Try primary and fallback APIs, return parsed JSON or None."""
        for api_url in (PRIMARY_API, FALLBACK_API):
            try:
                resp = await client.get(api_url)
                if resp.status_code == 200:
                    data = resp.json()
                    logger.info("[ppv] Fetched streams from %s", api_url)
                    return data
                logger.warning(
                    "[ppv] %s returned HTTP %d", api_url, resp.status_code
                )
            except Exception:
                logger.debug(
                    "[ppv] Failed to reach %s", api_url, exc_info=True
                )
        return None

    async def extract(self) -> list[ExtractedStream]:
        """Fetch F1 streams and return embed URLs for iframe playback."""
        streams: list[ExtractedStream] = []

        try:
            async with httpx.AsyncClient(
                timeout=15.0,
                follow_redirects=True,
                headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
            ) as client:
                data = await self._fetch_streams(client)
                if data is None:
                    logger.warning("[ppv] Could not fetch streams from any API")
                    return []

                # The API returns:
                # { "streams": [ { "category": "Name", "id": N, "streams": [...] }, ... ] }
                # Flatten into (category_name, stream_obj) tuples.
                all_streams = self._normalize_streams(data)

                logger.info(
                    "[ppv] Found %d total stream(s) across all categories",
                    len(all_streams),
                )

                for category_name, stream_obj in all_streams:
                    name = stream_obj.get("name", "") or stream_obj.get("title", "")

                    if not _is_f1_stream(name, category_name):
                        continue

                    # Build the embed URL
                    embed_url = self._get_embed_url(stream_obj)
                    if not embed_url:
                        logger.debug("[ppv] No embed URL for stream: %s", name)
                        continue

                    # Extract quality from tag if present
                    tag = stream_obj.get("tag", "")
                    quality = tag if tag else ""

                    # Build descriptive title
                    title = name
                    viewers = stream_obj.get("viewers")
                    if viewers and int(viewers) > 0:
                        title += f" ({viewers} viewers)"

                    # Check for substreams (multiple quality/language options)
                    substreams = stream_obj.get("substreams")
                    if isinstance(substreams, list) and substreams:
                        for i, sub in enumerate(substreams):
                            sub_embed = sub.get("iframe", "") or sub.get("embed_url", "")
                            if not sub_embed:
                                # Fall back to the parent embed URL
                                sub_embed = embed_url
                            sub_name = sub.get("name", "") or sub.get("label", "")
                            sub_quality = sub.get("tag", "") or sub.get("quality", "") or quality
                            sub_title = f"{name}"
                            if sub_name:
                                sub_title += f" - {sub_name}"
                            elif i > 0:
                                sub_title += f" #{i + 1}"

                            streams.append(
                                ExtractedStream(
                                    url=sub_embed,
                                    site_key=self.site_key,
                                    site_name=self.site_name,
                                    quality=sub_quality,
                                    title=sub_title,
                                    stream_type="embed",
                                    embed_url=sub_embed,
                                )
                            )
                    else:
                        # Single stream, no substreams
                        streams.append(
                            ExtractedStream(
                                url=embed_url,
                                site_key=self.site_key,
                                site_name=self.site_name,
                                quality=quality,
                                title=title,
                                stream_type="embed",
                                embed_url=embed_url,
                            )
                        )

        except Exception:
            logger.exception("[ppv] Failed to extract streams")

        logger.info("[ppv] Extracted %d F1 stream(s)", len(streams))
        return streams

    @staticmethod
    def _normalize_streams(data: dict | list) -> list[tuple[str, dict]]:
        """Normalize the API response into a flat list of (category_name, stream_dict) tuples.

        The PPV API returns data in this shape:
        {
            "streams": [
                {
                    "category": "Motorsports",
                    "id": 35,
                    "streams": [ { stream objects... } ]
                },
                ...
            ]
        }

        Each category group has a "category" string and a nested "streams" list.
        """
        result: list[tuple[str, dict]] = []

        # Handle the top-level wrapper
        if isinstance(data, dict):
            categories = data.get("streams", [])
        elif isinstance(data, list):
            categories = data
        else:
            return result

        for category_group in categories:
            if not isinstance(category_group, dict):
                continue

            category_name = category_group.get("category", "")

            # The nested streams within this category
            inner_streams = category_group.get("streams", [])
            if isinstance(inner_streams, list):
                for stream_obj in inner_streams:
                    if isinstance(stream_obj, dict):
                        # Attach category_name to each stream for filtering
                        result.append((category_name, stream_obj))
            elif isinstance(category_group, dict) and "name" in category_group:
                # Fallback: the item itself is a stream (flat list format)
                result.append((category_name, category_group))

        return result

    @staticmethod
    def _get_embed_url(stream: dict) -> str:
        """Extract or construct the embed URL for a stream."""
        # Prefer the iframe field directly
        iframe = stream.get("iframe", "")
        if iframe:
            return iframe

        # Construct from uri_name
        uri_name = stream.get("uri_name", "") or stream.get("uri", "")
        if uri_name:
            # Strip leading slash if present
            uri_name = uri_name.lstrip("/")
            return f"{EMBED_BASE}/{uri_name}"

        # Last resort: use the stream id
        stream_id = stream.get("id")
        if stream_id:
            return f"{EMBED_BASE}/{stream_id}"

        return ""
