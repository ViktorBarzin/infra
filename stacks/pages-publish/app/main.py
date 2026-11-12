"""FastAPI surface for pages-publish (port 8080).

- GET  /health  -> 200 {"status":"ok"}, no auth.
- POST /publish -> bearer-authenticated; renders + commits + pushes one page.
- POST /preview -> bearer-authenticated; renders one page and returns the bytes
  plus the assets it links. Nothing is committed or pushed. It exists so a
  caller with no pages checkout can look at a page before publishing it;
  the site itself is owner-gated and 403s every automated client.
- /publish and /preview answer 413 for a page over publisher.MAX_PAGE_BYTES.
- POST /publish-bundle -> with a user's API token (2026-11-12): publishes one
  HTML file as a page or several files as a Bundle in that user's Space, with
  its Bundle URL (app/bundles.py). With a legacy BUNDLE token (a separate map,
  the Showcase CI): replaces <user>/<slug>/ with the files sent. No rendering.
- POST /share, /unshare -> API token; create or remove a public link
  /p/<token>/ to a page in the caller's Space or shared/.
- POST /unpublish -> API token; delete a page or Bundle with its links.
- Pages and links published from 2026-11-12 expire after 90 days unless
  `expires` says otherwise; a background sweep deletes them (app/bundles.py).

Concurrent publishes serialize on an asyncio lock; the blocking render + git
work runs in a worker thread so /health stays responsive.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import os
import threading

from collections.abc import AsyncIterator, Awaitable, Callable
from typing import Literal

from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response
from fastapi.responses import JSONResponse

from pydantic import BaseModel

from . import auth, bundles, config, publisher

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
    public: bool = False  # also create (or keep) a public link; see /share
    expires: str | None = None  # "<N>d" or "never"; new pages default to 90d
    # NOTE: there is deliberately NO `user` field. Identity comes from the
    # token; any extra body keys are ignored by pydantic.


class BundleFile(BaseModel):
    path: str  # relative, e.g. "assets/app.js"; validated in the publisher
    content: str
    encoding: Literal["utf-8", "base64"] = "utf-8"


class BundleRequest(BaseModel):
    files: list[BundleFile]
    # With a user token: the file or directory name published from, which is
    # the page's identity. Ignored with a bundle token, whose slug is fixed.
    name: str | None = None
    status: str = "draft"
    shared: bool = False
    public: bool = False
    expires: str | None = None  # "<N>d" or "never"; new items default to 90d
    # NOTE: no user field. It comes from the token, as does a bundle slug.


class ShareRequest(BaseModel):
    page: str  # a page URL, its served name, shared/<name>, or its source name
    shared: bool = False
    expires: str | None = None  # /share only: the link's lifetime


# A /publish-bundle body over this waits for no one: see large_in_flight.
LARGE_BODY_BYTES = 1024 * 1024

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
    lock = asyncio.Lock()

    @contextlib.asynccontextmanager
    async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
        # Clone viktor/pages now rather than inside the first publish, which
        # otherwise outlived the CLI's timeout after every pod restart.
        task = None
        if os.environ.get("PAGES_PRECLONE", "1") != "0" and cfg.key_map:

            async def run() -> None:
                async with lock:
                    try:
                        await asyncio.to_thread(publisher.ensure_repo, cfg)
                    except Exception:
                        log.exception("startup clone failed; the first publish will retry")

            task = asyncio.create_task(run())
        # Expiry sweep (2026-11-12): pages and public links past their date
        # are deleted, a few times a day, under the publish lock.
        sweeper = None
        interval = int(os.environ.get("PAGES_EXPIRY_INTERVAL", "21600"))
        if interval > 0 and cfg.key_map:

            async def sweep() -> None:
                while True:
                    await asyncio.sleep(interval)
                    async with lock:
                        try:
                            result = await asyncio.to_thread(bundles.expire, cfg)
                            log.info("expiry sweep: %s", result)
                        except Exception:
                            log.exception("expiry sweep failed")

            sweeper = asyncio.create_task(sweep())
        yield
        for t in (task, sweeper):
            if t is not None and not t.done():
                t.cancel()

    app = FastAPI(title="pages-publish", lifespan=lifespan)
    app.state.cfg = cfg
    # One large publish at a time, refused BEFORE its body is read. Requests
    # queue on `lock` only after FastAPI has parsed the whole body, so five
    # queued 25 MiB publishes held ~700 MB between them (measured by the
    # 2026-11-12 challenger at ~140 MB per 35 MB body).
    app.state.large_in_flight = threading.BoundedSemaphore(1)

    async def current_user(authorization: str | None = Header(default=None)) -> str:
        return auth.resolve_user(cfg.key_map, authorization)

    async def current_bundle(
        authorization: str | None = Header(default=None),
    ) -> tuple[str, str | None]:
        """(user, slug) for a bundle token, (user, None) for an API token."""
        token = (authorization or "").removeprefix("Bearer ").strip()
        if token in cfg.bundle_map:
            return cfg.bundle_map[token]
        return auth.resolve_user(cfg.key_map, authorization), None

    @app.middleware("http")
    async def cap_page_body(
        request: Request, call_next: Callable[[Request], Awaitable[Response]]
    ) -> Response:
        # Runs before the route reads the body, so an oversized page is refused
        # without ever being held in memory.
        length = request.headers.get("content-length", "")
        if request.method == "POST" and request.url.path in _PAGE_PATHS:
            if length.isdigit() and int(length) > publisher.MAX_PAGE_REQUEST_BYTES:
                return JSONResponse(
                    status_code=413,
                    content={"detail": _too_large("the request body", int(length))},
                )
        if request.method == "POST" and request.url.path == "/publish-bundle":
            if not length.isdigit():
                return JSONResponse(
                    status_code=411,
                    content={"detail": "send Content-Length: a chunked body has no size to check"},
                )
            if int(length) > bundles.MAX_REQUEST_BYTES:
                return JSONResponse(
                    status_code=413,
                    content={"detail": (
                        f"the request body is {length} bytes; a publish may carry at most "
                        f"{bundles.MAX_PUBLISH_BYTES // (1024 * 1024)} MiB of files "
                        f"({bundles.MAX_REQUEST_BYTES // (1024 * 1024)} MiB of request)"
                    )},
                )
            if int(length) > LARGE_BODY_BYTES:
                if not app.state.large_in_flight.acquire(blocking=False):
                    return JSONResponse(
                        status_code=429,
                        headers={"Retry-After": "30"},
                        content={"detail": "another large publish is running; retry in a minute"},
                    )
                try:
                    return await call_next(request)
                finally:
                    app.state.large_in_flight.release()
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

    def publish_and_maybe_share(body: PublishRequest, user: str) -> dict:
        result = publisher.publish(
            cfg,
            user=user,
            content=body.content,
            filename=body.filename,
            status=body.status,
            shared=body.shared,
            ttl=body.expires,
        )
        if body.public:
            link = bundles.share(
                cfg, user=user, page=os.path.basename(result["path"]), shared=body.shared
            )
            result["public_url"] = link["url"]
        return result

    @app.post("/publish")
    async def publish_endpoint(
        body: PublishRequest, user: str = Depends(current_user)
    ) -> dict:
        _require_page_size(body.content)
        try:
            async with lock:
                return await asyncio.to_thread(publish_and_maybe_share, body, user)
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
        body: BundleRequest, target: tuple[str, str | None] = Depends(current_bundle)
    ) -> dict:
        user, slug = target
        files = [f.model_dump() for f in body.files]
        try:
            async with lock:
                if slug is None:
                    return await asyncio.to_thread(
                        bundles.publish,
                        cfg,
                        user=user,
                        name=body.name,
                        files=files,
                        status=body.status,
                        shared=body.shared,
                        public=body.public,
                        ttl=body.expires,
                    )
                return await asyncio.to_thread(
                    publisher.publish_bundle,
                    cfg,
                    user=user,
                    slug=slug,
                    files=files,
                )
        except publisher.PublishError as e:
            raise HTTPException(status_code=400, detail=str(e))
        except publisher.RenderError as e:
            log.error("bundle publish failed for %s/%s: %s", user, slug, e)
            raise HTTPException(status_code=500, detail=str(e))
        except Exception:
            log.exception("unhandled error publishing bundle %s/%s", user, slug)
            raise

    async def link_call(fn, body: ShareRequest, user: str, **extra) -> dict:
        try:
            async with lock:
                return await asyncio.to_thread(
                    fn, cfg, user=user, page=body.page, shared=body.shared, **extra
                )
        except LookupError:
            raise HTTPException(
                status_code=404,
                detail=f"no page {body.page!r} in your Space or shared/",
            )
        except publisher.PublishError as e:
            raise HTTPException(status_code=400, detail=str(e))
        except publisher.RenderError as e:
            log.error("%s failed for %s (%s): %s", fn.__name__, user, body.page, e)
            raise HTTPException(status_code=500, detail=str(e))

    @app.post("/share")
    async def share_endpoint(body: ShareRequest, user: str = Depends(current_user)) -> dict:
        return await link_call(bundles.share, body, user, ttl=body.expires)

    @app.post("/unshare")
    async def unshare_endpoint(body: ShareRequest, user: str = Depends(current_user)) -> dict:
        return await link_call(bundles.unshare, body, user)

    @app.post("/unpublish")
    async def unpublish_endpoint(body: ShareRequest, user: str = Depends(current_user)) -> dict:
        return await link_call(bundles.unpublish, body, user)

    return app


app = create_app()
