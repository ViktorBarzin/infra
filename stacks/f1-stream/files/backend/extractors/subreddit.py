"""Subreddit extractor — pulls live-stream posts from motorsport subreddits.

Uses the public old.reddit.com JSON API (no auth required) to discover
posts in r/MotorsportsReplays, r/motorsports, r/MotorsportsStreaming etc.
that are tagged "Live" or whose title matches motorsport stream keywords.

Each candidate URL is then sent to the chrome-service-driven pipeline
(via ChromeBrowserExtractor.scrape one-off) so the m3u8 is captured even
when the link points to an aggregator page rather than a direct playlist.
"""

import asyncio
import logging
import re
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

# Subreddits to scan. old.reddit.com serves the public JSON API anonymously
# without the auth wall the new site bounces requests off.
SUBREDDITS: tuple[str, ...] = (
    "MotorsportsReplays",
    "motorsports",
    "formula1",
    "motogp",
)

# Reject post URLs we already know don't yield playable streams (Discord
# invite links, social media, paywalled F1TV, our own host).
_REJECT_HOSTS = {
    "discord.gg", "discord.com", "twitter.com", "x.com",
    "youtube.com", "youtu.be", "instagram.com", "tiktok.com",
    "f1tv.formula1.com", "viktorbarzin.me",
}

_LIVE_KEYWORDS = re.compile(r"\b(live|stream|fp1|fp2|fp3|qualifying|race|session|grand prix|gp\b|sprint)\b", re.I)


class _RedditPost(NamedTuple):
    title: str
    url: str
    subreddit: str
    flair: str


def _interesting(post: _RedditPost) -> bool:
    if not post.url:
        return False
    if any(host in post.url for host in _REJECT_HOSTS):
        return False
    if (post.flair or "").lower() in {"live", "live stream", "stream"}:
        return True
    text = f"{post.title} {post.flair or ''}"
    return bool(_LIVE_KEYWORDS.search(text))


class SubredditExtractor(BaseExtractor):
    """Scan motorsport subreddits for live-stream candidate URLs."""

    @property
    def site_key(self) -> str:
        return "subreddit"

    @property
    def site_name(self) -> str:
        return "Subreddit"

    async def extract(self) -> list[ExtractedStream]:
        async with httpx.AsyncClient(
            timeout=15.0,
            follow_redirects=True,
            headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
        ) as client:
            tasks = [self._fetch(client, sub) for sub in SUBREDDITS]
            results = await asyncio.gather(*tasks, return_exceptions=True)

        candidates: list[_RedditPost] = []
        for r in results:
            if isinstance(r, Exception):
                logger.debug("[subreddit] fetch failed: %s", r)
                continue
            candidates.extend(r)

        # Filter to live-stream posts and dedupe by URL.
        seen: set[str] = set()
        picks: list[_RedditPost] = []
        for p in candidates:
            if not _interesting(p):
                continue
            if p.url in seen:
                continue
            seen.add(p.url)
            picks.append(p)

        logger.info(
            "[subreddit] %d post(s) across %d sub(s) — %d live-stream candidate(s)",
            len(candidates), len(SUBREDDITS), len(picks),
        )
        # Hand off URL discovery to the existing chrome-service pipeline
        # via ChromeBrowserExtractor — but in lazy form: we register the
        # discovered URL as an `embed`-type stream so the verifier visits
        # it, captures the actual m3u8 via JS, and (if successful) marks
        # is_live=True. The frontend will iframe it for playback.
        return [
            ExtractedStream(
                url=p.url,
                site_key=self.site_key,
                site_name=f"Subreddit r/{p.subreddit}",
                quality="",
                title=p.title[:100],
                stream_type="embed",
                embed_url=p.url,
            )
            for p in picks
        ]

    async def _fetch(self, client: httpx.AsyncClient, sub: str) -> list[_RedditPost]:
        url = f"https://old.reddit.com/r/{sub}/new.json?limit=25"
        try:
            resp = await client.get(url)
        except Exception as e:
            logger.debug("[subreddit] r/%s fetch failed: %s", sub, e)
            return []
        if resp.status_code != 200:
            logger.debug("[subreddit] r/%s HTTP %d", sub, resp.status_code)
            return []
        try:
            data = resp.json()
        except Exception:
            return []
        posts: list[_RedditPost] = []
        for child in (data.get("data", {}) or {}).get("children", []):
            d = child.get("data", {}) or {}
            posts.append(
                _RedditPost(
                    title=d.get("title", "") or "",
                    url=d.get("url", "") or "",
                    subreddit=sub,
                    flair=d.get("link_flair_text", "") or "",
                )
            )
        return posts
