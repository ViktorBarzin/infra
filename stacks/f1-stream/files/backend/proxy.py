"""HLS proxy - fetches upstream m3u8 playlists and relays media segments.

Three core functions:
1. Playlist proxy: fetches an upstream m3u8 playlist, rewrites all URIs
   to route through our /proxy and /relay endpoints, returns the rewritten
   playlist to the client.
2. Quality selection: when the upstream m3u8 is a master playlist containing
   multiple quality variants, allows selecting a specific variant by index.
3. Segment relay: fetches an upstream media segment (TS, fMP4, init) and
   streams it to the client using chunked transfer encoding, never buffering
   the full segment in memory.

All responses include CORS headers for browser playback.
"""

import logging
import re
from dataclasses import dataclass
from typing import AsyncGenerator
from urllib.parse import urljoin

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


@dataclass
class QualityVariant:
    """A single quality variant parsed from a master HLS playlist."""

    index: int  # 0-based index in the playlist
    bandwidth: int  # BANDWIDTH value in bits/sec
    resolution: str  # e.g., "1920x1080" or "" if not specified
    codecs: str  # e.g., "avc1.640028,mp4a.40.2" or "" if not specified
    name: str  # e.g., "720p" or "" if not specified
    uri: str  # The variant playlist URI (absolute)

    def to_dict(self) -> dict:
        """Serialize to a plain dictionary for JSON responses."""
        return {
            "index": self.index,
            "bandwidth": self.bandwidth,
            "resolution": self.resolution,
            "codecs": self.codecs,
            "name": self.name,
            "uri": self.uri,
        }


def _is_master_playlist(content: str) -> bool:
    """Check if an m3u8 playlist is a master playlist (contains variant streams).

    A master playlist contains #EXT-X-STREAM-INF tags pointing to variant
    playlists. A media playlist contains #EXTINF tags pointing to segments.

    Args:
        content: The raw m3u8 playlist text.

    Returns:
        True if this is a master playlist.
    """
    return "#EXT-X-STREAM-INF:" in content


def parse_quality_variants(content: str, base_url: str) -> list[QualityVariant]:
    """Parse quality variants from a master HLS playlist.

    Extracts all #EXT-X-STREAM-INF entries and their associated URIs.

    Args:
        content: The raw m3u8 master playlist text.
        base_url: The URL of the playlist (for resolving relative URIs).

    Returns:
        List of QualityVariant objects sorted by bandwidth (highest first).
    """
    variants: list[QualityVariant] = []
    lines = content.splitlines()
    index = 0

    for i, line in enumerate(lines):
        stripped = line.strip()
        if not stripped.startswith("#EXT-X-STREAM-INF:"):
            continue

        # Parse attributes from the STREAM-INF tag
        attrs = stripped[len("#EXT-X-STREAM-INF:"):]

        bandwidth = _parse_attr_int(attrs, "BANDWIDTH")
        resolution = _parse_attr_str(attrs, "RESOLUTION")
        codecs = _parse_attr_quoted(attrs, "CODECS")
        name = _parse_attr_quoted(attrs, "NAME")

        # The next non-empty, non-comment line is the variant URI
        uri = ""
        for j in range(i + 1, len(lines)):
            next_line = lines[j].strip()
            if next_line and not next_line.startswith("#"):
                uri = next_line
                break

        if not uri:
            continue

        # Resolve relative URI
        if not uri.startswith("http://") and not uri.startswith("https://"):
            uri = urljoin(base_url, uri)

        # Generate a human-readable name if not provided
        if not name and resolution:
            # Extract height from resolution (e.g., "1920x1080" -> "1080p")
            parts = resolution.split("x")
            if len(parts) == 2:
                name = f"{parts[1]}p"

        variants.append(QualityVariant(
            index=index,
            bandwidth=bandwidth,
            resolution=resolution,
            codecs=codecs,
            name=name,
            uri=uri,
        ))
        index += 1

    # Sort by bandwidth descending (highest quality first)
    variants.sort(key=lambda v: v.bandwidth, reverse=True)
    # Re-index after sorting
    for i, v in enumerate(variants):
        v.index = i

    return variants


