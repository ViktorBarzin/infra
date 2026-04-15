"""M4B chapter metadata embedding service."""

import re
import subprocess
import tempfile
from pathlib import Path

from pydub import AudioSegment

from .epub_parser import Chapter


def get_chapter_audio_durations(output_dir: Path) -> list[int]:
    """Calculate duration of each chapter WAV file in milliseconds.

    audiblez produces files like: {bookname}_chapter_{N}.wav
    e.g., mybook_chapter_1.wav, mybook_chapter_2.wav

    Args:
        output_dir: Directory containing the WAV files

    Returns:
        List of durations in milliseconds, ordered by chapter number
    """
    durations = []

    # Find all chapter WAV files - audiblez uses {name}_chapter_{N}.wav
    wav_files = list(output_dir.glob("*_chapter_*.wav"))

    if not wav_files:
        # Fallback: try any WAV files
        wav_files = list(output_dir.glob("*.wav"))

    if not wav_files:
        print(f"No WAV files found in {output_dir}")
        return durations

    # Sort by extracting chapter number from filename using regex
    # Pattern: look for _chapter_N or chapter_N in filename
    def extract_chapter_num(path: Path) -> int:
        name = path.stem
        # Try to find chapter number with regex - handles various patterns
        # e.g., "book_chapter_1", "mybook_chapter_12", "chapter_3_voice"
        match = re.search(r'chapter[_-]?(\d+)', name, re.IGNORECASE)
        if match:
            return int(match.group(1))
        # Fallback: find any number in the filename
        match = re.search(r'(\d+)', name)
        if match:
            return int(match.group(1))
        return 0

    wav_files.sort(key=extract_chapter_num)

    print(f"Found {len(wav_files)} WAV files to process for durations")
    for wav_file in wav_files:
        try:
            audio = AudioSegment.from_file(str(wav_file))
            durations.append(len(audio))  # duration in ms
            print(f"  Chapter WAV: {wav_file.name} - {len(audio)}ms ({len(audio)/1000:.1f}s)")
        except Exception as e:
            print(f"  Error reading {wav_file}: {e}")
            continue

    return durations


def generate_ffmpeg_metadata(chapters: list[Chapter], durations: list[int]) -> str:
    """Generate FFmpeg FFMETADATA1 format string with chapter markers.

    Args:
        chapters: List of Chapter objects with titles
        durations: List of durations in milliseconds for each chapter

    Returns:
        FFMETADATA1 formatted string
    """
    metadata = ";FFMETADATA1\n"

    current_time_ms = 0

    # Match chapters with durations
    num_chapters = min(len(chapters), len(durations))

    for i in range(num_chapters):
        chapter = chapters[i]
        duration = durations[i]

        chapter.start_ms = current_time_ms
        chapter.end_ms = current_time_ms + duration
        chapter.duration_ms = duration

        metadata += f"\n[CHAPTER]\n"
        metadata += f"TIMEBASE=1/1000\n"
        metadata += f"START={chapter.start_ms}\n"
        metadata += f"END={chapter.end_ms}\n"
        metadata += f"title={chapter.title}\n"

        current_time_ms = chapter.end_ms

    return metadata


def embed_chapters_in_m4b(input_m4b: Path, metadata_content: str) -> Path:
    """Re-mux M4B with chapter metadata using FFmpeg.

    Args:
        input_m4b: Path to the input M4B file
        metadata_content: FFMETADATA1 formatted string

    Returns:
        Path to the output M4B with chapters (same as input, replaced)
    """
    output_m4b = input_m4b.with_suffix('.chaptered.m4b')

    # Write metadata to temporary file
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
        f.write(metadata_content)
        metadata_file = Path(f.name)

    try:
        cmd = [
            'ffmpeg', '-y',
            '-i', str(input_m4b),
            '-f', 'ffmetadata', '-i', str(metadata_file),
            '-map', '0:a',
            '-map_metadata', '1',
            '-c:a', 'copy',  # Copy audio without re-encoding
            '-movflags', '+faststart+use_metadata_tags',
            str(output_m4b)
        ]

        print(f"Running FFmpeg: {' '.join(cmd)}")
        result = subprocess.run(cmd, check=True, capture_output=True, text=True)

        if result.returncode != 0:
            print(f"FFmpeg stderr: {result.stderr}")
            raise RuntimeError(f"FFmpeg failed: {result.stderr}")

        # Replace original with chaptered version
        input_m4b.unlink()
        output_m4b.rename(input_m4b)

        print(f"Successfully embedded chapters in {input_m4b}")
        return input_m4b

    except subprocess.CalledProcessError as e:
        print(f"FFmpeg error: {e.stderr}")
        # Clean up temp file
        if output_m4b.exists():
            output_m4b.unlink()
        raise
    finally:
        # Clean up metadata file
        if metadata_file.exists():
            metadata_file.unlink()
