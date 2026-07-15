#!/usr/bin/env bash
# CaptureOS one-tap launcher — the desktop icon runs this. No terminal
# needed: it makes sure the services are up, waits for them to be
# healthy, then opens the booth UI on the touchscreen and the gallery
# on the wall display in Chromium kiosk mode.
#
# Works in two modes, detected automatically:
#   installed — systemd units exist (deploy/install.sh): just nudge
#               them and use nginx on port 80.
#   portable  — no systemd install: start the camera service and
#               backend directly from this app directory; the backend
#               serves the built frontend on port 3000.
#
# Options / env:
#   --no-browser          start + health-check services, skip Chromium
#   --list-displays       print connected monitors and exit
#   --list-inputs         print touch devices and exit
#   CAPTUREOS_GALLERY=0   don't open the wall-display gallery window
#
# Display layout is resolved automatically (smallest monitor -> booth,
# largest other -> gallery). Override in ~/.config/captureos/display.conf:
#   CAPTUREOS_BOOTH_OUTPUT=HDMI-2
#   CAPTUREOS_GALLERY_OUTPUT=HDMI-1
# Run `captureos-launch.sh --list-displays` to see output names on your Pi.
# If both windows open on one monitor, set outputs in display.conf (see example).

set -uo pipefail

export DISPLAY="${DISPLAY:-:0}"
export XAUTHORITY="${XAUTHORITY:-${HOME}/.Xauthority}"

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
DIR="$(dirname "$SELF")"
if [[ -d "$DIR/camera-service" ]]; then
    APP_DIR="$DIR"                              # /opt/captureos layout
elif [[ -d "$DIR/../../camera-service" ]]; then
    APP_DIR="$(readlink -f "$DIR/../..")"       # repo checkout layout
else
    echo "CaptureOS: cannot find app directory next to $SELF" >&2
    exit 1
fi

LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/captureos"
mkdir -p "$LOG_DIR"

LAYOUT_SH="$(dirname "$SELF")/display-layout.sh"
TOUCH_SH="$(dirname "$SELF")/touch-input.sh"
WAYLAND_SH="$(dirname "$SELF")/wayland-display.sh"
WINPOS_SH="$(dirname "$SELF")/window-position.sh"
if [[ -f "$LAYOUT_SH" ]]; then
    # shellcheck source=display-layout.sh
    source "$LAYOUT_SH"
fi
if [[ -f "$TOUCH_SH" ]]; then
    # shellcheck source=touch-input.sh
    source "$TOUCH_SH"
fi
if [[ -f "$WAYLAND_SH" ]]; then
    # shellcheck source=wayland-display.sh
    source "$WAYLAND_SH"
fi
if [[ -f "$WINPOS_SH" ]]; then
    # shellcheck source=window-position.sh
    source "$WINPOS_SH"
fi

NO_BROWSER=0
LIST_DISPLAYS=0
LIST_INPUTS=0
DIAGNOSE=0
for arg in "$@"; do
    case "$arg" in
        --no-browser) NO_BROWSER=1 ;;
        --list-displays) LIST_DISPLAYS=1 ;;
        --list-inputs) LIST_INPUTS=1 ;;
        --diagnose) DIAGNOSE=1 ;;
    esac
done

