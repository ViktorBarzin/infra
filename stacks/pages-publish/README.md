# pages-publish

FastAPI service that lets any devvm user publish to `pages.viktorbarzin.me` from
a locked account: a markdown doc (rendered by the repo's `tools/render.py`, with
decks and chart blocks), one HTML file, or a directory of files (a **Bundle**:
3D viewers, HTML decks, images, short clips), plus public links. It writes into
that user's private `<user>/` dir (or `shared/`) and commits + pushes to the
private Forgejo repo `viktor/pages`, whose root is the site. The learn pod
git-syncs that repo and serves the page ~30s later.

Since 2026-11-12 every page is served in a sandboxed frame (ADR-0042, design
`docs/plans/2026-11-12-pages-rich-content-design.md`). What that means for
authors is in "What a page can do" below.

Until 2026-11-03 the same tree was the `pages/` subdir of the GitHub monorepo
(`ViktorBarzin/monorepo`), which was dissolved that day. `viktor/pages` carries
its history, including the `plans/` era, and is Forgejo-only with no GitHub
push-mirror, by Viktor's decision.

## Security model (the load-bearing part)

- The **publishing user is resolved ONLY from the bearer token**, never from the
  request body. `PAGES_API_KEYS` is a JSON `{user: token}` map, inverted to
  `token -> user` (mirrors `claude_memory/api/auth.py`). Unknown/missing token
  → 401. The request model has no `user` field.
- The write path is **one fixed top-level segment** that is either the literal
  `shared` or the token-resolved user — never request input. Users are
  charset-validated at config load. Because the user dirs sit at the repo root
  beside `.git`, `assets/` and `tools/`, a user (or bundle slug) starting with
  `.`, or a user named `shared`, `assets` or `tools`, is refused at load and
  again at write time.
- The **slug** (from `filename`) is the only request value that reaches a path:
  strip a trailing `.md`, then require `^[0-9A-Za-z._-]+$` with no `..`. A
  path-bearing name (`../x`, `a/b`, `/etc/passwd`) is **rejected (400)**, not
  basenamed to its leaf. The service is structurally incapable of writing
  outside `<user>/` or `shared/` (asserted with a realpath check: the resolved
  target must equal `<realpath(repo)>/<segment>`, so a committed symlink is
  refused).

## How a publish reaches master (no rebase, by design)

`/repo` is a per-pod **emptyDir** clone, and one replica plus an asyncio lock
means publishes are serialized. Each attempt inside `publish()` runs:

1. `sync_to_master` — abandon any interrupted rebase/merge, `fetch origin
   master`, `reset --hard FETCH_HEAD`, `clean -ffd` (a failed request's
   untracked files would otherwise ride along with the next commit),
   `checkout -B master`. The pod clones at startup (`PAGES_PRECLONE=0` turns
   that off) so the first publish after a restart does not wait for it.
2. `render_page` — regenerate the page **and** that dir's `index.html`.
3. `stage_and_commit` — `git add`/`status` scoped to `<user>/`; an
   unchanged dir returns the URL without committing.
4. `push_to_master` — one attempt. A rejection is a lost race, not an error:
   loop back to step 1, up to `DEFAULT_ATTEMPTS` (5).

Re-rendering is what makes the retry safe — a page is a pure function of its
markdown, so regenerating it on the master that won produces the same bytes with
nothing to merge. Step 2 must stay *after* step 1: the renderer rebuilds
`index.html` from the files on disk, so rendering against a stale checkout would
publish an index missing whatever landed meanwhile.

**Why not `pull --rebase`** (what this replaced, 2026-08-17): every publish
regenerates `<user>/index.html`, so two concurrent publishes conflict
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
- `POST /publish` (Bearer): body `{content, filename, status?, shared?, public?}` →
  `{"url": "...", "path": "<user>/<file>.html"}`, plus `public_url` when
  `public` is true. `status` ∈ {draft,approved,executing,done} (default draft);
  `shared` default false. The filename is the page's identity: the same name
  from the same user updates the same page on any later day (the renderer gets
  `--source-name`; until 2026-11-12 each day's publish made a new page because
  the markdown sat in a fresh temp dir).
- `POST /preview` (Bearer): same body → `{"filename", "html", "assets"}`.
  Renders one page and hands back the bytes plus the `/assets/*` files that page
  links, keyed by the path it links them at. Nothing is committed or pushed.
