"""
MAM freeleech grabber — demand-first, ratio-guarded.

Selects small-but-popular freeleech titles to grow the account's upload
credit. Refuses to grab while the account is in Mouse class or ratio is
below 1.2, because MAM rejects peer-list announces under those conditions
and new grabs only deepen the ratio hole.

Cleanup is handled by `mam-farming-janitor.py`, which runs unconditionally.
"""
import json
import math
import os
import random
import sys
import tempfile
import time

import requests

QB_URL = "http://qbittorrent.servarr.svc.cluster.local"
PUSHGW = "http://prometheus-prometheus-pushgateway.monitoring:9091"
COOKIE_FILE = "/data/mam_id"
GRABBED_IDS_FILE = "/data/grabbed_ids.txt"

MIN_MB = int(os.environ.get("MIN_MB", "50"))
MAX_MB = int(os.environ.get("MAX_MB", "1024"))
LEECHER_FLOOR = int(os.environ.get("LEECHER_FLOOR", "1"))
# MAM's catalogue is well-seeded by design — a ceiling of 50 rejected ~99%
# of candidates in live testing. 200 still filters out truly oversupplied
# swarms while keeping enough working-set to grab 3-5 titles per run.
SEEDER_CEILING = int(os.environ.get("SEEDER_CEILING", "200"))
GRAB_PER_RUN = int(os.environ.get("GRAB_PER_RUN", "5"))
MAX_TORRENTS = int(os.environ.get("MAX_TORRENTS", "500"))
# The guard's real job is to prevent the Mouse-class death spiral (see RC1
# in the original recovery plan). Once class > Mouse, MAM serves peer
# lists normally and demand-first filtering (leechers>=1) keeps new grabs
# upload-positive. Keep a low floor as a tripwire for catastrophic dips
# rather than a steady-state block.
RATIO_FLOOR = float(os.environ.get("RATIO_FLOOR", "0.5"))
REQUEST_SLEEP = float(os.environ.get("REQUEST_SLEEP", "3"))

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


def parse_size(s):
    # MAM pretty-prints sizes with thousands separators (e.g. "1,002.9 MiB").
    units = {"B": 1, "KiB": 1024, "MiB": 1024**2, "GiB": 1024**3, "TiB": 1024**4}
    parts = s.replace(",", "").split()
    if len(parts) != 2:
        return 0
    return int(float(parts[0]) * units.get(parts[1], 1))


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
            f"{PUSHGW}/metrics/job/mam-freeleech-grabber", data=metrics, timeout=10
        )
    except Exception as e:
        print(f"pushgateway error: {e}", file=sys.stderr)


def load_cookie():
    if os.path.exists(COOKIE_FILE):
        return open(COOKIE_FILE).read().strip()
    return os.environ.get("MAM_ID", "")


def exit_cookie_expired(status):
    push("mam_farming_cookie_expired 1\n")
    print(f"Cookie expired: {status}", file=sys.stderr)
    sys.exit(1)


