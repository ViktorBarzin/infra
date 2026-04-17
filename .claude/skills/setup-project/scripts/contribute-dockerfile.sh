#!/usr/bin/env bash
# Contribute a working Dockerfile back to an upstream GitHub repo.
#
# Reads state from <service-module-dir>/.contribution-state.json and:
#   1. Validates triggers (dockerfile_state ∈ {written-from-scratch, fixed-broken-upstream})
#   2. Confirms upstream is public, not archived, no concurrent Dockerfile landed
#   3. Forks upstream to ViktorBarzin (idempotent)
#   4. Syncs fork with upstream default branch
#   5. Creates branch (add-dockerfile or fix-dockerfile), appends -<ts> on collision
#   6. Commits Dockerfile + .dockerignore + BUILD.md via Contents API
#   7. Opens PR against upstream with body rendered from PR_BODY.md
#   8. Writes contribution_pr_url back into state file
#
# Usage:
#   contribute-dockerfile.sh <service-module-dir>
#
# Example:
#   contribute-dockerfile.sh /home/wizard/code/infra/modules/kubernetes/myapp
#
# Requires: jq, curl, vault CLI (logged in).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../templates" && pwd)"

FORK_OWNER="ViktorBarzin"

log()  { echo "contribute-dockerfile: $*"; }
die()  { echo "contribute-dockerfile: ERROR: $*" >&2; exit 1; }
skip() { echo "contribute-dockerfile: SKIP: $*"; exit 0; }

if [ "$#" -ne 1 ]; then
  die "usage: $0 <service-module-dir>"
fi

MODULE_DIR="$1"
STATE_FILE="$MODULE_DIR/.contribution-state.json"

[ -f "$STATE_FILE" ] || die "state file not found: $STATE_FILE"

# --- Read + validate state ---
dockerfile_state=$(jq -r '.dockerfile_state // ""'        "$STATE_FILE")
upstream_repo=$(jq -r '.upstream_repo // ""'              "$STATE_FILE")
dockerfile_path=$(jq -r '.dockerfile_path_in_infra // ""' "$STATE_FILE")
deploy_verified_at=$(jq -r '.deploy_verified_at // ""'    "$STATE_FILE")
existing_pr_url=$(jq -r '.contribution_pr_url // ""'      "$STATE_FILE")

if [ -n "$existing_pr_url" ] && [ "$existing_pr_url" != "null" ]; then
  skip "PR already exists: $existing_pr_url"
fi

case "$dockerfile_state" in
  written-from-scratch)  BRANCH_NAME="add-dockerfile"; reason_type="none" ;;
  fixed-broken-upstream) BRANCH_NAME="fix-dockerfile"; reason_type="broken" ;;
  *) skip "dockerfile_state='$dockerfile_state' — nothing to contribute" ;;
esac

[ -z "$deploy_verified_at" ] || [ "$deploy_verified_at" = "null" ] && die "deploy not verified yet (deploy_verified_at empty); run stability-gate first"