if [[ $DIAGNOSE -eq 1 ]]; then
    echo "===== CaptureOS display diagnostics ====="
    echo "date: $(date '+%F %T')"
    echo
    echo "--- session ---"
    echo "XDG_SESSION_TYPE = ${XDG_SESSION_TYPE:-(unset)}"
    echo "WAYLAND_DISPLAY  = ${WAYLAND_DISPLAY:-(unset)}"
    echo "DISPLAY          = ${DISPLAY:-(unset)}"
    echo "XAUTHORITY       = ${XAUTHORITY:-(unset)}"
    if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        echo ">> This is a WAYLAND session."
    elif [[ -n "${DISPLAY:-}" ]]; then
        echo ">> This is an X11 session."
    else
        echo ">> No graphical session detected in this shell."
        echo "   Run this from the Pi's desktop terminal, not over plain SSH."
    fi
    echo
    echo "--- xrandr (X11 / XWayland) ---"
    if command -v xrandr >/dev/null 2>&1; then
        DISPLAY="${DISPLAY:-:0}" xrandr --query 2>&1 | grep -E ' connected| disconnected' || echo "(xrandr produced no output)"
    else
        echo "xrandr not installed"
    fi
    echo
    echo "--- wlr-randr (Wayland: wlroots/labwc) ---"
    if command -v wlr-randr >/dev/null 2>&1; then
        wlr-randr 2>&1 || echo "(wlr-randr failed)"
    else
        echo "wlr-randr not installed (apt install wlr-randr)"
    fi
    echo
    echo "--- tools present ---"
    for t in chromium-browser chromium xrandr xdotool wlr-randr xinput; do
        if command -v "$t" >/dev/null 2>&1; then
            echo "  $t: $(command -v "$t")"
        else
            echo "  $t: MISSING"
        fi
    done
    echo
    echo "--- resolved layout (what the launcher would use) ---"
    if declare -F captureos_resolve_display_layout >/dev/null 2>&1; then
        captureos_resolve_display_layout >/dev/null 2>&1 || true
        echo "  booth:   ${CAPTUREOS_BOOTH_OUTPUT:-?} at ${CAPTUREOS_BOOTH_X:-?},${CAPTUREOS_BOOTH_Y:-?} ${CAPTUREOS_BOOTH_W:-?}x${CAPTUREOS_BOOTH_H:-?}"
        echo "  gallery: ${CAPTUREOS_GALLERY_OUTPUT:-?} at ${CAPTUREOS_GALLERY_X:-?},${CAPTUREOS_GALLERY_Y:-?} ${CAPTUREOS_GALLERY_W:-?}x${CAPTUREOS_GALLERY_H:-?}"
    fi
    echo
    echo "--- config files ---"
    for f in /etc/captureos/display.conf "${XDG_CONFIG_HOME:-$HOME/.config}/captureos/display.conf"; do
        if [[ -r "$f" ]]; then
            echo "  $f:"
            sed 's/^/    /' "$f"
        else
            echo "  $f: (none)"
        fi
    done
    echo
    echo "--- last launcher log ---"
    if [[ -r "$LOG_DIR/launcher.log" ]]; then
        tail -n 40 "$LOG_DIR/launcher.log"
    else
        echo "(no launcher log yet at $LOG_DIR/launcher.log)"
    fi
    echo "===== end diagnostics ====="
    exit 0
fi

if [[ $LIST_INPUTS -eq 1 ]]; then
    if declare -F captureos_print_inputs >/dev/null 2>&1; then
        captureos_print_inputs
    else
        echo "touch-input.sh not found next to $SELF" >&2
        exit 1
    fi
    exit $?
fi

if [[ $LIST_DISPLAYS -eq 1 ]]; then
    if declare -F captureos_print_displays >/dev/null 2>&1; then
        captureos_print_displays
    else
        echo "display-layout.sh not found next to $SELF" >&2
        exit 1
    fi
    exit $?
fi
# Launched from an icon there is no terminal — keep a log instead.
if [[ $NO_BROWSER -eq 0 ]]; then
    exec >>"$LOG_DIR/launcher.log" 2>&1
fi
echo "[$(date '+%F %T')] CaptureOS launcher starting (app: $APP_DIR)"

# Only one launcher at a time (autostart + desktop icon can race).
LOCK_FILE="$LOG_DIR/launcher.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "another CaptureOS launcher is already running — exiting"
    exit 0
fi

# --- 1. make sure the services are running -------------------------------

