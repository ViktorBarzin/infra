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


# --- select_offender: recycle the biggest over-budget tenant under pressure ---
def test_no_action_when_free_at_or_above_floor():
    used = {("immich", "immich-ml-x"): 6750}
    budgets = {("immich", "immich-ml-x"): 2500}
    assert w.select_offender(used, budgets, free_mib=4090, floor_mib=1536) is None


def test_immich_ml_is_the_sacrificial_target_under_pressure():
    # immich-ml over its (sacrificial) budget, llama-swap within budget:
    # the watchdog must pick immich-ml, never llama-swap mid-inference.
    used = {("immich", "immich-ml-x"): 6750, ("llama-cpp", "llama-swap-y"): 4400}
    budgets = {("immich", "immich-ml-x"): 2500, ("llama-cpp", "llama-swap-y"): 4500}
    res = w.select_offender(used, budgets, free_mib=900, floor_mib=1536)
    assert res is not None
    _, key, _, _ = res
    assert key == ("immich", "immich-ml-x")


def test_no_offender_when_all_within_budget():
    used = {("immich", "immich-ml-x"): 2000}
    budgets = {("immich", "immich-ml-x"): 2500}
    assert w.select_offender(used, budgets, free_mib=900, floor_mib=1536) is None


def test_biggest_overshoot_wins_when_multiple_over():
    used = {("a", "p1"): 3000, ("b", "p2"): 5000}
    budgets = {("a", "p1"): 1000, ("b", "p2"): 2000}  # overshoot 2000 vs 3000
    res = w.select_offender(used, budgets, free_mib=100, floor_mib=1536)
    _, key, _, _ = res
    assert key == ("b", "p2")
