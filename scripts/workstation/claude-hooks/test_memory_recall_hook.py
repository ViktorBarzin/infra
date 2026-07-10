#!/usr/bin/env python3
"""Unit tests for homelab-memory-recall.py (UserPromptSubmit hook, ADR-0007).

Pure python: the homelab CLI subprocess is mocked and TMP_DIR is redirected to
a pytest tmp_path — no network, no real ~/.claude. Run:

    cd scripts/workstation/claude-hooks && python3 -m pytest test_memory_recall_hook.py -q
"""

import importlib.util
import io
import json
import os
import pathlib
import subprocess
import sys
import time
import types

_HOOK_PATH = pathlib.Path(__file__).resolve().parent / "homelab-memory-recall.py"
_spec = importlib.util.spec_from_file_location("homelab_memory_recall", _HOOK_PATH)
hook = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hook)

PROMPT = "what is the traefik load balancer ip?"


def _mem(mid, content="fact", category="facts", rank=0.5, importance=0.7, **extra):
    m = {
        "id": mid,
        "content": content,
        "category": category,
        "tags": "",
        "importance": importance,
        "is_sensitive": False,
        "rank": rank,
        "owner": "wizard",
        "created_at": "2026-07-10T00:00:00",
        "updated_at": "2026-07-10T00:00:00",
        "shared_by": None,
    }
    m.update(extra)
    return m


# ---------------------------------------------------------------- rendering

def test_render_line_uses_rank_as_score():
    m = _mem(7, content="Traefik LB is 10.0.20.203", category="gotchas", rank=0.42)
    assert hook.render_memory_line(m) == "#7 [gotchas] (0.42) Traefik LB is 10.0.20.203"


def test_render_line_falls_back_to_importance_without_rank():
    m = _mem(9, rank=None, importance=0.9)
    assert "(0.90)" in hook.render_memory_line(m)


def test_render_flattens_newlines():
    line = hook.render_memory_line(_mem(3, content="line one\nline two"))
    assert "\n" not in line
    assert "line one line two" in line


def test_link_pointers_only_for_pointer_types():
    m = _mem(4, links=[
        {"type": "part-of", "target_id": 123},
        {"type": "see-also", "target_id": 9},
        {"type": "resolved-by", "target_id": 66},   # auto-attach, not a pointer
        {"type": "supersedes", "target_id": 67},    # redirect, not a pointer
    ])
    assert hook.link_pointer_lines(m) == [
        "  ↳ see #123 (part-of)",
        "  ↳ see #9 (see-also)",
    ]


def test_link_pointers_tolerate_links_in_with_source_id():
    m = _mem(4, links_in=[{"type": "part-of", "source_id": 55}])
    assert hook.link_pointer_lines(m) == ["  ↳ see #55 (part-of)"]


def test_redirect_note():
    m = _mem(11, redirected_from=55)
    assert hook.redirect_lines(m) == ["  ↳ redirected from #55 (supersedes)"]


def test_attachment_rendered_indented_under_source():
    payload = {"memories": [
        _mem(1, content="symptom text"),
        _mem(2, content="the answer", rank=0.3,
             attached_via={"type": "resolved-by", "source_id": 1}),
    ]}
    ctx, ids = hook.build_context(payload, set())
    assert ids == [1, 2]
    assert "  ↳ resolved-by #2 [facts] (0.30) the answer" in ctx
    assert ctx.index("#1 [") < ctx.index("  ↳ resolved-by #2")


def test_attachment_adjacency_fallback_when_source_unparseable():
    # attached_via present but carries no usable id -> rides with the entry
    # it arrived immediately after.
    payload = {"memories": [
        _mem(1, content="symptom text"),
        _mem(2, content="the answer", attached_via=True),
    ]}
    ctx, ids = hook.build_context(payload, set())
    assert ids == [1, 2]
    assert "  ↳ resolved-by #2" in ctx


# ------------------------------------------------------- selection / dedupe

def test_seen_ids_dropped_and_attachment_of_seen_source_dropped():
    payload = {"memories": [
        _mem(1),
        _mem(2, attached_via={"source_id": 1}),
        _mem(3),
    ]}
    ctx, ids = hook.build_context(payload, {1})
    assert ids == [3]
    assert "#1 [" not in ctx
    assert "resolved-by #2" not in ctx


