# homelab Home Assistant verbs: token resolution + host SSH, not entity control

v0.7 adds `ha token` and `ha ssh`. They were chosen by mining a heavy HA
operator's sessions: across ~1,900 shell commands the single most-repeated line
(420×) was a hand-rolled `kubectl … | base64 -d | python -c '…token'` pipeline,
and a bespoke `ssh -o StrictHostKeyChecking=no -o …` invocation was redefined as
a shell function ~30× — both re-derived from scratch every session. The existing
`home-assistant-sofia.py` already covers the *API*, but it goes unused from an
arbitrary cwd (it needs `HOME_ASSISTANT_SOFIA_TOKEN` set and is referenced by a
cwd-relative path), so agents bypassed it. A global verb on `$PATH` closes that
gap for every user in every directory.

## Decisions

- **Only the two gaps the `ha` MCP can't fill.** The `ha` MCP server already
  does entity state and control (`get_state`, `call_service`, history, logs).
  Per the CLI's founding rule — *MCP-encoded actions are out of scope* (ADR-0004)
  — we do **not** reimplement `on`/`off`/`list`/`state`. We add only token
  *resolution* and host *SSH*, neither of which an API-only MCP can provide. The
  value is endpoint/secret/host resolution, exactly like `net`/`dns` (ADR-0010).
- **`ha token` resolves live from the cluster, not from an env var.** It reads
  the dedicated k8s Secret `openclaw/ha-tokens` (one key per instance: `sofia` /
  `london`) via the ambient kubeconfig. This is robust to env drift — the precise
  failure that made agents re-derive the pipeline. Read-tier, prints the bare
  token to stdout so it composes in `$(…)`, mirroring `memory secret`.
- **The token is split into its own least-privilege secret** (`stacks/openclaw/ha_tokens.tf`).
  It was originally read from `openclaw-secrets` → `skill_secrets` (a JSON blob
  also holding `slack_webhook` + `uptime_kuma_password`), which only cluster
  admins can read — so the verb hung/failed for the non-admin operator it was
  built for (emo = `emil.barzin@gmail.com`, group `Home Server Admins`, whose
  OIDC identity is barred from secrets in `openclaw`). `ha-tokens` carries only
  the HA tokens, with a Role+RoleBinding granting `get` on *just that secret* to
  the `Home Server Admins` group (k8s RBAC can't scope to a JSON sub-key, hence
  the separate object). openclaw's own deployment keeps reading `openclaw-secrets`
  — this is purely additive.
- **`ha ssh` is deterministic and per-user.** Flags are fixed for unattended
  use: `-F /dev/null` (ignore user ssh-config), `StrictHostKeyChecking=no` +
  `UserKnownHostsFile=/dev/null` (no host-key prompt/record — agents have no
  TTY), `BatchMode=yes` + `ConnectTimeout=10` (fail fast, never hang). The key
  is the **invoking user's** `~/.ssh/id_ed25519`, so the verb isn't tied to
  whoever first wrote the workflow; that user's key must be enrolled on the HA
  host. Write-tier (runs an arbitrary remote command).
- **sofia is the default; london is structural.** The devvm sits on the Sofia
  LAN, so `vbarzin@192.168.1.8` is reachable and is the default instance. london
  (`hassio@192.168.8.103`) is in the instance map so `ha token --instance london`
  works (a pure secret read), but `ha ssh --instance london` generally won't
  connect from here — london is remote. We model it correctly rather than
  pretend it's reachable.
- **Scope held at two verbs.** `ha api` (an authenticated curl passthrough for
  the endpoints the MCP/script don't cover — `/api/template`, `/reload`,
  `check_config`, `/error_log`) was deferred: once `ha token` exists, raw curl is
  already unblocked, and a generic passthrough overlaps the MCP. Re-measure via
  `usage top` (ADR-0011); add targeted sugar verbs only if those endpoints are
  still hand-rolled often.
