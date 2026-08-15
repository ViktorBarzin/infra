#!/usr/bin/env python3
"""Build the workspace-level (cross-repo) layer of the Corpus.

WHY THIS EXISTS: indexing a repo and relating repos to each other are two
different jobs in repowise, and only the first one runs in our deployment.

The server's ``POST /api/workspace/sync`` fans out a per-repo index job for
every stale repo, which is what fills in each repo's own graph, health, docs and
history. The cross-repo layer — co-changes across repos, HTTP/gRPC/socket/topic
contracts, the system graph, breaking-change detection and conformance — is
built by ``run_cross_repo_hooks``, and that is only reached from the CLI's
workspace-update path (``core/workspace/update.py``), which we never invoke.
Without it the dashboard's System Map, Contracts and Co-Changes pages are
permanently empty and Conformance reports a hollow 10.0/10 over an empty graph.

Running the hooks directly, rather than ``repowise update``, keeps this to the
one job that is actually missing: no repo re-indexing, so it does not duplicate
or race the API's own jobs.

Writes into ``<workspace>/.repowise-workspace/`` (cross_repo_edges.json,
contracts.json, the system graph), which is what the workspace views read.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import sys
from pathlib import Path

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("cross-repo")

WORKSPACE = Path(os.environ.get("REPOWISE_WORKSPACE", "/workspace"))
DATA_DIR = WORKSPACE / ".repowise-workspace"


def _summary() -> dict[str, int]:
    """Count what landed on disk, so a pass can report something concrete."""
    out: dict[str, int] = {}
    for name, key in (("cross_repo_edges.json", "edges"), ("contracts.json", "contracts")):
        path = DATA_DIR / name
        try:
            data = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(data, dict):
            for candidate in ("edges", "contracts", "items", "records"):
                if isinstance(data.get(candidate), list):
                    out[key] = len(data[candidate])
                    break
            else:
                out[key] = len(data)
        elif isinstance(data, list):
            out[key] = len(data)
    return out


async def main() -> int:
    from repowise.core.workspace.config import WorkspaceConfig
    from repowise.core.workspace.update import run_cross_repo_hooks

    if not (WORKSPACE / ".repowise-workspace.yaml").is_file():
        log.error("no workspace at %s", WORKSPACE)
        return 1

    config = WorkspaceConfig.load(WORKSPACE)
    aliases = [r.alias for r in config.repos]
    if len(aliases) < 2:
        # The hooks no-op below two repos; say so rather than looking successful.
        log.info("only %d repo(s) in the workspace; nothing to relate", len(aliases))
        return 0

    log.info("building cross-repo layer over %d repos", len(aliases))
    # Every alias, not just the ones that moved: the hooks rebuild the whole
    # system graph from the current state, and a pass that named only changed
    # repos would keep re-deriving a partial picture.
    await run_cross_repo_hooks(config, WORKSPACE, aliases)
    log.info("cross-repo layer built: %s", _summary() or "no artefacts written")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