def test_seen_attachment_not_repeated_under_unseen_source():
    payload = {"memories": [
        _mem(1),
        _mem(2, attached_via={"source_id": 1}),
    ]}
    ctx, ids = hook.build_context(payload, {2})
    assert ids == [1]
    assert "resolved-by #2" not in ctx


def test_top5_limit_attachments_do_not_count():
    mems = [_mem(i) for i in range(1, 8)]
    mems.insert(1, _mem(100, content="rides along", attached_via={"source_id": 1}))
    ctx, ids = hook.build_context({"memories": mems}, set())
    assert ids == [1, 100, 2, 3, 4, 5]
    assert "#6 [" not in ctx
    assert "#7 [" not in ctx


def test_all_seen_yields_no_context():
    payload = {"memories": [_mem(1), _mem(2)]}
    assert hook.build_context(payload, {1, 2}) == (None, [])


# ------------------------------------------------------------------ clipping

def test_legacy_oversize_clipped_on_character_boundary():
    # Cyrillic is 2 bytes/char in UTF-8; the old hook once crashed on a
    # mid-rune byte truncation. Clip must count CHARACTERS, never bytes.
    line = hook.render_memory_line(_mem(7, content="я" * 1500))
    assert "я" * 1200 + "… [full: homelab memory get 7]" in line
    assert "я" * 1201 not in line
    line.encode("utf-8")  # would raise had we byte-sliced mid-rune


def test_content_at_bound_not_clipped():
    line = hook.render_memory_line(_mem(8, content="я" * 1400))
    assert "я" * 1400 in line
    assert "[full:" not in line


# ------------------------------------------------------------------ byte cap

def test_context_hard_capped_at_8000_bytes_drops_whole_entries_from_tail():
    mems = [_mem(i, content="я" * 1300, rank=1.0 - i / 10) for i in range(1, 6)]
    ctx, ids = hook.build_context({"memories": mems}, set())
    assert len(ctx.encode("utf-8")) <= 8000
    assert 1 <= len(ids) < 5                      # something had to be dropped
    assert ids == list(range(1, len(ids) + 1))    # dropped from the TAIL only
    assert ctx.count("я" * 1300) == len(ids)      # every kept entry arrives whole
    for dropped in range(len(ids) + 1, 6):
        assert f"#{dropped} [" not in ctx         # never a partial entry


def test_single_block_over_cap_yields_no_output():
    big = "𝄞" * 1300  # 4-byte rune: 5,200 bytes yet under the 1,400-char clip
    payload = {"memories": [
        _mem(1, content=big),
        _mem(2, content=big, attached_via={"source_id": 1}),
    ]}
    assert hook.build_context(payload, set()) == (None, [])


# ------------------------------------------------------------- main() wiring

def _run_main(monkeypatch, capsys, tmp_path, hook_input, payload=None,
              returncode=0, raw_stdout=None, stderr="", raise_exc=None, calls=None,
              homelab="/usr/local/bin/homelab", api_key="test-key"):
    monkeypatch.setattr(hook, "TMP_DIR", str(tmp_path))
    # Default to a fully wired user (binary present + key minted); tests for the
    # silent preflights override homelab=None / api_key=None explicitly.
    monkeypatch.setattr(hook, "_homelab_path", lambda: homelab)
    monkeypatch.delenv("CLAUDE_MEMORY_API_KEY", raising=False)
    if api_key is None:
        monkeypatch.delenv("MEMORY_API_KEY", raising=False)
    else:
        monkeypatch.setenv("MEMORY_API_KEY", api_key)

    def fake_run(cmd, **kwargs):
        if calls is not None:
            calls.append(cmd)
        if raise_exc is not None:
            raise raise_exc
        out = raw_stdout if raw_stdout is not None else json.dumps(payload or {})
        return types.SimpleNamespace(returncode=returncode, stdout=out, stderr=stderr)

    monkeypatch.setattr(hook.subprocess, "run", fake_run)
    monkeypatch.setattr(hook.sys, "stdin", io.StringIO(json.dumps(hook_input)))
    hook.main()
    return capsys.readouterr().out


