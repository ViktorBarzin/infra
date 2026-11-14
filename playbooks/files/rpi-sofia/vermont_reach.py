#!/usr/bin/env python3
"""Vermont complex watch: is the video system reachable from outside, and is it healthy?

Runs every 5 minutes on rpi-sofia (vermont-reach.timer). One run:

1. collects observations:
   - in netns guestns (the complex LAN): the NVR (.150) and the back-door
     terminal (.117) over ISAPI: their own Hik-Connect registration, the NVR
     disk, channel status and new exception log entries;
   - in the host netns (the home internet): a TCP connect to the complex's
     public address on port 8000, the port residents use. No login is made.
2. turns them into checks and debounces each one: a check must fail on two
   runs in a row before a notification goes out, and a recovery message goes
   out only for a failure that was notified.
3. publishes the raw state as MQTT discovery sensors and each notification on
   MQTT topic vermont-reach/notify. An automation on ha-sofia sends that to
   Emil's phone and to HA's notifications.

Suppression keeps one cause to one message: while the complex internet is
down, the cloud and port checks do not count; while the NVR does not answer
on the LAN, its cloud, port, disk and camera checks do not count.

Credentials come from /etc/vermont-reach.env and the mosquitto_pub options
file; none of them is ever put on a command line.
"""
import json
import os
import re
import socket
import subprocess
import sys
import urllib.request
import uuid
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta

ENV = "/etc/vermont-reach.env"
STATE = "/var/lib/vermont-reach/state.json"
NS = "{http://www.hikvision.com/ver20/XMLSchema}"
NVR = "http://192.168.1.150:81"
ACS = "http://192.168.1.117"
NOTIFY_TOPIC = "vermont-reach/notify"
EXCLUDE_CHANNELS = {28}     # points at the Pi itself, not a camera
DEBOUNCE = 2                # failing runs in a row before a notification
EVENT_COOLDOWN = timedelta(hours=1)
TS = "%Y-%m-%dT%H:%M:%S"

# Exception log kinds that other checks already cover, or that are noise.
IGNORED_KINDS = {"illlegealAccess", "illegalAccess", "ezvizOffline",
                 "ezvizOperationAbnormal", "ezvizOnline"}
IGNORED_KIND_RE = re.compile(r"ipc.*(disconn|offline)|videoloss", re.I)
KIND_LABELS = {
    "hdError": "грешка на диска",
    "hdFull": "дискът е пълен",
    "netBroken": "NVR-ът загуби мрежата",
    "ipConflict": "IP конфликт",
    "recordException": "грешка при запис",
    "abnormalReboot": "неочакван рестарт",
}

CHECKS = {
    "internet": ("Интернетът на комплекса спря",
                 "Интернетът на комплекса се върна"),
    "nvr_lan": ("NVR-ът не отговаря в мрежата на комплекса",
                "NVR-ът отговаря отново"),
    "acs_lan": ("Задната врата (.117) не отговаря в мрежата на комплекса",
                "Задната врата (.117) отговаря отново"),
    "nvr_cloud": ("NVR-ът изпадна от Hik-Connect",
                  "NVR-ът е отново в Hik-Connect"),
    "acs_cloud": ("Задната врата (.117) изпадна от Hik-Connect",
                  "Задната врата (.117) е отново в Hik-Connect"),
    "port8000": ("Порт 8000 отвън не отговаря",
                 "Порт 8000 отвън отговаря отново"),
    "disk": ("Дискът на NVR-а не е наред", "Дискът на NVR-а е наред"),
}
DOWN_HINT = {
    "internet": "NVR-ът и задната врата са извън Hik-Connect и порт 8000 не отговаря. "
                "Камерите се виждат само през HA.",
    "nvr_lan": "Няма запис и няма картина. Вероятно няма ток или мрежа до NVR-а.",
    "acs_lan": "Вратата работи сама, но не се вижда отдалеч.",
    "nvr_cloud": "Интернетът в комплекса работи. Приложението няма да покаже камерите.",
    "acs_cloud": "Интернетът в комплекса работи. Вратата не се отваря от приложението.",
    "port8000": "Облакът работи, но живущите, които влизат през порт 8000, не виждат камерите. "
                "Възможно е публичният адрес на комплекса да е сменен.",
}


