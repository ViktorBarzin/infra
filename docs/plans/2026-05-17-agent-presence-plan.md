# Agent Presence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a shared presence board so Claude Code agent sessions can see which shared infra resources are being actively mutated by other sessions, preventing redundant investigations and overlapping operations.

**Architecture:** Single-table store on the existing Dolt server (`10.0.20.200:3306`, `beads` DB, new `presence_claims` table). Python single-file CLI (`scripts/presence`) writes/reads claims. Heartbeat-driven TTL — entries expire 15 min after the last heartbeat, so "left unclosed" is structurally impossible. A consolidated UserPromptSubmit hook injects other sessions' active claims into every turn for ambient awareness. CLAUDE.md rule mandates agents claim before mutating shared state.

**Tech Stack:** Python 3 stdlib + `pymysql`; Dolt (MySQL-compatible) at `10.0.20.200:3306`; Bash hooks; Terraform Kubernetes provider.

**Coverage of design decisions (locked in grilling):**
- Pure presence/coordination — not work tracking
- Resource-scoped entries (`<type>:<name>`)
- Heartbeat TTL + Stop-hook release
- Agent-driven claim via CLI invoked from agent reasoning per CLAUDE.md rule
- Stored on Dolt `beads` DB, new table
- CLI verbs: `claim`, `heartbeat`, `release`, `list`, `peek`
- UserPromptSubmit hook consolidates beads + presence
- Seed vocab: `node:`, `host:`, `stack:`, `service:`, `db:`, `pvc:`, `infra:`
- Only mutating ops trigger claim
- Co-claim allowed; soft-defer protocol on conflict
- MVP devvm only (no claude-agent-service / Woodpecker)
- Beads coexists with cleaned semantics
- Pure rule + visibility for enforcement (measure first)
- Python single-file CLI at `~/code/scripts/presence`

---

## File Structure

**New files:**
- `scripts/presence` — Python single-file CLI (~250 lines)
- `scripts/tests/test_presence.py` — pytest unit tests for the CLI
- `scripts/tests/conftest.py` — pytest fixtures (mocked DB)
- `.claude/hooks/presence-session-start.sh` — generates session ID at start
- `.claude/hooks/presence-heartbeat.sh` — throttled heartbeat on PostToolUse
- `.claude/hooks/presence-release.sh` — release on Stop
- `.claude/hooks/agent-state-context.sh` — consolidated beads+presence injector (replaces user-global `beads-task-context.sh`)

**Modified files:**
- `infra/stacks/beads-server/main.tf` — add `presence_claims` schema init
- `.claude/settings.json` — wire new hooks; swap UserPromptSubmit to consolidated script
- `CLAUDE.md` — add the claim-before-mutate rule, seed vocab, defer protocol

**Touched-but-untouched (audit only):**
- Stale `in_progress` beads items (close or revert to `open`)

---

## Task 1: Create `presence_claims` table on the Dolt server

**Files:**
- Modify: `infra/stacks/beads-server/main.tf` — extend the existing `kubernetes_config_map.dolt_init` data block + add a `kubernetes_job` for idempotent table creation on already-running Dolt
- Apply via `scripts/tg apply` from `infra/stacks/beads-server/`

The `dolt_init` ConfigMap only runs on fresh Dolt PVCs. Since Dolt is already running with the existing PV, the new SQL won't fire from there. The Job is the workaround for live updates and stays idempotent forever.

- [ ] **Step 1: Add the schema SQL into the existing `dolt_init` ConfigMap**

In `infra/stacks/beads-server/main.tf`, locate `resource "kubernetes_config_map" "dolt_init"` and add a second data entry:

```hcl
resource "kubernetes_config_map" "dolt_init" {
  metadata {
    name      = "dolt-init"
    namespace = kubernetes_namespace.beads.metadata[0].name
  }
  data = {
    "01-create-beads-user.sql" = <<-EOT
      CREATE USER IF NOT EXISTS 'beads'@'%' IDENTIFIED BY '';
      GRANT ALL PRIVILEGES ON *.* TO 'beads'@'%' WITH GRANT OPTION;
    EOT
    "02-create-presence-table.sql" = <<-EOT
      CREATE DATABASE IF NOT EXISTS beads;
      USE beads;
      CREATE TABLE IF NOT EXISTS presence_claims (
        session_id      VARCHAR(128)  NOT NULL,
        resource_label  VARCHAR(255)  NOT NULL,
        purpose         TEXT          NOT NULL,
        claimed_at      DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        expires_at      DATETIME(3)   NOT NULL,
        host            VARCHAR(128)  NOT NULL,
        user            VARCHAR(64)   NOT NULL,
        agent_name      VARCHAR(64)   DEFAULT 'claude-code',
        PRIMARY KEY (session_id, resource_label),
        INDEX idx_resource (resource_label),
        INDEX idx_expires  (expires_at)
      );
    EOT
  }
}
```

- [ ] **Step 2: Add an idempotent migration Job that creates the table on the running Dolt**

Append a new resource block in `infra/stacks/beads-server/main.tf`, after the `kubernetes_deployment.dolt` resource:

```hcl
resource "kubernetes_job" "presence_schema_migrate" {
  metadata {
    # name includes a hash of the SQL so a real schema change forces a new Job
    name      = "presence-schema-${substr(sha256(kubernetes_config_map.dolt_init.data["02-create-presence-table.sql"]), 0, 8)}"
    namespace = kubernetes_namespace.beads.metadata[0].name
  }
  spec {
    backoff_limit = 3
    template {
      metadata {}
      spec {
        restart_policy = "OnFailure"
        container {
          name    = "migrate"
          image   = "mysql:8.4"
          command = ["sh", "-c"]
          args = [
            "mysql -h dolt.beads-server.svc.cluster.local -P 3306 -u root < /sql/02-create-presence-table.sql"
          ]
          volume_mount {
            name       = "sql"
            mount_path = "/sql"
          }
        }
        volume {
          name = "sql"
          config_map {
            name = kubernetes_config_map.dolt_init.metadata[0].name
          }
        }
      }
    }
  }
  wait_for_completion = true
  timeouts {
    create = "5m"
  }
  depends_on = [kubernetes_deployment.dolt]
}
```

