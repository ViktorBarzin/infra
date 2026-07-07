#!/usr/bin/env python3
"""Live reader for the WD-01ADE potted-plant watering controller ("Саксии").

The official Home Assistant Tuya integration only surfaces the two pump
switches. The schedule (timer1/2), the per-channel watering duration
(woter_timer1/2) and the run log live only in the Tuya cloud "thing model"
(shadow properties). This script polls the Tuya developer Cloud API, decodes
the raw timer blobs, and pushes the values into ha-sofia as sensor.* entities
via the HA REST API so they can be shown live on the
"Напояване → Саксии" dashboard.

Runs from the tuya_bridge image (tinytuya + requests already present).
Env:
  TUYA_API_KEY, TUYA_API_SECRET  - Tuya developer project creds (region EU)
  TUYA_DEVICE_ID                 - WD-01ADE device id
  HA_URL                         - e.g. https://ha-sofia.viktorbarzin.me
  HA_TOKEN                       - ha-sofia long-lived access token
"""
import os
import sys
import base64
import datetime

import tinytuya
import requests

DID = os.environ["TUYA_DEVICE_ID"]
HA_URL = os.environ["HA_URL"].rstrip("/")
HA_TOKEN = os.environ["HA_TOKEN"]

# WD-01ADE timer DP byte format (reverse-engineered 2026-07-06/07 against real
# schedules): base64 -> bytes; byte0 = header, then 11-byte entries:
#   [0]type [1]daymask [2]hh [3]mm [4]dur_hi [5]dur_lo [6]act [7..10]reserved.
#   duration = uint16 BE seconds.
#   daymask byte: bit0 = enabled; bit1=Mon bit2=Tue bit3=Wed bit4=Thu
#                 bit5=Fri bit6=Sat bit7=Sun. No weekday bit set -> never fires.
DOW = {1: "Пон", 2: "Вто", 3: "Сря", 4: "Чет", 5: "Пет", 6: "Съб", 7: "Нед"}


def decode_timer(b64):
    raw = base64.b64decode(b64 or "AA==")
    if len(raw) <= 1:
        return []
    body = raw[1:]
    out = []
    for i in range(0, len(body) - 5, 11):
        e = body[i:i + 11]
        rep, hh, mm = e[1], e[2], e[3]
        dur = (e[4] << 8) | e[5]
        days = [DOW[b] for b in range(1, 8) if rep & (1 << b)]
        repeat = " ".join(days) if days else "няма избрани дни"
        m, s = divmod(dur, 60)
        dur_h = ("%dм %dс" % (m, s)) if s else ("%d мин" % m)
        out.append({
            "старт": "%02d:%02d" % (hh, mm),
            "повторение": repeat,
            "продължителност": dur_h,
            "секунди": dur,
        })
    return out


def push(entity_id, state, attributes):
    r = requests.post(
        "%s/api/states/%s" % (HA_URL, entity_id),
        headers={
            "Authorization": "Bearer %s" % HA_TOKEN,
            "Content-Type": "application/json",
        },
        json={"state": state, "attributes": attributes},
        timeout=20,
    )
    r.raise_for_status()


def sched_state(entries):
    if not entries:
        return "няма график"
    if len(entries) == 1:
        return "1 график"
    return "%d графика" % len(entries)


def main():
    cloud = tinytuya.Cloud(
        apiRegion="eu",
        apiKey=os.environ["TUYA_API_KEY"],
        apiSecret=os.environ["TUYA_API_SECRET"],
        apiDeviceID=DID,
    )
    resp = cloud.cloudrequest("/v2.0/cloud/thing/%s/shadow/properties" % DID)
    if not isinstance(resp, dict) or not resp.get("success"):
        print("Tuya shadow read failed: %r" % (resp,), file=sys.stderr)
        sys.exit(1)
    props = {p["code"]: p.get("value") for p in resp["result"]["properties"]}

    dev = cloud.cloudrequest("/v1.0/devices/%s" % DID)
    online = bool(dev.get("result", {}).get("online")) if isinstance(dev, dict) else False

    sched_a = decode_timer(props.get("timer1"))
    sched_b = decode_timer(props.get("timer2"))
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()

    push("sensor.saksii_grafik_pompa_a", sched_state(sched_a),
         {"friendly_name": "Саксии — график Помпа A", "icon": "mdi:calendar-clock", "entries": sched_a})
    push("sensor.saksii_grafik_pompa_b", sched_state(sched_b),
         {"friendly_name": "Саксии — график Помпа B", "icon": "mdi:calendar-clock", "entries": sched_b})
    push("sensor.saksii_produljitelnost_a", props.get("woter_timer1"),
         {"friendly_name": "Саксии — ръчна продълж. A", "unit_of_measurement": "s", "icon": "mdi:timer-sand"})
    push("sensor.saksii_produljitelnost_b", props.get("woter_timer2"),
         {"friendly_name": "Саксии — ръчна продълж. B", "unit_of_measurement": "s", "icon": "mdi:timer-sand"})
    push("sensor.saksii_dnevnik", (props.get("run_log") or "празно"),
         {"friendly_name": "Саксии — дневник", "icon": "mdi:text-box-outline"})
    push("binary_sensor.saksii_online", "on" if online else "off",
         {"friendly_name": "Саксии — контролер онлайн", "device_class": "connectivity"})
    push("sensor.saksii_last_update", now,
         {"friendly_name": "Саксии — последно четене", "device_class": "timestamp", "icon": "mdi:update"})

    print("ok: schedules A=%d B=%d online=%s" % (len(sched_a), len(sched_b), online))


if __name__ == "__main__":
    main()