# ---------------------------------------------------------------- parsing

def parse_ezviz(text):
    """Hik-Connect registration as the device itself reports it."""
    m = re.search(r"<registerStatus>\s*(\w+)\s*</registerStatus>", text)
    return None if m is None else m.group(1).lower() == "true"


def parse_disk(text):
    """Worst HDD status: 'ok' when every disk is ok or idle."""
    statuses = re.findall(r"<status>\s*([^<\s]+)\s*</status>", text)
    if not statuses:
        return None
    bad = [s for s in statuses if s.lower() not in ("ok", "idle")]
    return bad[0] if bad else "ok"


def parse_channels(text):
    """{channel id: {'ip':..., 'online': bool}} without the excluded ids."""
    root = ET.fromstring(text)
    out = {}
    for ch in root.iter(NS + "InputProxyChannelStatus"):
        cid = ch.find(NS + "id")
        if cid is None or int(cid.text) in EXCLUDE_CHANNELS:
            continue
        onl = ch.find(NS + "online")
        ip = ch.find(NS + "sourceInputPortDescriptor/" + NS + "ipAddress")
        out[str(int(cid.text))] = {
            "ip": ip.text if ip is not None else "?",
            "online": (onl.text or "").strip().lower() == "true" if onl is not None else False,
        }
    return out


def parse_channel_names(text):
    root = ET.fromstring(text)
    names = {}
    for ch in root.iter(NS + "InputProxyChannel"):
        cid, name = ch.find(NS + "id"), ch.find(NS + "name")
        if cid is not None and name is not None and name.text:
            names[str(int(cid.text))] = name.text.strip()
    return names


def parse_log(text):
    """[{'time','kind','ip','channel'}] from an ISAPI logSearch answer."""
    out = []
    for block in re.findall(r"<logDescriptor>(.*?)</logDescriptor>", text, re.S):
        d = dict(re.findall(r"<(\w+)>([^<]*)</\1>", block))
        meta = d.get("metaId", "")
        out.append({"time": d.get("StartDateTime", "").rstrip("Z"),
                    "kind": meta.rsplit("/", 1)[-1],
                    "ip": d.get("ipAddress", ""),
                    "channel": d.get("channelNo") or d.get("localChannelNo") or ""})
    return out


# ------------------------------------------------------------- evaluation

def derive_internet(obs):
    """Up if any outside path works; down only if every known one fails."""
    signals = []
    if obs.get("nvr_lan"):
        signals.append(obs.get("nvr_cloud"))
        signals.append(obs.get("port8000"))
    if obs.get("acs_lan"):
        signals.append(obs.get("acs_cloud"))
    known = [s for s in signals if s is not None]
    if not known:
        return None
    return any(known)


def check_values(obs):
    """{check: True good | False bad | None unknown | 'suppress'}."""
    internet = derive_internet(obs)
    nvr_ok = obs.get("nvr_lan")
    vals = {"internet": internet, "nvr_lan": nvr_ok, "acs_lan": obs.get("acs_lan")}
    for key, lan in (("nvr_cloud", nvr_ok), ("acs_cloud", obs.get("acs_lan")),
                     ("port8000", nvr_ok)):
        if not lan or internet is False:
            vals[key] = "suppress"
        else:
            vals[key] = obs.get(key)
    disk = obs.get("disk")
    vals["disk"] = "suppress" if not nvr_ok else (None if disk is None else disk == "ok")
    channels = obs.get("channels")
    if not nvr_ok:
        for cid in obs.get("known_channels", []):
            vals["cam:" + cid] = "suppress"
    elif channels is not None:
        for cid, ch in channels.items():
            vals["cam:" + cid] = ch["online"]
    return vals


