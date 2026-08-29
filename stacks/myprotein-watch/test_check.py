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


def test_an_explicit_watchlist_still_narrows_to_those_flavours():
    """WATCH_FLAVOURS is retained as an opt-in narrowing filter, so a flavour
    outside an explicitly-configured list stays silent."""
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


# --- every flavour is in scope ----------------------------------------------
# The watchlist used to be four flavours, which meant a genuine bargain on a
# fifth would never be mentioned. Scope is now every flavour; what keeps the
# net honest is the protein figure behind each one, not Viktor's taste.

ALL = []  # no narrowing terms — the production default


def test_no_watch_terms_means_every_flavour_is_in_scope():
    cheap = variant(
        "Impact Whey Protein Powder - 2.7kg - 90servings - Vanilla",
        "Vanilla", "2.7kg - 90servings", "55.00", "97.49", 17712192,
    )
    deals = check.find_deals(check.parse_variants(page(cheap)), ALL, 28.0)
    assert [d.base_flavour for d in deals] == ["Vanilla"]


@pytest.mark.parametrize("env_value", ["", ",", " , ", "  "])
def test_a_blank_env_var_widens_rather_than_silencing_everything(env_value):
    """WATCH_FLAVOURS is split on commas, so an empty or whitespace-only value
    yields blank terms. Those must mean "no filter", not "match nothing" — the
    latter would quietly stop the job alerting at all."""
    v = check.parse_variants(page(VANILLA_90))[0]
    assert check._watched(v, env_value.split(","))


def test_previously_watched_flavours_are_unaffected():
    """Widening the net must not change what the original four already did."""
    cheap = variant(
        "Impact Whey Protein Powder - 2.7kg - 90servings - Strawberry Cream",
        "Strawberry Cream", "2.7kg - 90servings", "55.00", "97.49", 18000003,
    )
    parsed = check.parse_variants(page(cheap))
    assert check.find_deals(parsed, ALL, 28.0) == check.find_deals(parsed, WATCH, 28.0)


# --- protein per serving we can actually stand behind ------------------------
# The page advertises "up to 23g protein" — a ceiling, not a per-flavour figure,
# and per-flavour macros are not on the page at all. Assuming the ceiling for a
# flavour carrying chocolate-bar pieces would overstate its protein and so
# understate its £/kg, making it look like a better deal than it is.

def test_scoop_size_is_derived_from_pack_size_and_servings():
    v = check.parse_variants(page(VANILLA_90))[0]
    assert v.scoop_g == pytest.approx(30.0)


def test_a_standard_scoop_original_flavour_is_verified():
    assert check.parse_variants(page(VANILLA_90))[0].protein_verified


def test_the_milkshake_line_is_verified_by_its_own_published_claim():
    assert check.parse_variants(page(CRUMBLE_SHAKE_90))[0].protein_verified


def test_biscuit_piece_flavours_stay_verified_despite_a_bigger_scoop():
    """Their 20 g claim is published and already accounts for the pieces, so a
    32 g scoop is explained rather than unknown."""
    v = variant(
        "Impact Whey Protein Powder - 960g - 30servings - "
        "Chocolate Caramel with Crunchy Biscuit Pieces",
        "Chocolate Caramel with Crunchy Biscuit Pieces", "960g - 30servings",
        "34.99", "34.99", 18000010,
    )
    parsed = check.parse_variants(page(v))[0]
    assert parsed.scoop_g == pytest.approx(32.0)
    assert parsed.protein_verified
    assert parsed.whey_g_per_serving == 20.0


@pytest.mark.parametrize("flavour,amount,servings_g", [
    ("Snickers Original", "1KG - 31servings", 32.3),
    ("Snickers White", "1KG - 30servings", 33.3),
    ("Mars®", "1KG - 30servings", 33.3),
    ("Twix®", "1.05kg - 30servings", 35.0),
    ("Bounty®", "960g - 30servings", 32.0),
    ("Hotel Chocolat - Chocolate Billionaire", "660g - 20servings", 33.0),
    ("Jimmy's Coffee - Caramel", "600G - 20servings", 30.0),
])
def test_licensed_collab_flavours_are_not_verified(flavour, amount, servings_g):
    """Separate formulations with no protein claim on this page."""
    v = check.parse_variants(page(variant(
        f"Impact Whey Protein Powder - {amount} - {flavour}",
        flavour, amount, "39.99", "39.99", 18000011,
    )))[0]
    assert v.scoop_g == pytest.approx(servings_g, abs=0.1)
    assert not v.protein_verified


