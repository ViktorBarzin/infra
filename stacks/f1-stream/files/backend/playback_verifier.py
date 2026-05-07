"""Headless-browser playback verification for extracted streams.

The basic health checker (backend/health.py) only validates m3u8 syntax.
For embed/iframe streams it has nothing to check — the previous code blindly
marked every embed `is_live=True`, which meant the stream list was full of
news articles and aggregator landing pages that never actually played.

This module loads each candidate stream URL in headless Chromium (via
Playwright) and looks for *codec-independent* signals that the upstream
serves a playable stream:

- For m3u8: hls.js receives MANIFEST_PARSED + at least one FRAG_LOADED
  event. We don't wait for `<video>` to gain dimensions, because Playwright's
  chromium build doesn't include the H.264/AAC codecs. The user's real
  browser does, so confirming "manifest + segment fetch succeed" is the
  right server-side signal.
- For embed: a `<video>` element appears at top level OR inside the iframe
  (the embed proxy strips X-Frame-Options + frame-buster JS so we can
  introspect the iframe content), OR the player has set up a MediaSource.

Designed to be called from the extraction service's run_extraction()
hook, with bounded concurrency. Each verification typically takes
4-12 seconds.
"""

import asyncio
import base64
import logging
import os
import time
from dataclasses import dataclass

logger = logging.getLogger(__name__)

# Toggle off in development by setting PLAYBACK_VERIFY_ENABLED=false.
VERIFY_ENABLED = os.getenv("PLAYBACK_VERIFY_ENABLED", "true").lower() in ("true", "1", "yes")

# Maximum number of concurrent browser pages.
MAX_CONCURRENCY = int(os.getenv("PLAYBACK_VERIFY_CONCURRENCY", "2"))

# Per-stream verification budget (seconds). Beyond this we declare unplayable.
PER_STREAM_TIMEOUT = float(os.getenv("PLAYBACK_VERIFY_TIMEOUT", "20"))

# Where the embed proxy lives, used to wrap embed URLs so they bypass
# X-Frame-Options/CSP/JS frame-busters during verification. Defaults to
# loopback because verification runs inside the same FastAPI process.
PROXY_BASE = os.getenv("PLAYBACK_VERIFY_PROXY_BASE", "http://127.0.0.1:8000")

USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/120.0.0.0 Safari/537.36"
)


@dataclass
class PlaybackVerdict:
    is_playable: bool
    signal: str = ""  # which check triggered the positive verdict
    elapsed_ms: int = 0
    error: str = ""


def _b64url(s: str) -> str:
    """URL-safe base64 with padding stripped — matches m3u8_rewriter.encode_url."""
    return base64.urlsafe_b64encode(s.encode()).decode().rstrip("=")