def fmt_duration(seconds):
    seconds = int(seconds)
    d, rem = divmod(seconds, 86400)
    h, rem = divmod(rem, 3600)
    m, s = divmod(rem, 60)
    parts = ["%d%s" % (v, u) for v, u in ((d, "д"), (h, "ч"), (m, "м")) if v]
    if not (d or h) and (s or not parts):
        parts.append("%dс" % s)
    return " ".join(parts)


def fmt_time(dt):
    return dt.strftime("%d.%m.%Y %H:%M:%S")


def camera_label(cid, obs, state):
    names = state.get("names", {})
    ip = (obs.get("channels") or {}).get(cid, {}).get("ip") or \
        state.get("channel_ips", {}).get(cid, "?")
    name = names.get(cid)
    return ("%s (канал %s, %s)" % (name, cid, ip)) if name else ("Канал %s (%s)" % (cid, ip))


def down_message(key, since, obs, state):
    if key.startswith("cam:"):
        cid = key[4:]
        title = "Камера падна: " + camera_label(cid, obs, state)
        body = "Засечено: %s.\nNVR-ът не получава картина от камерата." % fmt_time(since)
        return title, body
    title = CHECKS[key][0]
    body = "Засечено: %s." % fmt_time(since)
    if key == "disk":
        body += "\nСъстояние на диска: %s. Записът може да е спрял." % obs.get("disk")
    elif DOWN_HINT.get(key):
        body += "\n" + DOWN_HINT[key]
    if key == "internet":
        if since.hour == 0 and since.minute < 20:
            body += "\nСпиране около полунощ: първо проверете дали таксата към Prolan е платена."
        else:
            body += "\nПроверете при Prolan за авария или неплатена такса."
    return title, body


def up_message(key, since, now, obs, state):
    if key.startswith("cam:"):
        title = "Камерата се върна: " + camera_label(key[4:], obs, state)
    else:
        title = CHECKS[key][1]
    body = "Повредата е засечена в %s.\nВъзстановено в %s, след %s." % (
        fmt_time(since), fmt_time(now), fmt_duration((now - since).total_seconds()))
    return title, body


def evaluate(state, obs, now):
    """Advance the per-check state. Returns (state, notifications)."""
    checks = state.setdefault("checks", {})
    notes = []
    for key, val in sorted(check_values(obs).items()):
        st = checks.setdefault(key, {"bad": 0, "since": None, "notified": False})
        if val is None:
            continue
        if val == "suppress":
            if not st["notified"]:
                st.update(bad=0, since=None)
            continue
        if val is False:
            st["bad"] += 1
            if st["since"] is None:
                st["since"] = now.strftime(TS)
            if st["bad"] >= DEBOUNCE and not st["notified"]:
                title, body = down_message(key, datetime.strptime(st["since"], TS), obs, state)
                notes.append({"kind": key, "state": "down", "title": title, "message": body})
                st["notified"] = True
        else:
            if st["notified"]:
                title, body = up_message(key, datetime.strptime(st["since"], TS), now, obs, state)
                notes.append({"kind": key, "state": "up", "title": title, "message": body})
            st.update(bad=0, since=None, notified=False)
    if obs.get("channels"):
        state["channel_ips"] = {cid: ch["ip"] for cid, ch in obs["channels"].items()}
    return state, notes


def log_window_start(state, now):
    """Where the next exception log search starts."""
    last = state.get("log_last")
    if last:
        return datetime.strptime(last, TS)
    return now