- Both take one page of at most 8 MiB of markdown (`MAX_PAGE_BYTES`, UTF-8
  bytes). A bigger page gets a `413` whose `detail` names the limit and the
  size sent: a middleware refuses a `Content-Length` over 16 MiB before the body
  is read, and the route checks the parsed `content` exactly. On 2026-11-05 a
  ~4.5 MB page OOM-killed the pod for everyone (viktor/infra#165).
- `POST /publish-bundle` (Bearer, a user's API token): body
  `{name, files: [{path, content, encoding?}], status?, shared?, public?}`.
  `name` is the file or directory name published from and is the identity.
  A file name (`viewer.html`) with one file → a page
  `<user>/<date>-<slug>.html` with `plan-*` meta added for the index. A
  directory name (`demo`) → a Bundle `<user>/<date>-<slug>/`, whose entry is
  `index.html`, or `index.md` rendered into one. Returns
  `{url, path, kind, public_url?}`. See "Bundles for every user".
- `POST /publish-bundle` (Bearer, a legacy bundle token): body
  `{"files": [{"path", "content", "encoding"?}]}` →
  `{"url": "<base>/<slug>/", "path": "<user>/<slug>", "committed", "files"}`.
  See "Publishing a multi-file bundle".
- `POST /share` (Bearer): `{page, shared?}` → `{url, page}`. `page` is a page
  URL, its served name, `shared/<name>`, or its source name; only the caller's
  Space and `shared/` are searched (404 otherwise). Idempotent: an existing
  link is returned.
- `POST /unshare` (Bearer): same body, or a `/p/<token>/` URL for one link →
  `{removed, page}`.
- `POST /unpublish` (Bearer): `{page, shared?}` → `{removed, links}`. Deletes a
  page or Bundle from the caller's Space or `shared/`, with its public links
  and Bundle URL. git history keeps a copy.
- Every publish and share takes `expires`: `<N>d` (up to 9999) or `never`, and
  answers with the `expires` date (or null). `/publish` also returns
  `warnings`: render.py's notes, such as a plan over its 600-word prose budget.

## Expiry (since 2026-11-12)

Viktor's rule: pages, Bundles and public links published or shared from
2026-11-12 on expire after 90 days unless `expires` says otherwise; anything
from before has no expiry and keeps none on republish. A republish or re-share
keeps the item's own lifetime and restarts the clock. Pages carry
`plan-ttl`/`plan-expires` meta (render.py `--ttl`/`--default-ttl`), Bundles
`ttl`/`expires` in their marker, links an entry in `p/.links.json`. Every
`PAGES_EXPIRY_INTERVAL` seconds (default 21600; 0 turns it off) the service
deletes what is past its date and commits `pages: expire N page(s) and M
public link(s)` as `pages-publish`. Restore one with `git revert` or by
republishing it.

## What a page can do (the sandbox)

Pages load in a frame with `Content-Security-Policy: sandbox allow-scripts
allow-forms allow-modals allow-popups allow-popups-to-escape-sandbox
allow-downloads allow-pointer-lock allow-top-navigation-by-user-activation`,
never `allow-same-origin`. So a page's scripts:

- run, and may load CDNs and the vendored libraries in `/assets/`
  (`assets/VERSIONS.md` in viktor/pages: three.js, reveal.js, Chart.js);
- cannot use `localStorage`, `sessionStorage`, `IndexedDB`, cookies or a
  service worker (they throw `SecurityError`);
- make every request without the sign-in cookie, so they cannot read another
  Space, and a single page cannot load relative files: anything beyond the
  page itself belongs in a Bundle;
- need the import map in `assets/VERSIONS.md` for three.js modules.

`?raw` (and reveal's `?print-pdf`) serves the page outside the frame, which is
how to print it.

## Bundles for every user

- Limits (`app/bundles.py`): 10 MiB per file, 25 MiB per publish, 200 files,
  3 path levels, no segment starting with `.`. Allowed types: web files
  (`html css js mjs json csv txt md svg wasm ...`), images, 3D models
  (`glb gltf bin stl obj ...`), fonts and short clips (`mp4 webm mp3 ogg ...`).
  `/publish-bundle` refuses a `Content-Length` over 40 MiB before reading it,
  a body with no `Content-Length` (411), and a second body over 1 MiB while
  one is in flight (429, `Retry-After: 30`): requests queue on the publish
  lock only after FastAPI has parsed the whole body, at ~4x its size.
- A page or Bundle from another source never takes a name: foo.md and
  foo.html both map to `<date>-foo`, so the second gets `<date>-foo-2`.
- Published HTML pages get `plan-*` meta and a small click handler
  (`#pages-top-links`) that opens links to other pages outside the frame,
  because a navigation the sandboxed frame starts itself carries no sign-in
  cookie.
- Each publish writes `<bundle>/.pages-bundle.json` (`cap`, `source`, `title`,
  `status`, `date`) and the symlink `c/<cap> → ../<space>/<bundle>`, with a new
  128-bit cap each time, removing the old link. The site's shell reads the
  marker and frames `/c/<cap>/`, because inside the sandbox the Bundle's own
  files load without the sign-in cookie. The cap is never returned by the API.
- A public link is `p/<token>` (a Bundle: symlink to `../<space>/<bundle>`) or
  `p/<token>/index.html` (a page: symlink to `../../<space>/<file>`). It
  survives republishes because the page keeps its name.
- Each attempt syncs to master and rewrites everything, then commits with
  `git add -A` scoped to the Space, `c/` and `p/`, so a lost push race retries
  like `/publish` does.

### Why /preview exists

A page is not verified by having been rendered, and `pages.viktorbarzin.me` is
owner-gated: it returns 403 to every automated client, in-cluster included. A
user with a `viktor/pages` checkout can serve the tree locally and look at the page
before publishing. A user without one had no way to see a page at all, so the
first look happened after it was live, on someone else's screen. That is how a
page with an inline SVG chart shipped on 2026-09-12 with a 555px hole in it.

`/preview` closes that: `homelab pages preview <doc.md>` writes the page and its
assets into a local directory laid out the way the site lays them out, so serving
that directory as the document root reproduces the published page exactly. The
default output dir is per user (`~/.cache/homelab/pages-preview/<slug>`); the
devvm is shared, and a single path under `/tmp` is one every user after the
first gets EACCES from.

Two design notes worth keeping:

- It renders into a throwaway directory, never into `<repo>/<user>/`. An
  untracked page left in the clone is staged by the next publish's
  `git add -- <user>/` and pushed as part of somebody else's page.
- It takes the same lock as `/publish`, because it re-syncs the one shared clone
  and would otherwise reset a publish's working tree mid-flight.
- Only assets the page actually links are read, so a doc with no diagram does not
  carry mermaid.min.js (3.5 MB) through the API.

## Publishing a multi-file bundle

This is the older, token-per-directory form of `/publish-bundle`, kept for a
static site that CI generates as a set of files, such as the homelab showcase page (`showcase/homelab/`, see
`docs/plans/2026-10-20-homelab-showcase-design.md`). `/publish` renders one
markdown doc, so it does not cover this case.

- Tokens come from `PAGES_BUNDLE_KEYS`, a JSON `{token: {"user", "slug"}}` map.
  Each token is bound to one directory, `<user>/<slug>/`, and the request
  body has no way to name another. Bundle tokens and `PAGES_API_KEYS` tokens are
  separate: each one is accepted only by its own endpoints, and a token listed in
  both maps stops the service at startup.
- Each file has a relative `path` and `content`, with `encoding` either `utf-8`
  (the default) or `base64` for binary files such as the OpenGraph PNG.
- Paths are up to 3 `/`-separated segments of `[0-9A-Za-z._-]`, with no `..`
  and no segment starting with `.`. A bundle holds 1 to 200 files and at most
  25 MiB decoded. Anything else is a 400, returned before the clone is touched.
- Each attempt of the publish loop syncs to master, deletes
  `<user>/<slug>/`, writes the files, and runs `git add -A` scoped to
  that directory, so files the new bundle no longer contains are removed in the
  same commit. The commit is authored by `<user>` with the message
  `pages: publish bundle <user>/<slug>`. Identical content returns
  `"committed": false` without a commit. A lost push race retries the same way
  `/publish` does.
- Nothing is rendered. The files are committed as sent, and `render.py` skips
  subdirectories when it rebuilds `<user>/index.html`.

## Config (env)

| var | default | notes |
|-----|---------|-------|
| `PAGES_API_KEYS` | — | JSON `{user: token}`; keys must equal the Caddyfile per-user dir names (`wizard`, `emo`) |
| `PAGES_BUNDLE_KEYS` | empty | JSON `{token: {"user": ..., "slug": ...}}`; tokens for `/publish-bundle` only |
| `REPO_DIR` | `/repo` | `viktor/pages` checkout (cloned on first run if absent) |
| `DEPLOY_KEY_PATH` | `/etc/pages-deploy/id_ed25519` | ssh key, read+write deploy key on `viktor/pages` (Vault `secret/pages-publish` `forgejo_deploy_key`) |
| `RENDER_SCRIPT` | `$REPO_DIR/tools/render.py` | |
| `RENDER_DIR_FLAG` | `--pages-dir` | |
| `REPO_URL` | `git@forgejo-ssh.forgejo.svc.cluster.local:viktor/pages.git` | in-cluster Service name, so a publish does not depend on the `git.viktorbarzin.me` record |
| `PAGES_BASE_URL` | `https://pages.viktorbarzin.me` | |

## Develop / test

```bash
pip install -r requirements.txt   # + pytest httpx for tests
python3 -m pytest                  # 232 tests; most stub git + render, tests/test_rich.py runs real git against a local bare repo
# on the devvm, without a venv:
uv run --quiet --no-project --with fastapi --with httpx --with pytest --with markdown python -m pytest -q
```

Build: `docker build -t pages-publish .` (context = this dir). Runs uvicorn on
`0.0.0.0:8080` as non-root uid 10001.
