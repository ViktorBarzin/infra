"""
YouTube Highlights Extraction Service

Downloads YouTube videos, transcribes them using Faster-Whisper,
and extracts highlights using OpenRouter LLM.
"""
import os
import json
import uuid
import asyncio
import logging
import threading
import queue
from datetime import datetime
from pathlib import Path
from typing import Optional
from contextlib import asynccontextmanager

import feedparser
import httpx
import redis
import yt_dlp
from faster_whisper import WhisperModel
from fastapi import FastAPI, HTTPException
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse
from pydantic import BaseModel

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Configuration from environment
DATA_PATH = Path(os.getenv("DATA_PATH", "/data"))
ASR_MODEL = os.getenv("ASR_MODEL", "large-v3")
ASR_DEVICE = os.getenv("ASR_DEVICE", "cuda")
OPENROUTER_API_KEY = os.getenv("OPENROUTER_API_KEY", "")
OPENROUTER_MODEL = os.getenv("OPENROUTER_MODEL", "deepseek/deepseek-r1-0528:free")
OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"

# Ollama fallback configuration (used as last resort if set)
OLLAMA_URL = os.getenv("OLLAMA_URL", "")  # e.g., "http://ollama.ollama.svc.cluster.local:11434"
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "qwen2.5:3b")  # Small but capable model

# Dynamic model pool - fetched from OpenRouter API
_cached_models: list[str] = []
_models_fetched_at: float = 0
MODEL_CACHE_TTL = 3600  # Refresh model list every hour


def _fetch_free_models() -> list[str]:
    """Fetch list of free models from OpenRouter API.

    Returns models sorted by preference (primary env model first if available).
    """
    import requests
    import time

    global _cached_models, _models_fetched_at

    # Return cached list if still valid
    if _cached_models and (time.time() - _models_fetched_at) < MODEL_CACHE_TTL:
        return _cached_models

    try:
        logger.info("Fetching available models from OpenRouter API...")
        response = requests.get(
            "https://openrouter.ai/api/v1/models",
            headers={"Authorization": f"Bearer {OPENROUTER_API_KEY}"},
            timeout=30.0
        )

        if response.status_code != 200:
            logger.warning(f"Failed to fetch models: {response.status_code}")
            # Return fallback list if API fails
            return _get_fallback_models()

        data = response.json()
        models = data.get("data", [])

        # Filter for free models (pricing is 0 or model ID ends with :free)
        free_models = []
        for model in models:
            model_id = model.get("id", "")
            pricing = model.get("pricing", {})

            # Check if model is free (prompt and completion are 0 or "0")
            prompt_price = pricing.get("prompt", "1")
            completion_price = pricing.get("completion", "1")

            is_free = (
                str(prompt_price) == "0" and str(completion_price) == "0"
            ) or model_id.endswith(":free")

            if is_free:
                free_models.append(model_id)

        logger.info(f"Found {len(free_models)} free models from OpenRouter")

        # Sort models - put preferred/primary model first if in list
        sorted_models = []
        if OPENROUTER_MODEL in free_models:
            sorted_models.append(OPENROUTER_MODEL)
            free_models.remove(OPENROUTER_MODEL)

        # Add remaining models (could add more sophisticated ordering here)
        sorted_models.extend(free_models)

        # Cache the result
        _cached_models = sorted_models
        _models_fetched_at = time.time()

        return sorted_models

    except Exception as e:
        logger.warning(f"Error fetching models from OpenRouter: {e}")
        return _get_fallback_models()


def _get_fallback_models() -> list[str]:
    """Fallback model list if API fetch fails - only models known to work."""
    return [
        OPENROUTER_MODEL,
        "deepseek/deepseek-r1-0528:free",
        "google/gemini-2.0-flash-exp:free",
        "meta-llama/llama-3.3-70b-instruct:free",
        "mistralai/mistral-small-3.1-24b-instruct:free",
        "google/gemma-3-27b-it:free",
    ]

# Slack configuration
SLACK_BOT_TOKEN = os.getenv("SLACK_BOT_TOKEN", "")
SLACK_CHANNEL = os.getenv("SLACK_CHANNEL", "automation")

# Redis configuration
REDIS_URL = os.getenv("REDIS_URL", "redis://redis.redis.svc.cluster.local:6379/0")
REDIS_PREFIX = "yt-highlights:"

# Paths
AUDIO_PATH = DATA_PATH / "audio"
TRANSCRIPTS_PATH = DATA_PATH / "transcripts"
HIGHLIGHTS_PATH = DATA_PATH / "highlights"
CONFIG_PATH = DATA_PATH / "config"
STATE_PATH = DATA_PATH / "state"

# Ensure directories exist
for path in [AUDIO_PATH, TRANSCRIPTS_PATH, HIGHLIGHTS_PATH, CONFIG_PATH, STATE_PATH]:
    path.mkdir(parents=True, exist_ok=True)

# Global state
whisper_model: Optional[WhisperModel] = None
redis_client: Optional[redis.Redis] = None

