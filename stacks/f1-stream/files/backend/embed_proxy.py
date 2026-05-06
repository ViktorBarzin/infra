"""Embed iframe-stripping reverse proxy.

Serves third-party embed pages (e.g. https://hmembeds.one/embed/{hash},
https://pooembed.eu/embed/{slug}) through our origin so we can:

1. Strip X-Frame-Options and Content-Security-Policy: frame-ancestors headers,
   so the embed loads in our <iframe> regardless of upstream policy.
2. Inject <base> + a frame-buster-defeat <script> at the top of <head> so
   the embed's JS sees `window.top === window` and a plausible
   `document.referrer` pointing at the upstream origin.
3. Forward Referer / User-Agent matching the upstream's own pages so
   the upstream's hotlink / origin-allowlist checks pass.

Two endpoints:
- GET /embed?url=<base64url> — the embed HTML page (rewritten).
- GET /embed-asset?url=<base64url> — fallback for any subresource the
  upstream blocks based on hotlink protection. Most assets load directly
  via the injected <base> tag and bypass our proxy.
"""

import logging
import re
from typing import AsyncGenerator
from urllib.parse import urlparse

import httpx
from fastapi import HTTPException

from backend.m3u8_rewriter import decode_url

logger = logging.getLogger(__name__)

EMBED_TIMEOUT = 20.0
ASSET_TIMEOUT = 30.0
RELAY_CHUNK_SIZE = 65536

USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/120.0.0.0 Safari/537.36"
)

# Response headers we never forward (they break frame embedding or leak upstream policy).
STRIP_RESPONSE_HEADERS = {
    "x-frame-options",
    "content-security-policy",
    "content-security-policy-report-only",
    "set-cookie",
    "report-to",
    "nel",
    "permissions-policy",
    "cross-origin-opener-policy",
    "cross-origin-embedder-policy",
    "cross-origin-resource-policy",
    # let httpx/uvicorn re-set these
    "transfer-encoding",
    "content-encoding",
    "content-length",
    "connection",
}

# Inject this <script> at the top of <head> to defeat JS frame-busters.
# - Locks window.top, window.parent, and window.self to the embed window
#   itself, so `self !== window.top` checks pass.
# - Forces document.referrer to the upstream origin so allowlist checks
#   like `document.referrer.includes("timstreams.net")` keep working.
# - No-ops anything that would call window.parent.location or attempt to
#   reload the top frame.
_FRAME_BUSTER_DEFEAT_TEMPLATE = """
<script>(function(){{
  try {{
    var fakeWindow = window;
    Object.defineProperty(window, 'top', {{get: function(){{return fakeWindow;}}, configurable: false}});
    Object.defineProperty(window, 'parent', {{get: function(){{return fakeWindow;}}, configurable: false}});
    Object.defineProperty(window, 'frameElement', {{get: function(){{return null;}}, configurable: false}});
    Object.defineProperty(document, 'referrer', {{get: function(){{return {referrer!r};}}, configurable: false}});
  }} catch (e) {{}}
  // Defeat the `disable-devtool.js` redirect trap that hmembeds and similar
  // embed hosts use. The trap fires `console.clear`/`console.table` in a
  // tight loop, then if it thinks DevTools is open, calls
  // `window.location = "https://www.google.com"`. We block those redirect
  // sinks while leaving normal playback unaffected.
  try {{
    var noop = function(){{}};
    console.clear = noop;
    console.table = noop;
    console.dir = noop;
    var loc = window.location;
    Object.defineProperty(window, 'location', {{
      get: function(){{ return loc; }},
      set: function(v){{ /* swallow assignment */ }},
      configurable: false,
    }});
    var origAssign = loc.assign && loc.assign.bind(loc);
    var origReplace = loc.replace && loc.replace.bind(loc);
    loc.assign = function(u){{ if (typeof u === 'string' && u.indexOf('google.com') !== -1) return; if (origAssign) origAssign(u); }};
    loc.replace = function(u){{ if (typeof u === 'string' && u.indexOf('google.com') !== -1) return; if (origReplace) origReplace(u); }};
  }} catch (e) {{}}

  // Route all cross-origin fetch/XHR requests through our /embed-asset
  // proxy. The hmembeds player calls a token-binding endpoint
  // (hghndasw.gbgdhdffhf.shop/sec/<JWT>) that CORS-rejects requests from
  // any origin other than hmembeds.one. By rewriting the URL to
  // /embed-asset?url=..., the browser fetches our same-origin endpoint
  // (no CORS issue), and our backend fetches the upstream with the
  // correct Referer/Origin server-side (no CORS issue there either).
  try {{
    var b64url = function(s) {{
      return btoa(unescape(encodeURIComponent(s)))
        .replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/, '');
    }};
    var sameOrigin = function(u) {{
      try {{ return (new URL(u, document.baseURI || location.href)).origin === location.origin; }}
      catch (_) {{ return true; }}
    }};
    var toAbsolute = function(u) {{
      try {{ return (new URL(u, document.baseURI || location.href)).toString(); }}
      catch (_) {{ return u; }}
    }};
    var proxify = function(u) {{
      var abs = toAbsolute(u);
      if (sameOrigin(abs)) return u;
      // Don't double-proxy.
      if (abs.indexOf('/embed-asset?') !== -1 || abs.indexOf('/embed?') !== -1) return u;
      return location.origin + '/embed-asset?url=' + b64url(abs);
    }};

    var _fetch = window.fetch && window.fetch.bind(window);
    if (_fetch) {{
      window.fetch = function(input, init) {{
        try {{
          if (typeof input === 'string') {{
            return _fetch(proxify(input), init);
          }} else if (input && input.url) {{
            var newUrl = proxify(input.url);
            if (newUrl !== input.url) {{
              return _fetch(new Request(newUrl, input), init);
            }}
          }}
        }} catch (e) {{}}
        return _fetch(input, init);
      }};
    }}

    var XHR = window.XMLHttpRequest;
    if (XHR && XHR.prototype && XHR.prototype.open) {{
      var _open = XHR.prototype.open;
      XHR.prototype.open = function(method, url) {{
        try {{ url = proxify(url); }} catch (e) {{}}
        var args = Array.prototype.slice.call(arguments);
        args[1] = url;
        return _open.apply(this, args);
      }};
    }}
  }} catch (e) {{}}
}})();</script>
"""


