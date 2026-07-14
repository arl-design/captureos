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
WINPOS_SH="$(dirname "$SELF")/window-position.sh"
if [[ -f "$LAYOUT_SH" ]]; then
    # shellcheck source=display-layout.sh
    source "$LAYOUT_SH"
fi
if [[ -f "$TOUCH_SH" ]]; then
    # shellcheck source=touch-input.sh
    source "$TOUCH_SH"
fi
if [[ -f "$WINPOS_SH" ]]; then
    # shellcheck source=window-position.sh
    source "$WINPOS_SH"
fi

NO_BROWSER=0
LIST_DISPLAYS=0
LIST_INPUTS=0
for arg in "$@"; do
    case "$arg" in
        --no-browser) NO_BROWSER=1 ;;
        --list-displays) LIST_DISPLAYS=1 ;;
        --list-inputs) LIST_INPUTS=1 ;;
    esac
done

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
            && nohup python3 camera_service.py >>"$LOG_DIR/camera.out" 2>&1 &)
    fi
    if ! pgrep -f 'node src/server.js' >/dev/null; then
        if [[ ! -d "$APP_DIR/backend/node_modules" ]]; then
            (cd "$APP_DIR/backend" && npm install --omit=dev --silent)
        fi
        (cd "$APP_DIR/backend" \
            && nohup node src/server.js >>"$LOG_DIR/backend.out" 2>&1 &)
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

if declare -F captureos_ensure_x_display >/dev/null 2>&1; then
    captureos_ensure_x_display || true
fi
if declare -F captureos_wait_for_displays >/dev/null 2>&1; then
    captureos_wait_for_displays 2 || true
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

echo "booth display:   ${CAPTUREOS_BOOTH_OUTPUT:-?} at ${CAPTUREOS_BOOTH_X},${CAPTUREOS_BOOTH_Y} ${CAPTUREOS_BOOTH_W}x${CAPTUREOS_BOOTH_H}"
echo "gallery display: ${CAPTUREOS_GALLERY_OUTPUT:-?} at ${CAPTUREOS_GALLERY_X},${CAPTUREOS_GALLERY_Y} ${CAPTUREOS_GALLERY_W}x${CAPTUREOS_GALLERY_H}"

if declare -F captureos_kill_kiosk_windows >/dev/null 2>&1; then
    captureos_kill_kiosk_windows
fi

KIOSK_FLAGS=(
    --kiosk
    --noerrdialogs
    --disable-infobars
    --disable-session-crashed-bubble
    --check-for-update-interval=31536000
    --overscroll-history-navigation=0
    --pull-to-refresh=0
)
# Prefer X11 so --window-position and xdotool can place windows on dual HDMI.
if [[ -z "${CAPTUREOS_OZONE_PLATFORM:-}" ]]; then
    CAPTUREOS_OZONE_PLATFORM=x11
fi
KIOSK_FLAGS+=(--ozone-platform="$CAPTUREOS_OZONE_PLATFORM")

launch_kiosk() {
    local profile="$1" class="$2" url="$3" x="$4" y="$5" w="$6" h="$7"
    "$BROWSER" "${KIOSK_FLAGS[@]}" \
        --class="$class" \
        --user-data-dir="$LOG_DIR/captureos-profile-${profile}" \
        --window-position="${x},${y}" \
        --window-size="${w},${h}" \
        "$url" &
}

# Gallery on the wall / main display.
if [[ "${CAPTUREOS_GALLERY:-1}" == "1" ]]; then
    launch_kiosk gallery CaptureOS-Gallery "$BASE_URL/#/gallery" \
        "$CAPTUREOS_GALLERY_X" "$CAPTUREOS_GALLERY_Y" \
        "$CAPTUREOS_GALLERY_W" "$CAPTUREOS_GALLERY_H"
    echo "gallery kiosk launched"
fi

# Booth on the touchscreen.
launch_kiosk booth CaptureOS-Booth "$BASE_URL/#/" \
    "$CAPTUREOS_BOOTH_X" "$CAPTUREOS_BOOTH_Y" \
    "$CAPTUREOS_BOOTH_W" "$CAPTUREOS_BOOTH_H"
echo "booth kiosk launched"

sleep 2

if declare -F captureos_position_window_class >/dev/null 2>&1; then
    if [[ "${CAPTUREOS_GALLERY:-1}" == "1" ]]; then
        captureos_position_window_class CaptureOS-Gallery \
            "$CAPTUREOS_GALLERY_X" "$CAPTUREOS_GALLERY_Y" \
            "$CAPTUREOS_GALLERY_W" "$CAPTUREOS_GALLERY_H" || true
    fi
    captureos_position_window_class CaptureOS-Booth \
        "$CAPTUREOS_BOOTH_X" "$CAPTUREOS_BOOTH_Y" \
        "$CAPTUREOS_BOOTH_W" "$CAPTUREOS_BOOTH_H" || true
fi

if declare -F captureos_map_touch_to_booth >/dev/null 2>&1; then
    captureos_map_touch_to_booth "${CAPTUREOS_BOOTH_OUTPUT:-}" || true
fi

disown -a 2>/dev/null || true
echo "done"