def _select_variant_playlist(
    content: str, base_url: str, variant_index: int
) -> str:
    """Extract a single variant from a master playlist by index.

    Instead of returning the full master playlist, returns just the selected
    variant's media playlist URL. The caller should then fetch and proxy that
    URL instead.

    Args:
        content: The raw m3u8 master playlist text.
        base_url: The URL of the playlist (for resolving relative URIs).
        variant_index: 0-based index of the desired variant (sorted by bandwidth desc).

    Returns:
        The absolute URL of the selected variant's media playlist.

    Raises:
        HTTPException: If the variant index is out of range.
    """
    variants = parse_quality_variants(content, base_url)

    if not variants:
        raise HTTPException(
            status_code=400,
            detail="Playlist has no quality variants to select from",
        )

    if variant_index < 0 or variant_index >= len(variants):
        raise HTTPException(
            status_code=400,
            detail=f"Quality index {variant_index} out of range (0-{len(variants) - 1})",
        )

    selected = variants[variant_index]
    logger.info(
        "Selected quality variant %d: %s (%d bps, %s)",
        variant_index,
        selected.name or "unknown",
        selected.bandwidth,
        selected.resolution or "no resolution",
    )

    return selected.uri


def _parse_attr_int(attrs: str, name: str) -> int:
    """Parse an integer attribute from an HLS tag attribute string.

    Args:
        attrs: The attribute string (e.g., 'BANDWIDTH=1280000,RESOLUTION=720x480').
        name: The attribute name to extract.

    Returns:
        The integer value, or 0 if not found.
    """
    match = re.search(rf"{name}=(\d+)", attrs)
    return int(match.group(1)) if match else 0


def _parse_attr_str(attrs: str, name: str) -> str:
    """Parse a bare (unquoted) string attribute from an HLS tag attribute string.

    Args:
        attrs: The attribute string.
        name: The attribute name to extract.

    Returns:
        The string value, or empty string if not found.
    """
    match = re.search(rf"{name}=([^,\s\"]+)", attrs)
    return match.group(1) if match else ""


def _parse_attr_quoted(attrs: str, name: str) -> str:
    """Parse a quoted string attribute from an HLS tag attribute string.

    Args:
        attrs: The attribute string.
        name: The attribute name to extract.

    Returns:
        The string value (without quotes), or empty string if not found.
    """
    match = re.search(rf'{name}="([^"]*)"', attrs)
    return match.group(1) if match else ""


async def proxy_playlist(
    encoded_url: str, proxy_base: str, quality: int | None = None
) -> str:
    """Fetch an upstream m3u8 playlist and rewrite all URIs through our proxy.

    If the upstream playlist is a master playlist (containing multiple quality
    variants) and a quality index is specified, fetches the selected variant's
    media playlist instead and rewrites that.

    Args:
        encoded_url: Base64url-encoded URL of the upstream m3u8 playlist.
        proxy_base: The base URL of our proxy service for rewriting URIs
                    (e.g., "https://f1.viktorbarzin.me").
        quality: Optional 0-based index of the desired quality variant.
                 Only applies when the upstream is a master playlist.
                 Variants are sorted by bandwidth descending (0 = highest).

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

    # If this is a master playlist and a quality variant was requested,
    # fetch the selected variant's media playlist instead
    if quality is not None and _is_master_playlist(content):
        variant_url = _select_variant_playlist(content, url, quality)
        logger.info("Fetching selected variant playlist: %s", variant_url)

        try:
            async with httpx.AsyncClient(
                timeout=PLAYLIST_TIMEOUT,
                follow_redirects=True,
                headers={
                    "User-Agent": USER_AGENT,
                    "Accept": "*/*",
                },
            ) as client:
                variant_response = await client.get(variant_url)

            if variant_response.status_code != 200:
                logger.warning(
                    "Variant playlist returned HTTP %d for %s",
                    variant_response.status_code,
                    variant_url,
                )
                raise HTTPException(
                    status_code=502,
                    detail=f"Variant playlist returned HTTP {variant_response.status_code}",
                )

            content = variant_response.text
            url = variant_url  # Use variant URL as base for relative URI resolution

            if "#EXTM3U" not in content:
                logger.warning(
                    "Variant playlist is not valid m3u8: %s", variant_url
                )
                raise HTTPException(
                    status_code=502,
                    detail="Variant playlist is not a valid HLS playlist",
                )

        except httpx.TimeoutException:
            logger.error("Timeout fetching variant playlist: %s", variant_url)
            raise HTTPException(
                status_code=504, detail="Variant playlist timeout"
            )
        except httpx.HTTPError as e:
            logger.error(
                "HTTP error fetching variant playlist: %s - %s", variant_url, e
            )
            raise HTTPException(
                status_code=502, detail=f"Variant playlist error: {e}"
            )
        except HTTPException:
            raise
        except Exception as e:
            logger.exception(
                "Unexpected error fetching variant playlist: %s", variant_url
            )
            raise HTTPException(
                status_code=500, detail=f"Internal error: {e}"
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
