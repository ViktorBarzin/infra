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
# RE-VERIFY ON EVERY AUTHENTIK BUMP: bump the FROM tag below AND the image tag in
# modules/authentik/values.yaml together. The grep guards fail the build LOUDLY if
# the upstream target line moved. If a future authentik version adds a NEW
# login-capable source type, add its lowercase accessor to the list below.
# Upstream: the bare select_subclasses() is still present in main (no fix/PR as of
# 2026-06-28) — drop this overlay once upstream narrows the query.
FROM ghcr.io/goauthentik/server:2026.2.4

USER root
RUN set -eux; \
    F=/authentik/stages/identification/stage.py; \
    grep -q 'order_by("name").select_subclasses()' "$F"; \
    sed -i 's/order_by("name")\.select_subclasses()/order_by("name").select_subclasses("oauthsource", "samlsource", "plexsource", "telegramsource", "kerberossource")/' "$F"; \
    grep -q 'select_subclasses("oauthsource", "samlsource", "plexsource", "telegramsource", "kerberossource")' "$F"; \
    PY="$(command -v python || command -v python3)"; "$PY" -c "import ast,sys; ast.parse(open('$F').read())"; \
    rm -f /authentik/stages/identification/__pycache__/stage.*.pyc
USER authentik