# Worker thread state
job_queue: queue.Queue = queue.Queue()
worker_thread: Optional[threading.Thread] = None
worker_running: bool = False


class JobStore:
    """Redis-backed job storage."""

    # Jobs older than this are auto-expired
    JOB_EXPIRY_HOURS = 24

    def __init__(self, client: redis.Redis, prefix: str = REDIS_PREFIX):
        self.client = client
        self.prefix = prefix

    def _key(self, job_id: str) -> str:
        return f"{self.prefix}job:{job_id}"

    def set(self, job_id: str, job_data: dict):
        """Store job data in Redis."""
        self.client.set(self._key(job_id), json.dumps(job_data))
        # Add to job index
        self.client.sadd(f"{self.prefix}jobs", job_id)

    def get(self, job_id: str) -> Optional[dict]:
        """Get job data from Redis."""
        data = self.client.get(self._key(job_id))
        if data:
            return json.loads(data)
        return None

    def update(self, job_id: str, **kwargs):
        """Update specific fields in a job."""
        job = self.get(job_id)
        if job:
            job.update(kwargs)
            self.set(job_id, job)

    def delete(self, job_id: str):
        """Delete a job from Redis."""
        self.client.delete(self._key(job_id))
        self.client.srem(f"{self.prefix}jobs", job_id)

    def all(self) -> list[dict]:
        """Get all jobs."""
        job_ids = self.client.smembers(f"{self.prefix}jobs")
        jobs = []
        for job_id in job_ids:
            job = self.get(job_id.decode() if isinstance(job_id, bytes) else job_id)
            if job:
                jobs.append(job)
        return jobs

    def get_pending(self) -> list[dict]:
        """Get jobs that need to be resumed (queued or processing)."""
        pending = []
        for job in self.all():
            if job.get("status") in ("queued", "downloading", "transcribing", "analyzing"):
                pending.append(job)
        return pending

    def expire_old_jobs(self) -> int:
        """Expire jobs older than JOB_EXPIRY_HOURS.

        Returns the number of jobs expired.
        """
        from datetime import datetime, timedelta

        cutoff = datetime.utcnow() - timedelta(hours=self.JOB_EXPIRY_HOURS)
        expired_count = 0

        for job in self.all():
            # Skip already completed or failed jobs
            if job.get("status") in ("completed", "failed", "expired"):
                continue

            # Check job age
            created_at = job.get("created_at")
            if not created_at:
                continue

            try:
                # Parse ISO format datetime
                job_time = datetime.fromisoformat(created_at.replace("Z", "+00:00").replace("+00:00", ""))
                if job_time < cutoff:
                    job_id = job.get("job_id")
                    self.update(
                        job_id,
                        status="expired",
                        error=f"Job expired after {self.JOB_EXPIRY_HOURS} hours"
                    )
                    expired_count += 1
                    logger.info(f"Expired old job: {job_id}")
            except (ValueError, TypeError) as e:
                logger.warning(f"Could not parse job date: {created_at}: {e}")

        return expired_count


# Global job store (initialized on startup)
job_store: Optional[JobStore] = None


# Pydantic models
class ProcessRequest(BaseModel):
    video_url: str
    whisper_model: Optional[str] = None
    language: Optional[str] = "en"
    num_highlights: Optional[int] = 5


class ChannelRequest(BaseModel):
    channel_id: str
    name: Optional[str] = None


class JobStatus(BaseModel):
    job_id: str
    status: str
    video_url: str
    video_title: Optional[str] = None
    progress: Optional[str] = None
    error: Optional[str] = None
    created_at: str


class Highlight(BaseModel):
    timestamp: str
    timestamp_seconds: int
    title: str
    description: str


class JobResult(BaseModel):
    job_id: str
    status: str
    video_url: str
    video_title: str
    duration_seconds: int
    highlights: list[Highlight]
    summary: str
    transcript_path: str


def load_json(path: Path, default: dict) -> dict:
    """Load JSON file or return default."""
    if path.exists():
        return json.loads(path.read_text())
    return default


def save_json(path: Path, data: dict):
    """Save data to JSON file."""
    path.write_text(json.dumps(data, indent=2))


def send_notification_sync(title: str, message: str, url: str = None):
    """Send notification via Slack (synchronous)."""
    import requests

    if not SLACK_BOT_TOKEN:
        logger.warning("Slack bot token not configured, skipping notification")
        return

    try:
        # Build Slack message blocks
        blocks = [
            {
                "type": "header",
                "text": {"type": "plain_text", "text": title[:150], "emoji": True}
            },
            {
                "type": "section",
                "text": {"type": "mrkdwn", "text": message[:2900]}
            }
        ]

        if url:
            blocks.append({
                "type": "section",
                "text": {"type": "mrkdwn", "text": f"<{url}|Watch Video>"}
            })

        response = requests.post(
            "https://slack.com/api/chat.postMessage",
            headers={
                "Authorization": f"Bearer {SLACK_BOT_TOKEN}",
                "Content-Type": "application/json",
            },
            json={
                "channel": SLACK_CHANNEL,
                "text": f"{title}: {message}",  # Fallback text
                "blocks": blocks
            },
            timeout=10.0
        )

        result = response.json()
        if not result.get("ok"):
            logger.warning(f"Slack API error: {result.get('error', 'unknown')}")
        else:
            logger.info(f"Slack notification sent: {title}")

    except Exception as e:
        logger.warning(f"Failed to send Slack notification: {e}")


