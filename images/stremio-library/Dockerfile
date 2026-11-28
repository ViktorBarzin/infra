# stremio-library: the runtime of the "Our server" Stremio addon
# (stacks/stremio/files, mounted from a ConfigMap at /app). The addon itself
# is standard-library Python; the image adds ffmpeg and ffsubsync, which time
# English subtitles to the sound of the playing file (subtitles.py).
# Pins change deliberately; Renovate does not scan Dockerfiles here.
FROM python:3.14.5-slim-trixie

# A static ffmpeg (about 80 MB) in place of Debian's, which brings 650 MB of
# libraries for codecs the addon never uses. Only ffmpeg is needed: ffsubsync
# runs on a WAV file that the addon extracts itself.
COPY --from=docker.io/mwader/static-ffmpeg:8.0 /ffmpeg /usr/local/bin/ffmpeg

# pip is removed once the pins are installed: nothing pip-installs at runtime.
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir --disable-pip-version-check -r /tmp/requirements.txt \
    && rm /tmp/requirements.txt \
    && pip uninstall -y pip \
    && ffsubsync --version

USER 65534:65534