def new_events(state, entries, now):
    """Filter log entries to new, relevant ones and fold them into one message."""
    seen = set(state.get("log_seen", []))
    last = state.get("log_last")
    cooldown = state.setdefault("event_cooldown", {})
    fresh = []
    for e in sorted(entries, key=lambda x: x["time"]):
        key = "%s|%s|%s" % (e["time"], e["kind"], e["channel"])
        if key in seen or (last and e["time"] < last):
            continue
        seen.add(key)
        if e["kind"] in IGNORED_KINDS or IGNORED_KIND_RE.search(e["kind"]):
            continue
        until = cooldown.get(e["kind"])
        if until and datetime.strptime(until, TS) > now:
            continue
        cooldown[e["kind"]] = (now + EVENT_COOLDOWN).strftime(TS)
        fresh.append(e)
    if entries:
        newest = max(e["time"] for e in entries)
        state["log_last"] = max(newest, last or newest)
        state["log_seen"] = sorted(k for k in seen if k.split("|", 1)[0] >= state["log_last"])
    elif not last:
        state["log_last"] = now.strftime(TS)
    if not fresh:
        return None
    lines = []
    for e in fresh:
        label = KIND_LABELS.get(e["kind"], e["kind"])
        when = datetime.strptime(e["time"], TS)
        extra = (", канал %s" % e["channel"]) if e["channel"] else ""
        lines.append("%s: %s%s" % (fmt_time(when), label, extra))
    title = "NVR съобщи за повреда" if len(fresh) == 1 else \
        "NVR съобщи за %d повреди" % len(fresh)
    return {"kind": "event", "state": "event", "title": title,
            "message": "\n".join(lines) + "\nСъщият вид се съобщава най-много веднъж на час."}


# ------------------------------------------------------------- collection

def load_env(path):
    cfg = {}
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip().strip('"').strip("'")
    return cfg


