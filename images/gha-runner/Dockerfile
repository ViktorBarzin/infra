# One-shot self-hosted GitHub Actions runner for the homelab (plan
# docs/plans/2026-11-26-gha-quota-fallback.md). The Woodpecker pipeline
# .woodpecker/gha-runner.yml starts it with a just-in-time config when the
# private GitHub minutes are used up. It runs the repo's own workflow jobs
# with `runs-on: homelab`, next to a Docker-in-Docker sidecar.
#
# GitHub's image has the runner, git, curl, sudo and the Docker CLI. The
# workflows also call node, npm, jq, gh, python3, unzip, zip, rsync and zstd,
# which ubuntu-latest has preinstalled. Without npm, the template's package
# check reports every @viktorbarzin package as unpublished (seen 2026-11-26).
FROM ghcr.io/actions/actions-runner:2.338.2

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends jq python3 unzip zip rsync zstd xz-utils ca-certificates curl gnupg \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*
# Node from nodejs.org: Ubuntu's 18 is too old for vite's bundler (rolldown
# needs node:util styleText, seen 2026-11-26); ubuntu-latest has 22 or later.
ARG NODE_VERSION=24.22.3
ARG NODE_SHA256=4f2b175a6d53a5c617a80dba2676238a0688cef28c6da4eba35c7d844e66fcfb
RUN curl -fsSLo /tmp/node.tar.xz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
 && echo "${NODE_SHA256}  /tmp/node.tar.xz" | sha256sum -c - \
 && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 --exclude CHANGELOG.md --exclude LICENSE --exclude README.md \
 && rm /tmp/node.tar.xz && node --version && npm --version
COPY gha_runner.py /usr/local/bin/gha-runner
USER runner
