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


# --- protein per serving ------------------------------------------------------
# Not every line puts the same protein in a serving, so £/serving is not a
# like-for-like price. All four figures below are the product page's own claims.

def test_original_line_is_23g_per_serving():
    v = check.parse_variants(page(VANILLA_90))[0]
    assert v.whey_g_per_serving == pytest.approx(23.0)


def test_milkshake_line_is_20g_per_serving():
    v = check.parse_variants(page(CRUMBLE_SHAKE_90))[0]
    assert v.whey_g_per_serving == pytest.approx(20.0)


def test_collagen_line_counts_only_the_whey_half():
    """Label says 20g; 10g of it is collagen peptides, which do not count
    toward muscle protein synthesis."""
    v = check.parse_variants(page(CC_COLLAGEN_90))[0]
    assert v.whey_g_per_serving == pytest.approx(10.0)


def test_crunchy_pieces_flavours_are_20g_even_on_the_original_line():
    """The biscuit pieces displace protein — these print 20g on-pack, not 23g,
    and one of them (Cookie Crumble Crunch) is on the watchlist."""
    v = check.parse_variants(page(variant(
        "Impact Whey Protein Powder - 900G - 30servings - Cookie Crumble Crunch with Crunchy Biscuit Pieces",
        "Cookie Crumble Crunch with Crunchy Biscuit Pieces", "900G - 30servings",
        "34.99", "34.99", 18000009)))[0]
    assert v.line == "Original"
    assert v.whey_g_per_serving == pytest.approx(20.0)


def test_price_per_kg_protein_normalises_across_lines():
    orig = check.parse_variants(page(VANILLA_90))[0]        # £97.49 / 90 / 23g
    assert orig.price_per_kg_protein == pytest.approx(97.49 / (90 * 23) * 1000)


# --- deal detection ----------------------------------------------------------

WATCH = ["Cookies and Cream", "Cookie Crumble", "Banana", "Strawberry Cream"]


def test_deal_fires_when_watched_flavour_is_under_threshold():
    cheap = variant(
        "Impact Whey Protein Powder - 2.7kg - 90servings - Strawberry Cream",
        "Strawberry Cream", "2.7kg - 90servings", "55.00", "97.49", 18000003,
    )
    deals = check.find_deals(check.parse_variants(page(cheap)), WATCH, 28.0)
    assert [d.sku for d in deals] == [18000003]


def test_no_deal_when_price_is_above_threshold():
    assert check.find_deals(check.parse_variants(page(STRAWBERRY_90)), WATCH, 28.0) == []


def test_unwatched_flavour_never_triggers_even_when_cheap():
    cheap = variant(
        "Impact Whey Protein Powder - 2.7kg - 90servings - Vanilla",
        "Vanilla", "2.7kg - 90servings", "10.00", "97.49", 17712192,
    )
    assert check.find_deals(check.parse_variants(page(cheap)), WATCH, 28.0) == []


def test_collagen_line_is_excluded_from_deals():
    """Half of a +Collagen serving is collagen, not whey — it is not the
    same product per pound, so it must not trip the per-serving trigger."""
    cheap = variant(
        "Impact Whey Protein Powder - 2340g - 90servings - Cookies and Cream (+Collagen)",
        "Cookies and Cream (+Collagen)", "2340g - 90servings", "20.00", "83.49", 18000001,
    )
    assert check.find_deals(check.parse_variants(page(cheap)), WATCH, 28.0) == []


def test_out_of_stock_never_triggers():
    oos = variant(
        "Impact Whey Protein Powder - 2.7kg - 90servings - Strawberry Cream",
        "Strawberry Cream", "2.7kg - 90servings", "40.00", "97.49", 18000003,
        in_stock=False,
    )
    assert check.find_deals(check.parse_variants(page(oos)), WATCH, 28.0) == []


def test_banana_watch_term_matches_chocolate_banana():
    cheap = variant(
        "Impact Whey Protein Powder - 2.61kg - 90servings - Chocolate Banana",
        "Chocolate Banana", "2.61kg - 90servings", "55.00", "97.49", 18000004,
    )
    deals = check.find_deals(check.parse_variants(page(cheap)), WATCH, 28.0)
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

def kinds(alerts, kind):
    """Alerts of one kind. Several triggers can fire on the same run, so a
    test about one of them must not assert on the total."""
    return [a for a in alerts if a.kind == kind]


