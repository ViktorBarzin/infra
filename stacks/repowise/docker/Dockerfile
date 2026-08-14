# repowise image, built from an upstream source checkout.
#
# WHY OURS AND NOT THEIRS: upstream ships docker/Dockerfile, but at v0.42.0 its
# frontend stage copies only packages/web before `npm install`, so the three
# workspace siblings that packages/web depends on (@repowise-dev/api-client,
# /types, /ui) resolve against the public registry, 404, and the build dies.
# They are local workspace packages and are not published.
#
# The frontend stage below follows upstream's own release workflow
# (.github/workflows/publish.yml, "Build Web UI"), which builds the dashboard
# correctly: install and build through the ROOT workspace so the siblings
# resolve from the root lockfile, then flatten Next.js's nested standalone
# output into a directory where `node server.js` just works.
#
# Two deliberate differences from upstream's Dockerfile, both load-bearing here:
#
#   1. NEXT_PUBLIC_REPOWISE_API_URL is empty. It is baked into the browser
#      bundle at build time; upstream's Dockerfile hardcodes localhost:7337,
#      which no browser outside the container can reach. Empty means the
#      dashboard issues same-origin /api/... requests, which Traefik routes to
#      the API service. (Upstream's release workflow also builds with "" — the
#      localhost value is specific to their docker-compose story.)
#   2. The runtime user has a pinned uid/gid of 10001 instead of whatever
#      `useradd -r` picks, because the Deployment sets fsGroup on the workspace
#      volume and that needs a stable number.
#
# No ENTRYPOINT: every container in the Deployment sets its own command
# (uvicorn / node / repowise mcp / the reconciler), so an entrypoint here would
# only ever be misleading.

# Debian-based Node builder to match the bookworm-based python runtime — an
# Alpine/musl node binary will not execute in the runtime stage.
FROM node:20-bookworm-slim AS frontend-builder

WORKDIR /src

# The whole tree, then install through the root workspace. Copying only some
# packages would break `npm ci`, which validates the root lockfile against
# every declared workspace (types, ui, api-client, web, vscode) — and partial
# copying is exactly what makes upstream's own Dockerfile fail. Build frequency
# is a few times a month, so the lost layer caching costs nothing.
COPY package.json package-lock.json ./
COPY packages/ packages/

RUN npm ci --workspace packages/web

ENV NEXT_TELEMETRY_DISABLED=1
# Empty on purpose — see the header. Same-origin requests from the browser.
ENV NEXT_PUBLIC_REPOWISE_API_URL=""
RUN npm run build --workspace packages/web

# Flatten the standalone bundle, mirroring upstream's release workflow. Next.js
# nests the server under the package path in a monorepo, and the static assets
# have to be copied in by hand.
RUN set -eux; \
    STANDALONE=packages/web/.next/standalone; \
    cp -r packages/web/.next/static "$STANDALONE/packages/web/.next/static"; \
    if [ -d packages/web/public ]; then cp -r packages/web/public "$STANDALONE/packages/web/public"; fi; \
    mkdir -p /out; \
    cp "$STANDALONE/packages/web/server.js" /out/; \
    cp -r "$STANDALONE/packages/web/.next" /out/.next; \
    if [ -d "$STANDALONE/packages/web/public" ]; then cp -r "$STANDALONE/packages/web/public" /out/public; fi; \
    cp -r "$STANDALONE/node_modules" /out/node_modules; \
    if [ -d "$STANDALONE/packages/web/node_modules" ]; then \
      cp -r "$STANDALONE/packages/web/node_modules/." /out/node_modules/; \
    fi; \
    test -f /out/server.js

# ---------------------------------------------------------------------------
# Runtime: Python API + MCP server + the flattened Next.js dashboard
# ---------------------------------------------------------------------------
FROM python:3.12-slim AS runtime

# git is required by gitpython, which is how repowise reads history and how the
# reconciler clones the Corpus.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
    && rm -rf /var/lib/apt/lists/*

# Take node from the official image rather than piping curl into a shell.
COPY --from=frontend-builder /usr/local/bin/node /usr/local/bin/node
COPY --from=frontend-builder /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm

WORKDIR /app

COPY pyproject.toml README.md LICENSE MANIFEST.in ./
COPY packages/core/ packages/core/
COPY packages/cli/ packages/cli/
COPY packages/server/ packages/server/
# graph-extra, not "all". repowise declares exactly three extras — postgres,
# graph-extra, dev — so upstream's Dockerfile line `pip install ".[all]"`
# matches nothing and silently installs no extras at all. The visible symptom
# is that graspologic is absent, community detection cannot run, and every
# repo reports zero communities, which leaves the dashboard's Architecture
# module map blank. postgres is deliberately not installed: workspace mode
# hard-codes per-repo SQLite, so it would never be used.
RUN pip install --no-cache-dir ".[graph-extra]" \
    && python3 -c "import graspologic"

COPY --from=frontend-builder /out /app/web

# The primary DB path. In workspace mode this holds only a registry — the real
# per-repo indexes live inside each clone — but the Deployment still mounts it
# from the volume so a restart does not discard it.
RUN mkdir -p /data
ENV REPOWISE_DB_URL=sqlite+aiosqlite:////data/wiki.db
ENV REPOWISE_EMBEDDER=mock
ENV PORT_BACKEND=7337
ENV PORT_FRONTEND=3000

EXPOSE 7337 3000 7338

# Pinned uid/gid: the Deployment's fsGroup on the workspace volume needs a
# stable number, which `useradd -r` cannot promise.
RUN groupadd -g 10001 repowise \
    && useradd -u 10001 -g 10001 -d /app -s /sbin/nologin repowise \
    && chown -R 10001:10001 /app /data
USER 10001:10001