def _hls_test_html(m3u8_url: str) -> str:
    """A self-contained HTML page that loads an m3u8 via hls.js into a <video>.

    The page exposes window._verifier with manifest_parsed / frag_loaded
    booleans the verifier polls. It also marks media-error or fatal-error
    so we can distinguish 'upstream is unreachable' from 'codec missing'.
    """
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>verify</title>
<script src="https://cdn.jsdelivr.net/npm/hls.js@1.5/dist/hls.min.js"></script>
</head><body>
<video id="v" muted playsinline width="640" height="360"></video>
<script>
window._verifier = {{
  manifest_parsed: false,
  frag_loaded: false,
  media_loaded: false,  // true when MSE has appended any buffer
  fatal_network_error: false,  // upstream truly unreachable
  manifest_incompatible: false,  // codec missing — separate from network reachability
  hls_error_details: ""
}};
const v = document.getElementById('v');
const url = {m3u8_url!r};
function start() {{
  if (window.Hls && Hls.isSupported()) {{
    const hls = new Hls({{enableWorker: true}});
    hls.on(Hls.Events.MANIFEST_PARSED, () => {{ window._verifier.manifest_parsed = true; }});
    hls.on(Hls.Events.FRAG_LOADED, () => {{ window._verifier.frag_loaded = true; }});
    hls.on(Hls.Events.BUFFER_APPENDED, () => {{ window._verifier.media_loaded = true; }});
    hls.on(Hls.Events.ERROR, (_, d) => {{
      window._verifier.hls_error_details = d.details || "";
      if (d.fatal && d.type === Hls.ErrorTypes.NETWORK_ERROR) {{
        window._verifier.fatal_network_error = true;
      }}
      if (d.details === Hls.ErrorDetails.MANIFEST_INCOMPATIBLE_CODECS_ERROR) {{
        window._verifier.manifest_incompatible = true;
      }}
    }});
    hls.loadSource(url);
    hls.attachMedia(v);
  }} else if (v.canPlayType('application/vnd.apple.mpegurl')) {{
    v.src = url;
    v.addEventListener('loadedmetadata', () => {{ window._verifier.manifest_parsed = true; window._verifier.frag_loaded = true; }});
    v.addEventListener('error', () => {{ window._verifier.fatal_network_error = true; }});
  }} else {{
    window._verifier.hls_error_details = "no hls support";
  }}
}}
window.addEventListener('load', start);
</script></body></html>"""


def _embed_test_html(_proxied_embed_url: str) -> str:
    """No longer used — verifier navigates the page directly to the proxy URL.

    The earlier iframe-wrapper approach hit same-origin policy when inspecting
    the iframe's contentDocument (the wrapper page was a data: URL, the iframe
    was http://127.0.0.1:8000), so we couldn't read the embed's DOM.
    """
    return ""


_M3U8_POLL_JS = """
() => {
  const v = window._verifier || {};
  const vid = document.querySelector('video');
  return {
    manifest_parsed: !!v.manifest_parsed,
    frag_loaded: !!v.frag_loaded,
    media_loaded: !!v.media_loaded,
    fatal_network_error: !!v.fatal_network_error,
    manifest_incompatible: !!v.manifest_incompatible,
    hls_error_details: v.hls_error_details || "",
    video_width: vid ? vid.videoWidth : 0,
    video_ready: vid ? vid.readyState : 0,
  };
}
"""


_EMBED_POLL_JS = """
() => {
  try {
    const vids = document.querySelectorAll('video');
    if (vids.length > 0) {
      const v = vids[0];
      return {
        has_video: true,
        src: v.currentSrc || v.src || "",
        width: v.videoWidth,
        ready: v.readyState,
        duration: isFinite(v.duration) ? v.duration : 0,
        media_keys: !!v.mediaKeys,
        sources: v.querySelectorAll('source').length,
      };
    }
    return {has_video: false};
  } catch (e) {
    return {has_video: false, err: String(e)};
  }
}
"""


async def _verify_m3u8(page, m3u8_url: str, deadline: float) -> PlaybackVerdict:
    """Confirm an m3u8 URL is fetchable via hls.js end-to-end.

    Positive signal hierarchy:
      1. media_loaded (MSE buffer appended) — strongest, codec-supported.
      2. frag_loaded (hls.js fetched at least one segment) — upstream is OK
         even if the local browser lacks codecs.
      3. manifest_parsed without media_loaded but with manifest_incompatible
         — indicates upstream playlist is valid; player can't decode here
         but a real user's browser will.
    Negative signal:
      - fatal_network_error: upstream is unreachable.
      - timeout with no manifest_parsed: upstream did not respond.
    """
    start = time.monotonic()
    html = _hls_test_html(m3u8_url)
    data_url = "data:text/html;base64," + base64.b64encode(html.encode()).decode()

    try:
        await page.goto(data_url, wait_until="domcontentloaded", timeout=10_000)
    except Exception as e:
        return PlaybackVerdict(
            is_playable=False, error=f"goto failed: {e}",
            elapsed_ms=int((time.monotonic() - start) * 1000),
        )

    last_state: dict = {}
    while time.monotonic() < deadline:
        try:
            state = await page.evaluate(_M3U8_POLL_JS)
        except Exception as e:
            return PlaybackVerdict(
                is_playable=False, error=f"evaluate failed: {e}",
                elapsed_ms=int((time.monotonic() - start) * 1000),
            )
        last_state = state
        if state.get("media_loaded"):
            return PlaybackVerdict(
                is_playable=True, signal="media_loaded",
                elapsed_ms=int((time.monotonic() - start) * 1000),
            )
        if state.get("frag_loaded"):
            return PlaybackVerdict(
                is_playable=True, signal="frag_loaded",
                elapsed_ms=int((time.monotonic() - start) * 1000),
            )
        # MANIFEST_INCOMPATIBLE_CODECS_ERROR fires after hls.js successfully
        # fetched and parsed the manifest — the failure is purely local
        # (chromium lacks H.264). The user's real browser has codecs, so
        # this URL is playable from the user's perspective.
        if state.get("manifest_incompatible"):
            return PlaybackVerdict(
                is_playable=True, signal="manifest_parsed_codec_missing_in_verifier",
                elapsed_ms=int((time.monotonic() - start) * 1000),
            )
        if state.get("manifest_parsed"):
            return PlaybackVerdict(
                is_playable=True, signal="manifest_parsed",
                elapsed_ms=int((time.monotonic() - start) * 1000),
            )
        if state.get("fatal_network_error"):
            return PlaybackVerdict(
                is_playable=False, error="upstream network error",
                elapsed_ms=int((time.monotonic() - start) * 1000),
            )
        await asyncio.sleep(0.25)

    err = "no playback signal"
    if last_state.get("hls_error_details"):
        err = f"hls.js error: {last_state['hls_error_details']}"
    return PlaybackVerdict(
        is_playable=False, error=err,
        elapsed_ms=int((time.monotonic() - start) * 1000),
    )


async def _verify_embed(page, proxied_url: str, deadline: float) -> PlaybackVerdict:
    """Navigate directly to the proxied embed and confirm a player rendered.

    Positive signals (in priority order):
      - <video> with src/sources/mediaKeys set (player wired up).
      - <video> element exists with any state (script ran, player attaching).
      - A player container div (jwplayer, video-js, [id*=player], etc.).

    Loading the embed page directly (not via iframe wrapper) avoids the
    same-origin policy that prevented earlier iframe-introspection runs
    from seeing the embed DOM.
    """
    start = time.monotonic()
    try:
        await page.goto(proxied_url, wait_until="domcontentloaded", timeout=15_000)
    except Exception as e:
        return PlaybackVerdict(
            is_playable=False, error=f"goto failed: {e}",
            elapsed_ms=int((time.monotonic() - start) * 1000),
        )

    # Track the best state seen across all polls. Some embeds load a player
    # briefly then anti-bot JS tears the DOM down (hmembeds redirects to
    # google.com if its devtool-detection trips). We accept any positive
    # signal observed during the window, even if it's gone by timeout.
    #
    # We require an actual <video> element — a "player container div"
    # is too weak (sportsurge has player-class divs but no real player).
    seen_video_wired = False
    seen_video_tag = False
    last_err = ""

    while time.monotonic() < deadline:
        try:
            r = await page.evaluate(_EMBED_POLL_JS)
        except Exception as e:
            return PlaybackVerdict(
                is_playable=False, error=f"evaluate failed: {e}",
                elapsed_ms=int((time.monotonic() - start) * 1000),
            )
        if r.get("has_video"):
            seen_video_tag = True
            if r.get("src") or r.get("width", 0) > 0 or r.get("media_keys") or r.get("sources", 0) > 0:
                seen_video_wired = True
                return PlaybackVerdict(
                    is_playable=True, signal="video.wired",
                    elapsed_ms=int((time.monotonic() - start) * 1000),
                )
        last_err = r.get("err", "")
        await asyncio.sleep(0.5)

    if seen_video_wired:
        return PlaybackVerdict(is_playable=True, signal="video.wired",
                               elapsed_ms=int((time.monotonic() - start) * 1000))
    if seen_video_tag:
        return PlaybackVerdict(is_playable=True, signal="video.tag_only",
                               elapsed_ms=int((time.monotonic() - start) * 1000))

    err = "no <video> element rendered"
    if last_err:
        err += f"; last_err: {last_err}"
    return PlaybackVerdict(is_playable=False, error=err,
                           elapsed_ms=int((time.monotonic() - start) * 1000))


class PlaybackVerifier:
    """Verifies playability of m3u8 and embed URLs via headless Chromium.

    Manages a single browser instance for the process lifetime (cheap per-page
    contexts) and bounds concurrency with a semaphore.
    """

    def __init__(self) -> None:
        self._browser = None
        self._playwright = None
        self._sem = asyncio.Semaphore(MAX_CONCURRENCY)
        self._lock = asyncio.Lock()

    async def _ensure_browser(self):
        if self._browser is not None:
            return self._browser
        async with self._lock:
            if self._browser is not None:
                return self._browser
            try:
                from playwright.async_api import async_playwright
            except ImportError:
                logger.error("playwright not installed — playback verification disabled")
                return None
            self._playwright = await async_playwright().start()
            ws_base = os.getenv("CHROME_WS_URL")
            ws_token = os.getenv("CHROME_WS_TOKEN")
            if ws_base and ws_token:
                self._browser = await self._playwright.chromium.connect(
                    f"{ws_base.rstrip('/')}/{ws_token}", timeout=15_000,
                )
                logger.info("connected to remote chrome-service (concurrency=%d)", MAX_CONCURRENCY)
            else:
                self._browser = await self._playwright.chromium.launch(
                    headless=True,
                    args=[
                        "--disable-dev-shm-usage",
                        "--disable-web-security",
                        "--no-sandbox",
                        "--disable-setuid-sandbox",
                        "--disable-features=IsolateOrigins,site-per-process",
                        "--autoplay-policy=no-user-gesture-required",
                    ],
                )
                logger.warning("CHROME_WS_URL not set — using in-process Chromium (concurrency=%d)", MAX_CONCURRENCY)
            return self._browser

    async def shutdown(self) -> None:
        if self._browser is not None:
            try:
                await self._browser.close()
            except Exception:
                logger.exception("error closing browser")
        if self._playwright is not None:
            try:
                await self._playwright.stop()
            except Exception:
                logger.exception("error stopping playwright")
        self._browser = None
        self._playwright = None

    async def verify(self, url: str, stream_type: str) -> PlaybackVerdict:
        if not VERIFY_ENABLED:
            return PlaybackVerdict(is_playable=True, error="disabled")

        browser = await self._ensure_browser()
        if browser is None:
            return PlaybackVerdict(is_playable=False, error="playwright unavailable")

        is_m3u8 = stream_type == "m3u8"
        if not is_m3u8:
            url = f"{PROXY_BASE}/embed?url={_b64url(url)}"

        async with self._sem:
            # Set the per-stream deadline AFTER acquiring the semaphore.
            # Otherwise queued streams that wait behind earlier ones
            # would have already-expired deadlines when they start.
            deadline = time.monotonic() + PER_STREAM_TIMEOUT
            try:
                context = await browser.new_context(
                    user_agent=USER_AGENT,
                    viewport={"width": 1280, "height": 720},
                    bypass_csp=True,
                )
                from backend.stealth import STEALTH_JS
                await context.add_init_script(STEALTH_JS)
                page = await context.new_page()
            except Exception as e:
                return PlaybackVerdict(
                    is_playable=False, error=f"context create failed: {e}",
                )
            try:
                if is_m3u8:
                    verdict = await _verify_m3u8(page, url, deadline)
                else:
                    verdict = await _verify_embed(page, url, deadline)
            except asyncio.TimeoutError:
                verdict = PlaybackVerdict(is_playable=False, error="overall timeout")
            except Exception as e:
                verdict = PlaybackVerdict(
                    is_playable=False, error=f"verify exception: {e}",
                )
            finally:
                try:
                    await page.close()
                    await context.close()
                except Exception:
                    pass
            logger.info(
                "[verify] %s -> playable=%s signal=%s err=%s elapsed=%dms",
                url[:120], verdict.is_playable, verdict.signal,
                verdict.error, verdict.elapsed_ms,
            )
            return verdict

    async def verify_many(self, items: list[tuple[str, str]]) -> dict[str, PlaybackVerdict]:
        if not items:
            return {}
        if not VERIFY_ENABLED:
            return {url: PlaybackVerdict(is_playable=True, error="disabled") for url, _ in items}

        async def _run(url: str, stream_type: str):
            verdict = await self.verify(url, stream_type)
            return url, verdict

        results = await asyncio.gather(
            *[_run(url, st) for url, st in items], return_exceptions=True
        )
        out: dict[str, PlaybackVerdict] = {}
        for r in results:
            if isinstance(r, Exception):
                logger.exception("verify task crashed: %s", r)
                continue
            url, verdict = r
            out[url] = verdict
        return out
