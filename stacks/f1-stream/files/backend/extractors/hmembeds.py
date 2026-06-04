"""hmembeds.one decoder + extractor.

Reverse-engineered 2026-05-07 (4-agent parallel session). The hmembeds
embed page contains an inline `<script>` block of the form:

    var k = "<16-char ASCII key>";
    var b = atob("<URI-encoded XOR-encrypted blob>");
    var c = decodeURIComponent(escape(b));
    var d = "";
    for (var i = 0; i < c.length; i++)
      d += String.fromCharCode(c.charCodeAt(i) ^ k.charCodeAt(i % k.length));
    (new Function(d))();

The decoded `d` is plain JavaScript that calls `jwplayer('player').setup({
file: <m3u8_url>, ... })`. The `<m3u8_url>` is a JWT-bound URL on
`amsterdam-0183.zulo-0084.online/sec/<JWT>/<embed_id>.m3u8` where the
JWT pins the request to a /24 of the requestor's IP.

So: pure client-side decoding. No fingerprint check, no canvas hash, no
browser-derived input. We can produce the m3u8 URL with curl + Python
faster than launching Chromium.

**Caveat (2026-05-07 reality)**: the hmembeds backend issues JWT URLs
for the curated `888520f3...` (Sky Sports F1 24/7) and `fc3a5463...`
(DAZN F1 24/7) embeds, but the origin (`amsterdam-0183.zulo-0084.online`)
returns 404/403 on the m3u8 fetch from any IP we tested (cluster IPv4
176.12.22.x, dev VM IPv6 2001:470:6f:43d::). Both legacy embed IDs
appear to be offline upstream. This extractor will produce JWT URLs
that the verifier marks unplayable for those specific embeds; if the
upstream broadcasts come back online or fresh IDs are added, the same
extractor logic just works.
"""

import base64
import logging
import re
import urllib.parse

import httpx

from backend.extractors.base import BaseExtractor
from backend.extractors.models import ExtractedStream

logger = logging.getLogger(__name__)

USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) "
    "Version/17.4 Safari/605.1.15"
)

# Curated hmembeds embed IDs that the community treats as 24/7 channels.
# `_CHANNELS` mirrors the legacy `CuratedExtractor` list — keeping them
# here means the resolver can attempt offline-decoded JWT URLs and the
# verifier filters out the ones that are upstream-offline.
_CHANNELS = (
    ("888520f36cd94c5da4c71fddc1a5fc9b", "Sky Sports F1 (24/7) — hmembeds"),
    ("fc3a54634d0867b0c02ee3223292e7c6", "DAZN F1 (24/7) — hmembeds"),
)

_KEY_RE = re.compile(r'k\s*=\s*"([a-z0-9]+)"')
_BLOB_RE = re.compile(r'b\s*=\s*atob\("([^"]+)"\)')
_URL_RE = re.compile(r'streamUrl\s*=\s*"([^"]+)"')


def decode_embed(html: str) -> str | None:
    """Pull the m3u8 URL out of an hmembeds embed HTML.

    Returns the JWT-bound m3u8 URL the page would tell JW Player to
    play, or None if the page doesn't match the expected shape.
    """
    km = _KEY_RE.search(html)
    bm = _BLOB_RE.search(html)
    if not km or not bm:
        return None
    key = km.group(1)
    blob = bm.group(1)
    try:
        # b = atob(blob)              — base64-decode bytes
        # c = decodeURIComponent(escape(b))   — Latin-1 → UTF-8 round-trip
        # d[i] = c[i] ^ k[i % len(k)]         — XOR with rotating key
        raw = base64.b64decode(blob).decode("latin-1")
        deuri = urllib.parse.unquote(raw)
        decoded = "".join(
            chr(ord(c) ^ ord(key[i % len(key)])) for i, c in enumerate(deuri)
        )
    except Exception:
        return None
    m = _URL_RE.search(decoded)
    return m.group(1) if m else None


class HmembedsExtractor(BaseExtractor):
    @property
    def site_key(self) -> str:
        return "hmembeds"

    @property
    def site_name(self) -> str:
        return "hmembeds.one"

    async def extract(self) -> list[ExtractedStream]:
        results: list[ExtractedStream] = []
        async with httpx.AsyncClient(
            timeout=15.0,
            follow_redirects=True,
            headers={"User-Agent": USER_AGENT, "Referer": "https://hmembeds.one/"},
        ) as client:
            for embed_id, label in _CHANNELS:
                try:
                    page = await client.get(f"https://hmembeds.one/embed/{embed_id}")
                except Exception:
                    logger.debug("[hmembeds] embed %s fetch failed", embed_id, exc_info=True)
                    continue
                if page.status_code != 200:
                    continue
                m3u8 = decode_embed(page.text)
                if not m3u8:
                    continue
                results.append(
                    ExtractedStream(
                        url=m3u8,
                        site_key=self.site_key,
                        site_name=self.site_name,
                        quality="",
                        title=label,
                        stream_type="m3u8",
                    )
                )
        logger.info("[hmembeds] resolved %d JWT URL(s) (verifier filters dead origins)", len(results))
        return results