def test_same_deal_is_not_re_alerted_on_the_next_run():
    cheap = variant(
        "Impact Whey Protein Powder - 2.7kg - 90servings - Strawberry Cream",
        "Strawberry Cream", "2.7kg - 90servings", "55.00", "97.49", 18000003,
    )
    variants = check.parse_variants(page(cheap))
    alerts, state = check.decide(variants, {}, WATCH, 28.0)
    assert len(kinds(alerts, "deal")) == 1
    again, _ = check.decide(variants, state, WATCH, 28.0)
    assert kinds(again, "deal") == []


def test_a_further_price_drop_re_alerts():
    v1 = check.parse_variants(page(variant(
        "Impact Whey Protein Powder - 2.7kg - 90servings - Strawberry Cream",
        "Strawberry Cream", "2.7kg - 90servings", "55.00", "97.49", 18000003)))
    _, state = check.decide(v1, {}, WATCH, 28.0)

    v2 = check.parse_variants(page(variant(
        "Impact Whey Protein Powder - 2.7kg - 90servings - Strawberry Cream",
        "Strawberry Cream", "2.7kg - 90servings", "48.00", "97.49", 18000003)))
    alerts, _ = check.decide(v2, state, WATCH, 28.0)
    assert len(kinds(alerts, "deal")) == 1


def test_price_going_back_up_clears_state_so_the_next_sale_alerts():
    sale = check.parse_variants(page(variant(
        "Impact Whey Protein Powder - 2.7kg - 90servings - Strawberry Cream",
        "Strawberry Cream", "2.7kg - 90servings", "55.00", "97.49", 18000003)))
    _, state = check.decide(sale, {}, WATCH, 28.0)

    full = check.parse_variants(page(STRAWBERRY_90))
    _, state = check.decide(full, state, WATCH, 28.0)

    alerts, _ = check.decide(sale, state, WATCH, 28.0)
    assert len(kinds(alerts, "deal")) == 1


# --- cheapest-ever ("new low") ----------------------------------------------
# Self-calibrating: it ignores MyProtein's RRP entirely and compares a variant
# only against its own history, so RRP drift and pack-size changes cannot fool it.

def at(price, sku=18000003, servings="2.7kg - 90servings"):
    return check.parse_variants(page(variant(
        "Impact Whey Protein Powder - 2.7kg - 90servings - Strawberry Cream",
        "Strawberry Cream", servings, price, "97.49", sku)))


def test_first_sighting_seeds_the_low_without_alerting():
    alerts, state = check.decide(at("90.00"), {}, WATCH, 28.0)
    assert kinds(alerts, "low") == []
    assert state["low:18000003"] == pytest.approx(90.00 / (90 * 23) * 1000)


def test_a_new_low_alerts():
    _, state = check.decide(at("90.00"), {}, WATCH, 28.0)
    alerts, state = check.decide(at("80.00"), state, WATCH, 28.0)
    assert len(kinds(alerts, "low")) == 1
    assert state["low:18000003"] == pytest.approx(80.00 / (90 * 23) * 1000)


def test_a_price_above_the_recorded_low_does_not_alert():
    _, state = check.decide(at("80.00"), {}, WATCH, 28.0)
    alerts, _ = check.decide(at("90.00"), state, WATCH, 28.0)
    assert kinds(alerts, "low") == []


def test_a_trivially_lower_price_is_not_worth_an_alert():
    """A 0.1% dip is noise, not news — record it, stay quiet."""
    _, state = check.decide(at("90.00"), {}, WATCH, 28.0)
    alerts, state = check.decide(at("89.95"), state, WATCH, 28.0)
    assert kinds(alerts, "low") == []
    assert state["low:18000003"] == pytest.approx(89.95 / (90 * 23) * 1000)


def test_lows_are_tracked_per_sku_not_per_flavour():
    _, state = check.decide(at("90.00", sku=1), {}, WATCH, 28.0)
    alerts, _ = check.decide(at("95.00", sku=2), state, WATCH, 28.0)
    assert kinds(alerts, "low") == []          # sku 2 is new — seeded, not alerted
    assert "low:1" in state


def test_collagen_lows_are_not_tracked():
    """Same reason it is excluded from the price trigger: half its protein is
    collagen, so 'cheapest ever' would invite a purchase that is poor value."""
    v = check.parse_variants(page(variant(
        "Impact Whey Protein Powder - 2340g - 90servings - Cookies and Cream (+Collagen)",
        "Cookies and Cream (+Collagen)", "2340g - 90servings", "61.99", "83.49", 18000001)))
    _, state = check.decide(v, {}, WATCH, 28.0)
    assert not any(k.startswith("low:") for k in state)


# --- deep discount ----------------------------------------------------------
# Unlike the two triggers above, this one covers ALL lines including +Collagen:
# it answers "is a big sale running", not "is this good value".

