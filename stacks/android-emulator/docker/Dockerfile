# Android emulator runner — slim on purpose: the SDK proper (platform-tools,
# emulator, system image, AVD) lives on the stack's PVC and is installed by
# entrypoint.sh on first boot, so this image carries only the JDK,
# cmdline-tools and the native libraries the emulator needs at runtime.
#
# Rebuild + push (rare — only when tool/library versions bump):
#   docker build -t forgejo.viktorbarzin.me/viktor/android-emulator:api36-v8 .
#   docker push forgejo.viktorbarzin.me/viktor/android-emulator:api36-v8
FROM eclipse-temurin:17-jdk-jammy

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    # emulator runtime deps (Qt window into Xvfb)
    libpulse0 libgl1 libglu1-mesa libnss3 libasound2 libfontconfig1 \
    libx11-6 libxcb1 libxcomposite1 libxcursor1 libxdamage1 libxext6 \
    libxfixes3 libxi6 libxrandr2 libxrender1 libxtst6 libxkbcommon0 \
    libegl1 libgles2 \
    libxkbfile1 libsm6 libice6 libdbus-1-3 \
    # virtual display + browser viewing
    xvfb x11vnc novnc websockify openbox wmctrl xdotool \
    # adb TCP forwarding + fetch tooling
    socat wget unzip ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Android cmdline-tools (sdkmanager/avdmanager). Pinned; SDK packages they
# install land on the PVC at /sdk, not in this image.
ARG CMDLINE_TOOLS_VERSION=13114758
RUN mkdir -p /opt/android/cmdline-tools && \
    wget -q "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_VERSION}_latest.zip" -O /tmp/clt.zip && \
    unzip -q /tmp/clt.zip -d /opt/android/cmdline-tools && \
    mv /opt/android/cmdline-tools/cmdline-tools /opt/android/cmdline-tools/latest && \
    rm /tmp/clt.zip

ENV ANDROID_SDK_ROOT=/sdk \
    ANDROID_USER_HOME=/sdk/.android \
    ANDROID_AVD_HOME=/sdk/.android/avd \
    PATH="/opt/android/cmdline-tools/latest/bin:/sdk/platform-tools:/sdk/emulator:${PATH}"

# scrcpy mirrors the headless (EMULATOR_GPU=host) emulator into Xvfb for the
# noVNC view. Official static Linux build; it runs against the SDK's adb.
ARG SCRCPY_VERSION=v4.1
RUN wget -q "https://github.com/Genymobile/scrcpy/releases/download/${SCRCPY_VERSION}/scrcpy-linux-x86_64-${SCRCPY_VERSION}.tar.gz" -O /tmp/scrcpy.tgz && \
    mkdir -p /opt/scrcpy && \
    tar xzf /tmp/scrcpy.tgz -C /opt/scrcpy --strip-components=1 && \
    rm /tmp/scrcpy.tgz

# Unversioned names for the system (glvnd) EGL/GLES libraries. The emulator
# dlopens "libEGL.so" and "libGLESv2.so"; in EMULATOR_GPU=host mode this
# directory goes first on LD_LIBRARY_PATH so those resolve to glvnd, which the
# GPU operator's NVIDIA vendor libraries plug into, instead of SwiftShader.
RUN mkdir -p /opt/egl-system && \
    ln -s /usr/lib/x86_64-linux-gnu/libEGL.so.1 /opt/egl-system/libEGL.so && \
    ln -s /usr/lib/x86_64-linux-gnu/libGLESv2.so.2 /opt/egl-system/libGLESv2.so && \
    ln -s /usr/lib/x86_64-linux-gnu/libGLESv2.so.2 /opt/egl-system/libGLES_CM.so

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 5555 adb (socat → emulator adbd), 6080 noVNC web UI
EXPOSE 5555 6080
ENTRYPOINT ["/entrypoint.sh"]
