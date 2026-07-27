"""FastAPI surface for pages-publish (port 8080).

- GET  /health  -> 200 {"status":"ok"}, no auth.
- POST /publish -> bearer-authenticated; renders + commits + pushes one page.

Concurrent publishes serialize on an asyncio lock; the blocking render + git
work runs in a worker thread so /health stays responsive.
"""

from __future__ import annotations

import asyncio

from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel

from . import auth, config, publisher


class PublishRequest(BaseModel):
    content: str  # raw markdown
    filename: str  # e.g. "2026-07-27-foo.md" — only the sanitized slug is used
    status: str = "draft"
    shared: bool = False
    # NOTE: there is deliberately NO `user` field. Identity comes from the
    # token; any extra body keys are ignored by pydantic.


def create_app(cfg: config.Config | None = None) -> FastAPI:
    cfg = cfg or config.load_config()
    app = FastAPI(title="pages-publish")
    app.state.cfg = cfg
    lock = asyncio.Lock()

    async def current_user(authorization: str | None = Header(default=None)) -> str:
        return auth.resolve_user(cfg.key_map, authorization)

    @app.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.post("/publish")
    async def publish_endpoint(
        body: PublishRequest, user: str = Depends(current_user)
    ) -> dict[str, str]:
        try:
            async with lock:
                return await asyncio.to_thread(
                    publisher.publish,
                    cfg,
                    user=user,
                    content=body.content,
                    filename=body.filename,
                    status=body.status,
                    shared=body.shared,
                )
        except publisher.PublishError as e:
            raise HTTPException(status_code=400, detail=str(e))
        except publisher.RenderError as e:
            raise HTTPException(status_code=500, detail=str(e))

    return app


app = create_app()
