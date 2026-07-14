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
#   CAPTUREOS_GALLERY=0   don't open the wall-display gallery window
#   TOUCH_WIDTH=1024      touchscreen width; the gallery window is
#                         placed to its right

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

NO_BROWSER=0
[[ "${1:-}" == "--no-browser" ]] && NO_BROWSER=1
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
    systemctl start captureos-camera.service captureos-backend.service 2>/dev/null || true
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
TOUCH_WIDTH="${TOUCH_WIDTH:-1024}"
KIOSK_FLAGS=(
    --kiosk
    --noerrdialogs
    --disable-infobars
    --disable-session-crashed-bubble
    --check-for-update-interval=31536000
    --overscroll-history-navigation=0
    --pull-to-refresh=0
)

# Booth on the touchscreen (primary output, position 0,0).
if ! pgrep -f 'captureos-profile-booth' >/dev/null; then
    "$BROWSER" "${KIOSK_FLAGS[@]}" \
        --user-data-dir="$LOG_DIR/captureos-profile-booth" \
        --window-position=0,0 \
        "$BASE_URL/#/" &
    echo "booth kiosk launched"
fi

# Gallery on the wall display, placed right of the touchscreen.
if [[ "${CAPTUREOS_GALLERY:-1}" == "1" ]] \
    && ! pgrep -f 'captureos-profile-gallery' >/dev/null; then
    "$BROWSER" "${KIOSK_FLAGS[@]}" \
        --user-data-dir="$LOG_DIR/captureos-profile-gallery" \
        --window-position="$TOUCH_WIDTH,0" \
        "$BASE_URL/#/gallery" &
    echo "gallery kiosk launched"
fi

disown -a 2>/dev/null || true
echo "done"
