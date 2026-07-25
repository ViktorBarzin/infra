#!/bin/bash
# Runs at container init (LinuxServer /custom-cont-init.d, as root, before the
# KasmVNC session). Fixes three things the base image's first-run-only config
# copy would otherwise leave stale on an existing profile PVC.

# 1) ALWAYS refresh the openbox autostart from the image. The base only copies
#    /defaults/autostart -> /config/.config/openbox/autostart when it's absent,
#    so image updates (the F11 un-fullscreen loop, --start-maximized) never reach
#    an existing profile without this.
mkdir -p /config/.config/openbox
cp /defaults/autostart /config/.config/openbox/autostart

# 2) Tune KasmVNC (1.3.3) encoding so Video Mode triggers for a small
#    fast-changing region (a video player), not just when 45% of the screen
#    changes for 5s. In Video Mode KasmVNC streams the changed region as a
#    frame-paced WebP/JPEG sequence (parallel-encoded) instead of the slow
#    per-rectangle path that re-encodes the whole player every frame — the
#    latter is why full-motion video stutters even at 320p. Keys validated
#    against /usr/local/share/kasmvnc/kasmvnc_defaults.yaml on the live image
#    (there is NO H.264/codec/video_streaming_mode key in 1.3.3 — video quality
#    is jpeg_quality/webp_quality inside video_encoding_mode). Written to the
#    user config (~/.vnc = /config/.vnc), merged over the system defaults.
#    logging.level:info makes Xvnc log each Video Mode enter/exit so the fix is
#    verifiable from the pod logs.
mkdir -p /config/.vnc
cat > /config/.vnc/kasmvnc.yaml <<'YAML'
encoding:
  max_frame_rate: 30
  video_encoding_mode:
    jpeg_quality: 6
    webp_quality: 6
    max_resolution:
      width: 1280
      height: 720
    enter_video_encoding_mode:
      time_threshold: 1
      area_threshold: 15%
    exit_video_encoding_mode:
      time_threshold: 2
    logging:
      level: info
YAML

# 3) Don't reopen the previous fullscreen window. A hard pod-kill leaves Chrome
#    marked "Crashed", so it restores the last (fullscreen) window on next start.
#    Mark the profile clean so Chrome opens a fresh maximized window instead (the
#    F11 loop in autostart remains a safety net). Logins/cookies persist.
for PREFS in /config/profile/Default/Preferences /config/profile/Default/Secure\ Preferences; do
  [ -f "$PREFS" ] && sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/g; s/"exited_cleanly":false/"exited_cleanly":true/g' "$PREFS"
done

chown -R abc:abc /config/.config/openbox /config/.vnc 2>/dev/null || true