def isapi(base, user, password, path, data=None, timeout=15):
    """One ISAPI request with a fresh digest handshake (the .117 rejects reused nonces)."""
    mgr = urllib.request.HTTPPasswordMgrWithDefaultRealm()
    mgr.add_password(None, base, user, password)
    opener = urllib.request.build_opener(urllib.request.HTTPDigestAuthHandler(mgr))
    req = urllib.request.Request(base + path, data=data.encode() if data else None,
                                 method="POST" if data else "GET")
    with opener.open(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


def collect_complex(cfg, log_start, log_end, want_names):
    """Runs inside netns guestns. Never raises: a failed call leaves None."""
    obs = {"nvr_lan": False, "acs_lan": False}
    nvr = (NVR, cfg["NVR_USER"], cfg["NVR_PASS"])
    try:
        obs["nvr_cloud"] = parse_ezviz(isapi(*nvr, "/ISAPI/System/Network/EZVIZ"))
        obs["nvr_lan"] = True
    except Exception as exc:                      # noqa: BLE001
        obs["nvr_error"] = str(exc)[:200]
    if obs["nvr_lan"]:
        for key, fn in (("disk", lambda: parse_disk(isapi(*nvr, "/ISAPI/ContentMgmt/Storage"))),
                        ("channels", lambda: parse_channels(
                            isapi(*nvr, "/ISAPI/ContentMgmt/InputProxy/channels/status")))):
            try:
                obs[key] = fn()
            except Exception as exc:              # noqa: BLE001
                obs[key + "_error"] = str(exc)[:200]
        if want_names:
            try:
                obs["names"] = parse_channel_names(
                    isapi(*nvr, "/ISAPI/ContentMgmt/InputProxy/channels"))
            except Exception:                     # noqa: BLE001
                pass
        body = ('<?xml version="1.0" encoding="UTF-8"?><CMSearchDescription>'
                '<searchID>%s</searchID><metaId>log.std-cgi.com/Exception</metaId>'
                '<timeSpanList><timeSpan><startTime>%sZ</startTime><endTime>%sZ</endTime>'
                '</timeSpan></timeSpanList><maxResults>200</maxResults>'
                '<searchResultPostion>0</searchResultPostion></CMSearchDescription>'
                % (uuid.uuid4(), log_start, log_end))
        try:
            obs["log"] = parse_log(isapi(*nvr, "/ISAPI/ContentMgmt/logSearch", data=body))
        except Exception as exc:                  # noqa: BLE001
            obs["log_error"] = str(exc)[:200]
    try:
        obs["acs_cloud"] = parse_ezviz(isapi(ACS, cfg["ACS_USER"], cfg["ACS_PASS"],
                                             "/ISAPI/System/Network/EZVIZ"))
        obs["acs_lan"] = True
    except Exception as exc:                      # noqa: BLE001
        obs["acs_error"] = str(exc)[:200]
    return obs


def port_open(host, port, attempts=2, timeout=5):
    for _ in range(attempts):
        try:
            with socket.create_connection((host, int(port)), timeout=timeout):
                return True
        except OSError:
            continue
    return False


# ------------------------------------------------------------- publishing

SENSORS = [
    # (object id, name, component, value key, device_class)
    ("vermont_internet_kompleks", "Вермонт интернет на комплекса", "binary_sensor", "internet", "connectivity"),
    ("vermont_nvr_lokalno", "Вермонт NVR в мрежата", "binary_sensor", "nvr_lan", "connectivity"),
    ("vermont_nvr_hik_connect", "Вермонт NVR в Hik-Connect", "binary_sensor", "nvr_cloud", "connectivity"),
    ("vermont_117_lokalno", "Вермонт задна врата в мрежата", "binary_sensor", "acs_lan", "connectivity"),
    ("vermont_117_hik_connect", "Вермонт задна врата в Hik-Connect", "binary_sensor", "acs_cloud", "connectivity"),
    ("vermont_port_8000_otvan", "Вермонт порт 8000 отвън", "binary_sensor", "port8000", "connectivity"),
    ("vermont_nvr_disk", "Вермонт NVR диск", "sensor", "disk", None),
]


def mqtt_pub(cfg, topic, payload, retain):
    # User and password come from $XDG_CONFIG_HOME/mosquitto_pub, not argv.
    cmd = ["mosquitto_pub", "-h", cfg["MQTT_HOST"], "-p", cfg.get("MQTT_PORT", "1883"),
           "-q", "1", "-t", topic, "-m", payload]
    if retain:
        cmd.append("-r")
    env = dict(os.environ, XDG_CONFIG_HOME=cfg.get("MQTT_OPTIONS_DIR", "/etc/vermont-reach"))
    r = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if r.returncode != 0:
        raise RuntimeError("mosquitto_pub %s: %s" % (topic, r.stderr.strip()))


def publish_sensors(cfg, obs):
    prefix = cfg.get("DISCOVERY_PREFIX", "homeassistant")
    values = dict(obs, internet=derive_internet(obs))
    for oid, name, comp, key, dclass in SENSORS:
        base = "%s/%s/%s" % (prefix, comp, oid)
        disc = {"name": name, "unique_id": oid, "object_id": oid,
                "state_topic": base + "/state", "expire_after": 1200,
                "device": {"identifiers": ["rpi-sofia"], "name": "rpi-sofia"}}
        if comp == "binary_sensor":
            disc["device_class"] = dclass
            val = values.get(key)
            payload = "None" if val is None else ("ON" if val else "OFF")
        else:
            disc["icon"] = "mdi:harddisk"
            payload = values.get(key) or "None"
        mqtt_pub(cfg, base + "/config", json.dumps(disc, ensure_ascii=False), retain=True)
        mqtt_pub(cfg, base + "/state", payload, retain=True)


def load_state():
    try:
        with open(STATE) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def save_state(state):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh, ensure_ascii=False, indent=1)
    os.replace(tmp, STATE)


