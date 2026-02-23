"""HLS proxy - fetches upstream m3u8 playlists and relays media segments.

Two core functions:
1. Playlist proxy: fetches an upstream m3u8 playlist, rewrites all URIs
   to route through our /proxy and /relay endpoints, returns the rewritten
   playlist to the client.
2. Segment relay: fetches an upstream media segment (TS, fMP4, init) and
   streams it to the client using chunked transfer encoding, never buffering
   the full segment in memory.

All responses include CORS headers for browser playback.
"""

import logging
from typing import AsyncGenerator

import httpx
from fastapi import HTTPException

from backend.m3u8_rewriter import decode_url, rewrite_playlist

logger = logging.getLogger(__name__)

# Chunk size for relay streaming (64 KB)
RELAY_CHUNK_SIZE = 65536

# Timeout for upstream playlist fetches (seconds)
PLAYLIST_TIMEOUT = 15.0

# Timeout for upstream segment relay - longer because segments are bigger
RELAY_TIMEOUT = 30.0

# User-Agent for upstream requests
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/120.0.0.0 Safari/537.36"
)


async def proxy_playlist(encoded_url: str, proxy_base: str) -> str:
    """Fetch an upstream m3u8 playlist and rewrite all URIs through our proxy.

    Args:
        encoded_url: Base64url-encoded URL of the upstream m3u8 playlist.
        proxy_base: The base URL of our proxy service for rewriting URIs
                    (e.g., "https://f1.viktorbarzin.me").

    Returns:
        The rewritten m3u8 playlist text.

    Raises:
        HTTPException: If the URL can't be decoded, upstream fails, or
                       content is not a valid HLS playlist.
    """
    # Decode the URL
    try:
        url = decode_url(encoded_url)
    except Exception as e:
        logger.error("Failed to decode proxy URL: %s", e)
        raise HTTPException(status_code=400, detail=f"Invalid encoded URL: {e}")

    logger.info("Proxying playlist: %s", url)

    # Fetch the upstream playlist
    try:
        async with httpx.AsyncClient(
            timeout=PLAYLIST_TIMEOUT,
            follow_redirects=True,
            headers={
                "User-Agent": USER_AGENT,
                "Accept": "*/*",
            },
        ) as client:
            response = await client.get(url)

        if response.status_code != 200:
            logger.warning(
                "Upstream playlist returned HTTP %d for %s",
                response.status_code,
                url,
            )
            raise HTTPException(
                status_code=502,
                detail=f"Upstream returned HTTP {response.status_code}",
            )

        content = response.text

    except httpx.TimeoutException:
        logger.error("Timeout fetching upstream playlist: %s", url)
        raise HTTPException(status_code=504, detail="Upstream playlist timeout")
    except httpx.HTTPError as e:
        logger.error("HTTP error fetching upstream playlist: %s - %s", url, e)
        raise HTTPException(status_code=502, detail=f"Upstream error: {e}")
    except HTTPException:
        raise
    except Exception as e:
        logger.exception("Unexpected error fetching playlist: %s", url)
        raise HTTPException(status_code=500, detail=f"Internal error: {e}")

    # Validate it looks like an m3u8 playlist
    if "#EXTM3U" not in content:
        logger.warning("Upstream response is not a valid m3u8 playlist: %s", url)
        raise HTTPException(
            status_code=502,
            detail="Upstream response is not a valid HLS playlist",
        )

    # Rewrite all URIs to go through our proxy
    rewritten = rewrite_playlist(content, url, proxy_base)

    logger.debug(
        "Proxied playlist from %s: %d bytes -> %d bytes",
        url,
        len(content),
        len(rewritten),
    )

    return rewritten


async def relay_stream(
    encoded_url: str,
    range_header: str | None = None,
) -> tuple[AsyncGenerator[bytes, None], dict[str, str], int]:
    """Relay an upstream media segment as a chunked byte stream.

    Never buffers the full segment in memory. Streams chunks as they
    arrive from the upstream server.

    Args:
        encoded_url: Base64url-encoded URL of the upstream segment.
        range_header: Optional HTTP Range header from the client to
                      forward to upstream.

    Returns:
        A tuple of (async_generator, headers_dict, status_code) where:
        - async_generator yields bytes chunks
        - headers_dict contains content-type and other relevant headers
        - status_code is the HTTP status (200 or 206)

    Raises:
        HTTPException: If the URL can't be decoded or upstream fails.
    """
    # Decode the URL
    try:
        url = decode_url(encoded_url)
    except Exception as e:
        logger.error("Failed to decode relay URL: %s", e)
        raise HTTPException(status_code=400, detail=f"Invalid encoded URL: {e}")

    logger.debug("Relaying segment: %s", url)

    # Build upstream request headers
    headers = {
        "User-Agent": USER_AGENT,
        "Accept": "*/*",
    }
    if range_header:
        headers["Range"] = range_header

    # Create the client and stream - caller is responsible for cleanup
    # via the async generator protocol
    client = httpx.AsyncClient(
        timeout=RELAY_TIMEOUT,
        follow_redirects=True,
    )

    try:
        response = await client.send(
            client.build_request("GET", url, headers=headers),
            stream=True,
        )

        if response.status_code not in (200, 206):
            await response.aclose()
            await client.aclose()
            logger.warning(
                "Upstream segment returned HTTP %d for %s",
                response.status_code,
                url,
            )
            raise HTTPException(
                status_code=502,
                detail=f"Upstream returned HTTP {response.status_code}",
            )

        # Collect relevant response headers to forward
        response_headers: dict[str, str] = {}

        content_type = response.headers.get("content-type", "video/mp2t")
        response_headers["Content-Type"] = content_type

        if "content-length" in response.headers:
            response_headers["Content-Length"] = response.headers["content-length"]

        if "content-range" in response.headers:
            response_headers["Content-Range"] = response.headers["content-range"]

        status_code = response.status_code

        async def _stream_chunks() -> AsyncGenerator[bytes, None]:
            """Yield chunks from the upstream response, then clean up."""
            try:
                async for chunk in response.aiter_bytes(chunk_size=RELAY_CHUNK_SIZE):
                    yield chunk
            except Exception as e:
                logger.error("Error streaming segment from %s: %s", url, e)
            finally:
                await response.aclose()
                await client.aclose()

        return _stream_chunks(), response_headers, status_code

    except HTTPException:
        raise
    except httpx.TimeoutException:
        await client.aclose()
        logger.error("Timeout relaying segment: %s", url)
        raise HTTPException(status_code=504, detail="Upstream segment timeout")
    except httpx.HTTPError as e:
        await client.aclose()
        logger.error("HTTP error relaying segment: %s - %s", url, e)
        raise HTTPException(status_code=502, detail=f"Upstream error: {e}")
    except Exception as e:
        await client.aclose()
        logger.exception("Unexpected error relaying segment: %s", url)
        raise HTTPException(status_code=500, detail=f"Internal error: {e}")