def discounted(pct_price, rrp="100.00", sku=18000003, flavour="Strawberry Cream"):
    return check.parse_variants(page(variant(
        f"Impact Whey Protein Powder - 2.7kg - 90servings - {flavour}",
        flavour, "2.7kg - 90servings", pct_price, rrp, sku)))


def test_deep_discount_fires_at_the_threshold():
    alerts, _ = check.decide(discounted("60.00"), {}, WATCH, 28.0)   # 40% off
    assert len(kinds(alerts, "discount")) == 1


def test_deep_discount_does_not_fire_just_below_the_threshold():
    alerts, _ = check.decide(discounted("61.00"), {}, WATCH, 28.0)   # 39% off
    assert kinds(alerts, "discount") == []


def test_deep_discount_covers_the_collagen_line():
    v = check.parse_variants(page(variant(
        "Impact Whey Protein Powder - 2340g - 90servings - Cookies and Cream (+Collagen)",
        "Cookies and Cream (+Collagen)", "2340g - 90servings", "50.00", "100.00", 18000001)))
    alerts, _ = check.decide(v, {}, WATCH, 28.0)
    assert len(kinds(alerts, "discount")) == 1


def test_collagen_discount_message_carries_the_caveat():
    v = check.parse_variants(page(variant(
        "Impact Whey Protein Powder - 2340g - 90servings - Cookies and Cream (+Collagen)",
        "Cookies and Cream (+Collagen)", "2340g - 90servings", "50.00", "100.00", 18000001)))
    alerts, _ = check.decide(v, {}, WATCH, 28.0)
    assert "half" in check.format_slack(alerts)["text"].lower()


def test_deep_discount_is_not_re_alerted_at_the_same_price():
    v = discounted("60.00")
    alerts, state = check.decide(v, {}, WATCH, 28.0)
    assert len(kinds(alerts, "discount")) == 1
    again, _ = check.decide(v, state, WATCH, 28.0)
    assert kinds(again, "discount") == []


def test_deep_discount_re_alerts_when_it_gets_deeper():
    _, state = check.decide(discounted("60.00"), {}, WATCH, 28.0)
    alerts, _ = check.decide(discounted("45.00"), state, WATCH, 28.0)
    assert len(kinds(alerts, "discount")) == 1


def test_discount_ending_clears_state_so_the_next_sale_alerts():
    _, state = check.decide(discounted("60.00"), {}, WATCH, 28.0)
    _, state = check.decide(discounted("95.00"), state, WATCH, 28.0)   # 5% off
    alerts, _ = check.decide(discounted("60.00"), state, WATCH, 28.0)
    assert len(kinds(alerts, "discount")) == 1


def test_unwatched_flavour_never_deep_discount_alerts():
    alerts, _ = check.decide(discounted("40.00", flavour="Vanilla"), {}, WATCH, 28.0)
    assert kinds(alerts, "discount") == []


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


def test_a_failed_state_write_after_posting_does_not_fail_the_run():
    """The alert is already delivered by then. Exiting non-zero would make the
    Job controller retry and post the SAME alert again (backoffLimit=2 → up to
    three copies). A missed state write costs at most one duplicate on the next
    scheduled run six hours later, which is the cheaper failure."""
    calls = {"posted": 0}

    def boom(*_a, **_kw):
        raise OSError("configmap PATCH refused")

    rc = check.persist_after_alert(
        save=boom, target="x", state={}, backend="configmap",
        on_error=lambda msg: calls.__setitem__("err", msg))
    assert rc == 0
    assert "err" in calls          # the failure is reported, not swallowed silently


def test_a_successful_state_write_reports_success():
    seen = {}
    rc = check.persist_after_alert(
        save=lambda t, s, b: seen.setdefault("ok", (t, b)),
        target="cm", state={"a": 1}, backend="configmap", on_error=lambda m: None)
    assert rc == 0
    assert seen["ok"] == ("cm", "configmap")


def test_slack_message_names_flavour_size_price_and_saving():
    cheap = variant(
        "Impact Whey Protein Powder - 2.7kg - 90servings - Strawberry Cream",
        "Strawberry Cream", "2.7kg - 90servings", "55.00", "97.49", 18000003,
    )
    alerts, _ = check.decide(check.parse_variants(page(cheap)), {}, WATCH, 28.0)
    text = check.format_slack(alerts)["text"]
    assert "Strawberry Cream" in text
    assert "90 servings" in text
    assert "£55.00" in text
    assert "44%" in text          # 55.00 off an rrp of 97.49
    assert "£0.61" in text        # per serving