def _decode(encoded_url: str) -> str:
    try:
        return decode_url(encoded_url)
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid encoded URL: {e}")


def _filter_headers(upstream_headers: httpx.Headers) -> dict[str, str]:
    """Forward upstream headers minus the ones we strip."""
    out: dict[str, str] = {}
    for k, v in upstream_headers.items():
        if k.lower() in STRIP_RESPONSE_HEADERS:
            continue
        out[k] = v
    # Always allow our domain to embed and load cross-origin
    out["Access-Control-Allow-Origin"] = "*"
    out["X-Frame-Options-Stripped"] = "by-f1-embed-proxy"
    return out


def _make_referer(upstream_url: str) -> str:
    """Build a plausible Referer header — the upstream's own root."""
    parsed = urlparse(upstream_url)
    return f"{parsed.scheme}://{parsed.netloc}/"


def _make_origin(upstream_url: str) -> str:
    parsed = urlparse(upstream_url)
    return f"{parsed.scheme}://{parsed.netloc}"


def _inject_into_head(html: str, upstream_url: str) -> str:
    """Inject <base> tag + frame-buster defeat script into the response HTML."""
    parsed = urlparse(upstream_url)
    base_href = f"{parsed.scheme}://{parsed.netloc}/"

    # The frame-buster-defeat script. Use the upstream's own URL as the spoofed referrer.
    busted = _FRAME_BUSTER_DEFEAT_TEMPLATE.format(referrer=upstream_url)

    base_tag = f'<base href="{base_href}">'

    injection = base_tag + busted

    # Drop any inline CSP <meta> tags first so they can't override our header strip.
    html = re.sub(
        r'<meta[^>]+http-equiv=[\'"]?Content-Security-Policy[\'"]?[^>]*>',
        "",
        html,
        flags=re.IGNORECASE,
    )

    # Strip disable-devtool.js script tags. The library runs detection heuristics
    # and redirects on match. Removing it reduces attack surface even with our
    # location-setter lockdown — saves redundant work and one fewer thing to
    # bypass in case the lockdown misses an edge case.
    html = re.sub(
        r'<script[^>]+(?:disable-devtool|devtool|disabledevtool)[^<]*</script>',
        "",
        html,
        flags=re.IGNORECASE,
    )
    html = re.sub(
        r'<script[^>]+src=["\'][^"\']*disable-devtool[^"\']*["\'][^>]*></script>',
        "",
        html,
        flags=re.IGNORECASE,
    )

    # Insert immediately after the opening <head> (case-insensitive).
    head_match = re.search(r"<head[^>]*>", html, flags=re.IGNORECASE)
    if head_match:
        idx = head_match.end()
        return html[:idx] + injection + html[idx:]

    # No <head> — prepend at the start of the document so the script runs first.
    return injection + html