def run_collector(cfg, log_start, log_end, want_names):
    """Re-run this file inside guestns; credentials travel on stdin."""
    payload = json.dumps({"cfg": cfg, "log_start": log_start, "log_end": log_end,
                          "want_names": want_names})
    r = subprocess.run(["ip", "netns", "exec", "guestns", sys.executable,
                        os.path.abspath(__file__), "--collect"],
                       input=payload, capture_output=True, text=True, timeout=180)
    if r.returncode != 0:
        raise RuntimeError("collector rc=%s: %s" % (r.returncode, r.stderr.strip()[:300]))
    return json.loads(r.stdout)


TEST_KINDS = ["internet", "nvr_lan", "nvr_cloud", "acs_cloud", "port8000", "disk"]


def send_test(cfg):
    """One test notification of every kind, through the real MQTT path."""
    now = datetime.now().replace(microsecond=0)
    since = now - timedelta(minutes=10)
    obs = {"disk": "error", "channels": {"1": {"ip": "192.168.1.51", "online": False}}}
    state = {"names": {"1": "Camera 01"}}
    notes = []
    for key in TEST_KINDS + ["cam:1"]:
        title, body = down_message(key, since, obs, state)
        notes.append({"title": title, "message": body})
    title, body = up_message("internet", since, now, obs, state)
    notes.append({"title": title, "message": body})
    ev = new_events({"log_last": since.strftime(TS)},
                    [{"time": now.strftime(TS), "kind": "hdError", "ip": "", "channel": ""}], now)
    notes.append(ev)
    for n in notes:
        n = dict(n, title="ТЕСТ: " + n["title"], kind="test", state="test")
        mqtt_pub(cfg, NOTIFY_TOPIC, json.dumps(n, ensure_ascii=False), retain=False)
    print("пратени %d тестови известия" % len(notes))


def main(argv):
    if "--collect" in argv:
        req = json.load(sys.stdin)
        obs = collect_complex(req["cfg"], req["log_start"], req["log_end"], req["want_names"])
        json.dump(obs, sys.stdout, ensure_ascii=False)
        return 0
    cfg = load_env(ENV)
    if "--test-notify" in argv:
        send_test(cfg)
        return 0
    dry = "--dry-run" in argv
    now = datetime.now().replace(microsecond=0)
    state = load_state()
    start = log_window_start(state, now)
    names_at = state.get("names_at")
    want_names = not names_at or datetime.strptime(names_at, TS) < now - timedelta(days=1)
    obs = run_collector(cfg, start.strftime(TS), (now + timedelta(minutes=2)).strftime(TS),
                        want_names)
    if obs.get("names"):
        state["names"], state["names_at"] = obs.pop("names"), now.strftime(TS)
    obs["port8000"] = port_open(cfg["PUBLIC_HOST"], cfg.get("PUBLIC_PORT", "8000"))
    obs["known_channels"] = sorted(state.get("channel_ips", {}))
    state, notes = evaluate(state, obs, now)
    if obs.get("log") is not None:
        ev = new_events(state, obs["log"], now)
        if ev:
            notes.append(ev)
    summary = {k: obs.get(k) for k in ("nvr_lan", "nvr_cloud", "acs_lan", "acs_cloud",
                                       "port8000", "disk")}
    down = sorted(c for c, ch in (obs.get("channels") or {}).items() if not ch["online"])
    print("internet=%s %s cams_down=%s notes=%d" % (
        derive_internet(obs), json.dumps(summary), down, len(notes)))
    for k in ("nvr_error", "acs_error", "log_error", "disk_error", "channels_error"):
        if obs.get(k):
            print("%s: %s" % (k, obs[k]), file=sys.stderr)
    for n in notes:
        print("известие: %s | %s" % (n["title"], n["message"].replace("\n", " / ")))
    if dry:
        return 0
    publish_sensors(cfg, obs)
    for n in notes:
        mqtt_pub(cfg, NOTIFY_TOPIC, json.dumps(n, ensure_ascii=False), retain=False)
    save_state(state)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