[ -z "$upstream_repo" ] && die "upstream_repo empty in state file"
[[ "$upstream_repo" == */* ]] || die "upstream_repo must be owner/name, got: $upstream_repo"

UP_OWNER="${upstream_repo%/*}"
UP_NAME="${upstream_repo#*/}"

abs_dockerfile="$MODULE_DIR/$(basename "$dockerfile_path")"
if [ ! -f "$MODULE_DIR/files/Dockerfile" ]; then
  die "Dockerfile not found at $MODULE_DIR/files/Dockerfile"
fi
DOCKERFILE_SRC="$MODULE_DIR/files/Dockerfile"
DOCKERIGNORE_SRC="$MODULE_DIR/files/.dockerignore"
BUILDMD_SRC="$MODULE_DIR/files/BUILD.md"
for f in "$DOCKERIGNORE_SRC" "$BUILDMD_SRC"; do
  [ -f "$f" ] || die "required file missing: $f"
done

# --- GitHub auth ---
GITHUB_TOKEN="${GITHUB_TOKEN:-$(vault kv get -field=github_pat secret/viktor 2>/dev/null || true)}"
[ -n "$GITHUB_TOKEN" ] || die "GITHUB_TOKEN not set and vault lookup failed (vault login -method=oidc first)"

gh_api() {
  local method="$1"; local path="$2"; local data="${3:-}"
  local url="https://api.github.com${path}"
  local curl_args=(-sS -w "\n%{http_code}" -X "$method"
    -H "Authorization: token $GITHUB_TOKEN"
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28")
  [ -n "$data" ] && curl_args+=(-d "$data")
  curl "${curl_args[@]}" "$url"
}

gh_api_retry() {
  local method="$1"; local path="$2"; local data="${3:-}"
  local attempt=1
  local max_attempts=3
  local out http
  while [ "$attempt" -le "$max_attempts" ]; do
    out=$(gh_api "$method" "$path" "$data")
    http=$(printf '%s' "$out" | tail -n1)
    body=$(printf '%s' "$out" | sed '$d')
    if [ "$http" -ge 500 ] || [ "$http" = "000" ]; then
      log "retry $attempt/$max_attempts on $method $path (http=$http)"
      attempt=$((attempt + 1))
      sleep $((2 ** attempt))
      continue
    fi
    printf '%s\n%s' "$body" "$http"
    return 0
  done
  die "GitHub API 5xx after $max_attempts attempts on $method $path"
}

# Helpers that parse the combined body+http form.
gh_http() { printf '%s' "$1" | tail -n1; }
gh_body() { printf '%s' "$1" | sed '$d'; }

# --- Upstream sanity checks ---
log "checking upstream $upstream_repo"
resp=$(gh_api_retry GET "/repos/$UP_OWNER/$UP_NAME")
http=$(gh_http "$resp"); body=$(gh_body "$resp")
if [ "$http" = "404" ]; then skip "upstream repo not found (may be private or deleted): $upstream_repo"; fi
[ "$http" = "200" ] || die "GET upstream failed http=$http body=$body"

archived=$(printf '%s' "$body" | jq -r '.archived')
default_branch=$(printf '%s' "$body" | jq -r '.default_branch')
[ "$archived" = "true" ] && skip "upstream is archived — not opening PR"
[ -n "$default_branch" ] || die "could not determine upstream default branch"
log "upstream default branch: $default_branch"

# If we wrote the Dockerfile from scratch, make sure one didn't land upstream meanwhile.
if [ "$dockerfile_state" = "written-from-scratch" ]; then
  resp=$(gh_api_retry GET "/repos/$UP_OWNER/$UP_NAME/contents/Dockerfile?ref=$default_branch")
  http=$(gh_http "$resp")
  if [ "$http" = "200" ]; then
    skip "a Dockerfile landed upstream since we started — aborting to avoid clobbering"
  fi
fi

# Check for an existing open PR from our fork.
resp=$(gh_api_retry GET "/repos/$UP_OWNER/$UP_NAME/pulls?state=open&head=${FORK_OWNER}:${BRANCH_NAME}")
http=$(gh_http "$resp"); body=$(gh_body "$resp")
if [ "$http" = "200" ]; then
  existing=$(printf '%s' "$body" | jq -r '.[0].html_url // ""')
  if [ -n "$existing" ]; then
    log "existing open PR found: $existing — recording and skipping"
    jq --arg url "$existing" '.contribution_pr_url = $url' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    exit 0
  fi
fi

# --- Fork ---
log "ensuring fork exists at $FORK_OWNER/$UP_NAME"
resp=$(gh_api_retry POST "/repos/$UP_OWNER/$UP_NAME/forks" '{}')
http=$(gh_http "$resp")
if [ "$http" != "202" ] && [ "$http" != "200" ]; then
  die "fork call failed http=$http"
fi

# Wait for fork to be ready (GitHub can take up to ~30s).
for i in $(seq 1 15); do
  resp=$(gh_api_retry GET "/repos/$FORK_OWNER/$UP_NAME")
  if [ "$(gh_http "$resp")" = "200" ]; then break; fi
  sleep 2
done
[ "$(gh_http "$resp")" = "200" ] || die "fork $FORK_OWNER/$UP_NAME did not become ready"

# --- Sync fork with upstream default branch ---
log "syncing fork with upstream/$default_branch"
resp=$(gh_api_retry POST "/repos/$FORK_OWNER/$UP_NAME/merge-upstream" "$(jq -n --arg b "$default_branch" '{branch:$b}')")
http=$(gh_http "$resp")
[ "$http" = "200" ] || [ "$http" = "409" ] || log "merge-upstream returned http=$http (continuing)"

# --- Determine base SHA for new branch ---
resp=$(gh_api_retry GET "/repos/$FORK_OWNER/$UP_NAME/git/ref/heads/$default_branch")
http=$(gh_http "$resp"); body=$(gh_body "$resp")
[ "$http" = "200" ] || die "could not read default branch ref on fork (http=$http)"
base_sha=$(printf '%s' "$body" | jq -r '.object.sha')

# --- Create branch (or append timestamp on collision) ---
attempt_branch="$BRANCH_NAME"
resp=$(gh_api_retry GET "/repos/$FORK_OWNER/$UP_NAME/git/ref/heads/$attempt_branch")
if [ "$(gh_http "$resp")" = "200" ]; then
  attempt_branch="${BRANCH_NAME}-$(date +%s | tail -c 9)"
  log "branch existed; using $attempt_branch"
fi

log "creating branch $attempt_branch off $base_sha"
payload=$(jq -n --arg r "refs/heads/$attempt_branch" --arg s "$base_sha" '{ref:$r,sha:$s}')
resp=$(gh_api_retry POST "/repos/$FORK_OWNER/$UP_NAME/git/refs" "$payload")
[ "$(gh_http "$resp")" = "201" ] || die "could not create branch: $(gh_body "$resp")"

# --- Helper to PUT a file via Contents API ---
put_file() {
  local src="$1"; local dst="$2"; local message="$3"
  local b64 payload exists_resp http existing_sha=""
  b64=$(base64 -w0 < "$src")

  exists_resp=$(gh_api_retry GET "/repos/$FORK_OWNER/$UP_NAME/contents/$dst?ref=$attempt_branch")
  if [ "$(gh_http "$exists_resp")" = "200" ]; then
    existing_sha=$(gh_body "$exists_resp" | jq -r '.sha')
  fi

  if [ -n "$existing_sha" ]; then
    payload=$(jq -n --arg m "$message" --arg c "$b64" --arg b "$attempt_branch" --arg sha "$existing_sha" \
      '{message:$m, content:$c, branch:$b, sha:$sha}')
  else
    payload=$(jq -n --arg m "$message" --arg c "$b64" --arg b "$attempt_branch" \
      '{message:$m, content:$c, branch:$b}')
  fi

  resp=$(gh_api_retry PUT "/repos/$FORK_OWNER/$UP_NAME/contents/$dst" "$payload")
  http=$(gh_http "$resp")
  [ "$http" = "200" ] || [ "$http" = "201" ] || die "PUT $dst failed http=$http body=$(gh_body "$resp")"
}

commit_msg_prefix="Add Dockerfile"
[ "$dockerfile_state" = "fixed-broken-upstream" ] && commit_msg_prefix="Fix Dockerfile"

log "committing Dockerfile, .dockerignore, BUILD.md"
put_file "$DOCKERFILE_SRC"   "Dockerfile"     "$commit_msg_prefix

Signed-off-by: Viktor Barzin <viktorbarzin@meta.com>"
put_file "$DOCKERIGNORE_SRC" ".dockerignore"  "Add .dockerignore

Signed-off-by: Viktor Barzin <viktorbarzin@meta.com>"
put_file "$BUILDMD_SRC"      "BUILD.md"       "Add BUILD.md

Signed-off-by: Viktor Barzin <viktorbarzin@meta.com>"

# --- Render PR body ---
reason_paragraph="This project currently has no Dockerfile, making it harder for the self-hosting community to run this. I put together a working one while deploying this app to my home Kubernetes cluster and wanted to upstream it."
if [ "$reason_type" = "broken" ]; then
  reason_paragraph="The existing Dockerfile in this repo does not build cleanly for \`linux/amd64\`. I tracked down the fixes while deploying this app to my home Kubernetes cluster and wanted to upstream them."
fi

IMAGE_SIZE=$(jq -r '.image_size // "unknown"'  "$STATE_FILE")
BASE_IMAGE=$(jq -r '.base_image // "unknown"'  "$STATE_FILE")
IMAGE_TAG=$(jq -r  '.image_tag  // "myapp:latest"' "$STATE_FILE")
DOCKERFILE_SHAPE=$(jq -r '.dockerfile_shape // "multi-stage, non-root, linux/amd64"' "$STATE_FILE")

pr_body=$(cat "$TEMPLATES_DIR/PR_BODY.md")
pr_body="${pr_body//\{\{REASON_PARAGRAPH\}\}/$reason_paragraph}"
pr_body="${pr_body//\{\{DOCKERFILE_SHAPE\}\}/$DOCKERFILE_SHAPE}"
pr_body="${pr_body//\{\{IMAGE_SIZE\}\}/$IMAGE_SIZE}"
pr_body="${pr_body//\{\{BASE_IMAGE\}\}/$BASE_IMAGE}"
pr_body="${pr_body//\{\{IMAGE_TAG\}\}/$IMAGE_TAG}"

pr_title="$commit_msg_prefix"

# --- Open PR ---
log "opening PR against $UP_OWNER/$UP_NAME:$default_branch"
payload=$(jq -n \
  --arg t "$pr_title" \
  --arg h "${FORK_OWNER}:${attempt_branch}" \
  --arg b "$default_branch" \
  --arg body "$pr_body" \
  '{title:$t, head:$h, base:$b, body:$body, maintainer_can_modify:true}')
resp=$(gh_api_retry POST "/repos/$UP_OWNER/$UP_NAME/pulls" "$payload")
http=$(gh_http "$resp"); body=$(gh_body "$resp")
if [ "$http" != "201" ]; then
  die "PR creation failed http=$http body=$body"
fi

pr_url=$(printf '%s' "$body" | jq -r '.html_url')
log "PR opened: $pr_url"

# --- Record PR URL in state file ---
jq --arg url "$pr_url" '.contribution_pr_url = $url' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
log "state file updated with PR URL"
