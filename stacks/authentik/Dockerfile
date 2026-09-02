# Old-browser overlay over the official authentik server image.
#
# ONE patch remains (PATCH #2 below). The overlay's original reason — SLOW-1a,
# the login-flow select_subclasses() narrowing — WENT UPSTREAM and shipped in
# 2026.8.1, so it is gone from here. Do not re-add it: 2026.8.1 carries
# goauthentik/authentik#25238 (cherry-pick 2d140c46, "stages/identification:
# only join Source subtypes that can render a login button"), which derives the
# login-capable subclasses via an @cache'd login_capable_source_subclasses()
# instead of our hardcoded list — strictly better, since a new login-capable
# source type is picked up automatically. Verified against the version/2026.8.1
# source on 2026-09-02: stage.py now reads
#     .select_subclasses(*login_capable_source_subclasses())
# History of that fix (~1.5s -> ~14ms on the cold-login hot path, measured live
# on 2026.2.4: 1527ms vs 14ms) is in the git log of this file, up to 2026.8.0.
#
# RE-VERIFY ON EVERY AUTHENTIK BUMP: the FROM tag below, the hardcoded tags in
# .github/workflows/build-authentik.yml, and the image tag in
# modules/authentik/values.yaml all move together — see the UPGRADE note in
# values.yaml for the full per-hop procedure. patch-compat-sfe.py asserts its
# upstream anchors, so the build fails LOUDLY if upstream moves underneath it.
FROM ghcr.io/goauthentik/server:2026.8.1

USER root
# PATCH #2 — old-browser BLANK LOGIN. authentik's modern flow SPA is ES2022 and
# hard-fails (blank login) on Safari<=16.3 (e.g. iPadOS<=16.3). authentik already
# ships a no-JS Simplified Flow Executor (SFE, ES5) but only serves it to
# IE/old-Edge/PKeyAuth. patch-compat-sfe.py (a) extends compat_needs_sfe() to
# serve the SFE to old Safari AND any iOS browser (Chrome/CriOS, Firefox/FxiOS —
# all share the system WebKit) on iOS<=16.3, and (b) injects static social-login
# <a> links into the SFE shell (the SFE can't render Identification-stage sources;
# needed for password-less Google-only accounts). Clients get the REAL authentik
# login (password + MFA + reputation, NO auth downgrade) instead of a blank page.
# The script is guarded (asserts both upstream anchors + ast-parses) so the build
# fails loudly if upstream moves — re-verify on every authentik bump.
COPY patch-compat-sfe.py /tmp/patch-compat-sfe.py
RUN python3 /tmp/patch-compat-sfe.py && rm -f /tmp/patch-compat-sfe.py
USER authentik
