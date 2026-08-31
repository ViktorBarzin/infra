"""Unit tests for the GPU VRAM watchdog pure functions (ADR-0016).

Run: cd stacks/nvidia/modules/nvidia && python3 -m pytest watchdog_test.py -q
Importing watchdog must have NO side effects (no env reads, no SA-token file),
so these run anywhere.
"""
import watchdog as w


# --- parse_gpumem_quantity: the int("5k") bug (infra#80 workstream C) ---------
def test_parse_plain_integers():
    assert w.parse_gpumem_quantity("1800") == 1800
    assert w.parse_gpumem_quantity("2300") == 2300
    assert w.parse_gpumem_quantity("1500") == 1500


def test_parse_canonical_si_suffixes_the_bug():
    # Kubernetes canonicalises round thousands: 5000 -> "5k" etc. int("5k")
    # threw ValueError and silently dropped these tenants from the offender set.
    assert w.parse_gpumem_quantity("5k") == 5000
    assert w.parse_gpumem_quantity("3k") == 3000
    assert w.parse_gpumem_quantity("2k") == 2000
    assert w.parse_gpumem_quantity("14k") == 14000


def test_parse_binary_suffix_for_robustness():
    assert w.parse_gpumem_quantity("1Ki") == 1024
    assert w.parse_gpumem_quantity("2Mi") == 2 * 1024 * 1024


def test_parse_malformed_returns_none():
    assert w.parse_gpumem_quantity("") is None
    assert w.parse_gpumem_quantity("abc") is None
    assert w.parse_gpumem_quantity(None) is None


# --- select_offender: pick the biggest over-budget tenant ---------------------
# Whether to act at all is contention_reason()'s job now (2026-08-31), so
# select_offender no longer takes free/floor: it answers "who is over contract".
def test_immich_ml_is_the_sacrificial_target():
    # immich-ml over its (sacrificial) budget, llama-swap within budget:
    # the watchdog must pick immich-ml, never llama-swap mid-inference.
    used = {("immich", "immich-ml-x"): 6750, ("llama-cpp", "llama-swap-y"): 4400}
    budgets = {("immich", "immich-ml-x"): 2500, ("llama-cpp", "llama-swap-y"): 4500}
    res = w.select_offender(used, budgets)
    assert res is not None
    _, key, _, _ = res
    assert key == ("immich", "immich-ml-x")


def test_no_offender_when_all_within_budget():
    used = {("immich", "immich-ml-x"): 2000}
    budgets = {("immich", "immich-ml-x"): 2500}
    assert w.select_offender(used, budgets) is None


def test_biggest_overshoot_wins_when_multiple_over():
    used = {("a", "p1"): 3000, ("b", "p2"): 5000}
    budgets = {("a", "p1"): 1000, ("b", "p2"): 2000}  # overshoot 2000 vs 3000
    res = w.select_offender(used, budgets)
    _, key, _, _ = res
    assert key == ("b", "p2")


def test_seatless_tenant_is_never_an_offender():
    # llama-swap declares no gpumem by design (2026-08-31). Using 7000 MiB with
    # no budget must not make it a recycle target — only declarers have a
    # contract to breach.
    used = {("llama-cpp", "llama-swap-y"): 7000, ("immich", "immich-ml-x"): 2600}
    budgets = {("immich", "immich-ml-x"): 2500}
    _, key, _, _ = w.select_offender(used, budgets)
    assert key == ("immich", "immich-ml-x")


# --- contention_reason: act on evidence someone is blocked, not on free space -
# A free-space trigger cannot tell "retained garbage" from "legitimately large
# job", so a big immich batch would be recycled, retried and recycled forever.
def test_holds_when_card_has_slack_and_nobody_is_blocked():
    assert w.contention_reason(
        free_mib=10500, floor_mib=1536, pending=set(), cuda_oom=set()
    ) is None


