"""Bearer-token -> user resolution.

Mirrors ``claude_memory/api/auth.py``: the identity is derived solely from the
``Authorization: Bearer <token>`` header against the ``{token: user}`` map. An
unknown or missing token is a 401. Nothing about the request body influences
who the caller is.
"""

from __future__ import annotations

from fastapi import HTTPException


def resolve_user(key_map: dict[str, str], authorization: str | None) -> str:
    if not authorization:
        raise HTTPException(status_code=401, detail="Missing bearer token")
    token = authorization.removeprefix("Bearer ").strip()
    user = key_map.get(token)
    if user is None:
        raise HTTPException(status_code=401, detail="Invalid API key")
    return user
