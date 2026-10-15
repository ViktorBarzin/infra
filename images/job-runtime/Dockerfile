# job-runtime: the tools the frequent infra CronJobs need, baked in so their
# pods stop running `apk add` / `pip install` on every start. Each install
# wrote 14-60 MB to the node's container layer on sdc, and the 11 CronJobs
# that did it ran about 1,500 times a day (measured 2026-10-15).
# Pins change deliberately; Renovate does not scan Dockerfiles here.
FROM python:3.15-alpine3.24

RUN apk add --no-cache curl jq sqlite openssh-client

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir --disable-pip-version-check -r /tmp/requirements.txt \
    && rm /tmp/requirements.txt
