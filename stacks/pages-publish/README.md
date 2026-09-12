# pages-publish

FastAPI service that lets any devvm user publish markdown to
`pages.viktorbarzin.me` from a locked account. The client sends raw markdown; the
service renders it (via the monorepo's `render.py`) into that user's private
`pages/<user>/` dir (or `pages/shared/`) and commits + pushes to the monorepo.
The learn pod git-syncs and serves the page ~30s later.

## Security model (the load-bearing part)

- The **publishing user is resolved ONLY from the bearer token**, never from the
  request body. `PAGES_API_KEYS` is a JSON `{user: token}` map, inverted to
  `token -> user` (mirrors `claude_memory/api/auth.py`). Unknown/missing token
  → 401. The request model has no `user` field.
- The write path is a **hardcoded `pages/` prefix + a fixed second segment**
  that is either the literal `shared` or the token-resolved user — never request
  input. Users are charset-validated at config load.
- The **slug** (from `filename`) is the only request value that reaches a path:
  strip a trailing `.md`, then require `^[0-9A-Za-z._-]+$` with no `..`. A
  path-bearing name (`../x`, `a/b`, `/etc/passwd`) is **rejected (400)**, not
  basenamed to its leaf. The service is structurally incapable of writing
  outside `pages/<user>/` or `pages/shared/` (asserted with a realpath check).

## How a publish reaches master (no rebase, by design)

`/repo` is a per-pod **emptyDir** clone, and one replica plus an asyncio lock
means publishes are serialized. Each attempt inside `publish()` runs:

1. `sync_to_master` — abandon any interrupted rebase/merge, `fetch origin
   master`, `reset --hard FETCH_HEAD`, `checkout -B master`.
2. `render_page` — regenerate the page **and** that dir's `index.html`.
3. `stage_and_commit` — `git add`/`status` scoped to `pages/<user>/`; an
   unchanged dir returns the URL without committing.
4. `push_to_master` — one attempt. A rejection is a lost race, not an error:
   loop back to step 1, up to `DEFAULT_ATTEMPTS` (5).

Re-rendering is what makes the retry safe — a page is a pure function of its
markdown, so regenerating it on the master that won produces the same bytes with
nothing to merge. Step 2 must stay *after* step 1: the renderer rebuilds
`index.html` from the files on disk, so rendering against a stale checkout would
publish an index missing whatever landed meanwhile.

**Why not `pull --rebase`** (what this replaced, 2026-08-17): every publish
regenerates `pages/<user>/index.html`, so two concurrent publishes conflict
there reliably. A conflicted rebase stops with `.git/rebase-merge` on disk and a
detached HEAD, and every later publish then fails on *"there is already a
rebase-merge directory"* — one lost race returned **HTTP 500 for every user**
until the pod was replaced, with 10 commits stranded in the emptyDir. A stale
rebase found at step 1 is now abandoned, so such a pod heals on the next
request.

**Read the logs, not the response, when a publish 500s.** Traefik's
`error-pages` middleware (500–504, default ingress chain) replaces the FastAPI
`detail` with a generic themed body, so the caller only ever sees *"The server
met an unexpected condition"*. The reason is logged instead:

```bash
homelab logs query '{namespace="pages-publish"} |~ "ERROR|WARNING"' --since 24h
```

## API

- `GET /health` → `200 {"status":"ok"}`, no auth.
- `POST /publish` (Bearer): body `{content, filename, status?, shared?}` →
  `{"url": "...", "path": "pages/<user>/<file>.html"}`. `status` ∈
  {draft,approved,executing,done} (default draft); `shared` default false.
- `POST /preview` (Bearer): same body → `{"filename", "html", "assets"}`.
  Renders one page and hands back the bytes plus the `/assets/*` files that page
  links, keyed by the path it links them at. Nothing is committed or pushed.

### Why /preview exists

A page is not verified by having been rendered, and `pages.viktorbarzin.me` is
owner-gated: it returns 403 to every automated client, in-cluster included. A
user with a monorepo checkout can serve the tree locally and look at the page
before publishing. A user without one had no way to see a page at all, so the
first look happened after it was live, on someone else's screen. That is how a
page with an inline SVG chart shipped on 2026-09-12 with a 555px hole in it.

`/preview` closes that: `homelab pages preview <doc.md>` writes the page and its
assets into a local directory laid out the way the site lays them out, so serving
that directory as the document root reproduces the published page exactly.

Two design notes worth keeping:

- It renders into a throwaway directory, never into `<repo>/pages/<user>/`. An
  untracked page left in the clone is staged by the next publish's
  `git add -- pages/<user>/` and pushed as part of somebody else's page.
- It takes the same lock as `/publish`, because it re-syncs the one shared clone
  and would otherwise reset a publish's working tree mid-flight.
- Only assets the page actually links are read, so a doc with no diagram does not
  carry mermaid.min.js (3.5 MB) through the API.

## Config (env)

| var | default | notes |
|-----|---------|-------|
| `PAGES_API_KEYS` | — | JSON `{user: token}`; keys must equal the Caddyfile per-user dir names (`wizard`, `emo`) |
| `REPO_DIR` | `/repo` | monorepo checkout (cloned on first run if absent) |
| `DEPLOY_KEY_PATH` | `/etc/pages-deploy/id_ed25519` | ssh key, read+write on the monorepo |
| `RENDER_SCRIPT` | `$REPO_DIR/pages/tools/render.py` | set to `.../plans/tools/render.py` pre-migration |
| `RENDER_DIR_FLAG` | `--pages-dir` | set to `--plans-dir` pre-migration |
| `REPO_URL` | `git@github.com:ViktorBarzin/monorepo.git` | |
| `PAGES_BASE_URL` | `https://pages.viktorbarzin.me` | |

## Develop / test

```bash
pip install -r requirements.txt   # + pytest httpx for tests
python3 -m pytest                  # 60 tests; git + render subprocess are stubbed
```

Build: `docker build -t pages-publish .` (context = this dir). Runs uvicorn on
`0.0.0.0:8080` as non-root uid 10001.
