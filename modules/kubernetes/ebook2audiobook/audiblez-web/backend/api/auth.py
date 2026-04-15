"""
Authentication module for extracting user identity from Authentik headers.

When nginx ingress is protected with Authentik, these headers are forwarded:
- X-Authentik-Username: The user's username
- X-Authentik-Uid: Unique user ID (used for directory separation)
- X-Authentik-Email: User's email
- X-Authentik-Name: User's display name
- X-Authentik-Groups: Comma-separated group list
"""

from dataclasses import dataclass
from fastapi import Request, HTTPException
from typing import Optional
import re


@dataclass
class User:
    """Represents an authenticated user from Authentik."""
    uid: str
    username: str
    email: Optional[str] = None
    name: Optional[str] = None
    groups: list[str] = None

    def __post_init__(self):
        if self.groups is None:
            self.groups = []


def sanitize_user_id(uid: str) -> str:
    """
    Sanitize user ID for use as a directory name.
    Only allows alphanumeric, hyphens, and underscores.
    """
    if not uid:
        raise ValueError("User ID cannot be empty")

    # Only allow safe characters for filesystem
    safe_uid = re.sub(r'[^a-zA-Z0-9\-_]', '', uid)

    if not safe_uid:
        raise ValueError("User ID contains no valid characters")

    # Limit length to prevent path issues
    if len(safe_uid) > 64:
        safe_uid = safe_uid[:64]

    return safe_uid


async def get_current_user(request: Request) -> User:
    """
    Extract user information from Authentik headers.

    This is a FastAPI dependency that should be used on protected endpoints.
    Raises 401 if user headers are not present (not authenticated).
    """
    # Header names are case-insensitive, but commonly forwarded as:
    uid = request.headers.get("X-Authentik-Uid")
    username = request.headers.get("X-Authentik-Username")
    email = request.headers.get("X-Authentik-Email")
    name = request.headers.get("X-Authentik-Name")
    groups_str = request.headers.get("X-Authentik-Groups", "")

    # For development/testing, check for alternative header names
    if not uid:
        uid = request.headers.get("X-Authentik-Userid")
    if not uid:
        uid = request.headers.get("Remote-User")

    if not uid or not username:
        raise HTTPException(
            status_code=401,
            detail="Authentication required. Authentik headers not found."
        )

    try:
        safe_uid = sanitize_user_id(uid)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    # Parse groups (comma-separated)
    groups = [g.strip() for g in groups_str.split(",") if g.strip()]

    return User(
        uid=safe_uid,
        username=username,
        email=email,
        name=name,
        groups=groups
    )


async def get_optional_user(request: Request) -> Optional[User]:
    """
    Extract user information if available, or return None.
    Use this for endpoints that work with or without authentication.
    """
    try:
        return await get_current_user(request)
    except HTTPException:
        return None
