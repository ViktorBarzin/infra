# pages-publish — renders markdown to pages.viktorbarzin.me and commits it to
# the monorepo. Needs git + an ssh client for the deploy-key clone/commit/push;
# needs the `markdown` lib because it shells out to the monorepo's render.py.
FROM python:3.12-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends git openssh-client ca-certificates \
 && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir fastapi "uvicorn[standard]" "markdown>=3.5"

# Non-root runtime user (uid 10001). Nothing is hardcoded to root: the pod
# securityContext fsGroup (set in the stack) makes the emptyDir /repo writable
# and the 0400 deploy-key secret group-readable by this uid. The key file stays
# owned by root, so OpenSSH's "permissions too open" check is skipped (it only
# fires when the key is owned by the running uid). A writable ~/.ssh lets
# StrictHostKeyChecking=accept-new record github's host key on first contact.
RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin pages \
 && mkdir -p /repo /home/pages/.ssh \
 && chown -R 10001:10001 /repo /home/pages/.ssh \
 && chmod 700 /home/pages/.ssh

# Trust the /repo emptyDir clone regardless of mount ownership. The emptyDir
# root is owned by root (fsGroup only sets the group), so git otherwise refuses
# operations in it as "dubious ownership" when running as uid 10001. Git honours
# safe.directory ONLY from system/global config (never -c or GIT_CONFIG_* env),
# so it must be baked into /etc/gitconfig here — an env var would be ignored.
RUN git config --system --add safe.directory /repo

WORKDIR /srv
COPY app /srv/app

ENV HOME=/home/pages \
    REPO_DIR=/repo \
    DEPLOY_KEY_PATH=/etc/pages-deploy/id_ed25519 \
    PYTHONUNBUFFERED=1

USER 10001
EXPOSE 8080
ENTRYPOINT ["python3", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
