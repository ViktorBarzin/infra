"""Pitsport.xyz extractor - fetches F1 streams from the Next.js RSC payload.

Architecture:
- Main page (pitsport.xyz) has a "Live Now" section with event cards containing
  category, title, time, imageUrl props and /watch/{UUID} links.
- Schedule page (pitsport.xyz/schedule) lists all events grouped by category
  (h2 headings) with /watch/{UUID} links and event titles.
- Watch pages (/watch/{UUID}) embed iframes from pushembdz.store/embed/{EMBED_UUID}.
- Embed pages contain an RSC payload with a stream config: {title, link, method}.
- When method is "player" or "hls", the link field points to a serveplay.site
  m3u8 playlist. Otherwise we return the embed URL for iframe playback.
"""

import logging
import re
from dataclasses import dataclass

import httpx

from backend.extractors.base import BaseExtractor
from backend.extractors.models import ExtractedStream

logger = logging.getLogger(__name__)

PITSPORT_BASE = "https://pitsport.xyz"
EMBED_BASE = "https://pushembdz.store"
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/120.0.0.0 Safari/537.36"
)

# Categories to include (case-insensitive match). Broadened beyond F1
# to also surface MotoGP and adjacent motorsports — keeps the f1-stream
# UI useful between race weekends and during the off-season.
MOTORSPORT_CATEGORIES = {
    "formula 1", "formula 2", "formula 3",
    "motogp", "moto gp", "moto2", "moto3", "motoe",
    "world rally championship", "wrc",
    "world endurance championship", "wec",
    "indycar series", "indycar", "indynxt",
    "nascar cup series", "nascar truck series", "nascar o'reilly auto parts series",
    "nascar xfinity series", "nascar",
}

# Title keywords that are strong positives even when the category text
# is missing (live-now cards sometimes elide it).
MOTORSPORT_KEYWORDS = {
    "formula 1", "formula one", "f1",
    "motogp", "moto gp", "moto2", "moto3",
    "rally", "wrc",
    "indycar", "indy car",
    "nascar",
    "le mans", "lemans", "wec", "endurance",
}
GP_KEYWORD = "grand prix"


@dataclass
class _PitsportEvent:
    """An event discovered from the Pitsport site."""

    category: str
    title: str
    watch_uuid: str


def _is_motorsport_category(category: str) -> bool:
    """Check if a category string matches an included motorsport series."""
    return category.strip().lower() in MOTORSPORT_CATEGORIES


def _is_motorsport_event(category: str, title: str) -> bool:
    """Check if an event is a motorsport we want to surface (F1 + adjacent)."""
    if _is_motorsport_category(category):
        return True
    lower = f"{category} {title}".lower()
    if any(kw in lower for kw in MOTORSPORT_KEYWORDS):
        return True
    if GP_KEYWORD in lower:
        return True
    return False


# Aliases kept so older call-sites stay compiling. Both now point at the
# broadened motorsport filter.
_is_f1_category = _is_motorsport_category
_is_f1_event = _is_motorsport_event


def _parse_live_events(html: str) -> list[_PitsportEvent]:
    """Parse live events from the main page RSC payload.

    The main page contains event cards with props:
        category, title, time, imageUrl
    wrapped in <a href="/watch/{UUID}"> links.
    """
    events: list[_PitsportEvent] = []

    # Match event cards in the RSC payload - they appear as JSON-like structures
    # Pattern: href="/watch/UUID" ... category":"...", "title":"..."
    # In the RSC payload, the data is in the format:
    #   ["$","$L2","/watch/UUID",{"href":"/watch/UUID","children":["$","$L10",null,
    #     {"category":"...","title":"...","time":...,"imageUrl":"..."}]}]
    pattern = re.compile(
        r'"href":"(/watch/([0-9a-f-]{36}))"[^}]*?"category":"([^"]+)","title":"([^"]+)"',
    )
    for match in pattern.finditer(html):
        _, uuid, category, title = match.groups()
        events.append(_PitsportEvent(category=category, title=title, watch_uuid=uuid))

    return events