if command -v systemctl >/dev/null 2>&1 \
    && systemctl cat captureos-backend.service >/dev/null 2>&1; then
    MODE=installed
    BASE_URL="http://localhost"
    systemctl start --no-ask-password captureos-camera.service \
        captureos-backend.service 2>/dev/null || true
else
    MODE=portable
    BASE_URL="http://localhost:3000"
    if ! pgrep -f 'python3 camera_service.py' >/dev/null; then
        (cd "$APP_DIR/camera-service" \
            && nohup python3 camera_service.py >>"$LOG_DIR/camera.out" 2>&1 9>&- &)
    fi
    if ! pgrep -f 'node src/server.js' >/dev/null; then
        if [[ ! -d "$APP_DIR/backend/node_modules" ]]; then
            (cd "$APP_DIR/backend" && npm install --omit=dev --silent)
        fi
        (cd "$APP_DIR/backend" \
            && nohup node src/server.js >>"$LOG_DIR/backend.out" 2>&1 9>&- &)
    fi
fi
echo "mode: $MODE, base url: $BASE_URL"

# --- 2. wait until the stack answers -------------------------------------

ok=0
for _ in $(seq 1 60); do
    if curl -fsS -o /dev/null "$BASE_URL/api/health"; then
        ok=1
        break
    fi
    sleep 1
done
if [[ $ok -ne 1 ]]; then
    echo "CaptureOS did not become healthy in 60s — see logs in $LOG_DIR" >&2
    exit 1
fi
echo "services healthy"

if [[ $NO_BROWSER -eq 1 ]]; then
    echo "ready: booth $BASE_URL/#/  gallery $BASE_URL/#/gallery"
    exit 0
fi

# --- 3. kiosk windows -----------------------------------------------------

BROWSER="$(command -v chromium-browser || command -v chromium)" || {
    echo "chromium not found" >&2
    exit 1
}
# Prefer the real binary over the Pi wrapper script (avoids
# "unrecognized flag --no-decommit-pooled-pages" noise).
for candidate in \
    /usr/lib/chromium/chromium \
    /usr/lib/chromium-browser/chromium-browser \
    /usr/lib/chromium-browser/chromium; do
    if [[ -x "$candidate" ]]; then
        BROWSER="$candidate"
        break
    fi
done

if declare -F captureos_ensure_wayland_env >/dev/null 2>&1; then
    captureos_ensure_wayland_env || true
fi
if declare -F captureos_ensure_x_display >/dev/null 2>&1; then
    captureos_ensure_x_display || true
fi
if declare -F captureos_wait_for_displays >/dev/null 2>&1; then
    # Short wait: with one monitor this must not stall the booth.
    captureos_wait_for_displays 2 8 || true
fi

# Re-apply dual-display + touch (Screen Configuration often resets on reboot).
if declare -F captureos_is_wayland_session >/dev/null 2>&1 \
    && captureos_is_wayland_session \
    && declare -F captureos_setup_wayland_displays >/dev/null 2>&1; then
    CAPTUREOS_DISPLAY_WAIT="${CAPTUREOS_DISPLAY_WAIT:-3}" \
        captureos_setup_wayland_displays || true
fi

if declare -F captureos_resolve_display_layout >/dev/null 2>&1; then
    captureos_resolve_display_layout || exit 1
else
    CAPTUREOS_BOOTH_X=0
    CAPTUREOS_BOOTH_Y=0
    CAPTUREOS_BOOTH_W="${TOUCH_WIDTH:-1024}"
    CAPTUREOS_BOOTH_H="${TOUCH_HEIGHT:-600}"
    CAPTUREOS_GALLERY_X="${TOUCH_WIDTH:-1024}"
    CAPTUREOS_GALLERY_Y=0
    CAPTUREOS_GALLERY_W="${GALLERY_WIDTH:-1920}"
    CAPTUREOS_GALLERY_H="${GALLERY_HEIGHT:-1080}"
fi

if declare -F captureos_arrange_extended_desktop >/dev/null 2>&1; then
    captureos_arrange_extended_desktop || true
    captureos_resolve_display_layout || true
