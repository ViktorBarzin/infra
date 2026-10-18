# shellcheck shell=bash
# Helpers for app install scripts (/app/install.sh) that drive a Windows
# installer's GUI on the virtual X display. Source it:
#
#   . /usr/local/bin/wine-app-lib.sh
#
# Every X call is wrapped in `timeout`: a stuck X client must fail the step,
# not hang the pod. Screen captures always crop the root window; never use
# `import -window <id>`, which falls back to an interactive "click a window"
# pointer grab when the window disappears and then blocks every other client.

WA_X_TIMEOUT=${WA_X_TIMEOUT:-10}

wa_log() { echo "[install $(date +%H:%M:%S)] $*" >&2; }

# Save a screenshot to /tmp/<name>.png and print it base64-encoded between
# markers, so a log viewer (kubectl logs, a CI log) can recover the image.
wa_screenshot() {
  local name=${1:-screen} f
  f="/tmp/${name}.png"
  timeout "$WA_X_TIMEOUT" import -window root "$f" 2>/dev/null || return 0
  echo "screenshot saved: $f" >&2
  echo "----- BEGIN ${name}.png (50% scale, base64) -----" >&2
  timeout "$WA_X_TIMEOUT" convert "$f" -resize 50% png:- 2>/dev/null | base64 >&2
  echo "----- END ${name}.png -----" >&2
}

wa_fail() {
  wa_log "FAILED: $*"
  wa_list_windows >&2 || true
  wa_screenshot install-failure
  exit 1
}

# Visible top-level windows: "<id> <x> <y> <w> <h> <class> <name>"
wa_list_windows() {
  local w g cls name
  for w in $(timeout "$WA_X_TIMEOUT" xdotool search --onlyvisible --name '' 2>/dev/null); do
    g=$(timeout "$WA_X_TIMEOUT" xdotool getwindowgeometry --shell "$w" 2>/dev/null) || continue
    eval "$g"
    cls=$(timeout "$WA_X_TIMEOUT" xprop -id "$w" WM_CLASS 2>/dev/null | cut -d'"' -f2)
    name=$(timeout "$WA_X_TIMEOUT" xdotool getwindowname "$w" 2>/dev/null)
    echo "$w $X $Y $WIDTH $HEIGHT ${cls:--} $name"
  done
}

# wa_find_window <class> <width> <height> [exclude-ids...]
# Prints the newest matching visible window id, or nothing.
wa_find_window() {
  local cls=$1 width=$2 height=$3; shift 3
  local id x y w h c rest found=""
  while read -r id x y w h c rest; do
    { [ "$c" = "$cls" ] && [ "$w" = "$width" ] && [ "$h" = "$height" ]; } || continue
    case " $* " in *" $id "*) continue ;; esac
    found=$id
  done < <(wa_list_windows)
  [ -n "$found" ] && echo "$found"
}

# wa_wait_window <timeout-s> <class> <width> <height> [exclude-ids...]
wa_wait_window() {
  local t=$1; shift
  local deadline=$((SECONDS + t)) id
  while [ $SECONDS -lt $deadline ]; do
    id=$(wa_find_window "$@") && { echo "$id"; return 0; }
    sleep 1
  done
  return 1
}

# Hash of a window's pixels, taken from the root window.
wa_window_hash() {
  local WINDOW X Y WIDTH HEIGHT SCREEN
  eval "$(timeout "$WA_X_TIMEOUT" xdotool getwindowgeometry --shell "$1" 2>/dev/null)" || return 1
  timeout "$WA_X_TIMEOUT" import -window root -crop "${WIDTH}x${HEIGHT}+${X}+${Y}" rgb:- 2>/dev/null | md5sum | cut -d' ' -f1
}

# wa_wait_stable <timeout-s> <window>: wait until the window stops repainting
# (two equal hashes one second apart).
wa_wait_stable() {
  local deadline=$((SECONDS + $1)) a b
  a=$(wa_window_hash "$2")
  while [ $SECONDS -lt $deadline ]; do
    sleep 1
    b=$(wa_window_hash "$2")
    [ -n "$b" ] && [ "$a" = "$b" ] && return 0
    a=$b
  done
  return 1
}

# wa_click <window> <x> <y> [expect-change-timeout-s]
# Click at window-relative coordinates. With a timeout, wait for the window's
# pixels to change afterwards and fail if they do not.
wa_click() {
  local w=$1 x=$2 y=$3 t=${4:-0} before after deadline
  [ "$t" -gt 0 ] && before=$(wa_window_hash "$w")
  timeout "$WA_X_TIMEOUT" xdotool mousemove --window "$w" "$x" "$y" click 1 \
    || wa_fail "click on window $w at $x,$y"
  [ "$t" -gt 0 ] || return 0
  deadline=$((SECONDS + t))
  while [ $SECONDS -lt $deadline ]; do
    after=$(wa_window_hash "$w")
    [ "$after" != "$before" ] && return 0
    sleep 0.5
  done
  wa_fail "window $w did not change within ${t}s after clicking $x,$y"
}

# wa_pixel <window> <x> <y>: "#RRGGBB" at window-relative coordinates.
wa_pixel() {
  local WINDOW X Y WIDTH HEIGHT SCREEN
  eval "$(timeout "$WA_X_TIMEOUT" xdotool getwindowgeometry --shell "$1" 2>/dev/null)" || return 1
  timeout "$WA_X_TIMEOUT" import -window root -crop "1x1+$((X + $2))+$((Y + $3))" -depth 8 txt:- 2>/dev/null \
    | grep -oE '#[0-9A-F]{6}' | head -1
}
