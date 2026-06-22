# chrome-service browser image (ADR-0002, infra-owned, built off-infra on GHA).
#
# The Playwright base provides Xvfb + every browser runtime dep + fonts. On top
# we install REAL Google Chrome for its licensed proprietary codecs (H.264/AAC):
# the bundled open-source Chromium ships with those codecs COMPILED OUT, so
# H.264/AAC video (Instagram Reels, X, most .mp4) fails in the noVNC view with
# MEDIA_ERR_SRC_NOT_SUPPORTED. Swapping libffmpeg.so does NOT help (Playwright's
# Chromium has the codecs compiled out, not just the lib stripped), and Chrome
# for Testing is also codec-less — only google-chrome-stable carries them.
#
# main.tf launches /opt/google/chrome/chrome instead of the bundled
# /ms-playwright/chromium-*/chrome. connect_over_cdp callers (tripit fare scrape,
# homelab browser, snapshot-harvester) attach to whatever Chrome runs here.
FROM mcr.microsoft.com/playwright:v1.48.0-noble

RUN apt-get update \
 && apt-get install -y --no-install-recommends wget gnupg ca-certificates \
 && wget -qO- https://dl.google.com/linux/linux_signing_key.pub \
      | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg \
 && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
      > /etc/apt/sources.list.d/google-chrome.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends google-chrome-stable \
 && rm -rf /var/lib/apt/lists/*

# Fail the build if Chrome isn't runnable / the path moved.
RUN /opt/google/chrome/chrome --version
