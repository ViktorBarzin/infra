"""Subreddit extractor — pulls community-curated live-stream URLs from
the *MotorsportsReplays* subreddit (and a few siblings).

The community follows a stable pattern: a single mod-curated post titled
`[Watch / Download] <Series> <Year> - <Round> | <Event>` goes up on or
near each race weekend with a `**Watch Online:**` link in the selftext,
pointing at an admin-run WordPress site (motomundo.net for MotoGP, the
F1 equivalent has rotated over the years). That WordPress page hosts
iframe embeds whose m3u8 is JS-computed at load time — ideal target for
the chrome-service pipeline downstream.

This extractor:
- Hits Reddit with a real-browser User-Agent (httpx default UA + cluster
  IP combo gets HTTP 403'd on r/motogp; a Safari UA does not).
- Searches for the `[Watch` thread pattern AND scans `/new.json` for
  any flair set to LIVE.
- Pulls selftext URLs and returns each candidate as an `embed`-type
  ExtractedStream. The verifier already drives chrome-service for embed
  streams, so the m3u8 capture happens there.
"""

import asyncio
import logging
import re
import urllib.parse
from typing import NamedTuple

import httpx

from backend.extractors.base import BaseExtractor
from backend.extractors.models import ExtractedStream

logger = logging.getLogger(__name__)

USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) "
    "Version/17.4 Safari/605.1.15"
)

# Subreddits to scan. r/MotorsportsReplays is the main signal; the others
# rarely have stream posts but cost nothing to skim.
SUBREDDITS: tuple[str, ...] = (
    "MotorsportsReplays",
    "motorsports",
    "formula1",
    "motogp",
)

# Search queries to fire against r/MotorsportsReplays (the ones below
# capture the consistent mod-post pattern). Encoded into the JSON
# search endpoint.
SEARCH_QUERIES: tuple[str, ...] = (
    "Watch Download F1 2026",
    "Watch Download MotoGP 2026",
    "Watch Online F1 2026",
    "Watch Online MotoGP 2026",
)

# Hosts we accept as "interesting" stream-page URLs. These are the
# admin-curated WordPress / aggregator sites the community links to.
# motomundo.net hosts MotoGP; new entries can be added freely.
_INTERESTING_HOSTS = (
    "motomundo.net",        # MotoGP
    "motomundo.top",        # MotoMundo embed host
    "motomundo.upns.xyz",   # MotoMundo embed host (newer)
    "freemotorsports.com",  # community curated link list
    "pitsport.xyz",         # in case a Reddit poster links it
    "rerace.io",            # F1 archives + live (when up)
    "dd12streams.com",      # live aggregator
    "f1mundo.net",          # speculative F1 sister to motomundo
    "f1.live",
    "f1live",
    "skystreams",
    "raceon",
    "watchf1",
)

# URLs we actively never try to scrape (auth-walled, social media,
# direct downloads with no live stream).
_REJECT_HOSTS = (
    "discord.gg", "discord.com",
    "twitter.com", "x.com",
    "youtube.com", "youtu.be",
    "instagram.com", "tiktok.com",
    "f1tv.formula1.com",
    "viktorbarzin.me",
    "gofile.io",
    "mega.nz", "drive.google.com",
    "1fichier.com", "rapidgator", "uploaded.net",
    "magnet:",
)

_URL_RE = re.compile(r"https?://[^\s\)\]\>\"']+")


class _Candidate(NamedTuple):
    title: str
    url: str
    subreddit: str
    flair: str


def _is_interesting(url: str) -> bool:
    low = url.lower()
    if any(host in low for host in _REJECT_HOSTS):
        return False
    return any(host in low for host in _INTERESTING_HOSTS)


def _has_live_marker(post: dict) -> bool:
    title = (post.get("title") or "").lower()
    flair = (post.get("link_flair_text") or "").lower()
    if "[watch" in title or "watch online" in title or "live" in flair:
        return True
    return False


class SubredditExtractor(BaseExtractor):
    """Scan motorsport subreddits for community-curated live-stream URLs."""

    @property
    def site_key(self) -> str:
        return "subreddit"

    @property
    def site_name(self) -> str:
        return "Subreddit"

    async def extract(self) -> list[ExtractedStream]:
        # NB: do NOT send `Accept: application/json` — Reddit's anti-bot
        # fingerprint flags that header from datacenter IPs and returns
        # HTTP 403 with HTML. Default Accept (`*/*`) gets through fine
        # and `.json` URLs always return JSON regardless.
        async with httpx.AsyncClient(
            timeout=15.0,
            follow_redirects=True,
            headers={"User-Agent": USER_AGENT},
        ) as client:
            tasks = [self._fetch_new(client, sub) for sub in SUBREDDITS]
            tasks.extend(self._search(client, q) for q in SEARCH_QUERIES)
            results = await asyncio.gather(*tasks, return_exceptions=True)

        candidates: list[_Candidate] = []
        for r in results:
            if isinstance(r, Exception):
                logger.debug("[subreddit] fetch failed: %s", r)
                continue
            candidates.extend(r)

        # Dedupe by URL, keep first occurrence.
        seen: set[str] = set()
        picks: list[_Candidate] = []
        for c in candidates:
            if c.url in seen:
                continue
            seen.add(c.url)
            picks.append(c)

        logger.info(
            "[subreddit] scanned %d source(s) — %d unique candidate URL(s)",
            len(SUBREDDITS) + len(SEARCH_QUERIES), len(picks),
        )
        return [
            ExtractedStream(
                url=c.url,
                site_key=self.site_key,
                site_name=f"r/{c.subreddit}",
                quality="",
                title=c.title[:100],
                stream_type="embed",
                embed_url=c.url,
            )
            for c in picks
        ]

    async def _fetch_new(self, client: httpx.AsyncClient, sub: str) -> list[_Candidate]:
        return await self._collect(
            client,
            f"https://www.reddit.com/r/{sub}/new.json?limit=25",
            sub,
        )

    async def _search(self, client: httpx.AsyncClient, query: str) -> list[_Candidate]:
        q = urllib.parse.quote_plus(query)
        return await self._collect(
            client,
            f"https://www.reddit.com/r/MotorsportsReplays/search.json?q={q}&restrict_sr=on&sort=new&limit=10",
            "MotorsportsReplays",
        )

    async def _collect(
        self, client: httpx.AsyncClient, url: str, sub: str
    ) -> list[_Candidate]:
        try:
            resp = await client.get(url)
        except Exception as e:
            logger.debug("[subreddit] fetch %s failed: %s", url, e)
            return []
        if resp.status_code != 200:
            logger.debug("[subreddit] %s -> HTTP %d", url, resp.status_code)
            return []
        try:
            data = resp.json()
        except Exception:
            return []
        out: list[_Candidate] = []
        for child in (data.get("data", {}) or {}).get("children", []):
            d = child.get("data", {}) or {}
            if not _has_live_marker(d):
                continue
            text = (d.get("selftext") or "")
            title = d.get("title") or ""
            flair = d.get("link_flair_text") or ""
            # First, the linked URL itself (if it's a recognised live site).
            top = d.get("url") or ""
            if top and _is_interesting(top):
                out.append(_Candidate(title, top, sub, flair))
            # Then any URL embedded in the selftext that points at a
            # community-curated live page.
            for u in _URL_RE.findall(text):
                if _is_interesting(u):
                    out.append(_Candidate(title, u, sub, flair))
        return out
