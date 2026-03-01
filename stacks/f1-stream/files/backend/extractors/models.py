"""Data models for the stream extraction framework."""

from dataclasses import dataclass, field
from datetime import datetime, timezone


@dataclass
class ExtractedStream:
    """Represents a single stream URL discovered by an extractor."""

    url: str  # The HLS/m3u8 URL
    site_key: str  # Which extractor found it
    site_name: str  # Human-readable name
    quality: str = ""  # e.g., "720p", "1080p", or empty
    title: str = ""  # e.g., "F1 Race Live"
    extracted_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    is_live: bool = False  # Whether it passed health check
    response_time_ms: int = 0  # Health check response time (lower = better)
    checked_at: str = ""  # ISO timestamp of last health check
    bitrate: int = 0  # Bitrate in bps if detectable from m3u8 playlist
    stream_type: str = "m3u8"  # "m3u8" for direct HLS, "embed" for iframe embed URL
    embed_url: str = ""  # The iframe-embeddable URL (when stream_type is "embed")

    def to_dict(self) -> dict:
        """Serialize to a plain dictionary for JSON responses."""
        return {
            "url": self.url,
            "site_key": self.site_key,
            "site_name": self.site_name,
            "quality": self.quality,
            "title": self.title,
            "extracted_at": self.extracted_at,
            "is_live": self.is_live,
            "response_time_ms": self.response_time_ms,
            "checked_at": self.checked_at,
            "bitrate": self.bitrate,
            "stream_type": self.stream_type,
            "embed_url": self.embed_url,
        }