fi

# Booth and gallery resolving to the same origin means the dual-display
# layout hasn't settled yet (mirrored, or the second screen still coming
# up). Launching now would pile both windows onto one screen — retry the
# arrangement for a bit first.
if [[ "${CAPTUREOS_GALLERY:-1}" == "1" ]]; then
    for _ in $(seq 1 6); do
        [[ "${CAPTUREOS_BOOTH_X:-0},${CAPTUREOS_BOOTH_Y:-0}" \
            != "${CAPTUREOS_GALLERY_X:-0},${CAPTUREOS_GALLERY_Y:-0}" ]] && break
        echo "booth and gallery overlap — re-arranging displays"
        sleep 2
        if declare -F captureos_is_wayland_session >/dev/null 2>&1 \
            && captureos_is_wayland_session \
            && declare -F captureos_setup_wayland_displays >/dev/null 2>&1; then
            captureos_setup_wayland_displays || true
        elif declare -F captureos_arrange_extended_desktop >/dev/null 2>&1; then
            captureos_arrange_extended_desktop || true
        fi
        captureos_resolve_display_layout || true
    done
fi

echo "booth display:   ${CAPTUREOS_BOOTH_OUTPUT:-?} at ${CAPTUREOS_BOOTH_X},${CAPTUREOS_BOOTH_Y} ${CAPTUREOS_BOOTH_W}x${CAPTUREOS_BOOTH_H}"
echo "gallery display: ${CAPTUREOS_GALLERY_OUTPUT:-?} at ${CAPTUREOS_GALLERY_X},${CAPTUREOS_GALLERY_Y} ${CAPTUREOS_GALLERY_W}x${CAPTUREOS_GALLERY_H}"
if declare -F captureos_log_display_map >/dev/null 2>&1; then
    captureos_log_display_map
fi

# Pin windows to outputs BEFORE Chromium starts (xdotool cannot move
# Chromium --kiosk windows under labwc/XWayland).
if declare -F captureos_apply_labwc_window_rules >/dev/null 2>&1; then
    captureos_apply_labwc_window_rules || true
fi

if declare -F captureos_kill_kiosk_windows >/dev/null 2>&1; then
    captureos_kill_kiosk_windows
fi

# Do NOT use --kiosk here: under Pi OS labwc/XWayland it creates unmovable
# windows that always open on the primary (big) display. Use an app window
# with explicit size/position; labwc window rules force the right output
# and fullscreen. (Optional CAPTUREOS_FORCE_KIOSK=1 restores old behaviour.)
# Do NOT use Chromium --kiosk by default: under labwc it maps both
# windows onto one screen and xdotool cannot move them. Hide the
# tab/search bar with --app instead, then fullscreen via wmctrl after
# the window is on the correct output. Set CAPTUREOS_FORCE_KIOSK=1 only
# as a last resort (single-display booths).
KIOSK_FLAGS=(
    --noerrdialogs
    --disable-infobars
    --disable-session-crashed-bubble
    --check-for-update-interval=31536000
    --overscroll-history-navigation=0
    --pull-to-refresh=0
    --password-store=basic
    --use-mock-keychain
    --no-first-run
    --disable-features=TranslateUI
    --disable-pinch
    --start-maximized
)
if [[ "${CAPTUREOS_FORCE_KIOSK:-0}" == "1" ]]; then
    KIOSK_FLAGS+=(--kiosk --kiosk-printing)
fi
# Prefer X11 so --window-position and xdotool/wmctrl can place windows.
if [[ -z "${CAPTUREOS_OZONE_PLATFORM:-}" ]]; then
    CAPTUREOS_OZONE_PLATFORM=x11
fi
KIOSK_FLAGS+=(--ozone-platform="$CAPTUREOS_OZONE_PLATFORM")

