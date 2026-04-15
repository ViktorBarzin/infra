"""EPUB chapter extraction service.

This parser attempts to match audiblez's chapter detection logic to ensure
the extracted chapters align with the WAV files audiblez produces.

audiblez iterates through EPUB ITEM_DOCUMENTs and uses is_chapter() to determine
if a document is a chapter based on content length (100+ chars) and filename patterns.
"""

import re
from dataclasses import dataclass
from pathlib import Path

from bs4 import BeautifulSoup
from ebooklib import epub, ITEM_DOCUMENT


@dataclass
class Chapter:
    """Represents a chapter extracted from an EPUB."""
    title: str
    index: int
    duration_ms: int = 0
    start_ms: int = 0
    end_ms: int = 0


def sanitize_title(title: str) -> str:
    """Remove characters that break FFmpeg metadata format."""
    if not title:
        return "Untitled"
    # Escape special chars for FFmpeg FFMETADATA format
    return (title
            .replace('=', '-')
            .replace(';', '-')
            .replace('#', '')
            .replace('\\', '')
            .replace('\n', ' ')
            .replace('\r', '')
            .strip())


def is_chapter(text: str, filename: str) -> bool:
    """Determine if a document is a chapter.

    Matches audiblez's is_chapter() logic:
    - Content must be over 100 characters
    - Filename should match common chapter patterns
    """
    if len(text) < 100:
        return False

    # Check filename patterns that indicate a chapter
    filename_lower = filename.lower()
    chapter_patterns = [
        r'chapter',
        r'part[_-]?\d+',
        r'split[_-]?\d+',
        r'ch[_-]?\d+',
        r'chap[_-]?\d+',
        r'sect',          # section
        r'content',
        r'text',
    ]

    for pattern in chapter_patterns:
        if re.search(pattern, filename_lower):
            return True

    # If content is substantial (1000+ chars), likely a chapter even without pattern match
    if len(text) > 1000:
        return True

    return False


def extract_title_from_content(soup: BeautifulSoup, filename: str, index: int) -> str:
    """Extract a chapter title from the document content."""
    # Try to find title in common heading tags
    for tag in ['title', 'h1', 'h2', 'h3']:
        element = soup.find(tag)
        if element and element.get_text(strip=True):
            title = element.get_text(strip=True)
            # Truncate long titles
            if len(title) > 100:
                title = title[:97] + "..."
            return title

    # Fallback: use filename without extension
    stem = Path(filename).stem
    # Clean up common patterns
    stem = re.sub(r'^(chapter|chap|ch)[_-]?', 'Chapter ', stem, flags=re.IGNORECASE)
    stem = re.sub(r'[_-]', ' ', stem)

    if stem and len(stem) < 50:
        return stem.title()

    return f"Chapter {index + 1}"


def extract_chapters(epub_path: Path) -> list[Chapter]:
    """Extract chapter titles matching audiblez's chapter detection logic.

    audiblez determines chapters by:
    1. Iterating through ITEM_DOCUMENT items
    2. Checking is_chapter() based on content length and filename patterns

    This ensures our chapter count matches the WAV files audiblez produces.

    Args:
        epub_path: Path to the EPUB file

    Returns:
        List of Chapter objects with title and index
    """
    try:
        book = epub.read_epub(str(epub_path))
    except Exception as e:
        print(f"Failed to read EPUB: {e}")
        return []

    chapters: list[Chapter] = []
    chapter_index = 0

    # Iterate through documents like audiblez does
    for item in book.get_items():
        if item.get_type() != ITEM_DOCUMENT:
            continue

        try:
            # Get content and parse with BeautifulSoup
            content = item.get_content()
            soup = BeautifulSoup(content, features='lxml')

            # Extract text from relevant tags (matching audiblez)
            text_parts = []
            for tag in soup.find_all(['title', 'p', 'h1', 'h2', 'h3', 'h4', 'li']):
                text = tag.get_text(strip=True)
                if text:
                    text_parts.append(text)

            full_text = ' '.join(text_parts)
            filename = item.get_name() or ""

            # Check if this document is a chapter
            if is_chapter(full_text, filename):
                title = extract_title_from_content(soup, filename, chapter_index)
                chapters.append(Chapter(
                    title=sanitize_title(title),
                    index=chapter_index
                ))
                chapter_index += 1

        except Exception as e:
            print(f"Error processing document {item.get_name()}: {e}")
            continue

    print(f"Extracted {len(chapters)} chapters from EPUB (audiblez-style detection)")

    # Debug: print first few chapters
    for i, ch in enumerate(chapters[:5]):
        print(f"  {i+1}. {ch.title}")
    if len(chapters) > 5:
        print(f"  ... and {len(chapters) - 5} more")

    return chapters