- [ ] **Step 3: Apply the Terraform change**

Run:
```bash
cd /home/wizard/code/infra/stacks/beads-server
../../scripts/tg apply
```
Expected: `kubernetes_config_map.dolt_init` updated + `kubernetes_job.presence_schema_migrate` created + Job completes successfully.

- [ ] **Step 4: Verify the table exists**

Run:
```bash
mysql -h 10.0.20.200 -u beads -e "USE beads; SHOW TABLES LIKE 'presence_claims'; DESCRIBE presence_claims;"
```
Expected: one row `presence_claims` from `SHOW TABLES`; DESCRIBE shows the 8 columns with the right types.

- [ ] **Step 5: Commit**

```bash
git add infra/stacks/beads-server/main.tf
git commit -m "beads-server: add presence_claims table for agent coordination

Adds the schema for the new agent presence board. Live Dolt is updated
via a hashed-named one-shot Job; the ConfigMap entry preserves fresh-PVC
init.
"
```

---

## Task 2: Python CLI scaffolding (argparse + DB connection)

**Files:**
- Create: `scripts/presence`
- Create: `scripts/tests/test_presence.py`
- Create: `scripts/tests/conftest.py`

- [ ] **Step 1: Write the failing test for `--help`**

Create `scripts/tests/test_presence.py`:

```python
import subprocess
from pathlib import Path

SCRIPT = Path(__file__).parent.parent / "presence"


def test_help_lists_subcommands():
    """--help should list all supported subcommands."""
    result = subprocess.run(
        [str(SCRIPT), "--help"], capture_output=True, text=True
    )
    assert result.returncode == 0
    for verb in ("claim", "heartbeat", "release", "list", "peek"):
        assert verb in result.stdout
```

- [ ] **Step 2: Run the test, confirm it fails**

Run: `pytest scripts/tests/test_presence.py::test_help_lists_subcommands -v`
Expected: FAIL — `scripts/presence` doesn't exist yet (FileNotFoundError).

- [ ] **Step 3: Create the CLI skeleton**

Create `scripts/presence`:

```python
#!/usr/bin/env python3
"""Agent presence board CLI.

Lets Claude Code agent sessions claim, heartbeat, release, list, and peek at
shared infra resource claims so that two sessions don't unknowingly mutate
the same thing at the same time.

Reads connection details from env:
  PRESENCE_DSN          mysql DSN (default: beads@10.0.20.200:3306/beads)
  CLAUDE_SESSION_ID     session identity (default: read from session-id file)
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import socket
import sys
import uuid
from pathlib import Path

SESSION_ID_FILE = Path.home() / ".cache" / "claude-presence" / "current.session"
DEFAULT_DSN = "mysql://beads@10.0.20.200:3306/beads"
DEFAULT_TTL_SECONDS = 15 * 60


def get_session_id() -> str:
    """Return the current session ID, generating a fallback if missing."""
    env = os.environ.get("CLAUDE_SESSION_ID")
    if env:
        return env
    if SESSION_ID_FILE.exists():
        return SESSION_ID_FILE.read_text().strip()
    # Fallback: ephemeral one-shot id (won't be cleaned up by Stop hook)
    return f"{getpass.getuser()}@{socket.gethostname().split('.')[0]}@{uuid.uuid4().hex[:8]}"


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="presence",
        description="Agent presence board for coordinating shared-infra mutations.",
    )
    p.add_argument("--json", action="store_true", help="emit machine-readable output")
    sub = p.add_subparsers(dest="verb", required=True)

    c = sub.add_parser("claim", help="claim a resource you're about to mutate")
    c.add_argument("label", help="resource label, e.g. node:k8s-node1")
    c.add_argument("--purpose", required=True, help="what + why")
    c.add_argument("--ttl", type=int, default=DEFAULT_TTL_SECONDS, help="seconds")

    sub.add_parser("heartbeat", help="extend TTL on all my active claims")

    r = sub.add_parser("release", help="release one or all of my claims")
    r.add_argument("label", nargs="?", help="resource label; omit with --all-mine")
    r.add_argument("--all-mine", action="store_true")

    li = sub.add_parser("list", help="show active claims")
    g = li.add_mutually_exclusive_group()
    g.add_argument("--mine", action="store_true")
    g.add_argument("--all", action="store_true", default=True)

    pe = sub.add_parser("peek", help="show all active claims on a resource")
    pe.add_argument("label", help="resource label")

    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    # Verbs implemented in later tasks; stub for now so --help works.
    print(f"verb={args.verb} not yet implemented", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Make it executable**

Run: `chmod +x /home/wizard/code/scripts/presence`

- [ ] **Step 5: Re-run the test, confirm it passes**

Run: `pytest scripts/tests/test_presence.py::test_help_lists_subcommands -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/presence scripts/tests/test_presence.py
git commit -m "presence: add CLI scaffolding with argparse subcommands"
```

---

## Task 3: `claim` verb — write to DB, return conflicts

**Files:**
- Modify: `scripts/presence`
- Modify: `scripts/tests/test_presence.py`
- Create: `scripts/tests/conftest.py`

- [ ] **Step 1: Add pymysql + fixture scaffolding in conftest**

Create `scripts/tests/conftest.py`:

```python
import os
from unittest.mock import MagicMock

import pytest


@pytest.fixture
def fake_db(monkeypatch):
    """Mocks pymysql.connect to return a MagicMock cursor we can inspect."""
    conn = MagicMock(name="conn")
    cur = MagicMock(name="cur")
    conn.cursor.return_value.__enter__.return_value = cur
    cur.fetchall.return_value = []

    import pymysql
    monkeypatch.setattr(pymysql, "connect", MagicMock(return_value=conn))
    monkeypatch.setenv("CLAUDE_SESSION_ID", "wizard@devvm@testtest")
    return cur
