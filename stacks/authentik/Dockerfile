# SLOW-1a overlay over the official authentik server image.
#
# The login flow's identification stage renders each enabled source's UI login
# button. Upstream authentik/stages/identification/stage.py does:
#     current_stage.sources.filter(enabled=True).order_by("name").select_subclasses()
# The bare no-arg select_subclasses() (django-model-utils InheritanceManager)
# LEFT-JOINs EVERY Source subtype table; on the cold-login hot path that is ~1.5s
# (verified live on 2026.2.4: 1527ms vs 14ms). Passing only the subtypes that
# actually render a UI login button — every concrete Source type that overrides
# ui_login_button: oauth/saml/plex/telegram/kerberos, NOT the sync-only ldap/scim —
# is ~100x faster and BYTE-IDENTICAL output (verified: concrete types + rendered
# buttons match). django-model-utils accepts the lowercase subclass *accessor
# names* as strings, so no new import is needed (no circular-import risk) — the
# patch is a single, reviewable line edit.
#
# RE-VERIFY ON EVERY AUTHENTIK BUMP: the FROM tag below, the hardcoded tags in
# .github/workflows/build-authentik.yml, and the image tag in
# modules/authentik/values.yaml all move together — see the UPGRADE note in
# values.yaml for the full per-hop procedure. The grep guards fail the build LOUDLY
# if the upstream target line moved. If a future authentik version adds a NEW
# login-capable source type, add its lowercase accessor to the list below.
# Upstream: still present in main as of 2026.8.0. Proposed upstream as
# goauthentik/authentik#25238, which derives the login-capable subclasses instead of
# listing them — drop this overlay once that (or any equivalent narrowing) ships.
FROM ghcr.io/goauthentik/server:2026.8.0

USER root
RUN set -eux; \
    F=/authentik/stages/identification/stage.py; \
    grep -q 'order_by("name").select_subclasses()' "$F" || { \
      echo "=== SLOW-1a GUARD TRIPPED ==="; \
      echo "The upstream target line is gone from $F."; \
      echo "This is EXPECTED, not a bug: the fix went upstream as"; \
      echo "goauthentik/authentik#25238, merged to main and cherry-picked to"; \
      echo "version-2026.8 on 2026-08-21. Any base image newer than the"; \
      echo "version/2026.8.0 tag already narrows this query itself."; \
      echo "DO: delete this entire PATCH #1 RUN block and the comment above it."; \
      echo "DO NOT: repair the grep or re-apply the sed. It is redundant now."; \
      echo "KEEP: PATCH #2 below (old-browser SFE). That one is NOT upstream --"; \
      echo "  its PR #25247 is milestoned for 2026.11 as nice-to-have."; \
      exit 1; \
    }; \
    sed -i 's/order_by("name")\.select_subclasses()/order_by("name").select_subclasses("oauthsource", "samlsource", "plexsource", "telegramsource", "kerberossource")/' "$F"; \
    grep -q 'select_subclasses("oauthsource", "samlsource", "plexsource", "telegramsource", "kerberossource")' "$F"; \
    PY="$(command -v python || command -v python3)"; "$PY" -c "import ast,sys; ast.parse(open('$F').read())"; \
    rm -f /authentik/stages/identification/__pycache__/stage.*.pyc

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
