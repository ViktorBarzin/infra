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
        }
