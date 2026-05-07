"""Generic chrome-service-driven extractor.

Drives the in-cluster headed Chromium pool (chrome-service) to load a list
of stream/aggregator pages, captures any HLS playlist URL the page fetches
at runtime, and returns one ExtractedStream per discovered playlist.

Unlike the API-based extractors (pitsport/streamed/ppv) this one handles
sites where the m3u8 is computed by JavaScript at page load time — the
URL only exists after the page evaluates an obfuscated decoder, fetches a
token, etc. Curl can't see it; a real browser can.

Add new targets via the `TARGETS` constant below. Each entry is a (label,
title, page_url) tuple. The extractor visits each URL with a stealthed
context, waits for the JS to settle, and yields any captured HLS URL.
"""

import asyncio
import logging
import os
import re
import urllib.parse
from dataclasses import dataclass

from backend.extractors.base import BaseExtractor
from backend.extractors.models import ExtractedStream

logger = logging.getLogger(__name__)

# Best-effort pause between navigation and capture. The decoder usually
# fires within 5s; 12s gives slow JS time to settle without dragging the
# extraction round.
DEFAULT_SETTLE_SECONDS = 12

USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) "
    "Version/17.4 Safari/605.1.15"
)


@dataclass(frozen=True)
class _Target:
    label: str         # site_name (homepage label in the UI)
    title: str         # human-readable stream title
    url: str           # page to navigate
    settle: int = DEFAULT_SETTLE_SECONDS


# ---------------------------------------------------------------------------
# Target list. F1-relevant 24/7 channels and motorsport aggregator pages
# whose m3u8 is JS-computed. Add freely — each one takes ~12s to scrape.
# ---------------------------------------------------------------------------
TARGETS: tuple[_Target, ...] = (
    # MotoMundo embed pages — the community-curated WordPress site for
    # MotoGP. Each /e/<id> URL is one of the iframes their "Watch Online"
    # post lists for the active session (FP/Q/Race). The m3u8 is
    # JS-computed at load time so a real browser is required to capture
    # it. Update IDs each weekend to match the current race; subreddit.py
    # discovers them from the Reddit "[Watch / Download]" thread.
    _Target(
        label="MotoMundo",
        title="MotoGP Live (MotoMundo) — French GP / Le Mans",
        url="https://motomundo.top/e/9yzn08jk9py4",
        settle=15,
    ),
    _Target(
        label="MotoMundo",
        title="MotoGP Live (MotoMundo upns) — French GP / Le Mans",
        url="https://motomundo.upns.xyz/#kqasde",
        settle=15,
    ),
)


# Heuristic to recognise an HLS playlist URL from network capture. Most CDNs
# use `.m3u8`; some (pushembdz/oe1.ossfeed) disguise the playlist as `.css`
# under a /out/v… or /hls/ path. Filter out obvious junk (.css for actual
# stylesheets, .ts segments — we only want the playlist).
_HLS_URL_RE = re.compile(r"\.m3u8(\?|$)|/out/v[0-9]+/.+\.css(\?|$)|/hls/.+/master\.css(\?|$)")
_SEGMENT_EXT_RE = re.compile(r"\.(ts|m4s|aac|key)(\?|$)")


def _looks_like_hls_playlist(url: str) -> bool:
    if _SEGMENT_EXT_RE.search(url):
        return False
    return bool(_HLS_URL_RE.search(url))


def _resolve_chrome_ws() -> str | None:
    base = os.getenv("CHROME_WS_URL")
    token = os.getenv("CHROME_WS_TOKEN")
    if not base or not token:
        return None
    return f"{base.rstrip('/')}/{token}"


