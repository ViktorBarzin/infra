"""Tests for the MyProtein price watcher.

Run: python3 -m pytest stacks/myprotein-watch/test_check.py -q
"""

import json

import pytest

import check


def variant(title, flavour, amount, price, rrp, sku, in_stock=True):
    """Build one variant object in MyProtein's real embedded-JSON shape."""
    return {
        "title": title,
        "sku": sku,
        "inStock": in_stock,
        "choices": [
            {"optionKey": "Flavour", "key": flavour, "title": flavour},
            {"optionKey": "Amount", "key": amount, "title": amount},
        ],
        "price": {
            "price": {"currency": "GBP", "amount": price, "displayValue": f"£{price}"},
            "rrp": {"currency": "GBP", "amount": rrp, "displayValue": f"£{rrp}"},
        },
    }


def page(*variants):
    """Embed variants in page noise, the way the real product page does."""
    body = ",".join(json.dumps(v) for v in variants)
    return f'<html><body><script>window.__DATA__={{"variants":[{body}]}}</script></body></html>'


VANILLA_90 = variant(
    "Impact Whey Protein Powder - 2.7kg - 90servings - Vanilla",
    "Vanilla", "2.7kg - 90servings", "97.49", "97.49", 17712192,
)
CC_COLLAGEN_90 = variant(
    "Impact Whey Protein Powder - 2340g - 90servings - Cookies and Cream (+Collagen)",
    "Cookies and Cream (+Collagen)", "2340g - 90servings", "61.99", "83.49", 18000001,
)
CRUMBLE_SHAKE_90 = variant(
    "Impact Whey Protein Powder - 2700g - 90servings - Cookie Crumble (Milkshake)",
    "Cookie Crumble (Milkshake)", "2700g - 90servings", "71.49", "96.49", 18000002,
)
STRAWBERRY_90 = variant(
    "Impact Whey Protein Powder - 2.7kg - 90servings - Strawberry Cream",
    "Strawberry Cream", "2.7kg - 90servings", "97.49", "97.49", 18000003,
)


# --- parsing -----------------------------------------------------------------

def test_parses_variants_out_of_page_noise():
    got = check.parse_variants(page(VANILLA_90, STRAWBERRY_90))
    assert [v.sku for v in got] == [17712192, 18000003]


def test_extracts_flavour_servings_and_price():
    v = check.parse_variants(page(VANILLA_90))[0]
    assert v.flavour == "Vanilla"
    assert v.servings == 90
    assert v.price == pytest.approx(97.49)
    assert v.rrp == pytest.approx(97.49)
    assert v.in_stock is True


def test_price_per_serving():
    v = check.parse_variants(page(CC_COLLAGEN_90))[0]
    assert v.price_per_serving == pytest.approx(61.99 / 90)


def test_line_is_derived_from_the_flavour_suffix():
    lines = {v.flavour: v.line for v in check.parse_variants(
        page(VANILLA_90, CC_COLLAGEN_90, CRUMBLE_SHAKE_90))}
    assert lines["Vanilla"] == "Original"
    assert lines["Cookies and Cream (+Collagen)"] == "Collagen"
    assert lines["Cookie Crumble (Milkshake)"] == "Milkshake"


def test_base_flavour_strips_the_line_suffix():
    v = check.parse_variants(page(CC_COLLAGEN_90))[0]
    assert v.base_flavour == "Cookies and Cream"


def test_duplicate_skus_are_collapsed():
    got = check.parse_variants(page(VANILLA_90, VANILLA_90))
    assert len(got) == 1


def test_malformed_variant_is_skipped_not_fatal():
    html = page(VANILLA_90).replace('"servings"', '"servings')  # no-op guard
    broken = '<script>{"title":"Impact Whey Protein Powder - broken</script>' + html
    assert [v.sku for v in check.parse_variants(broken)] == [17712192]


# --- deal detection ----------------------------------------------------------

WATCH = ["Cookies and Cream", "Cookie Crumble", "Banana", "Strawberry Cream"]


def test_deal_fires_when_watched_flavour_is_under_threshold():
    cheap = variant(
        "Impact Whey Protein Powder - 2.7kg - 90servings - Strawberry Cream",
        "Strawberry Cream", "2.7kg - 90servings", "55.00", "97.49", 18000003,
    )
    deals = check.find_deals(check.parse_variants(page(cheap)), WATCH, 0.65)
    assert [d.sku for d in deals] == [18000003]


def test_no_deal_when_price_is_above_threshold():
    assert check.find_deals(check.parse_variants(page(STRAWBERRY_90)), WATCH, 0.65) == []


def test_unwatched_flavour_never_triggers_even_when_cheap():
    cheap = variant(
        "Impact Whey Protein Powder - 2.7kg - 90servings - Vanilla",
        "Vanilla", "2.7kg - 90servings", "10.00", "97.49", 17712192,
    )
    assert check.find_deals(check.parse_variants(page(cheap)), WATCH, 0.65) == []


