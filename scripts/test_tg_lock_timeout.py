#!/usr/bin/env python3
"""Tests for scripts/tg lock-timeout injection.

scripts/tg wraps terragrunt. Tier-1 stacks rely on terraform's pg-backend
state lock; without -lock-timeout an apply fails instantly ("Error acquiring
the state lock") whenever anything else holds the lock — a Woodpecker-killed
run whose PG advisory lock has not been reaped yet, a concurrent local apply,
or the daily drift `plan`. This was the single largest cause of infra CI
failures. These tests pin that tg injects -lock-timeout for state-locking
verbs (and still preserves -auto-approve for non-interactive applies), so a
contended lock waits rather than fails.

Hermetic: a stub `terragrunt` on PATH records the args tg forwards; PG_CONN_STR
is pre-set so the Tier-1 Vault credential fetch is skipped (no network/Vault).
"""
import os
import shutil
import subprocess
from pathlib import Path

import pytest

SCRIPTS_DIR = Path(__file__).resolve().parent
TG = SCRIPTS_DIR / "tg"
AUTH_CHECK = SCRIPTS_DIR / "check-ingress-auth-comments.py"


def _run(tmp_path, *tg_args, env_extra=None):
    """Run a copy of scripts/tg in an isolated fake repo; return forwarded args."""
    repo = tmp_path / "repo"
    (repo / "scripts").mkdir(parents=True)
    shutil.copy(TG, repo / "scripts" / "tg")
    shutil.copy(AUTH_CHECK, repo / "scripts" / "check-ingress-auth-comments.py")
    os.chmod(repo / "scripts" / "tg", 0o755)
    os.chmod(repo / "scripts" / "check-ingress-auth-comments.py", 0o755)

    # Fake Tier-1 stack ("faketest" is NOT in TIER0_STACKS), no ingress auth lines.
    stack = repo / "stacks" / "faketest"
    stack.mkdir(parents=True)
    (stack / "terragrunt.hcl").write_text("# fake\n")
    (stack / "main.tf").write_text("# no ingress_factory auth lines here\n")

    # Stub terragrunt: append every forwarded arg (one per line) to a capture file.
    bindir = tmp_path / "bin"
    bindir.mkdir()
    capture = tmp_path / "tg_args.txt"
    stub = bindir / "terragrunt"
    stub.write_text(
        "#!/usr/bin/env bash\n"
        f'for a in "$@"; do echo "$a" >> "{capture}"; done\n'
        "exit 0\n"
    )
    os.chmod(stub, 0o755)

    env = dict(os.environ)
    env["PATH"] = f"{bindir}:{env['PATH']}"
    env["PG_CONN_STR"] = "postgres://stub"  # skip the Tier-1 Vault cred fetch
    env["TF_PLUGIN_CACHE_DIR"] = str(tmp_path / "plugin-cache")
    if env_extra:
        env.update(env_extra)

    proc = subprocess.run(
        ["bash", str(repo / "scripts" / "tg"), *tg_args],
        cwd=str(stack),
        env=env,
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, f"tg exited {proc.returncode}\nSTDERR:\n{proc.stderr}\nSTDOUT:\n{proc.stdout}"
    return capture.read_text().splitlines() if capture.exists() else []


def test_apply_non_interactive_has_lock_timeout_and_auto_approve(tmp_path):
    args = _run(tmp_path, "apply", "--non-interactive")
    assert "apply" in args
    assert "-auto-approve" in args, "non-interactive apply must keep -auto-approve"
    assert "-lock-timeout=5m" in args, "apply must wait for a contended state lock"


def test_plan_has_lock_timeout_but_not_auto_approve(tmp_path):
    args = _run(tmp_path, "plan")
    assert "plan" in args
    assert "-lock-timeout=5m" in args
    assert "-auto-approve" not in args, "plan must never get -auto-approve"


@pytest.mark.parametrize("verb", ["destroy", "refresh"])
def test_locking_verb_gets_lock_timeout(tmp_path, verb):
    args = _run(tmp_path, verb)
    assert "-lock-timeout=5m" in args, f"{verb} should carry -lock-timeout"


def test_non_locking_verb_has_no_lock_timeout(tmp_path):
    # validate does not take a state lock — must not carry -lock-timeout.
    args = _run(tmp_path, "validate")
    assert "validate" in args
    assert not any(a.startswith("-lock-timeout") for a in args)


def test_lock_timeout_is_env_overridable(tmp_path):
    args = _run(tmp_path, "plan", env_extra={"TG_LOCK_TIMEOUT": "2m"})
    assert "-lock-timeout=2m" in args
