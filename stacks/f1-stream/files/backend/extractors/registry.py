"""Central registry for stream extractors."""

import asyncio
import logging
from datetime import datetime, timezone

from backend.extractors.base import BaseExtractor
from backend.extractors.models import ExtractedStream

logger = logging.getLogger(__name__)


class ExtractorRegistry:
    """Central registry for all site extractors.

    Manages extractor instances and provides fan-out extraction across
    all registered extractors with independent error handling.
    """

    def __init__(self) -> None:
        self._extractors: dict[str, BaseExtractor] = {}

    def register(self, extractor: BaseExtractor) -> None:
        """Register an extractor instance.

        Args:
            extractor: A BaseExtractor subclass instance.

        Raises:
            ValueError: If an extractor with the same site_key is already registered.
        """
        key = extractor.site_key
        if key in self._extractors:
            raise ValueError(
                f"Extractor with site_key '{key}' is already registered "
                f"(existing: {self._extractors[key].site_name}, "
                f"new: {extractor.site_name})"
            )
        self._extractors[key] = extractor
        logger.info("Registered extractor: %s (%s)", extractor.site_name, key)

    def get(self, site_key: str) -> BaseExtractor | None:
        """Get an extractor by its site_key.

        Args:
            site_key: The unique identifier of the extractor.

        Returns:
            The extractor instance, or None if not found.
        """
        return self._extractors.get(site_key)

    def list_extractors(self) -> list[dict]:
        """List all registered extractors.

        Returns:
            A list of dicts with site_key and site_name for each extractor.
        """
        return [
            {"site_key": ext.site_key, "site_name": ext.site_name}
            for ext in self._extractors.values()
        ]

    async def extract_all(self) -> list[ExtractedStream]:
        """Fan-out extraction to all registered extractors concurrently.

        Each extractor runs independently. If one fails, the others
        continue and their results are still collected.

        Returns:
            Combined list of ExtractedStream from all extractors.
        """
        if not self._extractors:
            logger.warning("No extractors registered, nothing to extract")
            return []

        logger.info(
            "Running extraction across %d extractor(s): %s",
            len(self._extractors),
            ", ".join(self._extractors.keys()),
        )

        async def _safe_extract(extractor: BaseExtractor) -> list[ExtractedStream]:
            """Run a single extractor with error isolation."""
            try:
                streams = await extractor.extract()
                # Fill in site_key/site_name if the extractor didn't set them
                now = datetime.now(timezone.utc).isoformat()
                for stream in streams:
                    if not stream.site_key:
                        stream.site_key = extractor.site_key
                    if not stream.site_name:
                        stream.site_name = extractor.site_name
                    if not stream.extracted_at:
                        stream.extracted_at = now
                logger.info(
                    "[%s] Extracted %d stream(s)", extractor.site_key, len(streams)
                )
                return streams
            except Exception:
                logger.exception(
                    "[%s] Extractor failed during extraction", extractor.site_key
                )
                return []

        # Run all extractors concurrently
        tasks = [_safe_extract(ext) for ext in self._extractors.values()]
        results = await asyncio.gather(*tasks)

        # Flatten results
        all_streams: list[ExtractedStream] = []
        for stream_list in results:
            all_streams.extend(stream_list)

        logger.info("Extraction complete: %d total stream(s) found", len(all_streams))
        return all_streams