async def send_notification(title: str, message: str, url: str = None):
    """Send notification via Slack (async wrapper)."""
    loop = asyncio.get_event_loop()
    await loop.run_in_executor(None, send_notification_sync, title, message, url)


def get_channels() -> dict:
    """Get subscribed channels."""
    return load_json(CONFIG_PATH / "channels.json", {"channels": []})


def save_channels(data: dict):
    """Save channels."""
    save_json(CONFIG_PATH / "channels.json", data)


def get_processed() -> dict:
    """Get processed videos."""
    return load_json(STATE_PATH / "processed.json", {"processed_videos": {}})


def save_processed(data: dict):
    """Save processed videos."""
    save_json(STATE_PATH / "processed.json", data)


def cleanup_old_processed(hours: int = 24) -> int:
    """Remove processed videos older than specified hours.

    Deletes both the state entry and the highlights JSON file.
    Returns the number of videos cleaned up.
    """
    from datetime import datetime, timedelta

    cutoff = datetime.utcnow() - timedelta(hours=hours)
    processed = get_processed()
    videos = processed.get("processed_videos", {})
    cleaned = 0

    to_remove = []
    for video_id, info in videos.items():
        processed_at = info.get("processed_at")
        if not processed_at:
            continue

        try:
            # Parse ISO format datetime
            video_time = datetime.fromisoformat(processed_at.replace("Z", "+00:00").replace("+00:00", ""))
            if video_time < cutoff:
                to_remove.append(video_id)

                # Delete highlights file if exists
                highlights_path = info.get("highlights_path")
                if highlights_path:
                    path = Path(highlights_path)
                    if path.exists():
                        path.unlink()
                        logger.info(f"Deleted old highlights file: {path}")

                # Also delete transcript if exists
                transcript_path = TRANSCRIPTS_PATH / f"{video_id}.json"
                if transcript_path.exists():
                    transcript_path.unlink()
                    logger.info(f"Deleted old transcript file: {transcript_path}")

                cleaned += 1
        except (ValueError, TypeError) as e:
            logger.warning(f"Could not parse processed date: {processed_at}: {e}")

    # Remove from state
    for video_id in to_remove:
        del videos[video_id]
        logger.info(f"Removed old processed video: {video_id}")

    if to_remove:
        save_processed(processed)

    return cleaned


def extract_video_id(url: str) -> str:
    """Extract video ID from YouTube URL."""
    import re
    patterns = [
        r'(?:youtube\.com/watch\?v=|youtu\.be/|youtube\.com/embed/)([a-zA-Z0-9_-]{11})',
    ]
    for pattern in patterns:
        match = re.search(pattern, url)
        if match:
            return match.group(1)
    return url


async def download_audio(video_url: str, output_path: Path) -> dict:
    """Download audio from YouTube video (async wrapper)."""
    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(None, download_audio_sync, video_url, output_path)


def download_audio_sync(video_url: str, output_path: Path) -> dict:
    """Download audio from YouTube video (synchronous)."""
    ydl_opts = {
        # Accept any format - FFmpeg will extract audio
        'format': 'best',
        'postprocessors': [{
            'key': 'FFmpegExtractAudio',
            'preferredcodec': 'mp3',
            'preferredquality': '128',  # Lower quality is fine for transcription
        }],
        'outtmpl': str(output_path.with_suffix('')),
        'quiet': True,
        'no_warnings': True,
        # Avoid 403 errors from YouTube
        'http_headers': {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Accept-Language': 'en-us,en;q=0.5',
        },
        'extractor_args': {'youtube': {'player_client': ['ios', 'android', 'web']}},
    }

    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(video_url, download=True)
        return {
            'title': info.get('title', 'Unknown'),
            'duration': info.get('duration', 0),
            'channel': info.get('channel', 'Unknown'),
            'upload_date': info.get('upload_date', ''),
        }


async def transcribe_audio(audio_path: Path, language: str = "en") -> list[dict]:
    """Transcribe audio using Faster-Whisper (async wrapper)."""
    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(None, transcribe_audio_sync, audio_path, language)


def transcribe_audio_sync(audio_path: Path, language: str = "en") -> list[dict]:
    """Transcribe audio using Faster-Whisper (synchronous)."""
    global whisper_model

    if whisper_model is None:
        logger.info(f"Loading Whisper model: {ASR_MODEL} on {ASR_DEVICE}")
        whisper_model = WhisperModel(
            ASR_MODEL,
            device=ASR_DEVICE,
            compute_type="float16" if ASR_DEVICE == "cuda" else "int8"
        )

    segments, info = whisper_model.transcribe(
        str(audio_path),
        language=language,
        word_timestamps=True
    )
    return [
        {
            "start": segment.start,
            "end": segment.end,
            "text": segment.text.strip(),
        }
        for segment in segments
    ]


