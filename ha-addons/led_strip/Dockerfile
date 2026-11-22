FROM python:3.12-alpine3.22

# rpi_ws281x reads the board revision from /proc/device-tree, which Docker hides
# (/sys/firmware is masked). The Supervisor maps the device tree at /device-tree
# (config.yaml devicetree: true), so point the library there before building it.
RUN apk add --no-cache --virtual .build gcc musl-dev linux-headers \
    && pip download --no-deps --no-binary :all: rpi_ws281x==5.0.0 -d /tmp/src \
    && tar -xzf /tmp/src/rpi_ws281x-5.0.0.tar.gz -C /tmp/src \
    && sed -i 's#"/proc/device-tree/system/linux,revision"#"/device-tree/system/linux,revision"#' \
        /tmp/src/rpi_ws281x-5.0.0/lib/rpihw.c \
    && grep -q '"/device-tree/system/linux,revision"' /tmp/src/rpi_ws281x-5.0.0/lib/rpihw.c \
    && pip install --no-cache-dir /tmp/src/rpi_ws281x-5.0.0 \
    && rm -rf /tmp/src \
    && apk del .build

# The music patterns: parec records the Pi's output, numpy finds the bands.
RUN apk add --no-cache pulseaudio-utils \
    && pip install --no-cache-dir --only-binary=:all: numpy==2.3.5

WORKDIR /app
COPY server.py play.py patterns.py music.py ./

CMD ["python3", "-u", "server.py"]