def _looks_blocked_by_anti_bot(content: str) -> bool:
    """Detect Cloudflare-style challenge interstitials in the upstream body."""
    sample = content[:4096].lower()
    markers = (
        "cf-chl-bypass",
        "checking your browser",
        "just a moment",
        "attention required",
        "cf-browser-verification",
    )
    return any(m in sample for m in markers)


async def fetch_embed(encoded_url: str) -> tuple[bytes, dict[str, str], int]:
    """Fetch an upstream embed page, rewrite the HTML, and return the response.

    Returns: (body_bytes, headers_dict, status_code).
    Raises HTTPException on transport errors.
    """
    url = _decode(encoded_url)
    logger.info("Embed-proxying: %s", url)

    upstream_headers = {
        "User-Agent": USER_AGENT,
        "Referer": _make_referer(url),
        "Origin": _make_origin(url),
        "Accept": (
            "text/html,application/xhtml+xml,application/xml;q=0.9,"
            "image/avif,image/webp,*/*;q=0.8"
        ),
        "Accept-Language": "en-US,en;q=0.9",
    }

    try:
        async with httpx.AsyncClient(
            timeout=EMBED_TIMEOUT,
            follow_redirects=True,
        ) as client:
            response = await client.get(url, headers=upstream_headers)
    except httpx.TimeoutException:
        raise HTTPException(status_code=504, detail="Upstream embed timeout")
    except httpx.HTTPError as e:
        raise HTTPException(status_code=502, detail=f"Upstream embed error: {e}")

    status_code = response.status_code
    upstream_ct = response.headers.get("content-type", "")
    headers_out = _filter_headers(response.headers)

    body = response.content

    # Detect Cloudflare-style challenge so the frontend can show a clear error.
    if "html" in upstream_ct.lower():
        text = response.text
        if _looks_blocked_by_anti_bot(text):
            logger.warning("Upstream returned anti-bot challenge: %s", url)
            raise HTTPException(
                status_code=502,
                detail="Upstream returned anti-bot challenge — proxy cannot bypass",
            )

        rewritten = _inject_into_head(text, url)
        body = rewritten.encode("utf-8")
        headers_out["Content-Type"] = "text/html; charset=utf-8"

    return body, headers_out, status_code


async def relay_asset(
    encoded_url: str, range_header: str | None
) -> tuple[AsyncGenerator[bytes, None], dict[str, str], int]:
    """Relay an upstream subresource (JS/CSS/image/font) as a chunked stream.

    Used as a fallback when an upstream blocks hotlinked assets via Referer
    or Origin checks. The injected <base> tag handles most of these cases
    by letting the browser hit upstream directly — the relay is only for
    the awkward few that need a proxied origin.
    """
    url = _decode(encoded_url)
    logger.debug("Embed-asset relay: %s", url)

    headers = {
        "User-Agent": USER_AGENT,
        "Referer": _make_referer(url),
        "Origin": _make_origin(url),
        "Accept": "*/*",
    }
    if range_header:
        headers["Range"] = range_header

    client = httpx.AsyncClient(timeout=ASSET_TIMEOUT, follow_redirects=True)

    try:
        response = await client.send(
            client.build_request("GET", url, headers=headers),
            stream=True,
        )
    except httpx.TimeoutException:
        await client.aclose()
        raise HTTPException(status_code=504, detail="Upstream asset timeout")
    except httpx.HTTPError as e:
        await client.aclose()
        raise HTTPException(status_code=502, detail=f"Upstream asset error: {e}")

    if response.status_code >= 400:
        await response.aclose()
        await client.aclose()
        raise HTTPException(
            status_code=502,
            detail=f"Upstream asset returned HTTP {response.status_code}",
        )

    headers_out = _filter_headers(response.headers)

    async def _stream() -> AsyncGenerator[bytes, None]:
        try:
            async for chunk in response.aiter_bytes(chunk_size=RELAY_CHUNK_SIZE):
                yield chunk
        finally:
            await response.aclose()
            await client.aclose()

    return _stream(), headers_out, response.status_code
