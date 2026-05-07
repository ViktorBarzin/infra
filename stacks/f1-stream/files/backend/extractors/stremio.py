"""Stremio-addon-driven extractor.

Stremio addons expose a public HTTP API: each addon has a manifest at
`<base>/manifest.json` and per-resource endpoints like
`<base>/stream/<type>/<id>.json` returning `{streams:[{url,name,...}]}`.

This extractor calls a curated set of live-TV addons that surface F1
and Sky-Sports-class motorsport channels. We treat each returned URL as
an ExtractedStream and let the playback verifier confirm playability.
We don't need a Stremio client — we just call the documented HTTP API.

Findings from initial research (2026-05-07):
- **TvVoo** (`tvvoo.hayd.uk`) — wraps the Vavoo IPTV network, lists
  Sky Sports F1 (UK + IT + DE), DAZN F1, Movistar F1, Canal+ F1,
  Viaplay F1. The returned m3u8 URLs are IP-bound at the Vavoo CDN
  (`*.ngolpdkyoctjcddxshli469r.org/sunshine/...`); they're tokenised
  to whichever IP fetched the manifest. Currently their SSL certs have
  expired which fails most clients — the addon framework is right but
  delivery is degraded today.
- **StremVerse** (`stremverse.onrender.com`) — returns 11+ streams per
  catalog id (`stremevent_591`=F1, `stremevent_866`=MotoGP). Mix of
  DRM-walled DASH, JW-Player-broken-chain JWT, and apar151 HuggingFace
  proxy URLs. Master playlists parse; variant URLs sometimes return 404
  if they're meant to be resolved by the addon's player rather than
  directly.

Adding a new addon = one entry in `_ADDONS`. Each addon's resolver only
needs the manifest + stream endpoints; the addon does the heavy lifting.
"""

import asyncio
import logging
from dataclasses import dataclass
from typing import Iterable

import httpx

from backend.extractors.base import BaseExtractor
from backend.extractors.models import ExtractedStream

logger = logging.getLogger(__name__)

USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) "
    "Version/17.4 Safari/605.1.15"
)


@dataclass(frozen=True)
class _Addon:
    name: str
    base: str               # e.g. "https://tvvoo.hayd.uk"
    stream_ids: tuple[tuple[str, str, str], ...]
    """(stream_type, stream_id, label) per F1/motorsport entry."""


# Curated addon list — see module docstring. These IDs are documented in
# the addons' manifests / channel lists. Update when channel names/IDs
# rotate.
_ADDONS: tuple[_Addon, ...] = (
    _Addon(
        name="TvVoo",
        base="https://tvvoo.hayd.uk",
        stream_ids=(
            ("tv", "vavoo_SKY%20SPORTS%20F1|group:uk", "Sky Sports F1 UK (Vavoo)"),
            ("tv", "vavoo_SKY%20SPORTS%20F1%20HD|group:uk", "Sky Sports F1 HD UK (Vavoo)"),
            ("tv", "vavoo_SKY%20SPORT%20F1|group:it", "Sky Sport F1 IT (Vavoo)"),
            ("tv", "vavoo_SKY%20SPORT%20F1%20HD|group:de", "Sky Sport F1 DE (Vavoo)"),
            ("tv", "vavoo_DAZN%20F1|group:es", "DAZN F1 ES (Vavoo)"),
        ),
    ),
    _Addon(
        name="StremVerse",
        base="https://stremverse.onrender.com",
        stream_ids=(
            ("tv", "stremevent_591", "Formula 1 (StremVerse)"),
            ("tv", "stremevent_866", "MotoGP (StremVerse)"),
        ),
    ),
)


class StremioAddonExtractor(BaseExtractor):
    """Pull F1 + Sky-class motorsport URLs from public Stremio addons."""

    @property
    def site_key(self) -> str:
        return "stremio"

    @property
    def site_name(self) -> str:
        return "Stremio Addon"

    async def extract(self) -> list[ExtractedStream]:
        async with httpx.AsyncClient(
            timeout=15.0,
            follow_redirects=True,
            headers={"User-Agent": USER_AGENT},
            # Some addons (TvVoo→Vavoo) hand back URLs whose origin certs
            # are expired; honest-default verify=True is preserved here so
            # the verifier sees the same TLS errors a browser would.
        ) as client:
            tasks = []
            for addon in _ADDONS:
                for stype, sid, label in addon.stream_ids:
                    tasks.append(self._resolve(client, addon, stype, sid, label))
            results = await asyncio.gather(*tasks, return_exceptions=True)

        streams: list[ExtractedStream] = []
        for r in results:
            if isinstance(r, Exception):
                logger.debug("[stremio] resolve failed: %s", r)
                continue
            streams.extend(r)

        logger.info("[stremio] surfaced %d candidate stream URL(s) across %d addon(s)",
                    len(streams), len(_ADDONS))
        return streams

    async def _resolve(
        self, client: httpx.AsyncClient, addon: _Addon,
        stype: str, sid: str, label: str,
    ) -> list[ExtractedStream]:
        url = f"{addon.base}/stream/{stype}/{sid}.json"
        try:
            resp = await client.get(url)
        except Exception as e:
            logger.debug("[stremio] %s fetch failed: %s", url, e)
            return []
        if resp.status_code != 200:
            logger.debug("[stremio] %s -> HTTP %d", url, resp.status_code)
            return []
        try:
            data = resp.json()
        except Exception:
            return []

        out: list[ExtractedStream] = []
        for idx, s in enumerate(data.get("streams") or []):
            stream_url = (s.get("url") or "").strip()
            if not stream_url:
                continue
            # Skip DRM-tagged entries — they need Widevine which neither
            # our verifier nor a clean hls.js path can play.
            if "DRM" in (s.get("name") or "").upper():
                continue
            title = label
            if idx > 0:
                title = f"{label} #{idx + 1}"
            out.append(
                ExtractedStream(
                    url=stream_url,
                    site_key=self.site_key,
                    site_name=f"{addon.name}",
                    quality="",
                    title=title,
                    stream_type="m3u8",
                )
            )
        return out
