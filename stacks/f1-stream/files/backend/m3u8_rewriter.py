"""m3u8 playlist rewriter - rewrites URIs in HLS playlists to go through the proxy.

Handles both master playlists (containing variant stream references) and
media playlists (containing segment URLs). Resolves relative URIs to
absolute before encoding, and routes .m3u8 references through /proxy
while routing segments (.ts, .m4s, etc.) through /relay.
"""

import base64
import logging
import re
from urllib.parse import urljoin

logger = logging.getLogger(__name__)


def encode_url(url: str) -> str:
    """Base64url-encode a URL for safe transport as a query parameter.

    Uses URL-safe base64 encoding with padding stripped to avoid
    double-encoding issues when the URL contains special characters.

    Args:
        url: The raw URL to encode.

    Returns:
        Base64url-encoded string with padding removed.
    """
    return base64.urlsafe_b64encode(url.encode()).decode().rstrip("=")


def decode_url(encoded: str) -> str:
    """Decode a base64url-encoded URL.

    Re-adds padding that was stripped during encoding.

    Args:
        encoded: Base64url-encoded string (padding may be stripped).

    Returns:
        The original URL string.

    Raises:
        ValueError: If the encoded string is not valid base64url.
    """
    # Add padding back - base64 requires length to be multiple of 4
    padding = 4 - len(encoded) % 4
    if padding != 4:
        encoded += "=" * padding
    return base64.urlsafe_b64decode(encoded).decode()


def _resolve_uri(uri: str, base_url: str) -> str:
    """Resolve a potentially relative URI against a base URL.

    Args:
        uri: The URI from the m3u8 playlist (may be relative or absolute).
        base_url: The URL of the playlist itself (used as base for relative URIs).

    Returns:
        Absolute URL.
    """
    if uri.startswith("http://") or uri.startswith("https://"):
        return uri
    return urljoin(base_url, uri)


def _is_playlist_uri(uri: str) -> bool:
    """Determine if a URI likely points to another playlist (vs a segment).

    Playlist URIs end in .m3u8 or .m3u. Everything else is treated as a
    segment (TS, fMP4, init segment, etc.).

    Args:
        uri: The URI to classify.

    Returns:
        True if the URI appears to be a playlist reference.
    """
    # Strip query string for extension check
    path = uri.split("?")[0].split("#")[0].lower()
    return path.endswith(".m3u8") or path.endswith(".m3u")


def _build_proxy_url(absolute_uri: str, proxy_base: str) -> str:
    """Build a /proxy URL for a playlist reference.

    Args:
        absolute_uri: The absolute URL of the upstream playlist.
        proxy_base: The base URL of our proxy service.

    Returns:
        Rewritten URL pointing to our /proxy endpoint.
    """
    encoded = encode_url(absolute_uri)
    return f"{proxy_base}/proxy?url={encoded}"


def _build_relay_url(absolute_uri: str, proxy_base: str) -> str:
    """Build a /relay URL for a segment reference.

    Args:
        absolute_uri: The absolute URL of the upstream segment.
        proxy_base: The base URL of our proxy service.

    Returns:
        Rewritten URL pointing to our /relay endpoint.
    """
    encoded = encode_url(absolute_uri)
    return f"{proxy_base}/relay?url={encoded}"


def _rewrite_uri(uri: str, base_url: str, proxy_base: str) -> str:
    """Rewrite a single URI from an m3u8 playlist.

    Resolves relative URIs, then routes playlists through /proxy and
    segments through /relay.

    Args:
        uri: The raw URI from the playlist.
        base_url: The URL of the playlist containing this URI.
        proxy_base: The base URL of our proxy service.

    Returns:
        Rewritten URI pointing to our proxy.
    """
    absolute = _resolve_uri(uri, base_url)
    if _is_playlist_uri(uri):
        return _build_proxy_url(absolute, proxy_base)
    return _build_relay_url(absolute, proxy_base)


