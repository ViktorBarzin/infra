"""Environment-driven configuration.

The publishing identity is NEVER taken from a request body — it is resolved
from the bearer token against ``PAGES_API_KEYS`` (a JSON ``{user: token}`` map,
inverted here to ``{token: user}``), mirroring
``claude_memory/api/auth.py``. Every user key is validated to a strict charset
at load time so a malformed operator config can never widen the write path.
"""

from __future__ import annotations

import json
import os
import re
import sys
from dataclasses import dataclass, field

# Users (PAGES_API_KEYS keys) and slugs share this safe charset. Kept in sync
# with publisher._SLUG_RE — both feed the same ``pages/<segment>/`` path.
_SAFE_RE = re.compile(r"[0-9A-Za-z._-]+")


class ConfigError(RuntimeError):
    """Raised on a malformed environment (fail fast at startup)."""


def _invert_api_keys(raw: str) -> dict[str, str]:
    """Parse ``{user: token}`` JSON into a ``{token: user}`` lookup.

    Each user is validated against the safe charset (no ``/``, no ``..``,
    non-empty) — the user becomes a filesystem path segment, so an unsafe key
    is a config bug we refuse to start with rather than a traversal primitive.
    """
    if not raw:
        return {}
    try:
        user_to_token = json.loads(raw)
    except json.JSONDecodeError as e:
        raise ConfigError(f"PAGES_API_KEYS is not valid JSON: {e}") from e
    if not isinstance(user_to_token, dict):
        raise ConfigError("PAGES_API_KEYS must be a JSON object {user: token}")
    key_map: dict[str, str] = {}
    for user, token in user_to_token.items():
        if not isinstance(user, str) or not isinstance(token, str):
            raise ConfigError("PAGES_API_KEYS keys and values must be strings")
        if not user or ".." in user or not _SAFE_RE.fullmatch(user):
            raise ConfigError(f"unsafe user segment in PAGES_API_KEYS: {user!r}")
        if not token:
            raise ConfigError(f"empty token for user {user!r} in PAGES_API_KEYS")
        if token in key_map:
            raise ConfigError("duplicate token in PAGES_API_KEYS")
        key_map[token] = user
    return key_map


def _parse_bundle_keys(raw: str, api_tokens: dict[str, str]) -> dict[str, tuple[str, str]]:
    """Parse ``{token: {"user": ..., "slug": ...}}`` JSON into a token lookup.

    A bundle token publishes exactly one directory, ``pages/<user>/<slug>/``,
    so both segments get the same charset check as an API-key user. Bundle
    tokens live in their own map and may not repeat an API token: each token
    opens exactly one endpoint.
    """
    if not raw:
        return {}
    try:
        token_to_target = json.loads(raw)
    except json.JSONDecodeError as e:
        raise ConfigError(f"PAGES_BUNDLE_KEYS is not valid JSON: {e}") from e
    if not isinstance(token_to_target, dict):
        raise ConfigError(
            'PAGES_BUNDLE_KEYS must be a JSON object {token: {"user", "slug"}}'
        )
    bundle_map: dict[str, tuple[str, str]] = {}
    for token, target in token_to_target.items():
        if not token:
            raise ConfigError("empty token in PAGES_BUNDLE_KEYS")
        if token in api_tokens:
            raise ConfigError("PAGES_BUNDLE_KEYS token duplicates a PAGES_API_KEYS token")
        if not isinstance(target, dict):
            raise ConfigError('PAGES_BUNDLE_KEYS values must be {"user", "slug"} objects')
        user, slug = target.get("user"), target.get("slug")
        for name, segment in (("user", user), ("slug", slug)):
            if (
                not isinstance(segment, str)
                or not segment
                or ".." in segment
                or not _SAFE_RE.fullmatch(segment)
            ):
                raise ConfigError(f"unsafe {name} segment in PAGES_BUNDLE_KEYS: {segment!r}")
        bundle_map[token] = (user, slug)
    return bundle_map


@dataclass
class Config:
    key_map: dict[str, str]  # token -> resolved user (never from request body)
    repo_dir: str
    deploy_key_path: str
    render_script: str
    render_dir_flag: str
    repo_url: str
    base_url: str
    committer_name: str
    committer_email: str
    author_email_domain: str
    python_bin: str
    # token -> (user, slug) for /publish-bundle; disjoint from key_map
    bundle_map: dict[str, tuple[str, str]] = field(default_factory=dict)

    @property
    def git_ssh_command(self) -> str:
        # -i pins the deploy key; IdentitiesOnly stops ssh from trying an agent
        # or other keys; accept-new trusts github's host key on first contact
        # (the key is written to the runtime user's writable known_hosts).
        return (
            f"ssh -i {self.deploy_key_path} "
            "-o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes"
        )


def load_config(env: dict[str, str] | None = None) -> Config:
    env = os.environ if env is None else env
    repo_dir = env.get("REPO_DIR", "/repo")
    key_map = _invert_api_keys(env.get("PAGES_API_KEYS", ""))
    return Config(
        key_map=key_map,
        bundle_map=_parse_bundle_keys(env.get("PAGES_BUNDLE_KEYS", ""), key_map),
        repo_dir=repo_dir,
        deploy_key_path=env.get("DEPLOY_KEY_PATH", "/etc/pages-deploy/id_ed25519"),
        # Defaults follow the team spec (post plans/->pages/ migration). If the
        # renderer still lives at plans/tools/render.py with --plans-dir at
        # deploy time, override RENDER_SCRIPT + RENDER_DIR_FLAG in the stack.
        render_script=env.get(
            "RENDER_SCRIPT", os.path.join(repo_dir, "pages", "tools", "render.py")
        ),
        render_dir_flag=env.get("RENDER_DIR_FLAG", "--pages-dir"),
        repo_url=env.get("REPO_URL", "git@github.com:ViktorBarzin/monorepo.git"),
        base_url=env.get("PAGES_BASE_URL", "https://pages.viktorbarzin.me").rstrip("/"),
        committer_name=env.get("GIT_COMMITTER_NAME", "pages-publish"),
        committer_email=env.get("GIT_COMMITTER_EMAIL", "pages-publish@viktorbarzin.me"),
        author_email_domain=env.get("PAGES_AUTHOR_EMAIL_DOMAIN", "viktorbarzin.me"),
        python_bin=env.get("PYTHON_BIN", sys.executable),
    )
