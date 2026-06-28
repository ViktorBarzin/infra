#!/usr/bin/env python3
"""Overlay patch #2 — serve authentik's no-JS SFE login to old Safari/WebKit.

authentik's modern flow SPA uses ES2022 (static{} init blocks) that hard-fail on
Safari <= 16.3 (e.g. iPadOS <= 16.3) and render a COMPLETELY BLANK login. authentik
already ships the Simplified Flow Executor (SFE, ES5, /web/dist/sfe) and serves it
when flows/views/interface.py::compat_needs_sfe() returns True — but that only
detects IE / old-Edge / PKeyAuth, never old Safari. This extends it to old
Safari/WebKit so those clients get the REAL authentik login (password + MFA +
reputation, identity preserved — NO auth downgrade) instead of a blank page.

Guarded + idempotent-safe: asserts the upstream anchor exists exactly once and the
result parses, so the image build fails LOUDLY if upstream moves the code.
RE-VERIFY on every authentik upgrade (the anchor / SFE asset can change).
"""
import ast
import glob
import os

TARGET = "/authentik/flows/views/interface.py"

# Upstream tail of compat_needs_sfe() (authentik 2026.2.x).
ANCHOR = (
    '        if "PKeyAuth" in ua["string"]:\n'
    "            return True\n"
    "        return False"
)
REPLACEMENT = (
    '        if "PKeyAuth" in ua["string"]:\n'
    "            return True\n"
    "        # OVERLAY: old Safari/WebKit (iPadOS<=16.3) cannot parse the modern\n"
    "        # ES2022 flow SPA and renders a blank login; serve the SFE instead so\n"
    "        # those clients get the real authentik login (password + MFA).\n"
    '        if ua["user_agent"]["family"] in ("Safari", "Mobile Safari"):\n'
    "            try:\n"
    '                _maj = int(ua["user_agent"]["major"] or 0)\n'
    '                _min = int(ua["user_agent"]["minor"] or 0)\n'
    "            except (TypeError, ValueError):\n"
    "                _maj = _min = 0\n"
    "            if _maj and (_maj < 16 or (_maj == 16 and _min <= 3)):\n"
    "                return True\n"
    "        return False"
)

src = open(TARGET).read()
assert "def compat_needs_sfe" in src, "compat_needs_sfe() not found — upstream changed"
assert src.count(ANCHOR) == 1, f"anchor not found exactly once in {TARGET}"
src = src.replace(ANCHOR, REPLACEMENT)
open(TARGET, "w").write(src)
ast.parse(src)  # fail the build on a malformed patch
assert "Mobile Safari" in open(TARGET).read(), "patch did not apply"
for pyc in glob.glob("/authentik/flows/views/__pycache__/interface.*.pyc"):
    os.remove(pyc)
print("patch-compat-sfe: compat_needs_sfe() now serves the SFE to Safari<=16.3")
