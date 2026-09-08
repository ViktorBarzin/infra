"""Unit tests for the k8s-upgrade compat gate (compat-gate.py).

Run: pytest stacks/k8s-version-upgrade/scripts/test_compat_gate.py

The module filename has a hyphen so it is loaded via importlib rather than a
plain import. kget() (kubectl) is monkeypatched so the addon checks read a
controlled "running" image without a live cluster.
"""
import importlib.util
import pathlib

HERE = pathlib.Path(__file__).parent
_spec = importlib.util.spec_from_file_location("compat_gate", HERE / "compat-gate.py")
cg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cg)

# Single-addon matrices keep each test's intent obvious.
ESO_MATRIX = {
    "addons": [{
        "name": "external-secrets",
        "namespace": "external-secrets",
        "kind": "deployment",
        "resource": "external-secrets",
        "image_re": r"external-secrets:v(\d+\.\d+)",
        "max_k8s": {"0.12": "1.31", "2.0": "1.35"},
    }]
}
CALICO_MATRIX = {
    "addons": [{
        "name": "calico",
        "namespace": "calico-system",
        "kind": "daemonset",
        "resource": "calico-node",
        "image_re": r"node:v(\d+\.\d+)",
        "max_k8s": {"3.26": "1.28", "3.30": "1.35", "3.32": "1.36"},
    }]
}


def _img(monkeypatch, image):
    monkeypatch.setattr(cg, "kget", lambda args: image)


def test_minor_jump_blocks_when_addon_ceiling_below_target(monkeypatch):
    # running 1.34, target 1.35: ESO 0.12 ceiling 1.31 < 1.35 -> block.
    _img(monkeypatch, "external-secrets/external-secrets:v0.12.1")
    reasons = cg.check_addons(ESO_MATRIX, (1, 35), (1, 34))
    assert any("external-secrets" in r for r in reasons), reasons


def test_patch_within_running_minor_not_blocked(monkeypatch):
    # running 1.34, target 1.34.x patch: ceiling 1.31 < 1.34, BUT the cluster
    # already runs ESO 0.12 on 1.34, so a patch is empirically safe -> no block.
    _img(monkeypatch, "external-secrets/external-secrets:v0.12.1")
    reasons = cg.check_addons(ESO_MATRIX, (1, 34), (1, 34))
    assert reasons == [], reasons


def test_target_below_running_not_blocked(monkeypatch):
    # defensive: a target minor below running is never addon-blocked.
    _img(monkeypatch, "external-secrets/external-secrets:v0.12.1")
    reasons = cg.check_addons(ESO_MATRIX, (1, 33), (1, 34))
    assert reasons == [], reasons


def test_same_minor_addon_supports_target(monkeypatch):
    # running 1.34, target 1.35, calico 3.30 supports 1.35 -> no block.
    _img(monkeypatch, "quay.io/calico/node:v3.30.7")
    reasons = cg.check_addons(CALICO_MATRIX, (1, 35), (1, 34))
    assert reasons == [], reasons


def test_unreadable_addon_failsafe_on_minor_jump(monkeypatch):
    # can't read running version on a real minor jump -> fail safe (block).
    _img(monkeypatch, "")
    reasons = cg.check_addons(ESO_MATRIX, (1, 35), (1, 34))
    assert any("upgrade blind" in r or "could not read" in r for r in reasons), reasons


def test_unreadable_addon_ignored_on_patch(monkeypatch):
    # patch within running minor: addon checks are skipped entirely, so an
    # unreadable image must NOT fail-safe-block a legitimate patch.
    _img(monkeypatch, "")
    reasons = cg.check_addons(ESO_MATRIX, (1, 34), (1, 34))
    assert reasons == [], reasons


def test_running_minor_env_override(monkeypatch):
    monkeypatch.setenv("RUNNING_K8S", "1.34.9")
    assert cg.running_minor() == (1, 34)


def test_running_minor_from_kubectl(monkeypatch):
    monkeypatch.delenv("RUNNING_K8S", raising=False)
    # oldest kubelet wins (mirrors the detector): node2 on 1.33 is the floor.
    monkeypatch.setattr(cg, "kget", lambda args: "v1.34.9\nv1.33.5\nv1.34.9")
    assert cg.running_minor() == (1, 33)


# --- block classification: actionable / waiting-upstream / pinned ----------
# A block is ACTIONABLE if a newer addon version in the matrix supports the
# target (we can upgrade to clear it), WAITING if no released version supports
# the target yet (only upstream can clear it), or PINNED if a version exists but
# we deliberately hold the addon. Held (waiting|pinned) is quiet; actionable
# alerts.
KYVERNO_MATRIX = {
    "addons": [{
        "name": "kyverno",
        "namespace": "kyverno",
        "kind": "deployment",
        "resource": "kyverno-admission-controller",
        "image_re": r"kyverno:v(\d+\.\d+)",
        "max_k8s": {"1.16": "1.34", "1.18": "1.35"},
    }]
}
GPU_MATRIX = {
    "addons": [{
        "name": "gpu-operator",
        "namespace": "nvidia",
        "kind": "deployment",
        "resource": "gpu-operator",
        "image_re": r"gpu-operator:v(\d+\.\d+)",
        "max_k8s": {"25.10": "1.35", "26.3": "1.36"},
        "pinned": True,
        "pin_reason": "needs newer NVIDIA driver + Ubuntu release",
    }]
}