@pytest.mark.parametrize("flavour,amount", [
    ("Natural Vanilla", "810g - 30servings"),
    ("Mocha", "840g - 30servings"),
    ("Matcha Latte", "840g - 30servings"),
])
def test_original_flavours_with_an_undersized_scoop_are_not_verified(flavour, amount):
    """A 27–28 g scoop cannot hold the 23 g a 30 g scoop does."""
    v = check.parse_variants(page(variant(
        f"Impact Whey Protein Powder - {amount} - {flavour}",
        flavour, amount, "34.99", "34.99", 18000012,
    )))[0]
    assert not v.protein_verified


def test_marshmallow_is_not_mistaken_for_the_mars_bar_flavour():
    v = check.parse_variants(page(variant(
        "Impact Whey Protein Powder - 900G - 30servings - Marshmallow",
        "Marshmallow", "900G - 30servings", "34.99", "34.99", 18000013,
    )))[0]
    assert v.protein_verified


def test_an_unparseable_pack_size_is_treated_as_unverified():
    v = check.parse_variants(page(variant(
        "Impact Whey Protein Powder - 30servings - Vanilla",
        "Vanilla", "30servings", "34.99", "34.99", 18000014,
    )))[0]
    assert v.scoop_g is None
    assert not v.protein_verified


def test_unverified_flavours_never_fire_the_value_triggers():
    """However cheap a Twix tub looks, we cannot say it is at his price."""
    cheap = variant(
        "Impact Whey Protein Powder - 1.05kg - 30servings - Twix®",
        "Twix®", "1.05kg - 30servings", "10.00", "39.99", 18000015,
    )
    parsed = check.parse_variants(page(cheap))
    assert check.find_deals(parsed, ALL, 28.0) == []
    assert check.comparable(parsed, ALL) == []


def test_unverified_flavours_still_fire_the_big_sale_trigger():
    """That trigger answers "is a sale running", which needs no protein figure."""
    v = variant(
        "Impact Whey Protein Powder - 1.05kg - 30servings - Twix®",
        "Twix®", "1.05kg - 30servings", "19.99", "39.99", 18000016,
    )
    got = check.find_deep_discounts(check.parse_variants(page(v)), ALL, 40)
    assert [d.base_flavour for d in got] == ["Twix®"]


def test_unverified_flavours_are_left_out_of_cheapest_ever_tracking():
    v = variant(
        "Impact Whey Protein Powder - 1.05kg - 30servings - Twix®",
        "Twix®", "1.05kg - 30servings", "10.00", "39.99", 18000017,
    )
    _, new_state = check.decide(
        check.parse_variants(page(v)), {}, ALL, 28.0)
    assert "low:18000017" not in new_state


def test_a_new_flavour_seeds_its_low_silently_on_first_sighting():
    """Widening scope adds ~76 unseen SKUs; none of them may alert on sight."""
    alerts, new_state = check.decide(
        check.parse_variants(page(VANILLA_90)), {}, ALL, 28.0)
    assert alerts == []
    assert new_state["low:17712192"] == pytest.approx(47.10, abs=0.01)


# --- one line per price, not per flavour -------------------------------------
# MyProtein prices by pack size, not by flavour: every 150-serving Milkshake tub
# is the same £113.99. With all flavours in scope a single price point matches
# six or more variants, and a sitewide sale would match all ~72 — so the flavours
# sharing a price are named together instead of repeated a line at a time.

def _same_price_shake(flavours, price="55.00", servings=150, sku_base=18100000):
    return [
        variant(
            f"Impact Whey Protein Powder - 4350g - {servings}servings - {f} (Milkshake)",
            f"{f} (Milkshake)", f"4350g - {servings}servings", price, "153.99",
            sku_base + i,
        )
        for i, f in enumerate(flavours)
    ]