def _errors_log(tmp_path):
    p = tmp_path / "memory-recall-errors.log"
    return p.read_text() if p.exists() else ""


def test_main_injects_marks_seen_then_dedupes(monkeypatch, capsys, tmp_path):
    payload = {"memories": [_mem(1), _mem(2)]}
    hin = {"prompt": PROMPT, "session_id": "sess-1"}

    out1 = _run_main(monkeypatch, capsys, tmp_path, hin, payload=payload)
    body = json.loads(out1)["hookSpecificOutput"]
    assert body["hookEventName"] == "UserPromptSubmit"
    assert "#1 [" in body["additionalContext"]
    assert "#2 [" in body["additionalContext"]
    seen = tmp_path / "memory-recall-seen-sess-1.ids"
    assert seen.read_text().split() == ["1", "2"]

    # Same session, same results -> everything already seen -> silence.
    out2 = _run_main(monkeypatch, capsys, tmp_path, hin, payload=payload)
    assert out2 == ""

    # A different session has its own seen-file -> injects again.
    out3 = _run_main(monkeypatch, capsys, tmp_path,
                     {"prompt": PROMPT, "session_id": "sess-2"}, payload=payload)
    assert out3 != ""
    assert (tmp_path / "memory-recall-seen-sess-2.ids").exists()


def test_main_partial_dedupe_appends_new_ids(monkeypatch, capsys, tmp_path):
    seen = tmp_path / "memory-recall-seen-sess-1.ids"
    seen.write_text("1\n")
    out = _run_main(monkeypatch, capsys, tmp_path,
                    {"prompt": PROMPT, "session_id": "sess-1"},
                    payload={"memories": [_mem(1), _mem(2)]})
    ctx = json.loads(out)["hookSpecificOutput"]["additionalContext"]
    assert "#1 [" not in ctx
    assert "#2 [" in ctx
    assert seen.read_text().split() == ["1", "2"]


def test_main_empty_results_completely_silent(monkeypatch, capsys, tmp_path):
    out = _run_main(monkeypatch, capsys, tmp_path,
                    {"prompt": PROMPT, "session_id": "s"},
                    payload={"memories": []})
    assert out == ""
    assert not (tmp_path / "memory-recall-seen-s.ids").exists()
    assert _errors_log(tmp_path) == ""  # empty results are not an error


def test_main_short_prompt_skips_cli_silently(monkeypatch, capsys, tmp_path):
    calls = []
    out = _run_main(monkeypatch, capsys, tmp_path,
                    {"prompt": "hi", "session_id": "s"},
                    payload={"memories": [_mem(1)]}, calls=calls)
    assert out == ""
    assert calls == []
    assert _errors_log(tmp_path) == ""


def test_main_cli_argv_contract(monkeypatch, capsys, tmp_path):
    calls = []
    _run_main(monkeypatch, capsys, tmp_path,
              {"prompt": PROMPT, "session_id": "s"},
              payload={"memories": []}, calls=calls)
    assert calls
    assert calls[0][1:] == ["memory", "recall", PROMPT, "--limit", "10", "--json"]


def test_main_cli_failure_logged_and_silent(monkeypatch, capsys, tmp_path):
    out = _run_main(monkeypatch, capsys, tmp_path,
                    {"prompt": PROMPT, "session_id": "s"},
                    returncode=1, raw_stdout="", stderr="401 unauthorized")
    assert out == ""
    log = _errors_log(tmp_path)
    assert "401 unauthorized" in log
    assert log.startswith("20")  # ISO timestamp prefix


def test_main_timeout_logged_and_silent(monkeypatch, capsys, tmp_path):
    out = _run_main(monkeypatch, capsys, tmp_path,
                    {"prompt": PROMPT, "session_id": "s"},
                    raise_exc=subprocess.TimeoutExpired(cmd="homelab", timeout=6))
    assert out == ""
    assert "timed out" in _errors_log(tmp_path)


def test_main_unparseable_cli_output_logged_and_silent(monkeypatch, capsys, tmp_path):
    out = _run_main(monkeypatch, capsys, tmp_path,
                    {"prompt": PROMPT, "session_id": "s"},
                    raw_stdout="not json at all")
    assert out == ""
    assert "not JSON" in _errors_log(tmp_path)


