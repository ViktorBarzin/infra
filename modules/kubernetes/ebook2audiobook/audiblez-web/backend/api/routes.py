from fastapi import APIRouter, UploadFile, File, HTTPException, Depends
from fastapi.responses import FileResponse
from pydantic import BaseModel
from pathlib import Path
import shutil
import asyncio
import re

from models.schemas import Voice, JobCreate, Job, JobProgress, ChapterInfo
from services.voices import get_all_voices, get_voices_by_language, get_voice
from services.converter import job_manager
from api.auth import User, get_current_user

router = APIRouter(prefix="/api")


def sanitize_filename(filename: str, max_length: int = 200) -> str:
    """
    Sanitize a filename to prevent path traversal and shell injection.
    Only allows alphanumeric characters, spaces, hyphens, underscores, parentheses, and dots.
    """
    if not filename:
        raise ValueError("Filename cannot be empty")

    # Remove any path components (prevent path traversal)
    filename = Path(filename).name

    # Only allow safe characters: alphanumeric, space, hyphen, underscore, parentheses, dot
    # This regex removes anything that isn't in the allowed set
    safe_filename = re.sub(r'[^a-zA-Z0-9\s\-_().]', '', filename)

    # Collapse multiple spaces/dots
    safe_filename = re.sub(r'\s+', ' ', safe_filename)
    safe_filename = re.sub(r'\.+', '.', safe_filename)

    # Strip leading/trailing whitespace and dots
    safe_filename = safe_filename.strip(' .')

    # Limit length
    if len(safe_filename) > max_length:
        safe_filename = safe_filename[:max_length]

    if not safe_filename:
        raise ValueError("Filename contains no valid characters")

    return safe_filename


class RenameRequest(BaseModel):
    new_name: str


# ============================================================================
# Voice endpoints (no auth required - public info)
# ============================================================================

@router.get("/voices", response_model=list[Voice])
async def list_voices():
    """Get all available voices."""
    return get_all_voices()


@router.get("/voices/grouped")
async def list_voices_grouped():
    """Get voices grouped by language."""
    return get_voices_by_language()


@router.get("/voices/{voice_id}/sample")
async def get_voice_sample(voice_id: str):
    """Get voice sample audio file."""
    voice = get_voice(voice_id)
    if not voice:
        raise HTTPException(status_code=404, detail="Voice not found")

    # Try NFS storage first (persistent), then bundled samples
    sample_path = Path("/mnt/samples") / f"{voice_id}.mp3"
    if not sample_path.exists():
        sample_path = Path("/app/samples") / f"{voice_id}.mp3"
    if not sample_path.exists():
        raise HTTPException(status_code=404, detail="Sample not available")

    return FileResponse(sample_path, media_type="audio/mpeg")


# ============================================================================
# User info endpoint
# ============================================================================

@router.get("/me")
async def get_current_user_info(user: User = Depends(get_current_user)):
    """Get current authenticated user info."""
    return {
        "uid": user.uid,
        "username": user.username,
        "email": user.email,
        "name": user.name,
        "groups": user.groups
    }


# ============================================================================
# Upload endpoints (user-scoped)
# ============================================================================

@router.post("/upload")
async def upload_file(file: UploadFile = File(...), user: User = Depends(get_current_user)):
    """Upload an EPUB file to user's directory."""
    if not file.filename.endswith(".epub"):
        raise HTTPException(status_code=400, detail="Only EPUB files are supported")

    # Save file to user's uploads directory
    upload_dir = job_manager.get_user_uploads_dir(user.uid)

    # Sanitize the filename
    try:
        safe_filename = sanitize_filename(file.filename)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    file_path = upload_dir / safe_filename

    with file_path.open("wb") as buffer:
        shutil.copyfileobj(file.file, buffer)

    return {"filename": safe_filename, "size": file_path.stat().st_size}


# ============================================================================
# Job endpoints (user-scoped)
# ============================================================================

@router.post("/jobs", response_model=Job)
async def create_job(job_create: JobCreate, user: User = Depends(get_current_user)):
    """Create a new conversion job."""
    # Verify file exists in user's uploads
    file_path = job_manager.get_user_uploads_dir(user.uid) / job_create.filename
    if not file_path.exists():
        raise HTTPException(status_code=404, detail="File not found")

    # Verify voice exists
    voice = get_voice(job_create.voice)
    if not voice:
        raise HTTPException(status_code=404, detail="Voice not found")

    # Create job with user ownership
    job = job_manager.create_job(
        user_id=user.uid,
        filename=job_create.filename,
        voice=job_create.voice,
        speed=job_create.speed,
        use_gpu=job_create.use_gpu
    )

    # Start conversion in background
    asyncio.create_task(job_manager.run_conversion(job.id))

    return job