def test_flavours_sharing_a_price_are_named_on_one_line():
    parsed = check.parse_variants(page(*_same_price_shake(
        ["Banana", "Salted Caramel", "Chocolate Fudge"])))
    text = check.format_slack([check.Alert("deal", v) for v in parsed])["text"]
    body = [ln for ln in text.split("\n") if ":moneybag:" in ln]
    assert len(body) == 1
    for f in ("Banana", "Salted Caramel", "Chocolate Fudge"):
        assert f in body[0]
    assert body[0].count("£55.00") == 1


def test_different_pack_sizes_stay_on_their_own_lines():
    parsed = check.parse_variants(page(
        *_same_price_shake(["Banana"], price="55.00", servings=150),
        *_same_price_shake(["Banana"], price="30.00", servings=90, sku_base=18150000),
    ))
    text = check.format_slack([check.Alert("deal", v) for v in parsed])["text"]
    assert len([ln for ln in text.split("\n") if ":moneybag:" in ln]) == 2


def test_a_long_flavour_list_is_summarised_with_an_explicit_count():
    flavours = [f"Flavour{i}" for i in range(check.MAX_FLAVOURS_NAMED + 3)]
    parsed = check.parse_variants(page(*_same_price_shake(flavours)))
    text = check.format_slack([check.Alert("deal", v) for v in parsed])["text"]
    line = [ln for ln in text.split("\n") if ":moneybag:" in ln][0]
    assert "+3 more" in line
    assert line.count("Flavour") == check.MAX_FLAVOURS_NAMED


def test_grouping_does_not_merge_different_triggers():
    parsed = check.parse_variants(page(*_same_price_shake(["Banana", "Salted Caramel"])))
    alerts = [check.Alert("deal", parsed[0]), check.Alert("low", parsed[1])]
    text = check.format_slack(alerts)["text"]
    assert len([ln for ln in text.split("\n") if ":moneybag:" in ln]) == 1
    assert len([ln for ln in text.split("\n") if ":chart_with_downwards_trend:" in ln]) == 1


def test_grouping_keeps_lines_whose_protein_per_serving_differs_apart():
    """Same price and serving count, but the biscuit-pieces flavour is 20 g and
    the plain one 23 g — so their £/kg differs and they are not one price."""
    plain = variant(
        "Impact Whey Protein Powder - 900G - 30servings - Vanilla",
        "Vanilla", "900G - 30servings", "34.99", "34.99", 18200001,
    )
    crunch = variant(
        "Impact Whey Protein Powder - 900G - 30servings - "
        "Cookie Crumble Crunch with Crunchy Biscuit Pieces",
        "Cookie Crumble Crunch with Crunchy Biscuit Pieces", "900G - 30servings",
        "34.99", "34.99", 18200002,
    )
    parsed = check.parse_variants(page(plain, crunch))
    text = check.format_slack([check.Alert("deal", v) for v in parsed])["text"]
    assert len([ln for ln in text.split("\n") if ":moneybag:" in ln]) == 2


# --- the message must not assert what we do not know -------------------------

def _twix_sale_message():
    v = variant(
        "Impact Whey Protein Powder - 1.05kg - 30servings - Twix®",
        "Twix®", "1.05kg - 30servings", "16.00", "97.49", 18000020,
    )
    alerts = [check.Alert("discount", check.parse_variants(page(v))[0])]
    return check.format_slack(alerts)["text"]


def test_a_sale_on_an_unverified_flavour_quotes_no_price_per_kg_protein():
    """Excluding it from the value triggers but still printing a £/kg figure
    would hand back the very number we said we could not stand behind."""
    text = _twix_sale_message()
    assert "/kg protein" not in text
    assert "84% off" in text and "£16.00" in text


def test_a_sale_on_an_unverified_flavour_says_why_the_figure_is_missing():
    assert "not published" in _twix_sale_message()


def test_a_verified_flavour_still_leads_with_price_per_kg_protein():
    alerts = [check.Alert("deal", check.parse_variants(page(VANILLA_90))[0])]
    assert "/kg protein" in check.format_slack(alerts)["text"]


# --- what the run says it looked at ------------------------------------------

def _scope_lines(variants, watch=None):
    out = []
    check.print_scope(variants, watch if watch is not None else [], out.append)
    return out