def test_holds_even_when_a_tenant_is_bursting_into_real_slack():
    # 5478 MiB of arena on an otherwise-idle card, nothing else waiting.
    assert w.contention_reason(
        free_mib=7061, floor_mib=1536, pending=set(), cuda_oom=set()
    ) is None


def test_acts_when_a_declaring_tenant_is_pending_on_gpumem():
    r = w.contention_reason(
        free_mib=9000, floor_mib=1536, pending={"immich/immich-worker-z"}, cuda_oom=set()
    )
    assert r is not None and "pending" in r and "immich-worker-z" in r


def test_acts_when_a_seatless_tenant_hits_cuda_oom():
    # llama-swap and frigate have no Pending to show: they fail inside a running
    # pod. This is the signal that covers them.
    r = w.contention_reason(
        free_mib=600, floor_mib=1536, pending=set(), cuda_oom={"llama-cpp"}
    )
    assert r is not None and "cuda-oom" in r and "llama-cpp" in r


def test_emergency_floor_is_the_backstop_when_no_signal_arrives():
    r = w.contention_reason(
        free_mib=400, floor_mib=1536, pending=set(), cuda_oom=set()
    )
    assert r is not None and "floor" in r


def test_pending_wins_over_floor_in_the_reason_text():
    r = w.contention_reason(
        free_mib=100, floor_mib=1536, pending={"a/b"}, cuda_oom={"c"}
    )
    assert "pending" in r


# --- parse_pending_gpumem: read Pending-on-gpumem out of a pod list ----------
def _pod(ns, name, phase, msg=None):
    conds = []
    if msg is not None:
        conds = [{"type": "PodScheduled", "status": "False", "reason": "Unschedulable",
                  "message": msg}]
    return {"metadata": {"namespace": ns, "name": name},
            "status": {"phase": phase, "conditions": conds}}


def test_pending_on_our_resource_is_detected():
    payload = {"items": [
        _pod("immich", "w1", "Pending",
             "0/6 nodes are available: 1 Insufficient viktorbarzin.me/gpumem."),
    ]}
    assert w.parse_pending_gpumem(payload, "viktorbarzin.me/gpumem") == {"immich/w1"}


def test_pending_for_other_reasons_is_ignored():
    payload = {"items": [
        _pod("x", "p", "Pending", "0/6 nodes are available: 6 Insufficient cpu."),
        _pod("y", "q", "Running"),
    ]}
    assert w.parse_pending_gpumem(payload, "viktorbarzin.me/gpumem") == set()


def test_pending_detection_survives_missing_fields():
    payload = {"items": [{"metadata": {}, "status": {}}]}
    assert w.parse_pending_gpumem(payload, "viktorbarzin.me/gpumem") == set()


# --- parse_cuda_oom_alerts: read the Loki-sourced alert from Alertmanager ----
def test_active_cuda_oom_alert_yields_its_namespace():
    payload = [
        {"labels": {"alertname": "GpuCudaOom", "namespace": "llama-cpp"},
         "status": {"state": "active"}},
    ]
    assert w.parse_cuda_oom_alerts(payload, "GpuCudaOom") == {"llama-cpp"}


def test_suppressed_and_resolved_alerts_are_ignored():
    payload = [
        {"labels": {"alertname": "GpuCudaOom", "namespace": "a"},
         "status": {"state": "suppressed"}},
        {"labels": {"alertname": "GpuCudaOom", "namespace": "b"},
         "status": {"state": "resolved"}},
    ]
    assert w.parse_cuda_oom_alerts(payload, "GpuCudaOom") == set()


def test_other_alertnames_are_ignored():
    payload = [
        {"labels": {"alertname": "SomethingElse", "namespace": "z"},
         "status": {"state": "active"}},
    ]
    assert w.parse_cuda_oom_alerts(payload, "GpuCudaOom") == set()


def test_alert_without_namespace_label_is_ignored():
    payload = [{"labels": {"alertname": "GpuCudaOom"}, "status": {"state": "active"}}]
    assert w.parse_cuda_oom_alerts(payload, "GpuCudaOom") == set()