def test_collagen_line_is_excluded_from_deals():
    """Half of a +Collagen serving is collagen, not whey — it is not the
    same product per pound, so it must not trip the per-serving trigger."""
    cheap = variant(
        "Impact Whey Protein Powder - 2340g - 90servings - Cookies and Cream (+Collagen)",
        "Cookies and Cream (+Collagen)", "2340g - 90servings", "20.00", "83.49", 18000001,
    )
    assert check.find_deals(check.parse_variants(page(cheap)), WATCH, 0.65) == []


def test_out_of_stock_never_triggers():
    oos = variant(
        "Impact Whey Protein Powder - 2.7kg - 90servings - Strawberry Cream",
        "Strawberry Cream", "2.7kg - 90servings", "40.00", "97.49", 18000003,
        in_stock=False,
    )
    assert check.find_deals(check.parse_variants(page(oos)), WATCH, 0.65) == []


def test_banana_watch_term_matches_chocolate_banana():
    cheap = variant(
        "Impact Whey Protein Powder - 2.61kg - 90servings - Chocolate Banana",
        "Chocolate Banana", "2.61kg - 90servings", "55.00", "97.49", 18000004,
    )
    deals = check.find_deals(check.parse_variants(page(cheap)), WATCH, 0.65)
    assert [d.base_flavour for d in deals] == ["Chocolate Banana"]


# --- the discontinued-flavour comeback --------------------------------------

def test_cookies_and_cream_original_return_is_detected():
    back = variant(
        "Impact Whey Protein Powder - 2.7kg - 90servings - Cookies and Cream",
        "Cookies and Cream", "2.7kg - 90servings", "97.49", "97.49", 18000005,
    )
    got = check.find_returns(check.parse_variants(page(back, VANILLA_90)))
    assert [v.sku for v in got] == [18000005]


def test_collagen_cookies_and_cream_is_not_a_return():
    assert check.find_returns(check.parse_variants(page(CC_COLLAGEN_90))) == []


# --- de-duplication across runs ---------------------------------------------

def test_same_deal_is_not_re_alerted_on_the_next_run():
    cheap = variant(
        "Impact Whey Protein Powder - 2.7kg - 90servings - Strawberry Cream",
        "Strawberry Cream", "2.7kg - 90servings", "55.00", "97.49", 18000003,
    )
    variants = check.parse_variants(page(cheap))
    alerts, state = check.decide(variants, {}, WATCH, 0.65)
    assert len(alerts) == 1
    again, _ = check.decide(variants, state, WATCH, 0.65)
    assert again == []


def test_a_further_price_drop_re_alerts():
    v1 = check.parse_variants(page(variant(
        "Impact Whey Protein Powder - 2.7kg - 90servings - Strawberry Cream",
        "Strawberry Cream", "2.7kg - 90servings", "55.00", "97.49", 18000003)))
    _, state = check.decide(v1, {}, WATCH, 0.65)

    v2 = check.parse_variants(page(variant(
        "Impact Whey Protein Powder - 2.7kg - 90servings - Strawberry Cream",
        "Strawberry Cream", "2.7kg - 90servings", "48.00", "97.49", 18000003)))
    alerts, _ = check.decide(v2, state, WATCH, 0.65)
    assert len(alerts) == 1


def test_price_going_back_up_clears_state_so_the_next_sale_alerts():
    sale = check.parse_variants(page(variant(
        "Impact Whey Protein Powder - 2.7kg - 90servings - Strawberry Cream",
        "Strawberry Cream", "2.7kg - 90servings", "55.00", "97.49", 18000003)))
    _, state = check.decide(sale, {}, WATCH, 0.65)

    full = check.parse_variants(page(STRAWBERRY_90))
    _, state = check.decide(full, state, WATCH, 0.65)

    alerts, _ = check.decide(sale, state, WATCH, 0.65)
    assert len(alerts) == 1


# --- message ----------------------------------------------------------------

def test_configmap_patch_body_round_trips_the_state():
    """State lives in a ConfigMap so the job needs no persistent volume."""
    state = {"18000003": 55.0, "return:18000005": 97.49}
    body = check.configmap_patch_body(state)
    assert json.loads(body["data"]["state.json"]) == state


def test_configmap_state_is_read_back_out_of_an_api_response():
    api_response = {"data": {"state.json": json.dumps({"18000003": 55.0})}}
    assert check.state_from_configmap(api_response) == {"18000003": 55.0}


def test_missing_or_empty_configmap_reads_as_empty_state():
    assert check.state_from_configmap({}) == {}
    assert check.state_from_configmap({"data": {}}) == {}
    assert check.state_from_configmap({"data": {"state.json": "not json"}}) == {}


def test_slack_message_names_flavour_size_price_and_saving():
    cheap = variant(
        "Impact Whey Protein Powder - 2.7kg - 90servings - Strawberry Cream",
        "Strawberry Cream", "2.7kg - 90servings", "55.00", "97.49", 18000003,
    )
    alerts, _ = check.decide(check.parse_variants(page(cheap)), {}, WATCH, 0.65)
    text = check.format_slack(alerts)["text"]
    assert "Strawberry Cream" in text
    assert "90 servings" in text
    assert "£55.00" in text
    assert "44%" in text          # 55.00 off an rrp of 97.49
    assert "£0.61" in text        # per serving
