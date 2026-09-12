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
import urllib.error
import urllib.request

APPIUM = f"http://127.0.0.1:{os.environ.get('IOS_RIG_APPIUM_PORT', '4723')}"
UDID = os.environ.get("IOS_RIG_UDID", "00008110-001614D03442801E")
TEAM = os.environ.get("IOS_RIG_TEAM_ID", "26NB4W97WL")
WDA_BUNDLE = os.environ.get("IOS_RIG_WDA_BUNDLE_ID", "me.viktorbarzin.wda")


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


CAPS = {
    "capabilities": {
        "alwaysMatch": {
            "platformName": "iOS",
            "appium:automationName": "XCUITest",
            "appium:udid": UDID,
            "appium:xcodeOrgId": TEAM,
            "appium:xcodeSigningId": "Apple Development",
            "appium:updatedWDABundleId": WDA_BUNDLE,
            # Reuse a WDA that is already installed and signed rather than
            # rebuilding on every session. The 48h LaunchAgent owns re-signing.
            "appium:usePrebuiltWDA": True,
            "appium:newCommandTimeout": 120,
            "appium:wdaLaunchTimeout": 180_000,
        },
        "firstMatch": [{}],
    }
}


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