def test_actionable_when_higher_version_supports_target(monkeypatch):
    # calico 3.30 (ceiling 1.35), target 1.36, matrix has 3.32 -> 1.36:
    # upgrading calico WOULD clear it -> ACTIONABLE, with a remediation hint.
    _img(monkeypatch, "quay.io/calico/node:v3.30.7")
    reasons = cg.check_addons(CALICO_MATRIX, (1, 36), (1, 35))
    assert len(reasons) == 1, reasons
    assert reasons[0].startswith("[ACTIONABLE]"), reasons
    assert "3.32" in reasons[0] and "calico" in reasons[0]


def test_waiting_when_no_version_supports_target(monkeypatch):
    # kyverno 1.18 is the matrix ceiling (k8s 1.35); target 1.36 has NO
    # supporting version -> WAITING on upstream (nothing to upgrade to).
    _img(monkeypatch, "kyverno/kyverno:v1.18.1")
    reasons = cg.check_addons(KYVERNO_MATRIX, (1, 36), (1, 35))
    assert len(reasons) == 1, reasons
    assert reasons[0].startswith("[WAITING]"), reasons
    assert "kyverno" in reasons[0]


def test_pinned_addon_is_held_not_actionable(monkeypatch):
    # gpu-operator 25.10, target 1.36; 26.3 supports 1.36 BUT the entry is
    # pinned -> classified PINNED (held), never ACTIONABLE.
    _img(monkeypatch, "nvcr.io/nvidia/gpu-operator:v25.10.0")
    reasons = cg.check_addons(GPU_MATRIX, (1, 36), (1, 35))
    assert len(reasons) == 1, reasons
    assert reasons[0].startswith("[PINNED]"), reasons
    assert "gpu-operator" in reasons[0]


def test_unreadable_addon_tagged_actionable(monkeypatch):
    # fail-safe block on an unreadable image is ACTIONABLE (a human must look).
    _img(monkeypatch, "")
    reasons = cg.check_addons(ESO_MATRIX, (1, 35), (1, 34))
    assert reasons and reasons[0].startswith("[ACTIONABLE]"), reasons


def test_existing_reasons_are_tagged(monkeypatch):
    # the legacy "ceiling below target, newer version exists" case is ACTIONABLE.
    _img(monkeypatch, "external-secrets/external-secrets:v0.12.1")
    reasons = cg.check_addons(ESO_MATRIX, (1, 35), (1, 34))
    assert reasons[0].startswith("[ACTIONABLE]"), reasons


def test_held_reason_classifier():
    assert cg.held_reason("[WAITING] x")
    assert cg.held_reason("[PINNED] x")
    assert not cg.held_reason("[ACTIONABLE] x")
    assert not cg.held_reason("untagged")


def test_exit_code_mapping():
    assert cg.exit_code([]) == 0
    assert cg.exit_code(["[ACTIONABLE] x"]) == 2
    assert cg.exit_code(["[WAITING] x"]) == 4
    assert cg.exit_code(["[PINNED] x"]) == 4
    # held wins on a mix: an upstream/pinned wait can't be cleared by acting now
    assert cg.exit_code(["[ACTIONABLE] x", "[WAITING] y"]) == 4


def test_real_matrix_136_is_held(monkeypatch):
    """Regression guard on the SHIPPED addon-compat.json: at today's running
    versions a 1.36 jump must be HELD (exit 4) — calico ACTIONABLE (3.32 in the
    matrix), ESO+kyverno WAITING (no 1.36 release), gpu-operator PINNED. Catches
    a matrix edit that silently turns the quiet held state into a nightly alert."""
    import json as _json
    matrix = _json.loads((HERE / "addon-compat.json").read_text())
    running_imgs = {
        "calico-system": "quay.io/calico/node:v3.30.7",
        "external-secrets": "ghcr.io/external-secrets/external-secrets:v2.6.0",
        "kyverno": "ghcr.io/kyverno/kyverno:v1.18.1",
        "nvidia": "nvcr.io/nvidia/gpu-operator:v25.10.0",
    }

    def fake_kget(args):
        ns = args[args.index("-n") + 1] if "-n" in args else ""
        return running_imgs.get(ns, "")

    monkeypatch.setattr(cg, "kget", fake_kget)
    reasons = cg.check_addons(matrix, (1, 36), (1, 35))
    pick = lambda name: next(r for r in reasons if name in r)
    assert pick("calico").startswith("[ACTIONABLE]"), reasons
    assert pick("external-secrets").startswith("[WAITING]"), reasons
    assert pick("kyverno").startswith("[WAITING]"), reasons
    assert pick("gpu-operator").startswith("[PINNED]"), reasons
    assert cg.exit_code(reasons) == 4  # held wins