```

- [ ] **Step 2: Write the failing test for `claim` happy path**

Append to `scripts/tests/test_presence.py`:

```python
import importlib.util
import sys
from pathlib import Path


def _load_module():
    spec = importlib.util.spec_from_file_location("presence", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["presence"] = mod
    spec.loader.exec_module(mod)
    return mod


def test_claim_inserts_row(fake_db):
    presence = _load_module()
    rc = presence.main(["claim", "node:k8s-node1", "--purpose", "GPU upgrade"])
    assert rc == 0
    # First call: insert/upsert; second: read existing other-session claims
    sql_calls = [c.args[0] for c in fake_db.execute.call_args_list]
    assert any("INSERT" in s.upper() or "REPLACE" in s.upper() for s in sql_calls)
    assert any("SELECT" in s.upper() for s in sql_calls)


def test_claim_reports_other_session_conflict(fake_db, capsys):
    presence = _load_module()
    # Simulate one OTHER session already holding the label
    fake_db.fetchall.return_value = [
        {
            "session_id": "emo@laptop@aaaaaaaa",
            "purpose": "tcpdump on uplink",
            "claimed_at": "2026-05-17 14:10:00.000",
            "user": "emo",
            "host": "laptop",
        }
    ]
    rc = presence.main(["claim", "node:k8s-node1", "--purpose", "GPU upgrade"])
    out = capsys.readouterr().out
    assert rc == 0
    assert "emo@laptop@aaaaaaaa" in out
    assert "tcpdump on uplink" in out
```

- [ ] **Step 3: Run the tests, confirm they fail**

Run: `pytest scripts/tests/test_presence.py -v -k claim`
Expected: 2 failures — `claim` verb not implemented (stub prints "not yet implemented").

- [ ] **Step 4: Implement `claim` in `scripts/presence`**

Replace the bottom of `scripts/presence` (the stub `main`) with this. Also add the DB helpers and `_claim` function above `main`:

```python
import urllib.parse

try:
    import pymysql
    import pymysql.cursors
except ImportError:
    pymysql = None  # graceful: handled in _connect


def _connect():
    if pymysql is None:
        return None
    dsn = os.environ.get("PRESENCE_DSN", DEFAULT_DSN)
    u = urllib.parse.urlparse(dsn)
    try:
        return pymysql.connect(
            host=u.hostname,
            port=u.port or 3306,
            user=u.username or "beads",
            password=u.password or "",
            database=(u.path.lstrip("/") or "beads"),
            cursorclass=pymysql.cursors.DictCursor,
            connect_timeout=3,
            autocommit=True,
        )
    except Exception as e:
        print(f"presence: warning: dolt unreachable ({e}); continuing", file=sys.stderr)
        return None


def _claim(args, session_id: str) -> int:
    conn = _connect()
    if conn is None:
        return 0  # graceful degradation
    with conn.cursor() as cur:
        cur.execute(
            """
            REPLACE INTO presence_claims
                (session_id, resource_label, purpose, claimed_at, expires_at, host, user, agent_name)
            VALUES
                (%s, %s, %s, NOW(3), NOW(3) + INTERVAL %s SECOND, %s, %s, %s)
            """,
            (
                session_id,
                args.label,
                args.purpose,
                args.ttl,
                socket.gethostname().split(".")[0],
                getpass.getuser(),
                "claude-code",
            ),
        )
        cur.execute(
            """
            SELECT session_id, purpose, claimed_at, user, host
              FROM presence_claims
             WHERE resource_label = %s
               AND session_id    != %s
               AND expires_at    >  NOW(3)
             ORDER BY claimed_at
            """,
            (args.label, session_id),
        )
        conflicts = cur.fetchall()
    if not conflicts:
        print(f"presence: claimed {args.label}")
        return 0
    print(f"presence: claimed {args.label} -- ALSO CLAIMED BY:")
    for c in conflicts:
        print(f"  - {c['session_id']} ({c['user']}@{c['host']}): {c['purpose']} since {c['claimed_at']}")
    print("presence: per CLAUDE.md rule, default is to DEFER — release your claim and confirm with the user.")
    return 0
```

Update `main` to dispatch:

```python
def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    session_id = get_session_id()
    if args.verb == "claim":
        return _claim(args, session_id)
    print(f"verb={args.verb} not yet implemented", file=sys.stderr)
    return 0
```

- [ ] **Step 5: Run tests, confirm they pass**

Run: `pytest scripts/tests/test_presence.py -v -k claim`
Expected: both `test_claim_inserts_row` and `test_claim_reports_other_session_conflict` PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/presence scripts/tests/test_presence.py scripts/tests/conftest.py
git commit -m "presence: implement claim verb (upsert + conflict report)"
```

---

## Task 4: `peek` and `list` verbs (read paths)

**Files:**
- Modify: `scripts/presence`
- Modify: `scripts/tests/test_presence.py`

- [ ] **Step 1: Write the failing tests for `peek` and `list`**

Append to `scripts/tests/test_presence.py`:

```python
def test_peek_shows_all_active_claims_for_resource(fake_db, capsys):
    presence = _load_module()
    fake_db.fetchall.return_value = [
        {
            "session_id": "wizard@devvm@bbbbbbbb",
            "purpose": "GPU driver upgrade",
            "claimed_at": "2026-05-17 14:32:00.000",
            "expires_at": "2026-05-17 14:47:00.000",
            "user": "wizard",
            "host": "devvm",
        }
    ]
    rc = presence.main(["peek", "node:k8s-node1"])
    out = capsys.readouterr().out
    assert rc == 0
    assert "wizard@devvm@bbbbbbbb" in out
    assert "GPU driver upgrade" in out


def test_peek_empty_resource_prints_no_active_claim(fake_db, capsys):
    presence = _load_module()
    fake_db.fetchall.return_value = []
    rc = presence.main(["peek", "node:k8s-node99"])
    out = capsys.readouterr().out
    assert rc == 0
    assert "no active claim" in out.lower()


def test_list_all_shows_only_active(fake_db, capsys):
    presence = _load_module()
    fake_db.fetchall.return_value = [
        {
            "session_id": "wizard@devvm@xxxxxxxx",
            "resource_label": "stack:gpu-operator",
            "purpose": "rebuild driver",
            "claimed_at": "2026-05-17 14:00:00.000",
            "expires_at": "2026-05-17 14:15:00.000",
            "user": "wizard",
            "host": "devvm",
        }
    ]
    rc = presence.main(["list", "--all"])
    out = capsys.readouterr().out
    assert rc == 0
    assert "stack:gpu-operator" in out
    assert "wizard@devvm@xxxxxxxx" in out


def test_list_mine_filters_to_current_session(fake_db, monkeypatch):
    presence = _load_module()
    presence.main(["list", "--mine"])
    sql = fake_db.execute.call_args_list[-1].args[0]
    assert "session_id" in sql
    assert "expires_at" in sql
```

- [ ] **Step 2: Run the tests, confirm they fail**

Run: `pytest scripts/tests/test_presence.py -v -k "peek or list"`
Expected: 4 failures — verbs unimplemented.

- [ ] **Step 3: Implement `peek` and `list`**

Add to `scripts/presence`, above `main`:

```python
def _peek(args, session_id: str) -> int:
    conn = _connect()
    if conn is None:
        return 0
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT session_id, purpose, claimed_at, expires_at, user, host
              FROM presence_claims
             WHERE resource_label = %s
               AND expires_at    >  NOW(3)
             ORDER BY claimed_at
            """,
            (args.label,),
        )
        rows = cur.fetchall()
    if not rows:
        print(f"presence: no active claim on {args.label}")
        return 0
    print(f"presence: active claims on {args.label}:")
    for r in rows:
        marker = " (me)" if r["session_id"] == session_id else ""
        print(f"  - {r['session_id']}{marker} ({r['user']}@{r['host']}): {r['purpose']} since {r['claimed_at']} (expires {r['expires_at']})")
    return 0


def _list(args, session_id: str) -> int:
    conn = _connect()
    if conn is None:
        return 0
    query = """
        SELECT session_id, resource_label, purpose, claimed_at, expires_at, user, host
          FROM presence_claims
         WHERE expires_at > NOW(3)
    """
    params: tuple = ()
    if args.mine:
        query += " AND session_id = %s"
        params = (session_id,)
    query += " ORDER BY claimed_at"
    with conn.cursor() as cur:
        cur.execute(query, params)
        rows = cur.fetchall()
    if not rows:
        print("presence: no active claims")
        return 0
    for r in rows:
        marker = " (me)" if r["session_id"] == session_id else ""
        print(f"  {r['resource_label']:<32} {r['session_id']}{marker} -- {r['purpose']} ({r['claimed_at']})")
    return 0
```

Extend the dispatcher in `main`:

```python
    if args.verb == "claim":
        return _claim(args, session_id)
    if args.verb == "peek":
        return _peek(args, session_id)
    if args.verb == "list":
        return _list(args, session_id)
```

- [ ] **Step 4: Run tests, confirm they pass**

Run: `pytest scripts/tests/test_presence.py -v -k "peek or list"`
Expected: 4 PASSES.

- [ ] **Step 5: Commit**

```bash
git add scripts/presence scripts/tests/test_presence.py
git commit -m "presence: implement peek + list verbs"
```

---

## Task 5: `heartbeat` and `release` verbs

**Files:**
- Modify: `scripts/presence`
- Modify: `scripts/tests/test_presence.py`

- [ ] **Step 1: Write the failing tests**

Append to `scripts/tests/test_presence.py`:

```python
def test_heartbeat_extends_all_my_claims(fake_db):
    presence = _load_module()
    rc = presence.main(["heartbeat"])
    assert rc == 0
    sql = fake_db.execute.call_args_list[-1].args[0]
    assert "UPDATE" in sql.upper()
    assert "expires_at" in sql
    assert "session_id" in sql


def test_release_single_label(fake_db):
    presence = _load_module()
    rc = presence.main(["release", "node:k8s-node1"])
    assert rc == 0
    last = fake_db.execute.call_args_list[-1]
    assert "DELETE" in last.args[0].upper()
    assert "node:k8s-node1" in last.args[1]


def test_release_all_mine(fake_db):
    presence = _load_module()
    rc = presence.main(["release", "--all-mine"])
    assert rc == 0
    last = fake_db.execute.call_args_list[-1]
    assert "DELETE" in last.args[0].upper()
    assert "wizard@devvm@testtest" in last.args[1]
```

- [ ] **Step 2: Run tests, confirm they fail**

Run: `pytest scripts/tests/test_presence.py -v -k "heartbeat or release"`
Expected: 3 failures.

- [ ] **Step 3: Implement `heartbeat` and `release`**

Add to `scripts/presence`:

```python
def _heartbeat(args, session_id: str) -> int:
    conn = _connect()
    if conn is None:
        return 0
    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE presence_claims
               SET expires_at = NOW(3) + INTERVAL %s SECOND
             WHERE session_id = %s
               AND expires_at > NOW(3)
            """,
            (DEFAULT_TTL_SECONDS, session_id),
        )
    return 0


def _release(args, session_id: str) -> int:
    conn = _connect()
    if conn is None:
        return 0
    with conn.cursor() as cur:
        if args.all_mine:
            cur.execute("DELETE FROM presence_claims WHERE session_id = %s", (session_id,))
        else:
            if not args.label:
                print("presence: release requires <label> or --all-mine", file=sys.stderr)
                return 2
            cur.execute(
                "DELETE FROM presence_claims WHERE session_id = %s AND resource_label = %s",
                (session_id, args.label),
            )
    return 0
```

Extend dispatcher:

```python
    if args.verb == "heartbeat":
        return _heartbeat(args, session_id)
    if args.verb == "release":
        return _release(args, session_id)
```

- [ ] **Step 4: Run tests, confirm they pass**

Run: `pytest scripts/tests/test_presence.py -v -k "heartbeat or release"`
Expected: 3 PASSES.

- [ ] **Step 5: Commit**

```bash
git add scripts/presence scripts/tests/test_presence.py
git commit -m "presence: implement heartbeat + release verbs"
```

---

## Task 6: `--json` output mode (used by the hook)

**Files:**
- Modify: `scripts/presence`
- Modify: `scripts/tests/test_presence.py`

The UserPromptSubmit hook needs structured output to render the "currently in flight" section. `--json` covers `list` (the most common machine-consumed verb).

- [ ] **Step 1: Write the failing test**

Append:

```python
def test_list_json_emits_array(fake_db, capsys):
    presence = _load_module()
    fake_db.fetchall.return_value = [
        {
            "session_id": "wizard@devvm@yyyyyyyy",
            "resource_label": "stack:gpu-operator",
            "purpose": "rebuild driver",
            "claimed_at": "2026-05-17 14:00:00.000",
            "expires_at": "2026-05-17 14:15:00.000",
            "user": "wizard",
            "host": "devvm",
        }
    ]
    rc = presence.main(["--json", "list", "--all"])
    out = capsys.readouterr().out
    assert rc == 0
    payload = json.loads(out)
    assert isinstance(payload, list)
    assert payload[0]["resource_label"] == "stack:gpu-operator"
```

Add `import json` at top of `test_presence.py` if not already there.

- [ ] **Step 2: Run, confirm it fails**

Run: `pytest scripts/tests/test_presence.py::test_list_json_emits_array -v`
Expected: FAIL (`--json` not consumed; output not JSON).

- [ ] **Step 3: Implement JSON output**

In `_list`, branch on `getattr(args, "json", False)`. The `--json` flag is on the top-level parser already; we need to forward it. The cleanest path is to attach it onto the namespace post-parse:

In `main`, right after `args = parser.parse_args(argv)`:

```python
    # propagate top-level --json onto args.json (no-op if already there)
    args.json = bool(getattr(args, "json", False))
```

In `_list`, replace the printing branch with:

```python
    if args.json:
        out = []
        for r in rows:
            out.append({
                "session_id":      r["session_id"],
                "resource_label":  r["resource_label"],
                "purpose":         r["purpose"],
                "claimed_at":      str(r["claimed_at"]),
                "expires_at":      str(r["expires_at"]),
                "user":            r["user"],
                "host":            r["host"],
                "is_me":           r["session_id"] == session_id,
            })
        print(json.dumps(out))
        return 0
    if not rows:
        print("presence: no active claims")
        return 0
    for r in rows:
        marker = " (me)" if r["session_id"] == session_id else ""
        print(f"  {r['resource_label']:<32} {r['session_id']}{marker} -- {r['purpose']} ({r['claimed_at']})")
    return 0
```

- [ ] **Step 4: Run, confirm it passes**

Run: `pytest scripts/tests/test_presence.py::test_list_json_emits_array -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/presence scripts/tests/test_presence.py
git commit -m "presence: add --json output for list verb (hook consumption)"
```

---

## Task 7: Verify graceful degradation when Dolt is unreachable

**Files:**
- Modify: `scripts/tests/test_presence.py`

The CLI MUST exit 0 with a stderr warning when the DB is down. We've coded this; now lock it in with a test.

- [ ] **Step 1: Write the failing test**

Append:

```python
def test_claim_returns_zero_when_db_unreachable(monkeypatch, capsys):
    monkeypatch.setenv("CLAUDE_SESSION_ID", "wizard@devvm@offlineee")
    monkeypatch.setenv("PRESENCE_DSN", "mysql://beads@127.0.0.1:1/beads")
    presence = _load_module()
    rc = presence.main(["claim", "node:nowhere", "--purpose", "test"])
    err = capsys.readouterr().err
    assert rc == 0
    assert "dolt unreachable" in err
```

- [ ] **Step 2: Run, confirm it passes**

Run: `pytest scripts/tests/test_presence.py::test_claim_returns_zero_when_db_unreachable -v`
Expected: PASS (already implemented; this just locks it in).

- [ ] **Step 3: Run the full test suite to confirm nothing regressed**

Run: `pytest scripts/tests/test_presence.py -v`
Expected: all tests PASS.

- [ ] **Step 4: Commit**

```bash
git add scripts/tests/test_presence.py
git commit -m "presence: lock in graceful degradation when Dolt unreachable"
```

---

## Task 8: SessionStart hook — write the session ID

**Files:**
- Create: `.claude/hooks/presence-session-start.sh`

- [ ] **Step 1: Write the script**

Create `/home/wizard/code/.claude/hooks/presence-session-start.sh`:

```bash
#!/bin/bash
# SessionStart hook: generate a stable session ID and write it where the
# other hooks + the presence CLI can find it.
#
# Single-session-per-user limitation: last-started session wins. Override
# with `export CLAUDE_SESSION_ID=...` per shell if you need parallel sessions.

set -euo pipefail

DIR="$HOME/.cache/claude-presence"
mkdir -p "$DIR"

USER_SHORT="$(whoami)"
HOST_SHORT="$(hostname -s)"
RAND="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
SESSION_ID="${USER_SHORT}@${HOST_SHORT}@${RAND}"

echo -n "$SESSION_ID" > "$DIR/current.session"
exit 0
```

Make executable:

```bash
chmod +x /home/wizard/code/.claude/hooks/presence-session-start.sh
```

- [ ] **Step 2: Smoke-test**

Run:
```bash
/home/wizard/code/.claude/hooks/presence-session-start.sh
cat ~/.cache/claude-presence/current.session
```
Expected: a line like `wizard@devvm@a1b2c3d4`.

- [ ] **Step 3: Commit**

```bash
git add .claude/hooks/presence-session-start.sh
git commit -m "presence: SessionStart hook generates session id"
```

---

## Task 9: PostToolUse heartbeat hook (throttled)

**Files:**
- Create: `.claude/hooks/presence-heartbeat.sh`

Heartbeat on every tool call would spam the DB. Throttle to at most once every 120 seconds per session.

- [ ] **Step 1: Write the script**

Create `/home/wizard/code/.claude/hooks/presence-heartbeat.sh`:

```bash
#!/bin/bash
# PostToolUse hook: throttled heartbeat. Extends TTL on this session's
# active claims so they don't expire while we're working.
set -euo pipefail

SESSION_FILE="$HOME/.cache/claude-presence/current.session"
[[ -r "$SESSION_FILE" ]] || exit 0

SESSION_ID="$(cat "$SESSION_FILE")"
STAMP="/tmp/claude-presence-last-hb-${SESSION_ID}"

NOW=$(date +%s)
LAST=$(stat -c %Y "$STAMP" 2>/dev/null || echo 0)
if (( NOW - LAST < 120 )); then
    exit 0
fi
touch "$STAMP"

CLAUDE_SESSION_ID="$SESSION_ID" \
    /home/wizard/code/scripts/presence heartbeat >/dev/null 2>&1 || true
exit 0
```

Make executable:

```bash
chmod +x /home/wizard/code/.claude/hooks/presence-heartbeat.sh
```

- [ ] **Step 2: Smoke-test by setting an old timestamp and running twice**

Run:
```bash
rm -f /tmp/claude-presence-last-hb-*
/home/wizard/code/.claude/hooks/presence-heartbeat.sh
# Second call within 120s should silently no-op
/home/wizard/code/.claude/hooks/presence-heartbeat.sh
echo "OK"
```
Expected: both invocations exit 0, only the first one would have hit Dolt (you can verify by querying `presence_claims.expires_at` if a claim exists).

- [ ] **Step 3: Commit**

```bash
git add .claude/hooks/presence-heartbeat.sh
git commit -m "presence: PostToolUse heartbeat hook (throttled to 1/2min)"
```

---

## Task 10: Stop hook — release all of my claims

**Files:**
- Create: `.claude/hooks/presence-release.sh`

- [ ] **Step 1: Write the script**

Create `/home/wizard/code/.claude/hooks/presence-release.sh`:

```bash
#!/bin/bash
# Stop hook: release all active claims for this session and clean up
# session-id cache. Best-effort — never blocks shutdown.
set -euo pipefail

SESSION_FILE="$HOME/.cache/claude-presence/current.session"
[[ -r "$SESSION_FILE" ]] || exit 0

SESSION_ID="$(cat "$SESSION_FILE")"

CLAUDE_SESSION_ID="$SESSION_ID" \
    /home/wizard/code/scripts/presence release --all-mine >/dev/null 2>&1 || true

# clean the per-session heartbeat-stamp file
rm -f "/tmp/claude-presence-last-hb-${SESSION_ID}"
exit 0
```

Make executable:

```bash
chmod +x /home/wizard/code/.claude/hooks/presence-release.sh
```

- [ ] **Step 2: Smoke-test**

Run:
```bash
/home/wizard/code/.claude/hooks/presence-release.sh
echo "exit=$?"
```
Expected: prints `exit=0`.

- [ ] **Step 3: Commit**

```bash
git add .claude/hooks/presence-release.sh
git commit -m "presence: Stop hook releases all session claims"
```

---

## Task 11: Consolidate beads + presence into one UserPromptSubmit hook

**Files:**
- Create: `.claude/hooks/agent-state-context.sh`

Replaces the user-global `~/.claude/hooks/beads-task-context.sh`. The new hook emits one "Agent state context" block with two sections.

- [ ] **Step 1: Write the consolidated hook**

Create `/home/wizard/code/.claude/hooks/agent-state-context.sh`:

```bash
#!/bin/bash
# UserPromptSubmit hook: inject (1) beads in-progress + open tasks, and
# (2) other sessions' active presence claims. One consolidated block.

set -euo pipefail

BD="/home/wizard/.local/bin/bd"
BEADS_DIR="/home/wizard/code/.beads"
PRESENCE="/home/wizard/code/scripts/presence"
SESSION_FILE="$HOME/.cache/claude-presence/current.session"

CTX=""

# Section 1: beads
if [[ -x "$BD" && -d "$BEADS_DIR" ]]; then
    IN_PROG="$("$BD" --db "$BEADS_DIR" list --status in_progress 2>/dev/null || true)"
    OPEN="$("$BD" --db "$BEADS_DIR" list --status open 2>/dev/null | head -10 || true)"
    if [[ -n "$IN_PROG$OPEN" ]]; then
        CTX+="Active beads tasks (from shared Dolt server at 10.0.20.200):
"
        [[ -n "$IN_PROG" ]] && CTX+="
IN PROGRESS:
$IN_PROG
"
        [[ -n "$OPEN" ]] && CTX+="
OPEN (available):
$OPEN
"
        CTX+="
Use beads for tracked TODO work (multi-step epics, things to remember,
work that blocks other tasks). Skip beads for small in-session changes.
"
    fi
fi

# Section 2: presence — only other sessions' active claims
if [[ -x "$PRESENCE" && -r "$SESSION_FILE" ]]; then
    SESSION_ID="$(cat "$SESSION_FILE")"
    OTHERS="$(CLAUDE_SESSION_ID="$SESSION_ID" "$PRESENCE" --json list --all 2>/dev/null \
                | python3 -c "
import json, sys
try:
    rows = json.load(sys.stdin)
except Exception:
    sys.exit(0)
others = [r for r in rows if not r.get('is_me')]
if not others:
    sys.exit(0)
print('Currently being mutated by OTHER sessions:')
for r in others:
    print(f'  {r[\"resource_label\"]:<28} {r[\"session_id\"]} -- {r[\"purpose\"]} (since {r[\"claimed_at\"]})')
" 2>/dev/null || true)"
    if [[ -n "$OTHERS" ]]; then
        CTX+="
$OTHERS

If any of these resources overlap with what you're about to mutate,
DEFER and surface to the user. See CLAUDE.md \"Agent presence\" rule.
"
    fi
fi

[[ -z "$CTX" ]] && exit 0

python3 -c "
import json, sys
ctx = sys.stdin.read()
print(json.dumps({
    'hookSpecificOutput': {
        'hookEventName': 'UserPromptSubmit',
        'additionalContext': ctx
    }
}))
" <<< "$CTX"
```

Make executable:

```bash
chmod +x /home/wizard/code/.claude/hooks/agent-state-context.sh
```

- [ ] **Step 2: Smoke-test**

Run:
```bash
/home/wizard/code/.claude/hooks/agent-state-context.sh | python3 -m json.tool
```
Expected: JSON with `hookSpecificOutput.additionalContext` containing the beads sections (presence section if any claims exist).

- [ ] **Step 3: Commit**

```bash
git add .claude/hooks/agent-state-context.sh
git commit -m "presence: consolidated UserPromptSubmit hook (beads + presence)"
```

---

## Task 12: Wire all new hooks in project-level `.claude/settings.json`

**Files:**
- Modify: `.claude/settings.json`

- [ ] **Step 1: Replace the existing UserPromptSubmit + add new hooks**

Edit `/home/wizard/code/.claude/settings.json`. The existing hook stanza for UserPromptSubmit points at `~/.claude/hooks/beads-task-context.sh`. Replace it and add SessionStart/PostToolUse/Stop:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/home/wizard/code/.claude/hooks/presence-session-start.sh",
            "timeout": 3
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/home/wizard/code/.claude/hooks/agent-state-context.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/home/wizard/code/.claude/hooks/presence-heartbeat.sh",
            "timeout": 3
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/home/wizard/code/.claude/hooks/presence-release.sh",
            "timeout": 3
          }
        ]
      }
    ],
    "PermissionRequest": [
      {
        "matcher": "TaskCreate|TaskUpdate|TodoWrite",
        "hooks": [
          {
            "type": "command",
            "command": "python3 /home/wizard/.claude/hooks/beads-block-builtin-tasks.py",
            "timeout": 3
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 2: Validate JSON**

Run:
```bash
python3 -c "import json; json.load(open('/home/wizard/code/.claude/settings.json'))"
echo "OK"
```
Expected: `OK` (no traceback).

- [ ] **Step 3: Commit**

```bash
git add .claude/settings.json
git commit -m "presence: wire SessionStart/PostToolUse/Stop hooks + swap UserPromptSubmit to consolidated agent-state-context"
```

---

## Task 13: Add the CLAUDE.md rules

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Append the Agent Presence section to `CLAUDE.md`**

Add the following block to `/home/wizard/code/CLAUDE.md`, immediately after the "MANDATORY: Complete Tasks Fully" section and before "Repository Overview":

```markdown
## MANDATORY: Agent Presence — claim before mutating shared infra

**Before any operation that mutates shared infrastructure state, claim the affected resource(s) via the `presence` CLI.** This board is read by every Claude Code session in this repo (via the UserPromptSubmit hook), so other sessions know what's in flight and can avoid colliding with you.

### When to claim (high bar — only mutations)

**Triggers a claim:**
- `terraform apply` / `terragrunt apply`
- `kubectl apply`, `kubectl drain`, `kubectl delete`, `kubectl rollout restart`
- `helm upgrade --install`, `helm uninstall`
- Service restarts (`systemctl restart`, deliberate pod deletes)
- DB schema migrations or destructive queries
- Node-level changes (kernel, drivers, network config, firmware)

**Does NOT trigger a claim:**
- Read-only ops: `kubectl get/describe/logs`, `terraform plan`, `terragrunt plan`, file reads
- In-repo edits not yet applied (editing chart values, drafting Terraform)

### How to claim

```bash
~/code/scripts/presence claim <label> --purpose "<what + why>"
```

Resource label vocabulary (loose convention — pick the closest fit, use `infra:<freeform>` as fallback):

| Type | Example |
|---|---|
| `node:<name>` | `node:k8s-node1` (K8s node or VM) |
| `host:<name>` | `host:proxmox-1`, `host:devvm` (non-cluster machine) |
| `stack:<name>` | `stack:gpu-operator` (a Terraform stack) |
| `service:<name>` | `service:fire-planner` (a K8s service / app) |
| `db:<name>` | `db:pg-cluster` (a database) |
| `pvc:<ns>/<name>` | `pvc:prometheus/prom-data` (a PVC) |
| `infra:<freeform>` | catch-all |

A session may hold several claims simultaneously (e.g., GPU work claims `node:k8s-node1` AND `stack:gpu-operator`).

### Conflict resolution: defer by default

If `presence claim` reports an existing claim by another session on the same resource:

1. Read their `purpose` and `claimed_at`.
2. **Default: DEFER.** Release your own claim (`presence release <label>`) and tell the user: "Session S1 on host H is currently doing X (since T) — should I wait or proceed?"
3. Only proceed after explicit user authorization.
4. The underlying tool's own lock (terraform state, k8s resourceVersion, git) will still prevent silent overwrites — but presence-level deference saves you from blunt-forcing through it.

### Lifecycle (you don't need to think about it)

- Each claim lives for 15 minutes by default.
- The PostToolUse hook silently heartbeats every ~2 min while the session is active, extending TTL.
- The Stop hook releases all your claims on session exit.
- If a session dies abruptly, its claims expire automatically — no "left unclosed" failure mode.

### Discovery

Other sessions' active claims appear in the `Currently being mutated by OTHER sessions` block of your context on every turn (UserPromptSubmit hook). Before risky ops you can also `presence peek <label>` for a fresh read.

### Presence vs Beads

- **Beads** = TODO list / tracked work (have IDs, persist for days/weeks, closed when shipped).
- **Presence** = live mutations happening right now (no IDs, expire in minutes, auto-released).

Use both. They answer different questions.
```

- [ ] **Step 2: Verify CLAUDE.md renders**

Run:
```bash
head -160 /home/wizard/code/CLAUDE.md | tail -60
```
Expected: see the new section in place.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "CLAUDE.md: add Agent Presence rule (claim before mutating)"
```

---

## Task 14: Audit and clean up stale beads `in_progress` items

**Files:** none — this is a beads CLI operation.

The 8 currently `in_progress` items are exactly the "wrong granularity" failure. Audit each: if done, close; if not actively being worked, revert to `open` (or `blocked` if waiting on something).

- [ ] **Step 1: List the in_progress items with descriptions**

Run:
```bash
bd --db /home/wizard/code/.beads list --status in_progress
```
Expected: see the 8 items.

- [ ] **Step 2: For each item, decide done / revert / blocked**

For each `code-XXXX` item, run:
```bash
bd --db /home/wizard/code/.beads show <id>
```

Make a per-item decision:
- If the underlying work is complete → `bd --db /home/wizard/code/.beads close <id>` with a note explaining what landed.
- If it's truly active in this calendar week → leave `in_progress` (rare).
- If it's stalled / paused → `bd --db /home/wizard/code/.beads update <id> --status open` and add a `bd note <id>` explaining the pause.
- If it's blocked on external action → `bd --db /home/wizard/code/.beads update <id> --status blocked` and explain.

Expected: at the end, `bd list --status in_progress` either is empty or contains only what's *actually* being worked this calendar week. The 8 stale rows shown at the start of this plan should not all still be `in_progress`.

- [ ] **Step 3: Verify cleanup**

Run:
```bash
bd --db /home/wizard/code/.beads list --status in_progress | wc -l
```
Expected: ≤ 2 items (only what's genuinely active this week).

- [ ] **Step 4: No commit required for this task (beads state lives in Dolt, not git)**

---

## Task 15: End-to-end smoke test (two terminal sessions)

**Files:** none — this is a verification step.

- [ ] **Step 1: From terminal A, claim a fake resource**

Run:
```bash
cd /home/wizard/code
export CLAUDE_SESSION_ID="wizard@devvm@smoketestA"
./scripts/presence claim infra:smoke-test-a --purpose "verify presence v1"
```
Expected: `presence: claimed infra:smoke-test-a`.

- [ ] **Step 2: From terminal B, peek the same label**

Run:
```bash
cd /home/wizard/code
export CLAUDE_SESSION_ID="wizard@devvm@smoketestB"
./scripts/presence peek infra:smoke-test-a
```
Expected: shows terminal A's claim — `session_id=wizard@devvm@smoketestA`, purpose `verify presence v1`.

- [ ] **Step 3: From terminal B, claim same label — should show conflict**

Run:
```bash
./scripts/presence claim infra:smoke-test-a --purpose "intentional conflict"
```
Expected: `claimed` line PLUS `ALSO CLAIMED BY: wizard@devvm@smoketestA ...` and `DEFER` reminder.

- [ ] **Step 4: From terminal B, release**

Run:
```bash
./scripts/presence release --all-mine
./scripts/presence list --all
```
Expected: only terminal A's claim remains.

- [ ] **Step 5: Confirm UserPromptSubmit hook surfaces terminal A's claim**

From a new Claude Code session, type any message. Expected: the "Currently being mutated by OTHER sessions" block appears in the context (visible in the session's first response or via debug log) showing `infra:smoke-test-a` claimed by `wizard@devvm@smoketestA`.

- [ ] **Step 6: Clean up**

Run:
```bash
export CLAUDE_SESSION_ID="wizard@devvm@smoketestA"
./scripts/presence release --all-mine
./scripts/presence list --all
```
Expected: no claims listed.

- [ ] **Step 7: Push the branch**

```bash
git push origin master
```

Wait for CI / Drone deployment of the beads-server stack to succeed before marking the rollout complete.

---

## Out of scope for v1 (deferred to v2+)

- **claude-agent-service integration** — bake `presence` into the agent image. (Deferred per Q12 decision.)
- **Woodpecker CI integration** — `.woodpecker/*.yml` snippets that claim before `terraform apply`.
- **BeadBoard UI panel** — extend BeadBoard to render a "Currently in flight" section reading from `presence_claims`.
- **Hard enforcement** — PreToolUse hook that blocks mutating Bash without an active claim. Only add if measurement shows compliance < 50% after a few weeks.
- **Compliance measurement** — log `terraform apply` invocations and cross-reference with active claims at apply-time, to decide whether to escalate enforcement.

---

## Self-review

**Spec coverage**: Each of the 14 design decisions has a corresponding implementation task:
- Decisions 1-3 (purpose, unit, lifecycle) → Tasks 1, 8, 9, 10
- Decision 4 (mechanism) → Tasks 2-7 (CLI) + Task 13 (CLAUDE.md rule)
- Decision 5 (storage) → Task 1
- Decision 6 (CLI surface) → Tasks 3-6
- Decision 7 (discovery) → Tasks 11, 12
- Decision 8 (vocab) → Task 13 (CLAUDE.md)
- Decision 9 (trigger bar) → Task 13 (CLAUDE.md)
- Decision 10 (conflict) → Task 3 (`_claim`) + Task 13 (rule)
- Decision 11 (scope: devvm only) → implicit; out-of-scope items listed above
- Decision 12 (beads coexistence) → Tasks 11, 13, 14
- Decision 13 (pure rule + visibility) → Tasks 11, 12, 13
- Decision 14 (Python single-file) → Tasks 2-7

**Placeholder scan**: No `TBD` / `TODO` / "appropriate error handling" / "similar to" patterns.

**Type consistency**: Schema column names (`session_id`, `resource_label`, `purpose`, `claimed_at`, `expires_at`, `host`, `user`, `agent_name`) used identically in Task 1 (DDL), Task 3 (`_claim` SQL), Task 4 (`_peek`, `_list` SQL), Task 5 (`_heartbeat`, `_release` SQL), Task 6 (JSON output keys), Task 11 (hook output formatting).

**Risks flagged in plan body, not blockers:**
- Single-session-per-user limitation in SessionStart hook (Task 8). Documented; override via explicit `CLAUDE_SESSION_ID` env.
- Dolt commit history may grow from heartbeat writes — `dolt gc` periodically if it bloats.
- BeadBoard not updated in v1; will need a follow-up TF PR to render the new table.
