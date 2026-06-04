"""Aceztrims extractor — scrapes embed URLs from acestrlms.pages.dev/f11/.

The page (Cloudflare Pages, no anti-bot) hosts an iframe + a strip of
onclick channel-switcher buttons. Each button rewrites the iframe via
`document.getElementById('iframe').src = '<embed_url>'`. The initial
channel is hard-coded as `<iframe id='iframe' src='...'>`.

We strip HTML comments first because the page keeps ~20 legacy channel
buttons inside `<!-- ... -->` blocks for easy re-enablement; the previous
loose regex picked them up as false positives.

All channels are iframe embeds (no direct m3u8) — `stream_type='embed'`.

Site naming note: the extractor key stays `aceztrims` (the previous
domain) so registry/cache identifiers don't churn. The current domain
is `acestrlms.pages.dev` and the F1 path is `/f11/` (two ones — `/f1/`
is the cross-sport schedule page and has no stream buttons).
"""

import logging
import re

import httpx

from backend.extractors.base import BaseExtractor
from backend.extractors.models import ExtractedStream

logger = logging.getLogger(__name__)

BASE_URL = "https://acestrlms.pages.dev"
F1_PAGES = [
    ("/f11/", "Formula 1"),
]

USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/120.0.0.0 Safari/537.36"
)

# `document.getElementById('iframe').src = '<URL>'` — current channel-switcher format.
_ONCLICK_IFRAME_SRC = re.compile(
    r"""document\.getElementById\(['"]iframe['"]\)\.src\s*=\s*['"]([^'"]+)['"]""",
    re.IGNORECASE,
)
# `<iframe id='iframe' src='<URL>'>` — the default/initial channel.
_DEFAULT_IFRAME = re.compile(
    r"""<iframe[^>]*id\s*=\s*['"]iframe['"][^>]*src\s*=\s*['"]([^'"]+)['"]""",
    re.IGNORECASE,
)
_HTML_COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)


class AceztrimsExtractor(BaseExtractor):
    """Pulls iframe embed URLs out of the acestrlms.pages.dev F1 page."""

    @property
    def site_key(self) -> str:
        return "aceztrims"

    @property
    def site_name(self) -> str:
        return "Aceztrims"

    async def extract(self) -> list[ExtractedStream]:
        streams: list[ExtractedStream] = []

        async with httpx.AsyncClient(
            timeout=15.0,
            follow_redirects=True,
            headers={"User-Agent": USER_AGENT},
        ) as client:
            for path, category in F1_PAGES:
                try:
                    streams.extend(await self._scrape_page(client, path, category))
                except Exception:
                    logger.exception("[aceztrims] Failed to scrape %s", path)

        logger.info("[aceztrims] Extracted %d stream(s)", len(streams))
        return streams

    async def _scrape_page(
        self, client: httpx.AsyncClient, path: str, category: str
    ) -> list[ExtractedStream]:
        url = f"{BASE_URL}{path}"
        resp = await client.get(url)
        if resp.status_code != 200:
            logger.warning(
                "[aceztrims] %s returned HTTP %d", path, resp.status_code
            )
            return []

        # The page keeps a block of legacy channel buttons inside
        # `<!-- ... -->` for quick re-enablement. Strip comments first so
        # the regex only sees live buttons.
        html = _HTML_COMMENT.sub("", resp.text)

        seen: set[str] = set()
        streams: list[ExtractedStream] = []

        for pattern in (_DEFAULT_IFRAME, _ONCLICK_IFRAME_SRC):
            for match in pattern.finditer(html):
                embed_url = match.group(1).strip()
                if not embed_url or embed_url in seen:
                    continue
                seen.add(embed_url)
                streams.append(
                    ExtractedStream(
                        url=embed_url,
                        site_key=self.site_key,
                        site_name=self.site_name,
                        quality="",
                        title=f"{category} Stream",
                        stream_type="embed",
                        embed_url=embed_url,
                    )
                )

        logger.info(
            "[aceztrims] Found %d stream(s) on %s", len(streams), path
        )
        return streams
