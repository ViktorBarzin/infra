"""Stream extraction framework.

To add a new extractor:
1. Create a new file in this package (e.g., my_site.py)
2. Subclass BaseExtractor from backend.extractors.base
3. Implement site_key, site_name, and extract()
4. Import and register it in this file's create_registry() function

Example:
    from backend.extractors.my_site import MySiteExtractor
    registry.register(MySiteExtractor())
"""

from backend.extractors.aceztrims import AceztrimsExtractor
from backend.extractors.curated import CuratedExtractor
from backend.extractors.daddylive import DaddyLiveExtractor
from backend.extractors.discord_source import DiscordExtractor
from backend.extractors.models import ExtractedStream
from backend.extractors.pitsport import PitsportExtractor
from backend.extractors.ppv import PPVExtractor
from backend.extractors.registry import ExtractorRegistry
from backend.extractors.service import ExtractionService
from backend.extractors.streamed import StreamedExtractor
from backend.extractors.timstreams import TimStreamsExtractor

__all__ = [
    "ExtractedStream",
    "ExtractorRegistry",
    "ExtractionService",
    "create_registry",
    "create_extraction_service",
]


def create_registry() -> ExtractorRegistry:
    """Create and populate the extractor registry with all known extractors.

    Add new extractors here by importing and registering them.
    """
    registry = ExtractorRegistry()

    # --- Register extractors below ---
    # CuratedExtractor returns hand-picked 24/7 channels first so we always
    # have something. DemoExtractor and FallbackExtractor were removed —
    # demo streams aren't F1 content (just Big Buck Bunny etc.) and
    # FallbackExtractor surfaced aggregator landing pages that don't play
    # directly in an iframe.
    registry.register(CuratedExtractor())
    registry.register(StreamedExtractor())
    registry.register(DaddyLiveExtractor())
    registry.register(AceztrimsExtractor())
    registry.register(PitsportExtractor())
    registry.register(PPVExtractor())
    registry.register(TimStreamsExtractor())
    registry.register(DiscordExtractor())

    return registry


def create_extraction_service() -> ExtractionService:
    """Create an ExtractionService with all extractors registered.

    This is the main entry point for the extraction framework.
    Call this once during app startup.
    """
    registry = create_registry()
    return ExtractionService(registry)
