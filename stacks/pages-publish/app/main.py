"""FastAPI surface for pages-publish (port 8080).

- GET  /health  -> 200 {"status":"ok"}, no auth.
- POST /publish -> bearer-authenticated; renders + commits + pushes one page.
- POST /preview -> bearer-authenticated; renders one page and returns the bytes
  plus the assets it links. Nothing is committed or pushed. It exists so a
  caller with no pages checkout can look at a page before publishing it;
  the site itself is owner-gated and 403s every automated client.
- /publish and /preview answer 413 for a page over publisher.MAX_PAGE_BYTES.
- POST /publish-bundle -> bearer-authenticated with a BUNDLE token (a separate
  map from /publish's); replaces <user>/<slug>/ with the files sent and
  commits + pushes. No rendering.

Concurrent publishes serialize on an asyncio lock; the blocking render + git
work runs in a worker thread so /health stays responsive.
"""

from __future__ import annotations

import asyncio
import logging
import os

from collections.abc import Awaitable, Callable
from typing import Literal

from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response
from fastapi.responses import JSONResponse

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


class PreviewRequest(BaseModel):
    content: str  # raw markdown
    filename: str  # e.g. "2026-07-27-foo.md" — only the sanitized slug is used
    status: str = "draft"
    shared: bool = False  # validated, then unused: it moves a page, not its look


class PublishRequest(BaseModel):
    content: str  # raw markdown
    filename: str  # e.g. "2026-07-27-foo.md" — only the sanitized slug is used
    status: str = "draft"
    shared: bool = False
    # NOTE: there is deliberately NO `user` field. Identity comes from the
    # token; any extra body keys are ignored by pydantic.


class BundleFile(BaseModel):
    path: str  # relative, e.g. "assets/app.js"; validated in the publisher
    content: str
    encoding: Literal["utf-8", "base64"] = "utf-8"


class BundleRequest(BaseModel):
    files: list[BundleFile]
    # NOTE: no user or slug field. Both come from the bundle token.


# Endpoints that take one page of markdown; /publish-bundle has its own limits.
_PAGE_PATHS = ("/publish", "/preview")


def _too_large(what: str, size: int) -> str:
    return (
        f"{what} is {size} bytes; one page may be at most "
        f"{publisher.MAX_PAGE_BYTES} bytes ({publisher.MAX_PAGE_BYTES // (1024 * 1024)} MiB) "
        "of markdown. Split the page or move large embedded data out of it."
    )


def _require_page_size(content: str) -> None:
    size = len(content.encode("utf-8"))
    if size > publisher.MAX_PAGE_BYTES:
        raise HTTPException(status_code=413, detail=_too_large("the markdown", size))


def create_app(cfg: config.Config | None = None) -> FastAPI:
    cfg = cfg or config.load_config()
    app = FastAPI(title="pages-publish")
    app.state.cfg = cfg
    lock = asyncio.Lock()

    async def current_user(authorization: str | None = Header(default=None)) -> str:
        return auth.resolve_user(cfg.key_map, authorization)

    async def current_bundle(
        authorization: str | None = Header(default=None),
    ) -> tuple[str, str]:
        return auth.resolve_bundle(cfg.bundle_map, authorization)

    @app.middleware("http")
    async def cap_page_body(
        request: Request, call_next: Callable[[Request], Awaitable[Response]]
    ) -> Response:
        # Runs before the route reads the body, so an oversized page is refused
        # without ever being held in memory.
        if request.method == "POST" and request.url.path in _PAGE_PATHS:
            length = request.headers.get("content-length", "")
            if length.isdigit() and int(length) > publisher.MAX_PAGE_REQUEST_BYTES:
                return JSONResponse(
                    status_code=413,
                    content={"detail": _too_large("the request body", int(length))},
                )
        return await call_next(request)

    @app.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.post("/preview")
    async def preview_endpoint(
        body: PreviewRequest, user: str = Depends(current_user)
    ) -> dict:
        _require_page_size(body.content)
        # Shares /publish's lock: a preview re-syncs the one clone, so running
        # it alongside a publish would reset that publish's working tree
        # mid-flight.
        try:
            async with lock:
                return await asyncio.to_thread(
                    publisher.render_preview,
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
            log.error("preview failed for %s (%s): %s", user, body.filename, e)
            raise HTTPException(status_code=500, detail=str(e))
        except Exception:
            log.exception("unhandled error previewing %s for %s", body.filename, user)
            raise

    @app.post("/publish")
    async def publish_endpoint(
        body: PublishRequest, user: str = Depends(current_user)
    ) -> dict[str, str]:
        _require_page_size(body.content)
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

    @app.post("/publish-bundle")
    async def publish_bundle_endpoint(
        body: BundleRequest, target: tuple[str, str] = Depends(current_bundle)
    ) -> dict:
        user, slug = target
        try:
            async with lock:
                return await asyncio.to_thread(
                    publisher.publish_bundle,
                    cfg,
                    user=user,
                    slug=slug,
                    files=[f.model_dump() for f in body.files],
                )
        except publisher.PublishError as e:
            raise HTTPException(status_code=400, detail=str(e))
        except publisher.RenderError as e:
            log.error("bundle publish failed for %s/%s: %s", user, slug, e)
            raise HTTPException(status_code=500, detail=str(e))
        except Exception:
            log.exception("unhandled error publishing bundle %s/%s", user, slug)
            raise

    return app


app = create_app()
