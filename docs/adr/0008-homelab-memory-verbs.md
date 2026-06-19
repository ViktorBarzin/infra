# homelab memory verb-group: direct HTTP client to claude-memory; MCP deprecation path

v0.3 adds the memory verb-group so agents can search and navigate memory from the
CLI. `claude-memory` is a FastAPI service (Postgres-backed, `Bearer`-auth,
ingress `auth = "none"` so programmatic clients work) — the **MCP is just one
frontend over it**. `homelab memory` is a thin HTTP client over the same API,
using the env the hooks already set (`CLAUDE_MEMORY_API_URL` +
`CLAUDE_MEMORY_API_KEY`; defaults to the ingress). Because it talks to the HTTP
API directly, it **works even when the MCP frontend is down** — the recurring
MCP-disconnect problem that motivated claude-memory HA (and that took the MCP
offline for the entire session this was built in).

Verbs: `recall` (server-side semantic ranking), `list`, `categories`, `tags`,
`stats`, `secret` (read); `store`, `update`, `delete` (write). Validated against
the live API including a store→recall→delete round-trip — full data-plane parity
with the MCP.

## Deprecation path (deliberate follow-up — NOT done in v0.3)

The MCP is more than tools: the **per-prompt auto-recall hook** and the
**auto-learn hook** run on every prompt for every agent. Deprecating it safely is
a separate, sequenced change:

1. Rewire the auto-recall hook to `homelab memory recall` and the auto-learn hook
   to `homelab memory store`.
2. Update the CLAUDE.md memory policy to point at the CLI.
3. Uninstall the MCP.

Done CLI-first (verbs proven before touching the every-prompt path) so a
regression can't silently break auto-recall/auto-learn fleet-wide.