def format_timestamp(seconds: float) -> str:
    """Format seconds as MM:SS or HH:MM:SS."""
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = int(seconds % 60)
    if hours > 0:
        return f"{hours}:{minutes:02d}:{secs:02d}"
    return f"{minutes}:{secs:02d}"


async def extract_highlights(
    transcript: list[dict],
    video_title: str,
    num_highlights: int = 5
) -> dict:
    """Extract highlights using OpenRouter LLM (async wrapper)."""
    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(
        None, extract_highlights_sync, transcript, video_title, num_highlights
    )


def _call_llm_with_retry(prompt: str) -> dict:
    """Call OpenRouter LLM with limited retries, then Ollama fallback.

    Tries up to 5 OpenRouter models once each, then falls back to Ollama.
    Designed to fail fast - Ollama is the reliable fallback.
    """
    import requests
    import time

    # Configuration - keep it fast, Ollama is reliable fallback
    MAX_MODELS_TO_TRY = 5

    # Get available free models (cached, refreshed hourly)
    model_pool = _fetch_free_models()[:MAX_MODELS_TO_TRY]

    last_error = None

    for i, model in enumerate(model_pool):
        try:
            logger.info(f"Trying model: {model} ({i + 1}/{len(model_pool)})")

            response = requests.post(
                OPENROUTER_URL,
                headers={
                    "Authorization": f"Bearer {OPENROUTER_API_KEY}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": model,
                    "messages": [{"role": "user", "content": prompt}],
                    "temperature": 0.3,
                },
                timeout=60.0  # Shorter timeout
            )

            # Non-200 responses - log and try next model
            if response.status_code != 200:
                logger.warning(f"Model {model} returned {response.status_code}: {response.text[:200]}")
                last_error = f"Model {model} error: {response.status_code}"
                continue

            result = response.json()

            # Check for API-level errors
            if "error" in result:
                error_msg = result.get('error', {})
                if isinstance(error_msg, dict):
                    error_msg = error_msg.get('message', 'unknown')
                logger.warning(f"Model {model} API error: {error_msg}")
                last_error = f"Model {model} API error: {error_msg}"
                continue

            content = result.get("choices", [{}])[0].get("message", {}).get("content", "")

            if not content or not content.strip():
                logger.warning(f"Model {model} returned empty response")
                last_error = f"Model {model} returned empty response"
                continue

            # Parse and return if successful
            parsed = _parse_llm_response(content, model)
            if parsed:
                logger.info(f"Successfully used model: {model}")
                return parsed
            else:
                last_error = f"Model {model} returned unparseable response"
                continue

        except requests.exceptions.Timeout:
            logger.warning(f"Model {model} timed out")
            last_error = f"Model {model} timed out"
            continue
        except requests.exceptions.RequestException as e:
            logger.warning(f"Model {model} request failed: {e}")
            last_error = f"Model {model} request error: {e}"
            continue
        except Exception as e:
            logger.warning(f"Model {model} unexpected error: {e}")
            last_error = f"Model {model} error: {e}"
            continue

    # Try Ollama as last resort if configured
    if OLLAMA_URL:
        logger.info(f"All OpenRouter models failed, trying Ollama fallback: {OLLAMA_MODEL}")
        try:
            response = requests.post(
                f"{OLLAMA_URL}/api/generate",
                json={
                    "model": OLLAMA_MODEL,
                    "prompt": prompt,
                    "stream": False,
                    "options": {"temperature": 0.3}
                },
                timeout=300.0  # Ollama can be slow on first load
            )

            if response.status_code == 200:
                result = response.json()
                content = result.get("response", "")
                if content:
                    parsed = _parse_llm_response(content, f"ollama:{OLLAMA_MODEL}")
                    if parsed:
                        logger.info(f"Successfully used Ollama fallback: {OLLAMA_MODEL}")
                        return parsed
                    else:
                        last_error = f"Ollama {OLLAMA_MODEL} returned unparseable response"
                else:
                    last_error = f"Ollama {OLLAMA_MODEL} returned empty response"
            else:
                last_error = f"Ollama {OLLAMA_MODEL} error: {response.status_code}"
                logger.warning(f"Ollama fallback failed: {response.status_code} - {response.text[:200]}")

        except Exception as e:
            logger.warning(f"Ollama fallback failed: {e}")
            last_error = f"Ollama error: {e}"

    # All models failed
    raise ValueError(f"All models failed. Last error: {last_error}")