def rewrite_playlist(content: str, base_url: str, proxy_base: str) -> str:
    """Rewrite all URIs in an m3u8 playlist to go through the proxy.

    Handles both master playlists (with #EXT-X-STREAM-INF variant
    references) and media playlists (with segment URIs). Also handles
    #EXT-X-MAP:URI= init segment references.

    Args:
        content: The raw m3u8 playlist text.
        base_url: The original URL of this playlist (for resolving relative URIs).
        proxy_base: The base URL of our proxy (e.g., "https://f1.viktorbarzin.me").

    Returns:
        The rewritten m3u8 playlist text with all URIs proxied.
    """
    proxy_base = proxy_base.rstrip("/")
    lines = content.splitlines()
    output_lines: list[str] = []

    # Track if the previous line was #EXT-X-STREAM-INF (next line is a variant URI)
    next_is_variant = False

    for line in lines:
        stripped = line.strip()

        # Handle #EXT-X-MAP:URI="..." (init segment)
        if stripped.startswith("#EXT-X-MAP:"):
            output_lines.append(_rewrite_ext_x_map(stripped, base_url, proxy_base))
            continue

        # Handle #EXT-X-STREAM-INF (marks next line as variant playlist URI)
        if stripped.startswith("#EXT-X-STREAM-INF:"):
            output_lines.append(line)
            next_is_variant = True
            continue

        # Handle #EXT-X-MEDIA with URI= attribute
        if stripped.startswith("#EXT-X-MEDIA:") and "URI=" in stripped:
            output_lines.append(_rewrite_ext_x_media(stripped, base_url, proxy_base))
            continue

        # Handle #EXT-X-I-FRAME-STREAM-INF with URI= attribute
        if stripped.startswith("#EXT-X-I-FRAME-STREAM-INF:") and "URI=" in stripped:
            output_lines.append(
                _rewrite_tag_with_uri(stripped, base_url, proxy_base, is_playlist=True)
            )
            continue

        # If previous line was #EXT-X-STREAM-INF, this line is a variant playlist URI
        if next_is_variant and stripped and not stripped.startswith("#"):
            absolute = _resolve_uri(stripped, base_url)
            output_lines.append(_build_proxy_url(absolute, proxy_base))
            next_is_variant = False
            continue

        # Regular URI line (non-comment, non-empty, not a tag)
        if stripped and not stripped.startswith("#"):
            # This is a segment URI (TS, fMP4, etc.)
            absolute = _resolve_uri(stripped, base_url)
            output_lines.append(_build_relay_url(absolute, proxy_base))
            continue

        # Tags and comments pass through unchanged
        output_lines.append(line)
        # Reset variant flag if we hit another tag
        if stripped.startswith("#") and not stripped.startswith("#EXT-X-STREAM-INF:"):
            next_is_variant = False

    return "\n".join(output_lines)


def _rewrite_ext_x_map(line: str, base_url: str, proxy_base: str) -> str:
    """Rewrite the URI in an #EXT-X-MAP tag.

    #EXT-X-MAP:URI="init.mp4" -> #EXT-X-MAP:URI="<relay_url>"
    The init segment goes through /relay since it's binary data.
    """
    # Match URI="..." or URI=... (with or without quotes)
    match = re.search(r'URI="([^"]+)"', line)
    if not match:
        match = re.search(r"URI=([^,\s]+)", line)

    if not match:
        return line

    original_uri = match.group(1)
    absolute = _resolve_uri(original_uri, base_url)
    relay_url = _build_relay_url(absolute, proxy_base)

    return line[:match.start(1)] + relay_url + line[match.end(1):]


def _rewrite_ext_x_media(line: str, base_url: str, proxy_base: str) -> str:
    """Rewrite the URI in an #EXT-X-MEDIA tag.

    #EXT-X-MEDIA:TYPE=AUDIO,...,URI="audio.m3u8" -> rewrite URI to /proxy
    """
    return _rewrite_tag_with_uri(line, base_url, proxy_base, is_playlist=True)


def _rewrite_tag_with_uri(
    line: str, base_url: str, proxy_base: str, is_playlist: bool = False,
) -> str:
    """Rewrite the URI attribute within an HLS tag line.

    Generic handler for any tag that contains a URI="..." attribute.

    Args:
        line: The full tag line.
        base_url: Base URL for resolving relative URIs.
        proxy_base: Our proxy base URL.
        is_playlist: If True, route through /proxy; otherwise /relay.

    Returns:
        The tag line with the URI rewritten.
    """
    match = re.search(r'URI="([^"]+)"', line)
    if not match:
        match = re.search(r"URI=([^,\s]+)", line)

    if not match:
        return line

    original_uri = match.group(1)
    absolute = _resolve_uri(original_uri, base_url)

    if is_playlist:
        new_url = _build_proxy_url(absolute, proxy_base)
    else:
        new_url = _build_relay_url(absolute, proxy_base)

    return line[:match.start(1)] + new_url + line[match.end(1):]