def test_scope_output_reports_counts_and_the_cheapest():
    lines = _scope_lines(check.parse_variants(page(VANILLA_90, CRUMBLE_SHAKE_90)))
    assert "parsed 2 variants (2 in stock); 2 comparable" in lines[0]
    assert any("Cookie Crumble (Milkshake)" in ln for ln in lines)


def test_scope_output_names_what_it_held_back_and_why():
    twix = variant(
        "Impact Whey Protein Powder - 1.05kg - 30servings - Twix®",
        "Twix®", "1.05kg - 30servings", "39.99", "39.99", 18000018,
    )
    lines = _scope_lines(check.parse_variants(page(VANILLA_90, twix)))
    held = [ln for ln in lines if "held out of the value triggers" in ln]
    assert len(held) == 1
    assert "Twix®" in held[0]


def test_a_truncated_listing_says_so_rather_than_looking_complete():
    many = [
        variant(
            f"Impact Whey Protein Powder - 900G - 30servings - Flavour{i}",
            f"Flavour{i}", "900G - 30servings", f"{30 + i}.99", "97.49", 19000000 + i,
        )
        for i in range(check.LOG_CHEAPEST_N + 4)
    ]
    lines = _scope_lines(check.parse_variants(page(*many)))
    assert any(f"cheapest {check.LOG_CHEAPEST_N} of {len(many)}" in ln for ln in lines)


def test_no_truncation_notice_when_everything_is_listed():
    lines = _scope_lines(check.parse_variants(page(VANILLA_90)))
    assert not any("cheapest" in ln for ln in lines)


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


def test_the_collagen_line_never_reaches_the_big_sale_trigger():
    """Viktor 2026-08-29: the +Collagen line swaps whey for collagen peptides,
    which is not the product he wants at any discount. It was already out of the
    value triggers; the sale trigger was the last way it could reach him."""
    v = check.parse_variants(page(variant(
        "Impact Whey Protein Powder - 2340g - 90servings - Cookies and Cream (+Collagen)",
        "Cookies and Cream (+Collagen)", "2340g - 90servings", "50.00", "100.00", 18000001)))
    alerts, _ = check.decide(v, {}, WATCH, 28.0)
    assert alerts == []


def test_no_collagen_variant_can_appear_in_any_message():
    """Belt and braces on the formatter, not just the trigger: excluding an item
    from a computation is not the same as keeping it out of what Viktor reads."""
    v = check.parse_variants(page(variant(
        "Impact Whey Protein Powder - 2160g - 90servings - Strawberry Cream (+Collagen)",
        "Strawberry Cream (+Collagen)", "2160g - 90servings", "10.00", "100.00", 18000002)))
    alerts, _ = check.decide(v, {}, ALL, 28.0)
    assert alerts == []
    assert "Collagen" not in check.format_slack(alerts)["text"]


def test_an_unverified_original_flavour_still_fires_the_big_sale_trigger():
    """The exclusion is the Collagen LINE, not "anything we cannot price".
    Snickers and friends stay covered."""
    v = check.parse_variants(page(variant(
        "Impact Whey Protein Powder - 1.05kg - 30servings - Twix®",
        "Twix®", "1.05kg - 30servings", "20.00", "40.00", 18000003)))
    alerts, _ = check.decide(v, {}, ALL, 28.0)
    assert len(kinds(alerts, "discount")) == 1


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


# --- the daily heartbeat -----------------------------------------------------
# A watcher that only speaks when a deal lands is indistinguishable from a dead
# one: Viktor got zero messages in the week after it shipped and said he could
# not tell whether it worked. The digest posts on a schedule whether or not
# anything qualified, so silence stops being ambiguous. It is deliberately
# read-only — it must never consume the dedup state the alerting run depends on.

def test_digest_reports_scope_cheapest_and_threshold():
    parsed = check.parse_variants(page(VANILLA_90, CRUMBLE_SHAKE_90))
    line = check.digest_line(parsed, ALL, 28.0)
    assert "2 variants in scope" in line
    # £71.49/90 servings at 20g beats £97.49/90 at 23g — cheapest, not first
    assert "£39.72/kg protein" in line
    assert "£28.00" in line                 # the bar it is measured against


