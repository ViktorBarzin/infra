"""FastAPI surface for pages-publish (port 8080).

- GET  /health  -> 200 {"status":"ok"}, no auth.
- POST /publish -> bearer-authenticated; renders + commits + pushes one page.

Concurrent publishes serialize on an asyncio lock; the blocking render + git
work runs in a worker thread so /health stays responsive.
"""

from __future__ import annotations

import asyncio
import logging
import os

from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel

from . import auth, config, publisher

# Without a root handler, module loggers fall back to stderr at WARNING+ only,
# so the successful-publish audit line would never reach Loki. uvicorn keeps its
# own loggers non-propagating, so this does not duplicate access logs.
logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)

log = logging.getLogger(__name__)


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
            # Log before raising: Traefik's error-pages middleware replaces a
            # 500 body with a generic themed page, so this `detail` never
            # reaches the caller. The log line is the only record of WHY a
            # publish failed — a 500 with no log cost hours of digging once.
            log.error("publish failed for %s (%s): %s", user, body.filename, e)
            raise HTTPException(status_code=500, detail=str(e))
        except Exception:
            log.exception("unhandled error publishing %s for %s", body.filename, user)
            raise

    return app


app = create_app()
