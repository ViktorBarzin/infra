#!/usr/bin/env python3
"""Overlay patch — make authentik usable on OLD browsers (no modern-JS SPA).

authentik's modern flow SPA is ES2022 (static{} init blocks) that hard-fail on
Safari/WebKit <= 16.3 (e.g. iPadOS <= 16.3) and render a COMPLETELY BLANK login.
authentik ships a no-JS Simplified Flow Executor (SFE, ES5) but only serves it to
IE / old-Edge / PKeyAuth, and the SFE itself canNOT render Identification-stage
sources (social-login buttons) — authentik docs list "Sources" as unsupported.

This patch does TWO things, both guarded (assert the upstream anchor + verify the
result) so the image build fails LOUDLY if upstream moves. RE-VERIFY on every
authentik upgrade.

  1. flows/views/interface.py::compat_needs_sfe() -> also return True for old
     Safari/WebKit: (a) Safari/Mobile Safari Version <= 16.3 (covers desktop-mode
     iPadOS which reports as Mac Safari), and (b) ANY iOS browser (Chrome/CriOS,
     Firefox/FxiOS, Edge — all share the system WebKit) on iOS <= 16.3. So old
     iPads get the SFE on EVERY browser, not just Safari.

  2. flows/templates/if/flow-sfe.html -> inject static social-login <a> links
     (plain redirects to /source/oauth/login/<slug>/, work on ANY browser) so SFE
     users (who otherwise see only username/password) can use social login —
     required for accounts with no password (e.g. Google-only users like emo).
"""
import ast
import glob
import os

# --- Patch 1: compat_needs_sfe() UA gate -------------------------------------
INTERFACE = "/authentik/flows/views/interface.py"
ANCHOR = (
    '        if "PKeyAuth" in ua["string"]:\n'
    "            return True\n"
    "        return False"
)
REPLACEMENT = (
    '        if "PKeyAuth" in ua["string"]:\n'
    "            return True\n"
    "        # OVERLAY: old WebKit can't parse the modern ES2022 flow SPA (blank\n"
    "        # login) -> serve the SFE (real authentik login). (a) desktop-mode\n"
    "        # Safari/iPadOS reports as Mac Safari with Version<=16.3:\n"
    '        if ua["user_agent"]["family"] in ("Safari", "Mobile Safari"):\n'
    "            try:\n"
    '                _maj = int(ua["user_agent"]["major"] or 0)\n'
    '                _min = int(ua["user_agent"]["minor"] or 0)\n'
    "            except (TypeError, ValueError):\n"
    "                _maj = _min = 0\n"
    "            if _maj and (_maj < 16 or (_maj == 16 and _min <= 3)):\n"
    "                return True\n"
    "        # (b) ANY iOS browser (Chrome/CriOS, Firefox/FxiOS, Edge) shares the\n"
    "        # system WebKit, so iOS<=16.3 fails regardless of the browser family:\n"
    '        if ua["os"]["family"] == "iOS":\n'
    "            try:\n"
    '                _omaj = int(ua["os"]["major"] or 0)\n'
    '                _omin = int(ua["os"]["minor"] or 0)\n'
    "            except (TypeError, ValueError):\n"
    "                _omaj = _omin = 0\n"
    "            if _omaj and (_omaj < 16 or (_omaj == 16 and _omin <= 3)):\n"
    "                return True\n"
    "        return False"
)
src = open(INTERFACE).read()
assert "def compat_needs_sfe" in src, "compat_needs_sfe() not found — upstream changed"
assert src.count(ANCHOR) == 1, f"anchor not found exactly once in {INTERFACE}"
src = src.replace(ANCHOR, REPLACEMENT)
open(INTERFACE, "w").write(src)
ast.parse(src)
assert 'ua["os"]["family"] == "iOS"' in open(INTERFACE).read()
for pyc in glob.glob("/authentik/flows/views/__pycache__/interface.*.pyc"):
    os.remove(pyc)

# --- Patch 2: social-login links on the SFE shell ----------------------------
SFE_HTML = "/authentik/flows/templates/if/flow-sfe.html"
HTML_ANCHOR = (
    "        </main>\n"
    "        <span class=\"mt-3 mb-0 text-muted text-center\">{% trans 'Powered by authentik' %}</span>"
)
HTML_REPLACEMENT = (
    "        </main>\n"
    "        <!-- OVERLAY: the SFE can't render Identification-stage sources, so add\n"
    "             static social-login links (plain redirects, work on any browser).\n"
    "             Re-verify slugs on source changes; shown on all SFE flows. -->\n"
    '        <div class="form-signin w-100 m-auto pt-2 mt-2 border-top">\n'
    '          <a class="btn btn-outline-secondary w-100 mb-2" href="/source/oauth/login/google/">Continue with Google</a>\n'
    '          <a class="btn btn-outline-secondary w-100 mb-2" href="/source/oauth/login/github/">Continue with GitHub</a>\n'
    '          <a class="btn btn-outline-secondary w-100 mb-2" href="/source/oauth/login/facebook/">Continue with Facebook</a>\n'
    "        </div>\n"
    "        <span class=\"mt-3 mb-0 text-muted text-center\">{% trans 'Powered by authentik' %}</span>"
)
html = open(SFE_HTML).read()
assert html.count(HTML_ANCHOR) == 1, f"SFE html anchor not found exactly once in {SFE_HTML}"
html = html.replace(HTML_ANCHOR, HTML_REPLACEMENT)
open(SFE_HTML, "w").write(html)
assert "Continue with Google" in open(SFE_HTML).read()

print("patch-compat-sfe: SFE for old Safari + all iOS<=16.3; social-login links added to SFE")