class ChromeBrowserExtractor(BaseExtractor):
    """Drive chrome-service to capture m3u8 URLs from JS-heavy pages."""

    @property
    def site_key(self) -> str:
        return "chrome-browser"

    @property
    def site_name(self) -> str:
        return "Chrome Browser"

    async def extract(self) -> list[ExtractedStream]:
        ws_url = _resolve_chrome_ws()
        if not ws_url:
            logger.warning(
                "[chrome-browser] CHROME_WS_URL/TOKEN not set — extractor disabled"
            )
            return []

        try:
            from playwright.async_api import async_playwright
        except ImportError:
            logger.warning("[chrome-browser] playwright not installed — disabled")
            return []

        # One Playwright instance + one browser connection per extraction
        # round. Contexts are cheap; the browser is shared.
        async with async_playwright() as p:
            try:
                browser = await p.chromium.connect(ws_url, timeout=15_000)
            except Exception:
                logger.exception("[chrome-browser] connect to chrome-service failed")
                return []

            results: list[ExtractedStream] = []
            for target in TARGETS:
                try:
                    stream = await self._scrape(browser, target)
                    if stream:
                        results.append(stream)
                except Exception:
                    logger.exception(
                        "[chrome-browser] failed to scrape %s", target.url
                    )

            try:
                await browser.close()
            except Exception:
                pass

        logger.info("[chrome-browser] returned %d stream(s)", len(results))
        return results

    async def _scrape(self, browser, target: _Target) -> ExtractedStream | None:
        ctx = await browser.new_context(
            user_agent=USER_AGENT,
            viewport={"width": 1280, "height": 720},
            bypass_csp=True,
        )
        # Inject the same stealth script the verifier uses so anti-bot
        # checks don't trip the page before its decoder runs.
        try:
            from backend.stealth import STEALTH_JS
            await ctx.add_init_script(STEALTH_JS)
        except Exception:
            pass

        page = await ctx.new_page()
        captured: list[str] = []

        def on_response(resp):
            try:
                if _looks_like_hls_playlist(resp.url):
                    captured.append(resp.url)
            except Exception:
                pass

        page.on("response", on_response)
        # Some pages (DD12 variants) load the player in a child iframe;
        # frame events catch nested navigations.
        page.on(
            "framenavigated",
            lambda fr: captured.append(fr.url) if _looks_like_hls_playlist(fr.url) else None,
        )

        try:
            await page.goto(target.url, wait_until="domcontentloaded", timeout=20_000)
        except Exception as e:
            logger.debug("[chrome-browser] %s goto failed: %s", target.url, e)
            await ctx.close()
            return None

        # Let the page's JS settle.
        await asyncio.sleep(target.settle)

        # Also probe child iframes — `pushembdz`, `pooembed`, `embedsports`
        # all live behind one. Collect any HLS URL the iframes loaded.
        for fr in page.frames:
            if fr is page.main_frame:
                continue
            try:
                # JW Player and Clappr both expose the playing source via
                # a <video>/`<source>` element after setup completes.
                sources = await fr.evaluate(
                    "() => Array.from(document.querySelectorAll('video, source')).map(e => e.currentSrc || e.src || '').filter(s => s.includes('.m3u8') || s.includes('.css'))"
                )
                for s in sources:
                    if _looks_like_hls_playlist(s):
                        captured.append(s)
            except Exception:
                pass

        await ctx.close()

        # Pick the first plausible URL (any subsequent are usually variant
        # playlists referenced from the master). Prefer URLs that look like
        # full master playlists.
        unique = list(dict.fromkeys(captured))
        if not unique:
            logger.debug("[chrome-browser] %s yielded no HLS URL", target.url)
            return None

        # Prefer URLs that look like a master/index playlist over variant
        # playlists when both are captured.
        master = next(
            (u for u in unique if "master" in u.lower() or "index" in u.lower()),
            unique[0],
        )
        # Strip query strings on URLs that include short-lived tokens —
        # the verifier and frontend re-resolve them per request.
        # (Some CDNs require the query though; only strip when obvious.)
        m3u8 = master
        # Decode URL-encoded characters so the proxy gets a clean URL.
        m3u8 = urllib.parse.unquote(m3u8)

        logger.info(
            "[chrome-browser] %s -> %s",
            target.url, m3u8[:120],
        )
        return ExtractedStream(
            url=m3u8,
            site_key=self.site_key,
            site_name=target.label,
            quality="",
            title=target.title,
            stream_type="m3u8",
        )