launch_kiosk() {
    local profile="$1" class="$2" url="$3" x="$4" y="$5" w="$6" h="$7"
    # Warp cursor onto the target output first — labwc maps new windows
    # to the output under the cursor.
    if declare -F captureos_warp_cursor_to >/dev/null 2>&1; then
        captureos_warp_cursor_to "$x" "$y" "$w" "$h"
    fi
    # Seed a minimal profile that never shows the bookmarks bar.
    local profile_dir="$LOG_DIR/captureos-profile-${profile}"
    mkdir -p "$profile_dir/Default"
    local prefs="$profile_dir/Default/Preferences"
    if [[ ! -f "$prefs" ]]; then
        printf '%s\n' '{"bookmark_bar":{"show_on_all_tabs":false},"browser":{"custom_chrome_frame":false}}' >"$prefs"
    fi
    # --app hides the tab/search bar WITHOUT Chromium --kiosk (which
    # breaks dual-display placement). Keep --class for labwc matching.
    "$BROWSER" "${KIOSK_FLAGS[@]}" \
        --class="$class" \
        --name="$class" \
        --user-data-dir="$profile_dir" \
        --window-position="${x},${y}" \
        --window-size="${w},${h}" \
        --app="$url" \
        9>&- &
}

# Gallery on the wall / main display first (cursor already there).
if [[ "${CAPTUREOS_GALLERY:-1}" == "1" ]]; then
    launch_kiosk gallery CaptureOS-Gallery "$BASE_URL/#/gallery" \
        "$CAPTUREOS_GALLERY_X" "$CAPTUREOS_GALLERY_Y" \
        "$CAPTUREOS_GALLERY_W" "$CAPTUREOS_GALLERY_H"
    echo "gallery kiosk launched"
    # Let the kiosk surface map under the gallery cursor before moving on.
    sleep 3
fi

# Booth on the touchscreen.
launch_kiosk booth CaptureOS-Booth "$BASE_URL/#/" \
    "$CAPTUREOS_BOOTH_X" "$CAPTUREOS_BOOTH_Y" \
    "$CAPTUREOS_BOOTH_W" "$CAPTUREOS_BOOTH_H"
echo "booth kiosk launched"

sleep 4

# Verify-and-retry placement: at boot Chromium starts before the second
# monitor is fully arranged, so windows pile onto one screen. Keep
# checking where each window actually is and re-place until correct
# (a manual relaunch verifies on the first pass and exits immediately).
booth_placed=1
gallery_placed=1
if declare -F captureos_ensure_window_layout >/dev/null 2>&1; then
    if [[ "${CAPTUREOS_GALLERY:-1}" == "1" ]]; then
        captureos_ensure_window_layout CaptureOS-Gallery \
            "$CAPTUREOS_GALLERY_X" "$CAPTUREOS_GALLERY_Y" \
            "$CAPTUREOS_GALLERY_W" "$CAPTUREOS_GALLERY_H" 8 9>&- &
        GALLERY_POS_PID=$!
    fi
    captureos_ensure_window_layout CaptureOS-Booth \
        "$CAPTUREOS_BOOTH_X" "$CAPTUREOS_BOOTH_Y" \
        "$CAPTUREOS_BOOTH_W" "$CAPTUREOS_BOOTH_H" 8 9>&- &
    BOOTH_POS_PID=$!
    wait "$BOOTH_POS_PID" || booth_placed=0
    if [[ -n "${GALLERY_POS_PID:-}" ]]; then
        wait "$GALLERY_POS_PID" || gallery_placed=0
    fi

    # Last resort: the layout may have settled differently since launch,
    # or booth and gallery had resolved to the same screen — re-resolve
    # the (possibly new) geometry and place once more.
    if { (( booth_placed == 0 || gallery_placed == 0 )) \
        || [[ "${CAPTUREOS_BOOTH_OUTPUT:-a}" == "${CAPTUREOS_GALLERY_OUTPUT:-b}" ]] \
        || [[ "${CAPTUREOS_BOOTH_X:-0},${CAPTUREOS_BOOTH_Y:-0}" \
              == "${CAPTUREOS_GALLERY_X:-0},${CAPTUREOS_GALLERY_Y:-0}" ]]; } \
        && declare -F captureos_resolve_display_layout >/dev/null 2>&1; then
        echo "re-resolving display layout for a final placement pass"
        if declare -F captureos_wait_for_displays >/dev/null 2>&1; then
            captureos_wait_for_displays 2 20 || true
        fi
        if declare -F captureos_setup_wayland_displays >/dev/null 2>&1 \
            && captureos_is_wayland_session 2>/dev/null; then
            captureos_setup_wayland_displays || true
        fi
        captureos_resolve_display_layout || true
        if [[ "${CAPTUREOS_GALLERY:-1}" == "1" ]]; then
            captureos_ensure_window_layout CaptureOS-Gallery \
                "$CAPTUREOS_GALLERY_X" "$CAPTUREOS_GALLERY_Y" \
                "$CAPTUREOS_GALLERY_W" "$CAPTUREOS_GALLERY_H" 3 || true
        fi
        captureos_ensure_window_layout CaptureOS-Booth \
            "$CAPTUREOS_BOOTH_X" "$CAPTUREOS_BOOTH_Y" \
            "$CAPTUREOS_BOOTH_W" "$CAPTUREOS_BOOTH_H" 3 || true
    fi
    captureos_fullscreen_window_class CaptureOS-Gallery 2>/dev/null || true
    captureos_fullscreen_window_class CaptureOS-Booth 2>/dev/null || true