def test_digest_is_a_single_line():
    line = check.digest_line(check.parse_variants(page(VANILLA_90)), ALL, 28.0)
    assert "\n" not in line


def test_digest_says_nothing_qualifies_when_nothing_does():
    line = check.digest_line(check.parse_variants(page(VANILLA_90)), ALL, 28.0)
    assert "nothing" in line.lower()


def test_digest_flags_a_live_deal_rather_than_claiming_all_clear():
    """If a deal is running when the digest fires, the digest must not read as
    'nothing to see' — that would contradict the alert sent hours earlier."""
    cheap = variant(
        "Impact Whey Protein Powder - 2.7kg - 90servings - Strawberry Cream",
        "Strawberry Cream", "2.7kg - 90servings", "55.00", "97.49", 18000030,
    )
    line = check.digest_line(check.parse_variants(page(cheap)), ALL, 28.0)
    assert "nothing" not in line.lower()
    assert "£26.57/kg protein" in line


def test_digest_survives_a_page_with_nothing_comparable():
    """All-unverified page: still a heartbeat, no crash, no fake price."""
    twix = variant(
        "Impact Whey Protein Powder - 1.05kg - 30servings - Twix®",
        "Twix®", "1.05kg - 30servings", "39.99", "39.99", 18000031,
    )
    line = check.digest_line(check.parse_variants(page(twix)), ALL, 28.0)
    assert "\n" not in line
    assert "/kg protein" not in line


def test_digest_payload_is_slack_shaped():
    payload = check.format_digest(
        check.digest_line(check.parse_variants(page(VANILLA_90)), ALL, 28.0))
    assert payload["unfurl_links"] is False
    assert payload["text"].strip()


# --- a variant with no pack weight -------------------------------------------
# Seen live 2026-08-22: MyProtein listed a 120-serving Chocolate Milkshake whose
# amount is the bare string "120servings", no weight at all — and it was the
# CHEAPEST variant on the page, so it is what both the digest and any deal alert
# would name. Servings and protein-per-serving are both known, so the price
# maths is unaffected; only the human-readable size is.

BARE_SERVINGS = variant(
    "Impact Whey Protein Powder - 120servings - Chocolate (Milkshake)",
    "Chocolate (Milkshake)", "120servings", "90.99", "122.99", 18300001,
)


def test_pack_size_is_absent_when_the_page_states_no_weight():
    v = check.parse_variants(page(BARE_SERVINGS))[0]
    assert v.pack_size is None
    assert v.scoop_g is None


def test_pack_size_is_the_weight_token_when_present():
    assert check.parse_variants(page(VANILLA_90))[0].pack_size == "2.7kg"


def test_a_weightless_variant_still_prices_correctly():
    v = check.parse_variants(page(BARE_SERVINGS))[0]
    assert v.protein_verified          # Milkshake publishes 20 g regardless
    assert v.price_per_kg_protein == pytest.approx(37.91, abs=0.01)


def test_a_weightless_variant_does_not_print_its_servings_twice():
    v = check.parse_variants(page(BARE_SERVINGS))[0]
    detail = check._detail(v)
    assert "120 servings" in detail
    assert "120servings" not in detail.replace("120 servings", "")


def test_the_digest_names_a_weightless_variant_cleanly():
    line = check.digest_line(check.parse_variants(page(BARE_SERVINGS)), ALL, 28.0)
    assert "120 servings" in line
    assert ", 120servings" not in line


# --- a new low has to be worth hearing --------------------------------------
# 2026-08-28: a 250 g / 8-serving taster tub dropped to £10.00, hit its own
# personal record and alerted at £54.35/kg protein — while £33.33/kg sat on the
# same page. 4 of the 6 alert lines ever sent were worse than what was already
# available, because £/kg tracks pack size and every size is its own SKU, so a
# sitewide percentage sale makes all of them hit a personal best at once.
# A record is still worth KEEPING; it is not always worth SAYING.

def _shake(sku, servings, price, rrp="153.99", flavour="Banana"):
    return variant(
        f"Impact Whey Protein Powder - {servings}servings - {flavour} (Milkshake)",
        f"{flavour} (Milkshake)", f"4350g - {servings}servings", price, rrp, sku,
    )