def main():
    mam_id = load_cookie()
    if not mam_id:
        print("No mam_id available", file=sys.stderr)
        sys.exit(1)

    s = requests.Session()
    s.cookies.set("mam_id", mam_id, domain=".myanonamouse.net")

    r = s.get("https://www.myanonamouse.net/jsonLoad.php", timeout=15)
    if r.status_code != 200:
        exit_cookie_expired(r.status_code)
    save_cookie(r)

    profile = r.json()
    ratio = float(profile.get("ratio", 0) or 0)
    classname = profile.get("classname", "Mouse")
    # `*_bytes` are authoritative integers; `downloaded`/`uploaded` are
    # pretty strings like "715.55 MiB".
    downloaded = int(profile.get("downloaded_bytes", 0) or 0)
    uploaded = int(profile.get("uploaded_bytes", 0) or 0)
    class_code = CLASS_CODES.get(classname, 0)

    profile_metrics = (
        f"mam_farming_cookie_expired 0\n"
        f"mam_ratio {ratio}\n"
        f'mam_class_code{{classname="{classname}"}} {class_code}\n'
        f"mam_downloaded_bytes {downloaded}\n"
        f"mam_uploaded_bytes {uploaded}\n"
    )

    if ratio < RATIO_FLOOR or classname == "Mouse":
        reason = "mouse_class" if classname == "Mouse" else "low_ratio"
        print(
            f"Skip grab: ratio={ratio} class={classname} (floor={RATIO_FLOOR}) "
            f"reason={reason}"
        )
        push(
            profile_metrics
            + f'mam_grabber_skipped_reason{{reason="{reason}"}} 1\n'
            + f"mam_farming_grabbed 0\n"
        )
        return

    time.sleep(REQUEST_SLEEP)
    r = s.get("https://t.myanonamouse.net/json/dynamicSeedbox.php", timeout=15)
    save_cookie(r)
    print(f"Seedbox: {r.text[:80]}")

    grabbed_ids = set()
    if os.path.exists(GRABBED_IDS_FILE):
        raw = open(GRABBED_IDS_FILE).read().strip()
        grabbed_ids = set(raw.split("\n")) if raw else set()

    try:
        all_torrents = requests.get(
            f"{QB_URL}/api/v2/torrents/info", timeout=10
        ).json()
    except Exception as e:
        print(f"qBittorrent unreachable: {e}", file=sys.stderr)
        push(profile_metrics + "mam_farming_grabbed 0\n")
        sys.exit(1)

    farming = [t for t in all_torrents if t.get("category") == "mam-farming"]
    all_names_lower = {t["name"].lower() for t in all_torrents}
    total_size = sum(t.get("size", 0) for t in farming)

    print(
        f"Profile: ratio={ratio} class={classname} | "
        f"Farming: {len(farming)}, {total_size / (1024**3):.1f} GiB, "
        f"tracked IDs: {len(grabbed_ids)}"
    )

    grabbed = 0
    if len(farming) >= MAX_TORRENTS:
        print(f"At max torrents ({MAX_TORRENTS}), skipping grab")
    else:
        time.sleep(REQUEST_SLEEP)
        offset = random.randint(0, 1400)
        params = {
            "tor[searchType]": "fl",
            "tor[searchIn]": "torrents",
            "tor[perpage]": "50",
            "tor[startNumber]": str(offset),
        }
        r = s.get(
            "https://www.myanonamouse.net/tor/js/loadSearchJSONbasic.php",
            params=params,
            timeout=15,
        )
        save_cookie(r)
        data = r.json()
        results = data.get("data", []) or []
        print(
            f"Search offset={offset}, found={data.get('found', 0)}, "
            f"page_results={len(results)}"
        )

        candidates = []
        for t in results:
            tid = str(t.get("id", ""))
            if tid in grabbed_ids:
                continue
            title = t.get("title", "")
            if any(title.lower() in n for n in all_names_lower):
                grabbed_ids.add(tid)
                continue
            size = parse_size(t.get("size", "0 B"))
            if size < MIN_MB * 1024**2 or size > MAX_MB * 1024**2:
                continue
            seeders = int(t.get("seeders", 999) or 999)
            leechers = int(t.get("leechers", 0) or 0)
            if leechers < LEECHER_FLOOR:
                continue
            if seeders > SEEDER_CEILING:
                continue
            wedge_bonus = (
                200 if (t.get("free") == 1 or t.get("personal_freeleech") == 1) else 0
            )
            score = leechers * 3 - seeders * 0.5 + wedge_bonus
            candidates.append((score, t))

        candidates.sort(key=lambda x: -x[0])

        for score, t in candidates[:GRAB_PER_RUN]:
            time.sleep(REQUEST_SLEEP)
            tid = t["id"]
            r = s.get(
                f"https://www.myanonamouse.net/tor/download.php?tid={tid}", timeout=15
            )
            save_cookie(r)
            if not r.content.startswith(b"d"):
                print(f"Bad torrent body for tid={tid}")
                grabbed_ids.add(str(tid))
                continue
            add_resp = requests.post(
                f"{QB_URL}/api/v2/torrents/add",
                files={
                    "torrents": (
                        f"{tid}.torrent",
                        r.content,
                        "application/x-bittorrent",
                    )
                },
                data={
                    "savepath": "/downloads/mam-farming",
                    "category": "mam-farming",
                    "tags": "mam,freeleech",
                },
                timeout=20,
            )
            ok = add_resp.status_code == 200 and add_resp.text.strip() != "Fails."
            print(
                f"{'Added' if ok else 'FAILED'} (score={score:.1f}): "
                f"{t['title'][:60]} ({t['size']}, S:{t.get('seeders')} "
                f"L:{t.get('leechers')}) -> {add_resp.status_code}"
            )
            grabbed_ids.add(str(tid))
            if ok:
                grabbed += 1

        fd, tmp = tempfile.mkstemp(dir="/data")
        os.write(fd, "\n".join(grabbed_ids).encode())
        os.close(fd)
        os.rename(tmp, GRABBED_IDS_FILE)

    metrics = (
        profile_metrics
        + f"mam_farming_grabbed {grabbed}\n"
        + f"mam_farming_total_seeding {len(farming) + grabbed}\n"
        + f"mam_farming_size_bytes {total_size}\n"
    )
    push(metrics)
    print(f"Done: grabbed={grabbed}")


if __name__ == "__main__":
    main()