elif declare -F captureos_position_window_class >/dev/null 2>&1; then
    if [[ "${CAPTUREOS_GALLERY:-1}" == "1" ]]; then
        captureos_position_window_class CaptureOS-Gallery \
            "$CAPTUREOS_GALLERY_X" "$CAPTUREOS_GALLERY_Y" \
            "$CAPTUREOS_GALLERY_W" "$CAPTUREOS_GALLERY_H" || true
    fi
    captureos_position_window_class CaptureOS-Booth \
        "$CAPTUREOS_BOOTH_X" "$CAPTUREOS_BOOTH_Y" \
        "$CAPTUREOS_BOOTH_W" "$CAPTUREOS_BOOTH_H" || true
    captureos_fullscreen_window_class CaptureOS-Gallery 2>/dev/null || true
    captureos_fullscreen_window_class CaptureOS-Booth 2>/dev/null || true
fi

# Chromium sometimes drops fullscreen shortly after map — nudge again.
# Remap touch AFTER fullscreen settles: mapping against the extended desktop
# before the booth window is sized leaves taps offset (shutter too high).
if declare -F captureos_fullscreen_window_class >/dev/null 2>&1; then
    ( sleep 4
      captureos_fullscreen_window_class CaptureOS-Gallery 2>/dev/null || true
      captureos_fullscreen_window_class CaptureOS-Booth 2>/dev/null || true
      captureos_map_touch_to_booth "${CAPTUREOS_BOOTH_OUTPUT:-}" 2>/dev/null || true
      sleep 3
      captureos_fullscreen_window_class CaptureOS-Gallery 2>/dev/null || true
      captureos_fullscreen_window_class CaptureOS-Booth 2>/dev/null || true
      captureos_map_touch_to_booth "${CAPTUREOS_BOOTH_OUTPUT:-}" 2>/dev/null || true
    ) 9>&- &
fi

if declare -F captureos_map_touch_to_booth >/dev/null 2>&1; then
    captureos_map_touch_to_booth "${CAPTUREOS_BOOTH_OUTPUT:-}" || true
    ( sleep 8
      captureos_map_touch_to_booth "${CAPTUREOS_BOOTH_OUTPUT:-}" || true ) 9>&- &
fi

disown -a 2>/dev/null || true
echo "done"
