#!/bin/bash
# Runs at container init (LinuxServer /custom-cont-init.d, as root, AFTER s6 has
# compiled the service DB into /run but BEFORE svc-kasmvnc starts). Fixes three
# things the base image would otherwise leave wrong on an existing profile PVC.

# 1) ALWAYS refresh the openbox autostart from the image. The base only copies
#    /defaults/autostart -> /config/.config/openbox/autostart when it's absent,
#    so image updates (the pgrep-guarded relaunch, --start-maximized, the new
#    Chrome flags) never reach an existing profile without this.
mkdir -p /config/.config/openbox
cp /defaults/autostart /config/.config/openbox/autostart

# 2) Make KasmVNC Video Mode actually engage for a WINDOWED video player. The
#    YAML config (~/.vnc/kasmvnc.yaml) is IGNORED by this linuxserver Xvnc build
#    (verified: even max_frame_rate there had no effect) — the encoding knobs
#    only take via Xvnc COMMAND-LINE params. The stock run script uses the
#    default VideoArea 45% / VideoTime 5s, so a video player (~20-30% of screen)
#    never trips Video Mode and stays on the choppy still-image path. Lower the
#    trigger to 15% / 1s by appending the params to the compiled longrun run
#    script before svc-kasmvnc starts (idempotent; survives base run-script
#    changes since we only append, never replace). NOTE: KasmVNC 1.3.3 software
#    WebP encoding still can't do truly smooth video — that's why the WebRTC
#    (neko) path exists — but this is the correct config and the best KasmVNC does.
RUN=/run/service/svc-kasmvnc/run
if [ -f "$RUN" ] && ! grep -q "VideoArea" "$RUN"; then
  sed -i 's|-RectThreads 0 \\|-RectThreads 0 -VideoArea 15 -VideoTime 1 -VideoOutTime 2 \\|' "$RUN"
fi

# 3) Don't reopen the previous fullscreen window. A hard pod-kill leaves Chrome
#    marked "Crashed", so it restores the last (fullscreen) window on next start.
#    Mark the profile clean so Chrome opens a fresh maximized window instead
#    (--hide-crash-restore-bubble in autostart is the belt-and-suspenders).
#    Logins/cookies persist.
for PREFS in /config/profile/Default/Preferences /config/profile/Default/Secure\ Preferences; do
  [ -f "$PREFS" ] && sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/g; s/"exited_cleanly":false/"exited_cleanly":true/g' "$PREFS"
done

chown -R abc:abc /config/.config/openbox 2>/dev/null || true