def _parse_schedule_events(html: str) -> list[_PitsportEvent]:
    """Parse events from the schedule page.

    The schedule page groups events under category headers (h2 elements).
    In the rendered HTML:
        <h2 ...>Formula 1</h2>
        <div ...>
            <a href="/watch/UUID">...</a>
            ...
        </div>

    In the RSC payload, similar structure with section divs containing
    a category h2 and child event links with titles.
    """
    events: list[_PitsportEvent] = []

    # Strategy 1: Parse from rendered HTML
    # Find category sections: >CategoryName</h2> followed by watch links
    # Split HTML at each category header
    section_pattern = re.compile(
        r'>([^<]+)</h2>\s*<div[^>]*class="flex flex-wrap gap-6">(.*?)(?=</div>\s*</div>\s*(?:<div|</div>|$))',
        re.DOTALL,
    )
    for section_match in section_pattern.finditer(html):
        category = section_match.group(1).strip()
        section_html = section_match.group(2)

        # Find all watch links in this section
        link_pattern = re.compile(
            r'href="/watch/([0-9a-f-]{36})".*?<h1[^>]*>([^<]+)</h1>',
            re.DOTALL,
        )
        for link_match in link_pattern.finditer(section_html):
            uuid = link_match.group(1)
            title = link_match.group(2).strip()
            events.append(
                _PitsportEvent(category=category, title=title, watch_uuid=uuid)
            )

    # Strategy 2: Parse from RSC payload if rendered HTML didn't yield results
    # The RSC payload has patterns like:
    #   "children":"Formula 1"}] ... "/watch/UUID" ... "title":"EventTitle"
    if not events:
        events = _parse_schedule_rsc(html)

    return events


def _parse_schedule_rsc(html: str) -> list[_PitsportEvent]:
    """Parse events from schedule page RSC payload as fallback.

    Extracts category section divs from the RSC JSON structure.
    """
    events: list[_PitsportEvent] = []

    # Find the RSC payload chunks
    rsc_chunks = re.findall(
        r'self\.__next_f\.push\(\[1,"(.*?)"\]\)', html, re.DOTALL
    )
    if not rsc_chunks:
        return events

    # Concatenate and unescape
    full_payload = ""
    for chunk in rsc_chunks:
        try:
            full_payload += chunk.encode().decode("unicode_escape")
        except Exception:
            full_payload += chunk

    # Find category sections in the RSC data
    # Pattern: "children":"CategoryName"}],["$","div",...watch links...
    # Each section div contains an h2 with the category name and watch links
    cat_pattern = re.compile(
        r'border-gray-700 pb-2","children":"([^"]+)"\}.*?'
        r'(?=border-gray-700 pb-2","children"|$)',
        re.DOTALL,
    )
    for cat_match in cat_pattern.finditer(full_payload):
        category = cat_match.group(1)
        section_text = cat_match.group(0)

        # Find watch UUIDs and titles in this section
        # Pattern: "/watch/UUID" ... "title":"EventTitle"
        event_pattern = re.compile(
            r'/watch/([0-9a-f-]{36}).*?"title":"([^"]+)"',
        )
        for ev_match in event_pattern.finditer(section_text):
            uuid = ev_match.group(1)
            title = ev_match.group(2)
            events.append(
                _PitsportEvent(category=category, title=title, watch_uuid=uuid)
            )

    return events


def _parse_embed_uuids(html: str) -> list[str]:
    """Extract embed UUIDs from a watch page.

    Watch pages contain iframes like:
        <iframe src="https://pushembdz.store/embed/{EMBED_UUID}" ...>

    And in the RSC payload:
        "iframe":"https://pushembdz.store/embed/{EMBED_UUID}"
    """
    uuids: list[str] = []

    # From rendered HTML
    iframe_pattern = re.compile(
        r'pushembdz\.store/embed/([0-9a-f-]{36})',
    )
    for match in iframe_pattern.finditer(html):
        uuid = match.group(1)
        if uuid not in uuids:
            uuids.append(uuid)

    return uuids


@dataclass
class _StreamConfig:
    """Stream configuration extracted from an embed page."""

    title: str
    link: str
    method: str


