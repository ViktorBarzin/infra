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

## API

- `GET /health` → `200 {"status":"ok"}`, no auth.
- `POST /publish` (Bearer): body `{content, filename, status?, shared?}` →
  `{"url": "...", "path": "pages/<user>/<file>.html"}`. `status` ∈
  {draft,approved,executing,done} (default draft); `shared` default false.

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
python3 -m pytest                  # 47 tests; git + render subprocess are stubbed
```

Build: `docker build -t pages-publish .` (context = this dir). Runs uvicorn on
`0.0.0.0:8080` as non-root uid 10001.
