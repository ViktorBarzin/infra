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