def _parse_stream_config(html: str) -> _StreamConfig | None:
    """Extract stream config from an embed page RSC payload.

    The embed page now uses a `safeStream` payload that elides the link:
        4:["$","$Ld",null,{"safeStream":{"title":"Rally TV","method":"jwp"},
           "error":null,"slug":"..."}]
    The actual stream URL is fetched at runtime via
    pushembdz.store/api/stream/<slug>. Older payloads used "stream" with
    inline title+link+method — kept as fallback.
    """
    # Current format: safeStream with title + method only (link via API).
    pattern_safe = re.compile(
        r'\\?"safeStream\\?"\s*:\s*\{'
        r'\\?"title\\?"\s*:\s*\\?"([^"\\]+)\\?"\s*,\s*'
        r'\\?"method\\?"\s*:\s*\\?"([^"\\]+)\\?"',
    )
    match = pattern_safe.search(html)
    if match:
        return _StreamConfig(
            title=match.group(1),
            link="",  # filled in by the caller via the api/stream endpoint
            method=match.group(2),
        )

    # Legacy: escaped RSC payload with inline link.
    pattern = re.compile(
        r'"stream":\{["\']?\\?"title\\?"["\']?:["\']?\\?"([^"\\]+)\\?"["\']?,'
        r'["\']?\\?"link\\?"["\']?:["\']?\\?"([^"\\]+)\\?"["\']?,'
        r'["\']?\\?"method\\?"["\']?:["\']?\\?"([^"\\]+)\\?"',
    )
    match = pattern.search(html)
    if match:
        return _StreamConfig(title=match.group(1), link=match.group(2), method=match.group(3))

    pattern2 = re.compile(
        r'\\?"stream\\?":\{\\?"title\\?":\\?"([^\\]+)\\?",'
        r'\\?"link\\?":\\?"([^\\]+)\\?",'
        r'\\?"method\\?":\\?"([^\\]+)\\?"',
    )
    match = pattern2.search(html)
    if match:
        return _StreamConfig(title=match.group(1), link=match.group(2), method=match.group(3))

    pattern3 = re.compile(
        r'"stream"\s*:\s*\{\s*"title"\s*:\s*"([^"]+)"\s*,'
        r'\s*"link"\s*:\s*"([^"]+)"\s*,'
        r'\s*"method"\s*:\s*"([^"]+)"',
    )
    match = pattern3.search(html)
    if match:
        return _StreamConfig(title=match.group(1), link=match.group(2), method=match.group(3))

    return None


def _is_m3u8_method(method: str) -> bool:
    """Check if the stream method indicates a direct HLS stream."""
    # `jwp` (current pushembdz format) returns an m3u8 from the api/stream
    # endpoint regardless of player UI; treat it as HLS.
    return method.lower() in ("player", "hls", "jwp")


def _extract_m3u8_url(link: str) -> str:
    """Convert a serveplay.site player URL to an m3u8 playlist URL.

    Input:  https://dash.serveplay.site/{channel}/index.html
    Output: https://dash.serveplay.site/{channel}/index.html

    The index.html IS the m3u8 playlist (served with proper content-type
    when fetched with the correct Referer header).
    """
    return link


