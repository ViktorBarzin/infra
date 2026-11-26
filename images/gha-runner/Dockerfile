# One-shot self-hosted GitHub Actions runner for the homelab (plan
# docs/plans/2026-11-26-gha-quota-fallback.md). The Woodpecker pipeline
# .woodpecker/gha-runner.yml starts it with a just-in-time config when the
# private GitHub minutes are used up. It runs the repo's own workflow jobs
# with `runs-on: homelab`, next to a Docker-in-Docker sidecar.
#
# GitHub's image has the runner, git, curl, sudo and the Docker CLI. The
# workflows also call jq, gh, python3, unzip and zstd, which ubuntu-latest
# has preinstalled.
FROM ghcr.io/actions/actions-runner:2.338.2

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends jq python3 unzip zstd xz-utils ca-certificates curl gnupg \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*
COPY gha_runner.py /usr/local/bin/gha-runner
USER runner
