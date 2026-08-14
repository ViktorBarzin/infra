#!/usr/bin/env python3
"""Start repowise's MCP server with a Host allowlist that fits this deployment.

WHY THIS EXISTS instead of just running `repowise mcp --transport
streamable-http`:

repowise builds its FastMCP instance as `FastMCP("repowise", ...)`, with no host
argument, so the MCP SDK applies its default of 127.0.0.1. The SDK reads that as
"this server is localhost-only" and auto-enables DNS-rebinding protection with
allowed_hosts = ["127.0.0.1:*", "localhost:*", "[::1]:*"]. repowise then sets
`mcp.settings.host = 0.0.0.0` at run time, but the allowlist it derived earlier
is not revisited. The result is HTTP 421 "Invalid Host header" for every request
that arrives under a real hostname — including the in-cluster ClusterIP address
that agent jobs are meant to use. repowise exposes no configuration for this,
and the SDK's settings object is populated from explicit constructor arguments,
so a FASTMCP_* environment variable cannot override it either.

Rather than disable the protection, this sets an allowlist that actually
describes where the server is reachable from. Requests from anywhere else are
still rejected, and the credential gates (LAN allowlist + per-holder bearer at
Traefik) are unchanged.

Keep this in step with the Service name, namespace and ingress host in main.tf.
"""

from __future__ import annotations

import os

from mcp.server.transport_security import TransportSecuritySettings
from repowise.server.mcp_server import mcp, run_mcp

WORKSPACE = os.environ.get("REPOWISE_WORKSPACE", "/workspace")
PORT = int(os.environ.get("REPOWISE_MCP_PORT", "7338"))
SERVICE = os.environ.get("MCP_SERVICE_NAME", "repowise-mcp")
NAMESPACE = os.environ.get("MCP_NAMESPACE", "repowise")
INGRESS_HOST = os.environ.get("MCP_INGRESS_HOST", "repowise-mcp.viktorbarzin.me")


def _allowed_hosts() -> list[str]:
    """Every name this server is legitimately addressed by.

    Both a bare form and a ``:*`` form for each: the SDK matches the bare entry
    exactly, and the ``:*`` entry only when a port is present, so a client that
    includes the port and one that omits it need separate entries.
    """
    names = [
        # Traefik rewrites Host to localhost:<port> for ingress traffic, since
        # the SDK's own auto-derived allowlist was localhost-only.
        "localhost",
        "127.0.0.1",
        "[::1]",
        # In-cluster callers (claude-agent-service) reaching the ClusterIP, in
        # every form the cluster's search domains can produce.
        SERVICE,
        f"{SERVICE}.{NAMESPACE}",
        f"{SERVICE}.{NAMESPACE}.svc",
        f"{SERVICE}.{NAMESPACE}.svc.cluster.local",
        # The ingress hostname, so this keeps working if the Host rewrite is
        # ever removed.
        INGRESS_HOST,
    ]
    return names + [f"{n}:*" for n in names]


def _allowed_origins() -> list[str]:
    """Origins for clients that send one.

    A request with no Origin header passes regardless — which covers the CLI
    and agent clients. These entries exist so a browser-based or
    Origin-stamping client is not rejected.
    """
    origins: list[str] = []
    for scheme in ("http", "https"):
        origins += [
            f"{scheme}://localhost",
            f"{scheme}://127.0.0.1",
            f"{scheme}://{SERVICE}.{NAMESPACE}.svc.cluster.local",
            f"{scheme}://{INGRESS_HOST}",
        ]
    return origins + [f"{o}:*" for o in origins]


def main() -> None:
    mcp.settings.transport_security = TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=_allowed_hosts(),
        allowed_origins=_allowed_origins(),
    )
    # Same call the `repowise mcp` CLI makes, with the tool surface unrestricted.
    run_mcp(
        transport="streamable-http",
        repo_path=WORKSPACE,
        host="0.0.0.0",
        port=PORT,
        tools="all",
    )


if __name__ == "__main__":
    main()