@router.get("/jobs", response_model=list[Job])
async def list_jobs(user: User = Depends(get_current_user)):
    """Get all jobs for current user."""
    return job_manager.get_user_jobs(user.uid)


@router.get("/jobs/{job_id}", response_model=Job)
async def get_job(job_id: str, user: User = Depends(get_current_user)):
    """Get a specific job (must be owned by user)."""
    job = job_manager.get_job(job_id, user.uid)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    return job


@router.get("/jobs/{job_id}/download")
async def download_job(job_id: str, user: User = Depends(get_current_user)):
    """Download the completed audiobook."""
    job = job_manager.get_job(job_id, user.uid)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")

    if job.status != "completed":
        raise HTTPException(status_code=400, detail="Job not completed")

    if not job.output_file:
        raise HTTPException(status_code=404, detail="Output file not found")

    output_path = job_manager.get_user_outputs_dir(user.uid) / job_id / job.output_file
    if not output_path.exists():
        raise HTTPException(status_code=404, detail="Output file not found")

    return FileResponse(
        output_path,
        media_type="audio/mp4",
        filename=job.output_file
    )


@router.get("/jobs/{job_id}/chapters", response_model=list[ChapterInfo])
async def get_job_chapters(job_id: str, user: User = Depends(get_current_user)):
    """Get chapter metadata for a job's audiobook."""
    job = job_manager.get_job(job_id, user.uid)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")

    if job.status != "completed":
        raise HTTPException(status_code=400, detail="Job not completed")

    return job.chapters


@router.delete("/jobs/{job_id}")
async def delete_job(job_id: str, user: User = Depends(get_current_user)):
    """Delete a job (must be owned by user)."""
    if not job_manager.delete_job(job_id, user.uid):
        raise HTTPException(status_code=404, detail="Job not found")

    return {"status": "deleted"}


# ============================================================================
# Audiobook endpoints (user-scoped)
# ============================================================================

@router.get("/audiobooks")
async def list_audiobooks(user: User = Depends(get_current_user)):
    """List all completed audiobooks for current user."""
    return job_manager.get_user_audiobooks(user.uid)


@router.get("/audiobooks/{audiobook_id}/download")
async def download_audiobook(audiobook_id: str, user: User = Depends(get_current_user)):
    """Download an audiobook by its ID (job folder name)."""
    output_dir = job_manager.get_user_outputs_dir(user.uid) / audiobook_id

    if not output_dir.exists():
        raise HTTPException(status_code=404, detail="Audiobook not found")

    # Find the audio file
    audio_files = list(output_dir.glob("*.m4b")) + list(output_dir.glob("*.mp3"))
    if not audio_files:
        raise HTTPException(status_code=404, detail="Audio file not found")

    audio_file = audio_files[0]
    media_type = "audio/mp4" if audio_file.suffix == ".m4b" else "audio/mpeg"

    return FileResponse(
        audio_file,
        media_type=media_type,
        filename=audio_file.name
    )


@router.delete("/audiobooks/{audiobook_id}")
async def delete_audiobook(audiobook_id: str, user: User = Depends(get_current_user)):
    """Delete an audiobook and its folder."""
    output_dir = job_manager.get_user_outputs_dir(user.uid) / audiobook_id

    if not output_dir.exists():
        raise HTTPException(status_code=404, detail="Audiobook not found")

    # Delete all files in the directory and the directory itself
    for file in output_dir.iterdir():
        file.unlink()
    output_dir.rmdir()

    return {"status": "deleted"}


@router.patch("/audiobooks/{audiobook_id}/rename")
async def rename_audiobook(audiobook_id: str, rename_request: RenameRequest, user: User = Depends(get_current_user)):
    """Rename an audiobook file. Input is sanitized to prevent path traversal and injection."""
    output_dir = job_manager.get_user_outputs_dir(user.uid) / audiobook_id

    if not output_dir.exists():
        raise HTTPException(status_code=404, detail="Audiobook not found")

    # Find the audio file
    audio_files = list(output_dir.glob("*.m4b")) + list(output_dir.glob("*.mp3"))
    if not audio_files:
        raise HTTPException(status_code=404, detail="Audio file not found")

    current_file = audio_files[0]
    current_extension = current_file.suffix  # .m4b or .mp3

    # Sanitize the new name
    try:
        safe_name = sanitize_filename(rename_request.new_name)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    # Ensure the new name has the correct extension
    if not safe_name.lower().endswith(current_extension.lower()):
        safe_name = safe_name + current_extension

    # Create the new path (same directory, new filename)
    new_file = output_dir / safe_name

    # Check if target already exists
    if new_file.exists() and new_file != current_file:
        raise HTTPException(status_code=400, detail="A file with that name already exists")

    # Rename the file using pathlib (no shell commands)
    current_file.rename(new_file)

    return {"status": "renamed", "new_filename": safe_name}
