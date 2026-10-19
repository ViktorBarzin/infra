# job-runtime: the tools the frequent infra CronJobs need, baked in so their
# pods stop running `apk add` / `pip install` on every start. Each install
# wrote 14-60 MB to the node's container layer on sdc, and the 11 CronJobs
# that did it ran about 1,500 times a day (measured 2026-10-15).
# Pins change deliberately; Renovate does not scan Dockerfiles here.
FROM python:3.15-alpine3.24

# postgresql-client: net-worth-to-ha (wealthfolio) reads the wealthfolio_sync DB
RUN apk add --no-cache curl jq sqlite openssh-client postgresql-client

# pip is removed once the pins are installed: nothing pip-installs at runtime,
# and pip's vendored urllib3, msgpack and setuptools carry High CVEs that no
# pip release has fixed yet (pip 26.2.1, 2026-10).
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir --disable-pip-version-check -r /tmp/requirements.txt \
    && rm /tmp/requirements.txt \
    && pip uninstall -y pip