def test_main_session_id_sanitized_for_filename(monkeypatch, capsys, tmp_path):
    out = _run_main(monkeypatch, capsys, tmp_path,
                    {"prompt": PROMPT, "session_id": "../../evil/sess"},
                    payload={"memories": [_mem(1)]})
    assert out != ""
    files = [p.name for p in tmp_path.iterdir()]
    assert all("/" not in name for name in files)
    assert not (tmp_path.parent.parent / "evil").exists()


# ------------------------------------------------- silent preflights (steady states)

def test_main_no_binary_is_silent_not_an_error(monkeypatch, capsys, tmp_path):
    # A box without the homelab CLI is a steady state, not a per-prompt error.
    calls = []
    out = _run_main(monkeypatch, capsys, tmp_path,
                    {"prompt": PROMPT, "session_id": "s"},
                    payload={"memories": [_mem(1)]}, calls=calls, homelab=None)
    assert out == ""
    assert calls == []
    assert _errors_log(tmp_path) == ""


def test_main_keyless_user_is_silent_not_an_error(monkeypatch, capsys, tmp_path):
    # Documented steady state (docs/architecture/multi-tenancy.md): a wired but
    # keyless user's memory no-ops until an admin mints a key. That must NOT
    # grow the errors log by one line per prompt, forever.
    calls = []
    out = _run_main(monkeypatch, capsys, tmp_path,
                    {"prompt": PROMPT, "session_id": "s"},
                    payload={"memories": [_mem(1)]}, calls=calls, api_key=None)
    assert out == ""
    assert calls == []
    assert _errors_log(tmp_path) == ""


def test_main_code_blob_prompts_skip_cli_silently(monkeypatch, capsys, tmp_path):
    # Parity with the pre-rewrite production hook: pasted code/JSON/XML blobs
    # are not recall queries. All long enough to pass the length gate.
    for blob in ("`kubectl get pods -A` output pasted here",
                 '{"key": "value", "list": [1, 2, 3], "more": true}',
                 "<div>some pasted markup fragment</div>"):
        calls = []
        out = _run_main(monkeypatch, capsys, tmp_path,
                        {"prompt": blob, "session_id": "s"},
                        payload={"memories": [_mem(1)]}, calls=calls)
        assert out == ""
        assert calls == []
    assert _errors_log(tmp_path) == ""


# ------------------------------------------------------- tmp-file housekeeping

def test_stale_seen_files_pruned_when_a_new_session_starts(monkeypatch, capsys, tmp_path):
    stale = tmp_path / "memory-recall-seen-old-sess.ids"
    stale.write_text("9\n")
    old = time.time() - hook.SEEN_TTL_S - 3600
    os.utime(stale, (old, old))
    fresh = tmp_path / "memory-recall-seen-live-sess.ids"
    fresh.write_text("8\n")
    errors = tmp_path / "memory-recall-errors.log"
    errors.write_text("2026-07-01T00:00:00+00:00 old diagnostics\n")
    os.utime(errors, (old, old))

    out = _run_main(monkeypatch, capsys, tmp_path,
                    {"prompt": PROMPT, "session_id": "new-sess"},
                    payload={"memories": [_mem(1)]})
    assert out != ""
    assert not stale.exists()   # idle past the TTL -> pruned
    assert fresh.exists()       # recently active session survives
    assert errors.exists()      # prune never touches the errors log
    assert (tmp_path / "memory-recall-seen-new-sess.ids").exists()


def test_errors_log_rotates_at_size_cap(monkeypatch, tmp_path):
    monkeypatch.setattr(hook, "TMP_DIR", str(tmp_path))
    log = tmp_path / "memory-recall-errors.log"
    log.write_text("x" * (hook.ERRORS_LOG_MAX_BYTES + 1))
    hook.log_error("fresh line after rotation")
    rotated = tmp_path / "memory-recall-errors.log.1"
    assert rotated.exists()
    assert rotated.read_text().startswith("x")
    text = log.read_text()
    assert "fresh line after rotation" in text
    assert len(text) < 1000     # the live log restarted small