def _parse_llm_response(content: str, model_name: str) -> Optional[dict]:
    """Parse LLM response content into JSON dict. Returns None if parsing fails."""
    import re

    # Strip DeepSeek R1 thinking blocks (e.g., <think>...</think>)
    content = re.sub(r'<think>.*?</think>', '', content, flags=re.DOTALL)

    # Parse JSON from response (handle markdown code blocks)
    if "```json" in content:
        content = content.split("```json")[1].split("```")[0]
    elif "```" in content:
        content = content.split("```")[1].split("```")[0]

    content = content.strip()
    if not content:
        logger.warning(f"Model {model_name} returned no JSON content after stripping")
        return None

    try:
        return json.loads(content)
    except json.JSONDecodeError as e:
        logger.warning(f"Model {model_name} returned invalid JSON: {e}")
        return None


def extract_highlights_sync(
    transcript: list[dict],
    video_title: str,
    num_highlights: int = 5
) -> dict:
    """Extract highlights using OpenRouter LLM (synchronous).

    For long transcripts, splits into chunks and processes each separately,
    then combines results. Tries multiple models with exponential backoff.
    """
    # Chunk configuration - conservative limit for free tier models
    MAX_CHUNK_CHARS = 6000  # ~1500 tokens, safe for most free models
    HIGHLIGHTS_PER_CHUNK = max(2, num_highlights // 2)

    # Format transcript with timestamps
    formatted_segments = [
        f"[{format_timestamp(seg['start'])}] {seg['text']}"
        for seg in transcript
    ]
    formatted_transcript = "\n".join(formatted_segments)

    # If transcript is small enough, process in one go
    if len(formatted_transcript) <= MAX_CHUNK_CHARS:
        logger.info(f"Processing transcript in single chunk ({len(formatted_transcript)} chars)")
        return _process_single_chunk(formatted_transcript, video_title, num_highlights)

    # Split into chunks for long transcripts
    chunks = []
    current_chunk = []
    current_length = 0

    for segment in formatted_segments:
        seg_len = len(segment) + 1  # +1 for newline
        if current_length + seg_len > MAX_CHUNK_CHARS and current_chunk:
            chunks.append("\n".join(current_chunk))
            current_chunk = [segment]
            current_length = seg_len
        else:
            current_chunk.append(segment)
            current_length += seg_len

    if current_chunk:
        chunks.append("\n".join(current_chunk))

    logger.info(f"Processing transcript in {len(chunks)} chunks ({len(formatted_transcript)} total chars)")

    # Process each chunk
    all_highlights = []
    summaries = []

    for i, chunk in enumerate(chunks):
        logger.info(f"Processing chunk {i + 1}/{len(chunks)} ({len(chunk)} chars)")
        try:
            result = _process_single_chunk(chunk, video_title, HIGHLIGHTS_PER_CHUNK, is_partial=True, chunk_num=i+1, total_chunks=len(chunks))
            all_highlights.extend(result.get("highlights", []))
            if result.get("summary"):
                summaries.append(result["summary"])
        except Exception as e:
            logger.warning(f"Chunk {i + 1} failed: {e}")
            # Continue with other chunks

    if not all_highlights and not summaries:
        raise ValueError("All chunks failed to process")

    # Sort highlights by timestamp and take top N
    all_highlights.sort(key=lambda h: h.get("timestamp_seconds", 0))
    top_highlights = all_highlights[:num_highlights]

    # Combine summaries
    if len(summaries) > 1:
        combined_summary = " ".join(summaries)
    elif summaries:
        combined_summary = summaries[0]
    else:
        combined_summary = "Video processed in chunks."

    return {
        "highlights": top_highlights,
        "summary": combined_summary
    }


def _process_single_chunk(
    formatted_transcript: str,
    video_title: str,
    num_highlights: int,
    is_partial: bool = False,
    chunk_num: int = 1,
    total_chunks: int = 1
) -> dict:
    """Process a single transcript chunk to extract highlights."""
    chunk_context = ""
    summary_instruction = "Provide a brief summary (2-3 sentences MAX, under 200 characters) of the main takeaway."
    if is_partial:
        chunk_context = f" (Part {chunk_num} of {total_chunks})"
        summary_instruction = "Provide a one-sentence summary (under 100 characters) of this section's main point."

    prompt = f"""Analyze this video transcript and extract key moments.

Video: "{video_title}"{chunk_context}

TASK:
1. Identify exactly {num_highlights} most important/interesting moments
2. {summary_instruction}

OUTPUT FORMAT (valid JSON only, no other text):
{{
  "highlights": [
    {{"timestamp": "MM:SS", "timestamp_seconds": <int>, "title": "<max 8 words>", "description": "<1 sentence>"}}
  ],
  "summary": "<brief summary as instructed>"
}}

RULES:
- Timestamps MUST match exactly from transcript (format: MM:SS or H:MM:SS)
- Keep titles punchy and specific (not generic like "Important point")
- Summary must be SHORT - this is critical

Transcript:
{formatted_transcript}"""

    return _call_llm_with_retry(prompt)


def process_video_sync(job_id: str, video_url: str, language: str, num_highlights: int):
    """Process a video: download, transcribe, extract highlights (synchronous).

    This runs entirely in the worker thread, keeping the main event loop free.
    """
    video_id = extract_video_id(video_url)

    try:
        job_store.update(job_id, status="downloading", progress="Downloading audio...")

        audio_path = AUDIO_PATH / f"{video_id}.mp3"
        video_info = download_audio_sync(video_url, audio_path)

        job_store.update(
            job_id,
            video_title=video_info["title"],
            status="transcribing",
            progress="Transcribing audio..."
        )

        transcript = transcribe_audio_sync(audio_path, language)

        # Save transcript
        transcript_path = TRANSCRIPTS_PATH / f"{video_id}.json"
        save_json(transcript_path, {
            "video_id": video_id,
            "video_url": video_url,
            "title": video_info["title"],
            "duration": video_info["duration"],
            "segments": transcript
        })

        job_store.update(job_id, status="analyzing", progress="Extracting highlights...")

        highlights = extract_highlights_sync(
            transcript,
            video_info["title"],
            num_highlights
        )

        # Save highlights
        result = {
            "job_id": job_id,
            "video_id": video_id,
            "video_url": video_url,
            "video_title": video_info["title"],
            "duration_seconds": video_info["duration"],
            "highlights": highlights.get("highlights", []),
            "summary": highlights.get("summary", ""),
            "transcript_path": str(transcript_path),
            "processed_at": datetime.utcnow().isoformat()
        }

        highlights_path = HIGHLIGHTS_PATH / f"{video_id}.json"
        save_json(highlights_path, result)

        # Update processed state
        processed = get_processed()
        processed["processed_videos"][video_id] = {
            "processed_at": datetime.utcnow().isoformat(),
            "status": "completed",
            "highlights_path": str(highlights_path)
        }
        save_processed(processed)

        job_store.update(job_id, status="completed", progress=None, result=result)

        # Cleanup audio file
        if audio_path.exists():
            audio_path.unlink()

        logger.info(f"Job {job_id} completed: {video_info['title']}")

        # Build notification message with summary and highlights
        summary_text = highlights.get('summary', 'No summary')
        highlight_list = highlights.get('highlights', [])

        message_parts = [f"*Summary:* {summary_text}"]

        if highlight_list:
            message_parts.append("\n*Key Moments:*")
            for h in highlight_list[:5]:  # Limit to 5 highlights
                ts = h.get('timestamp', '0:00')
                title = h.get('title', 'Untitled')
                message_parts.append(f"- `{ts}` {title}")

        notification_message = "\n".join(message_parts)

        # Send notification (sync version)
        send_notification_sync(
            title=f"Video Processed: {video_info['title'][:50]}",
            message=notification_message,
            url=video_url
        )

    except Exception as e:
        logger.exception(f"Job {job_id} failed: {e}")
        job_store.update(job_id, status="failed", error=str(e))


def worker_loop():
    """Worker thread main loop - processes jobs from the queue one at a time."""
    global worker_running
    logger.info("Worker thread started")

    while worker_running:
        try:
            # Block for up to 1 second waiting for a job
            job = job_queue.get(timeout=1.0)
        except queue.Empty:
            continue

        try:
            job_id = job["job_id"]
            video_url = job["video_url"]
            language = job.get("language", "en")
            num_highlights = job.get("num_highlights", 5)

            logger.info(f"Worker processing job {job_id}: {video_url}")
            process_video_sync(job_id, video_url, language, num_highlights)

        except Exception as e:
            logger.exception(f"Worker error processing job: {e}")
        finally:
            job_queue.task_done()

    logger.info("Worker thread stopped")


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan handler."""
    global redis_client, job_store, worker_thread, worker_running

    logger.info("Starting yt-highlights service...")

    # Initialize Redis connection
    try:
        redis_client = redis.from_url(REDIS_URL, decode_responses=False)
        redis_client.ping()
        job_store = JobStore(redis_client)
        logger.info(f"Connected to Redis at {REDIS_URL}")

        # Expire old jobs on startup
        expired = job_store.expire_old_jobs()
        if expired:
            logger.info(f"Expired {expired} old jobs on startup")

        # Cleanup old processed videos on startup
        cleaned = cleanup_old_processed(hours=24)
        if cleaned:
            logger.info(f"Cleaned up {cleaned} old processed videos on startup")

        # Check for pending jobs that need to be resumed
        pending = job_store.get_pending()
        if pending:
            logger.info(f"Found {len(pending)} pending jobs to resume")
            for job in pending:
                # Mark as failed with resume note - they need to be resubmitted
                job_store.update(
                    job["job_id"],
                    status="failed",
                    error="Service restarted - please resubmit"
                )
    except Exception as e:
        logger.error(f"Failed to connect to Redis: {e}")
        raise

    # Start worker thread
    worker_running = True
    worker_thread = threading.Thread(target=worker_loop, daemon=True, name="video-worker")
    worker_thread.start()
    logger.info("Worker thread started")

    yield

    logger.info("Shutting down yt-highlights service...")

    # Stop worker thread
    worker_running = False
    if worker_thread and worker_thread.is_alive():
        worker_thread.join(timeout=5.0)
        logger.info("Worker thread stopped")

    if redis_client:
        redis_client.close()


app = FastAPI(
    title="YouTube Highlights Extractor",
    description="Extract key moments and summaries from YouTube videos",
    version="1.0.0",
    lifespan=lifespan
)


@app.get("/health")
async def health():
    """Health check endpoint."""
    return {"status": "healthy", "model": ASR_MODEL, "device": ASR_DEVICE}


@app.post("/process")
async def process(request: ProcessRequest):
    """Queue a video for processing."""
    job_id = str(uuid.uuid4())[:8]

    job_data = {
        "job_id": job_id,
        "status": "queued",
        "video_url": request.video_url,
        "video_title": None,
        "progress": None,
        "error": None,
        "created_at": datetime.utcnow().isoformat(),
    }

    job_store.set(job_id, job_data)

    # Add to worker queue instead of background task
    job_queue.put({
        "job_id": job_id,
        "video_url": request.video_url,
        "language": request.language or "en",
        "num_highlights": request.num_highlights or 5,
    })

    return JobStatus(**job_data)


@app.get("/status/{job_id}")
async def status(job_id: str):
    """Get job status."""
    job = job_store.get(job_id)
    if not job:
        raise HTTPException(404, f"Job {job_id} not found")
    return JobStatus(**job)


@app.get("/results/{job_id}")
async def results(job_id: str):
    """Get job results."""
    job = job_store.get(job_id)
    if not job:
        raise HTTPException(404, f"Job {job_id} not found")

    if job["status"] != "completed":
        raise HTTPException(400, f"Job {job_id} not completed: {job['status']}")

    return job.get("result", {})


@app.delete("/jobs/{job_id}")
async def delete_job(job_id: str):
    """Delete a job from the queue."""
    job = job_store.get(job_id)
    if not job:
        raise HTTPException(404, f"Job {job_id} not found")

    job_store.delete(job_id)
    return {"status": "deleted", "job_id": job_id}


def resolve_channel_id(channel_input: str) -> tuple[str, str]:
    """Resolve a YouTube channel handle/URL to a channel ID.

    Args:
        channel_input: Can be a handle (@username), channel ID (UC...), or URL

    Returns:
        Tuple of (channel_id, channel_name)
    """
    # If it's already a channel ID (starts with UC and is 24 chars), return as-is
    if channel_input.startswith("UC") and len(channel_input) == 24:
        return channel_input, channel_input

    # Build URL from handle or use as-is if it's a URL
    if channel_input.startswith("@"):
        url = f"https://www.youtube.com/{channel_input}"
    elif channel_input.startswith("http"):
        url = channel_input
    else:
        url = f"https://www.youtube.com/@{channel_input}"

    try:
        ydl_opts = {
            'quiet': True,
            'extract_flat': True,
            'playlist_items': '1',
            'no_warnings': True,
        }
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(url, download=False)
            channel_id = info.get('channel_id')
            channel_name = info.get('channel') or info.get('uploader') or channel_input
            if channel_id:
                return channel_id, channel_name
            raise ValueError(f"Could not resolve channel ID for {channel_input}")
    except Exception as e:
        logger.error(f"Failed to resolve channel: {channel_input}: {e}")
        raise ValueError(f"Could not resolve channel: {channel_input}")


@app.get("/channels")
async def list_channels():
    """List subscribed channels."""
    return get_channels()


@app.post("/channels")
async def add_channel(request: ChannelRequest):
    """Add a channel subscription.

    Accepts handles (@username), channel IDs (UC...), or URLs.
    Resolves to the actual channel ID for RSS feed compatibility.
    """
    channels = get_channels()

    # Resolve to actual channel ID
    try:
        channel_id, channel_name = resolve_channel_id(request.channel_id)
    except ValueError as e:
        raise HTTPException(400, str(e))

    # Check if already subscribed (check both input and resolved ID)
    for ch in channels["channels"]:
        if ch["id"] == channel_id:
            raise HTTPException(400, f"Channel already subscribed (ID: {channel_id})")

    channels["channels"].append({
        "id": channel_id,
        "name": request.name or channel_name,
        "handle": request.channel_id if request.channel_id.startswith("@") else None,
        "added_at": datetime.utcnow().isoformat(),
        "last_checked": None,
        "enabled": True
    })

    save_channels(channels)
    logger.info(f"Added channel: {channel_name} (ID: {channel_id})")
    return {"status": "added", "channel_id": channel_id, "name": channel_name}


@app.delete("/channels/{channel_id}")
async def remove_channel(channel_id: str):
    """Remove a channel subscription."""
    channels = get_channels()
    channels["channels"] = [
        ch for ch in channels["channels"]
        if ch["id"] != channel_id
    ]
    save_channels(channels)
    return {"status": "removed", "channel_id": channel_id}


@app.post("/channels/migrate")
async def migrate_channels():
    """Migrate existing channels from handles to proper channel IDs.

    Fixes channels that were added with handles (@username) instead of IDs.
    """
    channels = get_channels()
    migrated = []
    failed = []

    for channel in channels["channels"]:
        old_id = channel["id"]
        # Skip if already a proper channel ID
        if old_id.startswith("UC") and len(old_id) == 24:
            continue

        try:
            new_id, new_name = resolve_channel_id(old_id)
            channel["id"] = new_id
            channel["handle"] = old_id if old_id.startswith("@") else None
            channel["name"] = new_name
            migrated.append({"old": old_id, "new": new_id, "name": new_name})
            logger.info(f"Migrated channel: {old_id} -> {new_id}")
        except Exception as e:
            failed.append({"id": old_id, "error": str(e)})
            logger.error(f"Failed to migrate channel {old_id}: {e}")

    if migrated:
        save_channels(channels)

    return {"migrated": migrated, "failed": failed}


@app.post("/check-new")
async def check_new_videos():
    """Check all subscribed channels for new videos."""
    channels = get_channels()
    processed = get_processed()
    new_videos = []

    for channel in channels["channels"]:
        if not channel.get("enabled", True):
            continue

        feed_url = f"https://www.youtube.com/feeds/videos.xml?channel_id={channel['id']}"

        try:
            feed = feedparser.parse(feed_url)

            for entry in feed.entries[:5]:  # Check last 5 videos
                video_id = entry.yt_videoid

                if video_id not in processed.get("processed_videos", {}):
                    new_videos.append({
                        "video_id": video_id,
                        "video_url": entry.link,
                        "title": entry.title,
                        "channel": channel["name"],
                        "published": entry.published
                    })

            # Update last checked
            channel["last_checked"] = datetime.utcnow().isoformat()

        except Exception as e:
            logger.error(f"Error checking channel {channel['id']}: {e}")

    save_channels(channels)

    return {
        "channels_checked": len(channels["channels"]),
        "new_videos": new_videos
    }


@app.get("/jobs")
async def list_jobs():
    """List all jobs. Auto-expires jobs older than 24 hours."""
    # Expire old jobs before listing
    job_store.expire_old_jobs()
    return {"jobs": job_store.all()}


@app.get("/processed")
async def list_processed():
    """List all processed videos with their results. Auto-cleans videos older than 24 hours."""
    # Cleanup old processed videos before listing
    cleanup_old_processed(hours=24)

    results = []
    for video_id, info in get_processed().get("processed_videos", {}).items():
        highlights_path = Path(info.get("highlights_path", ""))
        if highlights_path.exists():
            try:
                data = json.loads(highlights_path.read_text())
                results.append(data)
            except Exception:
                pass
    # Sort by processed_at descending
    results.sort(key=lambda x: x.get("processed_at", ""), reverse=True)
    return {"videos": results}


@app.post("/auto-process")
async def auto_process():
    """Check for new videos and auto-queue them for processing.

    Designed to be called by n8n or other schedulers.
    """
    # First check for new videos
    channels = get_channels()
    processed = get_processed()
    new_videos = []

    for channel in channels["channels"]:
        if not channel.get("enabled", True):
            continue

        feed_url = f"https://www.youtube.com/feeds/videos.xml?channel_id={channel['id']}"

        try:
            feed = feedparser.parse(feed_url)

            for entry in feed.entries[:3]:  # Check last 3 videos
                video_id = entry.yt_videoid

                if video_id not in processed.get("processed_videos", {}):
                    new_videos.append({
                        "video_id": video_id,
                        "video_url": entry.link,
                        "title": entry.title,
                        "channel": channel["name"],
                    })

            channel["last_checked"] = datetime.utcnow().isoformat()

        except Exception as e:
            logger.error(f"Error checking channel {channel['id']}: {e}")

    save_channels(channels)

    # Queue new videos for processing
    queued_jobs = []
    for video in new_videos:
        job_id = str(uuid.uuid4())[:8]

        job_data = {
            "job_id": job_id,
            "status": "queued",
            "video_url": video["video_url"],
            "video_title": video["title"],
            "progress": None,
            "error": None,
            "created_at": datetime.utcnow().isoformat(),
        }

        job_store.set(job_id, job_data)

        # Add to worker queue instead of background task
        job_queue.put({
            "job_id": job_id,
            "video_url": video["video_url"],
            "language": "en",
            "num_highlights": 5,
        })

        queued_jobs.append({"job_id": job_id, "title": video["title"]})

    return {
        "channels_checked": len(channels["channels"]),
        "new_videos_found": len(new_videos),
        "queued": queued_jobs
    }


# Serve static files for web UI
STATIC_PATH = Path(__file__).parent / "static"
if STATIC_PATH.exists():
    app.mount("/static", StaticFiles(directory=str(STATIC_PATH)), name="static")


@app.get("/")
async def root():
    """Serve the web UI."""
    index_path = STATIC_PATH / "index.html"
    if index_path.exists():
        return FileResponse(index_path)
    return {"message": "YouTube Highlights API", "docs": "/docs"}
