#!/usr/bin/env python3
"""Drive the rig iPhone through Appium and bring back a screenshot.

Talks the W3C WebDriver HTTP API directly so the devvm needs no Appium client
library. Appium listens on the Mac's loopback; `ios-rig tunnel` forwards it to
127.0.0.1 here.

    appium_screenshot.py out.png
    appium_screenshot.py out.png --url https://pages.viktorbarzin.me --tap 200,400
"""

import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

APPIUM = f"http://127.0.0.1:{os.environ.get('IOS_RIG_APPIUM_PORT', '4723')}"
UDID = os.environ.get("IOS_RIG_UDID", "00008110-001614D03442801E")


def call(method, path, body=None, timeout=180):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        APPIUM + path, data=data, method=method,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:600]
        raise SystemExit(f"Appium {method} {path} -> HTTP {e.code}\n{detail}")
    except urllib.error.URLError as e:
        raise SystemExit(
            f"Cannot reach Appium at {APPIUM} ({e.reason}).\n"
            "Is the tunnel up? systemctl --user status ios-rig-tunnel"
        )


# Stolen Device Protection on this phone gates the classic lockdown pairing
# behind Face ID, and Face ID is not enrolled for its current owner. Without
# that pairing Appium's usbmuxd device layer cannot attach, and a normal
# session dies at "Could not find a pair record for device".
#
# webDriverAgentUrl routes around it: the driver skips building, installing and
# launching WDA, and proxies straight to a WDA already running on the device,
# reached over Wi-Fi. assertWdaHostPlatformSupported early-returns on this cap,
# so no device-layer attach happens at all. Taps, gestures, screenshots, page
# source and mobile: deepLink all work; app install and device logs do not,
# because those genuinely need usbmux. Use `devicectl install app` for those.
WDA_URL = os.environ.get("IOS_RIG_WDA_URL", "http://192.168.9.205:8100")

CAPS = {
    "capabilities": {
        "alwaysMatch": {
            "platformName": "iOS",
            "appium:automationName": "XCUITest",
            "appium:udid": UDID,
            "appium:webDriverAgentUrl": WDA_URL,
            "appium:newCommandTimeout": 120,
        },
        "firstMatch": [{}],
    }
}


def wait_for_front(bundle_id, sid, timeout=30):
    """Block until bundle_id is the foreground app, or give up."""
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        info = call("POST", f"/session/{sid}/execute/sync",
                    {"script": "mobile: activeAppInfo", "args": []})["value"]
        last = info.get("bundleId")
        if last == bundle_id:
            # Frontmost is not the same as finished animating.
            time.sleep(1.5)
            print(f"{bundle_id} frontmost", file=sys.stderr)
            return True
        time.sleep(0.5)
    print(f"warning: {bundle_id} never came to the front (saw {last})", file=sys.stderr)
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--url", help="open this URL in Safari before screenshotting")
    ap.add_argument("--tap", help="tap at X,Y after loading")
    ap.add_argument("--bundle-id", help="launch this app instead of Safari")
    args = ap.parse_args()

    caps = json.loads(json.dumps(CAPS))
    if args.bundle_id:
        caps["capabilities"]["alwaysMatch"]["appium:bundleId"] = args.bundle_id

    sid = call("POST", "/session", caps)["value"]["sessionId"]
    print(f"session {sid}", file=sys.stderr)
    try:
        if args.url:
            call("POST", f"/session/{sid}/execute/sync",
                 {"script": "mobile: deepLink",
                  "args": [{"url": args.url, "bundleId": "com.apple.mobilesafari"}]})
            # A screenshot taken straight after a deepLink catches the iOS
            # app-switch animation and comes back as a blurred frosted pane.
            # Poll until the target app is actually frontmost instead.
            wait_for_front("com.apple.mobilesafari", sid)
        if args.tap:
            x, y = (int(v) for v in args.tap.split(","))
            call("POST", f"/session/{sid}/actions", {"actions": [{
                "type": "pointer", "id": "finger1",
                "parameters": {"pointerType": "touch"},
                "actions": [
                    {"type": "pointerMove", "duration": 0, "x": x, "y": y},
                    {"type": "pointerDown", "button": 0},
                    {"type": "pause", "duration": 120},
                    {"type": "pointerUp", "button": 0},
                ],
            }]})
            print(f"tapped {x},{y}", file=sys.stderr)
        png = call("GET", f"/session/{sid}/screenshot")["value"]
        with open(args.out, "wb") as f:
            f.write(base64.b64decode(png))
        print(f"wrote {args.out} ({os.path.getsize(args.out)} bytes)", file=sys.stderr)
    finally:
        call("DELETE", f"/session/{sid}", timeout=60)


if __name__ == "__main__":
    main()
