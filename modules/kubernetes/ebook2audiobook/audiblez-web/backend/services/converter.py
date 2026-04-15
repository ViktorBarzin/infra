import asyncio
import uuid
import os
from datetime import datetime
from pathlib import Path
from typing import Callable, Optional
import subprocess
import json

from models.schemas import Job, JobStatus, JobProgress, ChapterInfo
from services.epub_parser import extract_chapters, Chapter
from services.chapter_embedder import (
    get_chapter_audio_durations,
    generate_ffmpeg_metadata,
    embed_chapters_in_m4b
)


class JobManager:
    """Manages conversion jobs and their state with user isolation."""

    def __init__(self, storage_path: str = "/mnt"):
        self.storage_path = Path(storage_path)
        self.jobs: dict[str, Job] = {}
        self.progress_callbacks: dict[str, list[Callable]] = {}

    def get_user_uploads_dir(self, user_id: str) -> Path:
        """Get the uploads directory for a specific user."""
        user_dir = self.storage_path / "users" / user_id / "uploads"
        user_dir.mkdir(parents=True, exist_ok=True)
        return user_dir

    def get_user_outputs_dir(self, user_id: str) -> Path:
        """Get the outputs directory for a specific user."""
        user_dir = self.storage_path / "users" / user_id / "outputs"
        user_dir.mkdir(parents=True, exist_ok=True)
        return user_dir

    def create_job(self, user_id: str, filename: str, voice: str, speed: float, use_gpu: bool) -> Job:
        """Create a new conversion job for a user."""
        job_id = str(uuid.uuid4())
        now = datetime.now()

        job = Job(
            id=job_id,
            user_id=user_id,
            filename=filename,
            voice=voice,
            speed=speed,
            use_gpu=use_gpu,
            status=JobStatus.PENDING,
            created_at=now,
            updated_at=now,
        )

        self.jobs[job_id] = job
        return job

    def get_job(self, job_id: str, user_id: Optional[str] = None) -> Optional[Job]:
        """Get a job by ID. If user_id is provided, verify ownership."""
        job = self.jobs.get(job_id)
        if job and user_id and job.user_id != user_id:
            return None  # User doesn't own this job
        return job

    def get_user_jobs(self, user_id: str) -> list[Job]:
        """Get all jobs for a specific user."""
        return [job for job in self.jobs.values() if job.user_id == user_id]

    def get_all_jobs(self) -> list[Job]:
        """Get all jobs (admin use only)."""
        return list(self.jobs.values())

    def update_job_status(self, job_id: str, status: JobStatus, error: Optional[str] = None):
        """Update job status."""
        if job_id in self.jobs:
            self.jobs[job_id].status = status
            self.jobs[job_id].updated_at = datetime.now()
            if error:
                self.jobs[job_id].error = error

    def update_job_progress(self, job_id: str, progress: float, current_chapter: Optional[str] = None, eta: Optional[str] = None):
        """Update job progress."""
        if job_id in self.jobs:
            self.jobs[job_id].progress = progress
            self.jobs[job_id].updated_at = datetime.now()

            # Notify callbacks
            if job_id in self.progress_callbacks:
                progress_data = JobProgress(
                    progress=progress,
                    eta=eta,
                    current_chapter=current_chapter,
                    status=self.jobs[job_id].status
                )
                for callback in self.progress_callbacks[job_id]:
                    try:
                        asyncio.create_task(callback(progress_data))
                    except Exception as e:
                        print(f"Error in progress callback: {e}")

    def register_progress_callback(self, job_id: str, callback: Callable):
        """Register a callback for progress updates."""
        if job_id not in self.progress_callbacks:
            self.progress_callbacks[job_id] = []
        self.progress_callbacks[job_id].append(callback)

    def unregister_progress_callback(self, job_id: str, callback: Callable):
        """Unregister a progress callback."""
        if job_id in self.progress_callbacks:
            self.progress_callbacks[job_id].remove(callback)
            if not self.progress_callbacks[job_id]:
                del self.progress_callbacks[job_id]

    async def run_conversion(self, job_id: str):
        """Run the audiblez conversion in the background."""
        job = self.jobs.get(job_id)
        if not job:
            return

        try:
            self.update_job_status(job_id, JobStatus.PROCESSING)

            # Prepare user-specific paths
            input_path = self.get_user_uploads_dir(job.user_id) / job.filename
            output_dir = self.get_user_outputs_dir(job.user_id) / job_id
            output_dir.mkdir(parents=True, exist_ok=True)

            # Extract chapters from EPUB before conversion
            chapters: list[Chapter] = []
            if input_path.suffix.lower() == '.epub':
                chapters = extract_chapters(input_path)
                self.jobs[job_id].total_chapters = len(chapters)
                print(f"Extracted {len(chapters)} chapters from EPUB")

            # Build audiblez command - use the venv python/audiblez
            cmd = [
                "/app/audiblez/bin/audiblez",
                str(input_path),
                "-o", str(output_dir),
                "-v", job.voice,
                "-s", str(job.speed),
            ]

            if job.use_gpu:
                cmd.append("-c")  # --cuda flag for GPU

            # Run conversion
            process = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=str(self.storage_path)
            )

            # Monitor progress from stderr/stdout
            async def read_stream(stream, is_stderr=False):
                while True:
                    line = await stream.readline()
                    if not line:
                        break

                    line_str = line.decode().strip()
                    print(f"{'[STDERR]' if is_stderr else '[STDOUT]'} {line_str}")

                    # Parse progress from output
                    # Audiblez outputs progress in various formats
                    # We'll do a simple pattern match
                    if "%" in line_str:
                        try:
                            # Try to extract percentage
                            parts = line_str.split("%")
                            if len(parts) > 1:
                                # Find the number before %
                                num_str = parts[0].split()[-1]
                                progress = float(num_str)
                                self.update_job_progress(job_id, progress)
                        except:
                            pass

                    # Check for chapter info
                    if "Chapter" in line_str or "chapter" in line_str:
                        self.update_job_progress(
                            job_id,
                            job.progress,
                            current_chapter=line_str
                        )

            # Read both streams concurrently
            await asyncio.gather(
                read_stream(process.stdout),
                read_stream(process.stderr, is_stderr=True)
            )

            # Wait for completion
            returncode = await process.wait()

            if returncode == 0:
                # Find output file
                output_files = list(output_dir.glob("*.m4b"))
                if not output_files:
                    output_files = list(output_dir.glob("*.mp3"))

                if output_files:
                    output_file = output_files[0]

                    # Embed chapter metadata if we have chapters and WAV files
                    if chapters:
                        try:
                            durations = get_chapter_audio_durations(output_dir)
                            print(f"Found {len(durations)} chapter audio durations")

                            if durations:
                                # Match chapter count with duration count
                                num_chapters = min(len(chapters), len(durations))
                                if num_chapters != len(chapters):
                                    print(f"Warning: chapter count ({len(chapters)}) != duration count ({len(durations)})")

                                metadata = generate_ffmpeg_metadata(chapters[:num_chapters], durations[:num_chapters])
                                embed_chapters_in_m4b(output_file, metadata)

                                # Store chapter info in job for API access
                                self.jobs[job_id].chapters = [
                                    ChapterInfo(
                                        title=c.title,
                                        start_ms=c.start_ms,
                                        end_ms=c.end_ms
                                    )
                                    for c in chapters[:num_chapters]
                                ]
                                print(f"Embedded {num_chapters} chapters in M4B")
                            else:
                                print("No WAV files found for chapter duration calculation")
                        except Exception as e:
                            print(f"Failed to embed chapters: {e}")
                            # Continue without chapter embedding - non-fatal error

                    self.jobs[job_id].output_file = str(output_file.name)
                    self.update_job_status(job_id, JobStatus.COMPLETED)
                    self.update_job_progress(job_id, 100.0)
                else:
                    self.update_job_status(job_id, JobStatus.FAILED, "No output file generated")
            else:
                self.update_job_status(job_id, JobStatus.FAILED, f"Conversion failed with code {returncode}")

        except Exception as e:
            print(f"Conversion error: {e}")
            self.update_job_status(job_id, JobStatus.FAILED, str(e))

    def delete_job(self, job_id: str, user_id: str) -> bool:
        """Delete a job and its output files."""
        job = self.get_job(job_id, user_id)
        if not job:
            return False

        # Delete output directory if exists
        output_dir = self.get_user_outputs_dir(user_id) / job_id
        if output_dir.exists():
            import shutil
            shutil.rmtree(output_dir)

        # Remove from jobs dict
        del self.jobs[job_id]
        return True

    def get_user_audiobooks(self, user_id: str) -> list[dict]:
        """List all completed audiobooks for a user."""
        outputs_dir = self.get_user_outputs_dir(user_id)
        audiobooks = []

        if outputs_dir.exists():
            for job_dir in outputs_dir.iterdir():
                if job_dir.is_dir():
                    # Look for m4b or mp3 files
                    audio_files = list(job_dir.glob("*.m4b")) + list(job_dir.glob("*.mp3"))
                    for audio_file in audio_files:
                        stat = audio_file.stat()
                        audiobooks.append({
                            "id": job_dir.name,
                            "filename": audio_file.name,
                            "size": stat.st_size,
                            "created_at": stat.st_mtime,
                        })

        # Sort by creation time, newest first
        audiobooks.sort(key=lambda x: x["created_at"], reverse=True)
        return audiobooks


# Global job manager instance
job_manager = JobManager()