class PitsportExtractor(BaseExtractor):
    """Extracts F1 streams from Pitsport.xyz.

    Scrapes the Next.js RSC payload from the main page and schedule page
    to find F1 events, then resolves embed UUIDs to stream configurations.
    """

    @property
    def site_key(self) -> str:
        return "pitsport"

    @property
    def site_name(self) -> str:
        return "Pitsport"

    async def extract(self) -> list[ExtractedStream]:
        """Fetch F1 events and return stream URLs or embed URLs."""
        streams: list[ExtractedStream] = []

        try:
            async with httpx.AsyncClient(
                timeout=20.0,
                follow_redirects=True,
                headers={"User-Agent": USER_AGENT},
            ) as client:
                # Fetch both pages to get comprehensive event data
                events = await self._discover_events(client)
                logger.info(
                    "[pitsport] Found %d F1 event(s) to process", len(events)
                )

                # Deduplicate by watch UUID
                seen_uuids: set[str] = set()
                unique_events: list[_PitsportEvent] = []
                for ev in events:
                    if ev.watch_uuid not in seen_uuids:
                        seen_uuids.add(ev.watch_uuid)
                        unique_events.append(ev)

                # For each event, resolve streams
                for event in unique_events:
                    event_streams = await self._resolve_event_streams(
                        client, event
                    )
                    streams.extend(event_streams)

        except Exception:
            logger.exception("[pitsport] Failed to extract streams")

        logger.info("[pitsport] Extracted %d stream(s)", len(streams))
        return streams

    async def _discover_events(
        self, client: httpx.AsyncClient
    ) -> list[_PitsportEvent]:
        """Discover F1 events from both main page and schedule page."""
        all_events: list[_PitsportEvent] = []

        # Fetch main page for live events
        try:
            resp = await client.get(PITSPORT_BASE)
            if resp.status_code == 200:
                live_events = _parse_live_events(resp.text)
                logger.info(
                    "[pitsport] Main page: %d live event(s)", len(live_events)
                )
                for ev in live_events:
                    if _is_f1_event(ev.category, ev.title):
                        all_events.append(ev)
            else:
                logger.warning(
                    "[pitsport] Main page returned HTTP %d", resp.status_code
                )
        except Exception:
            logger.exception("[pitsport] Failed to fetch main page")

        # Fetch schedule page for upcoming events
        try:
            resp = await client.get(f"{PITSPORT_BASE}/schedule")
            if resp.status_code == 200:
                schedule_events = _parse_schedule_events(resp.text)
                logger.info(
                    "[pitsport] Schedule page: %d total event(s)",
                    len(schedule_events),
                )
                for ev in schedule_events:
                    if _is_f1_event(ev.category, ev.title):
                        all_events.append(ev)
            else:
                logger.warning(
                    "[pitsport] Schedule page returned HTTP %d",
                    resp.status_code,
                )
        except Exception:
            logger.exception("[pitsport] Failed to fetch schedule page")

        return all_events

    async def _resolve_event_streams(
        self, client: httpx.AsyncClient, event: _PitsportEvent
    ) -> list[ExtractedStream]:
        """Resolve an event's watch page to actual stream URLs."""
        streams: list[ExtractedStream] = []

        try:
            # Fetch the watch page to get embed UUIDs
            watch_url = f"{PITSPORT_BASE}/watch/{event.watch_uuid}"
            resp = await client.get(watch_url)
            if resp.status_code != 200:
                logger.debug(
                    "[pitsport] Watch page %s returned HTTP %d",
                    event.watch_uuid,
                    resp.status_code,
                )
                return []

            embed_uuids = _parse_embed_uuids(resp.text)
            if not embed_uuids:
                logger.debug(
                    "[pitsport] No embed UUIDs found for %s", event.watch_uuid
                )
                return []

            logger.debug(
                "[pitsport] Event '%s' has %d embed(s)",
                event.title,
                len(embed_uuids),
            )

            # Resolve each embed to a stream config
            for i, embed_uuid in enumerate(embed_uuids):
                stream = await self._resolve_embed(
                    client, embed_uuid, event, stream_num=i + 1
                )
                if stream:
                    streams.append(stream)

        except Exception:
            logger.debug(
                "[pitsport] Failed to resolve event %s",
                event.watch_uuid,
                exc_info=True,
            )

        return streams

    async def _resolve_embed(
        self,
        client: httpx.AsyncClient,
        embed_uuid: str,
        event: _PitsportEvent,
        stream_num: int,
    ) -> ExtractedStream | None:
        """Resolve an embed UUID to a stream configuration."""
        try:
            embed_url = f"{EMBED_BASE}/embed/{embed_uuid}"
            resp = await client.get(embed_url)
            if resp.status_code != 200:
                logger.debug(
                    "[pitsport] Embed page %s returned HTTP %d",
                    embed_uuid,
                    resp.status_code,
                )
                return None

            config = _parse_stream_config(resp.text)
            if not config:
                logger.debug(
                    "[pitsport] No stream config found in embed %s",
                    embed_uuid,
                )
                return None

            # Build the stream title
            stream_title = f"{event.category} - {event.title}"
            if config.title:
                stream_title += f" ({config.title})"
            if stream_num > 1:
                stream_title += f" #{stream_num}"

            # `safeStream` payload elides the link — fetch it from the
            # pushembdz.store/api/stream/<slug> endpoint. Older `stream`
            # payloads provided the link inline.
            link = config.link
            if not link and _is_m3u8_method(config.method):
                api_url = f"{EMBED_BASE}/api/stream/{embed_uuid}"
                try:
                    api_resp = await client.get(
                        api_url,
                        headers={"Referer": embed_url, "Accept": "application/json"},
                    )
                    if api_resp.status_code == 200:
                        link = (api_resp.json() or {}).get("link", "")
                except Exception:
                    logger.debug(
                        "[pitsport] api/stream lookup failed for %s",
                        embed_uuid,
                        exc_info=True,
                    )

            # Treat any HLS-ish URL (m3u8, or pushembdz's .css disguise) as m3u8.
            looks_hls = link and (".m3u8" in link or link.endswith(".css") or "serveplay.site" in link)
            if _is_m3u8_method(config.method) and looks_hls:
                return ExtractedStream(
                    url=link,
                    site_key=self.site_key,
                    site_name=self.site_name,
                    quality="",
                    title=stream_title,
                    stream_type="m3u8",
                )
            else:
                # Iframe embed fallback
                return ExtractedStream(
                    url=embed_url,
                    site_key=self.site_key,
                    site_name=self.site_name,
                    quality="",
                    title=stream_title,
                    stream_type="embed",
                    embed_url=embed_url,
                )

        except Exception:
            logger.debug(
                "[pitsport] Failed to resolve embed %s",
                embed_uuid,
                exc_info=True,
            )
            return None