def _taster(sku, price, rrp="13.99"):
    """250 g / 8 servings — structurally poor value per kg, whatever it costs."""
    return variant(
        "Impact Whey Protein Powder - 250G - 8servings - Chocolate Brownie",
        "Chocolate Brownie", "250G - 8servings", price, rrp, sku,
    )


def test_a_new_low_on_the_best_price_still_alerts():
    page_ = page(_shake(18400001, 150, "99.99"))
    prior = {"low:18400001": 40.0}
    alerts, _ = check.decide(check.parse_variants(page_), prior, ALL, 28.0)
    assert [a.kind for a in alerts] == ["low"]


def test_the_taster_tub_regression_does_not_alert():
    """The exact 2026-08-28 shape: taster hits a personal low at £54.35/kg while
    £33.33/kg is on the same page."""
    parsed = check.parse_variants(page(_shake(18400002, 150, "99.99"),
                                       _taster(18400003, "10.00")))
    # Both already on record; only the taster is dropping.
    prior = {"low:18400002": 33.33, "low:18400003": 60.0}
    alerts, new_state = check.decide(parsed, prior, ALL, 28.0)
    assert alerts == []
    # The record still ratchets down — history is kept, only the shout is dropped.
    assert new_state["low:18400003"] == pytest.approx(54.35, abs=0.01)


def test_a_suppressed_low_is_recorded_so_it_cannot_alert_again_later():
    parsed = check.parse_variants(page(_shake(18400004, 150, "99.99"),
                                       _taster(18400005, "10.00")))
    prior = {"low:18400004": 33.33, "low:18400005": 60.0}
    _, state1 = check.decide(parsed, prior, ALL, 28.0)
    alerts2, _ = check.decide(parsed, state1, ALL, 28.0)
    assert alerts2 == []


@pytest.mark.parametrize("taster_price,should_alert", [
    ("6.15", True),    # ~£33.4/kg — level with the page best, genuinely news
    ("10.00", False),  # £54.35/kg — today's case
])
def test_the_gate_is_about_price_not_pack_size(taster_price, should_alert):
    """A small pack is not banned — it just has to be competitive to speak."""
    parsed = check.parse_variants(page(_shake(18400006, 150, "99.99"),
                                       _taster(18400007, taster_price)))
    prior = {"low:18400006": 33.33, "low:18400007": 99.0}
    alerts, _ = check.decide(parsed, prior, ALL, 28.0)
    assert bool(alerts) is should_alert


def test_a_deal_at_his_price_alerts_even_if_it_is_not_the_page_best():
    """The relevance gate guards the LOW trigger only. Hitting his actual
    buying price is news regardless of what else is on the page."""
    parsed = check.parse_variants(page(_shake(18400008, 150, "60.00"),
                                       _shake(18400009, 150, "83.00", flavour="Chocolate")))
    alerts, _ = check.decide(parsed, {}, ALL, 28.0)
    assert "deal" in [a.kind for a in alerts]


def test_the_page_best_ignores_variants_we_cannot_price():
    """An unverified flavour must not set the bar the gate measures against."""
    twix = variant(
        "Impact Whey Protein Powder - 1.05kg - 30servings - Twix®",
        "Twix®", "1.05kg - 30servings", "5.00", "5.00", 18400010,
    )
    parsed = check.parse_variants(page(_shake(18400011, 150, "99.99"), twix))
    prior = {"low:18400011": 40.0}
    alerts, _ = check.decide(parsed, prior, ALL, 28.0)
    assert [a.kind for a in alerts] == ["low"]


def test_the_run_log_states_the_collagen_line_is_out_of_scope():
    """A whole product line dropping out should be visible in the run, not a
    silent omission that leaves the parsed/comparable counts unexplained."""
    col = variant(
        "Impact Whey Protein Powder - 2160g - 90servings - Strawberry Cream (+Collagen)",
        "Strawberry Cream (+Collagen)", "2160g - 90servings", "61.99", "83.49", 18000040)
    lines = _scope_lines(check.parse_variants(page(VANILLA_90, col)))
    joined = " ".join(lines)
    assert "Collagen" in joined and "1" in joined
