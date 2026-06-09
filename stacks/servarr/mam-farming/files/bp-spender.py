"""
MAM bonus-point spender — tier-aware, pay-what-we-owe.

MAM's bonusBuy.php API enforces a hard 50 GiB minimum per purchase
("Automated spenders are limited to buying at least 50 GB... due to log
spam"). Valid API tiers are 50, 100, 200, 500 GiB (@ 500 BP/GiB). That
means the "pay exactly what we owe" approach from the recovery plan
rounds UP to 50 GiB for the first purchase — small buys can only be done
via the web UI, not the API.

Logic: pick the smallest valid tier that both (a) satisfies the ratio
deficit and (b) we can afford without burning the BP reserve. Skip if
nothing fits; the cron will retry in 6 h once BP grows.
"""
import math
import os
import sys
import tempfile
import time

import requests

PUSHGW = "http://prometheus-prometheus-pushgateway.monitoring:9091"
COOKIE_FILE = "/data/mam_id"

TARGET_RATIO = float(os.environ.get("TARGET_RATIO", "2.0"))
RESERVE_BP = int(os.environ.get("RESERVE_BP", "500"))
BP_PER_GB = int(os.environ.get("BP_PER_GB", "500"))
# MAM-enforced minimum purchase for API callers: 50 GiB.
API_TIERS_GIB = (50, 100, 200, 500)

CLASS_CODES = {
    "Mouse": 0,
    "Vole": 1,
    "User": 2,
    "Power User": 3,
    "Elite": 4,
    "Torrent Master": 5,
    "Power TM": 6,
    "Elite TM": 7,
    "VIP": 8,
}


def save_cookie(resp):
    for c in resp.cookies:
        if c.name == "mam_id":
            fd, tmp = tempfile.mkstemp(dir="/data")
            os.write(fd, c.value.encode())
            os.close(fd)
            os.rename(tmp, COOKIE_FILE)
            return


def push(metrics):
    try:
        requests.post(
            f"{PUSHGW}/metrics/job/mam-bp-spender", data=metrics, timeout=10
        )
    except Exception as e:
        print(f"pushgateway error: {e}", file=sys.stderr)


def load_cookie():
    if os.path.exists(COOKIE_FILE):
        return open(COOKIE_FILE).read().strip()
    return os.environ.get("MAM_ID", "")


def main():
    mam_id = load_cookie()
    if not mam_id:
        print("No mam_id available", file=sys.stderr)
        sys.exit(1)

    s = requests.Session()
    s.cookies.set("mam_id", mam_id, domain=".myanonamouse.net")

    r = s.get("https://www.myanonamouse.net/jsonLoad.php", timeout=15)
    if r.status_code != 200:
        push("mam_farming_cookie_expired 1\n")
        print(f"Cookie expired: {r.status_code}", file=sys.stderr)
        sys.exit(1)
    save_cookie(r)

    profile = r.json()
    ratio = float(profile.get("ratio", 0) or 0)
    classname = profile.get("classname", "Mouse")
    class_code = CLASS_CODES.get(classname, 0)
    # MAM returns `downloaded`/`uploaded` as pretty strings ("715.55 MiB");
    # `*_bytes` are the authoritative integer fields.
    downloaded = int(profile.get("downloaded_bytes", 0) or 0)
    uploaded = int(profile.get("uploaded_bytes", 0) or 0)
    bp = int(float(profile.get("seedbonus", 0) or 0))

    deficit_bytes = max(0, int(downloaded * TARGET_RATIO) - uploaded)
    needed_gib = math.ceil(deficit_bytes / (1024**3)) + 1 if deficit_bytes > 0 else 0
    affordable_gib = max(0, (bp - RESERVE_BP) // BP_PER_GB)

    # Pick the smallest API tier that satisfies the deficit AND fits the
    # budget. If even the smallest tier is too expensive, skip — the cron
    # will retry in 6 h once BP has grown.
    buy_gib = 0
    for tier in API_TIERS_GIB:
        if tier >= needed_gib and tier <= affordable_gib:
            buy_gib = tier
            break
    if buy_gib == 0 and needed_gib > 0 and affordable_gib >= API_TIERS_GIB[0]:
        # Deficit exceeds all tiers we can afford — buy the largest
        # tier that fits to make progress.
        for tier in reversed(API_TIERS_GIB):
            if tier <= affordable_gib:
                buy_gib = tier
                break

    print(
        f"Profile: ratio={ratio} class={classname} "
        f"DL={downloaded / 1024**3:.2f} GiB UL={uploaded / 1024**3:.2f} GiB "
        f"BP={bp} | deficit={deficit_bytes / 1024**3:.2f} GiB "
        f"needed={needed_gib} affordable={affordable_gib} buy={buy_gib}"
    )

    spent_gib = 0
    if buy_gib >= API_TIERS_GIB[0]:
        time.sleep(3)
        url = (
            "https://www.myanonamouse.net/json/bonusBuy.php"
            f"?spendtype=upload&amount={buy_gib}"
        )
        r2 = s.get(url, timeout=15)
        save_cookie(r2)
        try:
            body = r2.json()
        except ValueError:
            body = {}
        ok = r2.status_code == 200 and body.get("success") is True
        print(
            f"Buy {buy_gib} GiB -> {r2.status_code} "
            f"success={body.get('success')} {r2.text[:160]}"
        )
        if ok:
            spent_gib = buy_gib

    metrics = (
        "mam_farming_cookie_expired 0\n"
        f"mam_ratio {ratio}\n"
        f'mam_class_code{{classname="{classname}"}} {class_code}\n'
        f"mam_downloaded_bytes {downloaded}\n"
        f"mam_uploaded_bytes {uploaded}\n"
        f"mam_bp_balance {bp}\n"
        f"mam_bp_spent_gb {spent_gib}\n"
        f"mam_bp_needed_gib {needed_gib}\n"
        f"mam_bp_affordable_gib {affordable_gib}\n"
    )
    push(metrics)
    print(
        f"Done: BP={bp}, spent={spent_gib} GiB (needed={needed_gib}, "
        f"affordable={affordable_gib})"
    )


if __name__ == "__main__":
    main()
