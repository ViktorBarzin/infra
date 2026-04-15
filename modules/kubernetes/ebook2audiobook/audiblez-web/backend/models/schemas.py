from pydantic import BaseModel, Field
from typing import Optional, Literal
from datetime import datetime
from enum import Enum


class JobStatus(str, Enum):
    PENDING = "pending"
    PROCESSING = "processing"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"


class Voice(BaseModel):
    id: str
    name: str
    language: str
    gender: Literal["M", "F"]
    quality: str = "medium"


class JobCreate(BaseModel):
    filename: str
    voice: str
    speed: float = Field(default=1.0, ge=0.5, le=2.0)
    use_gpu: bool = True


class ChapterInfo(BaseModel):
    """Chapter metadata extracted from EPUB and embedded in M4B."""
    title: str
    start_ms: int
    end_ms: int


class JobProgress(BaseModel):
    progress: float = Field(ge=0, le=100)
    eta: Optional[str] = None
    current_chapter: Optional[str] = None
    total_chapters: Optional[int] = None
    status: JobStatus


class Job(BaseModel):
    id: str
    user_id: str  # User who owns this job
    filename: str
    voice: str
    speed: float
    use_gpu: bool
    status: JobStatus
    progress: float = 0
    created_at: datetime
    updated_at: datetime
    error: Optional[str] = None
    output_file: Optional[str] = None
    total_chapters: int = 0
    chapters: list[ChapterInfo] = []
