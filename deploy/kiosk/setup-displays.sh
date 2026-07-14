#!/usr/bin/env bash
# Apply dual-display layout + touch mapping at login (before the booth starts).
# Pi OS Screen Configuration often resets on reboot; this script re-applies
# the CaptureOS layout every time you log in.

set -euo pipefail

APP_DIR=/opt/captureos
export DISPLAY="${DISPLAY:-:0}"
export XAUTHORITY="${XAUTHORITY:-${HOME}/.Xauthority}"

LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/captureos"
mkdir -p "$LOG_DIR"
exec >>"$LOG_DIR/display-setup.log" 2>&1

echo "[$(date '+%F %T')] CaptureOS display setup starting"

[[ -f "$APP_DIR/display-layout.sh" ]] && source "$APP_DIR/display-layout.sh"
[[ -f "$APP_DIR/wayland-display.sh" ]] && source "$APP_DIR/wayland-display.sh"
[[ -f "$APP_DIR/window-position.sh" ]] && source "$APP_DIR/window-position.sh"
[[ -f "$APP_DIR/touch-input.sh" ]] && source "$APP_DIR/touch-input.sh"

if declare -F captureos_ensure_x_display >/dev/null 2>&1; then
    captureos_ensure_x_display || true
fi

for attempt in $(seq 1 12); do
    if declare -F captureos_is_wayland_session >/dev/null 2>&1 \
        && captureos_is_wayland_session \
        && declare -F captureos_setup_wayland_displays >/dev/null 2>&1; then
        if captureos_setup_wayland_displays; then
            echo "Wayland display setup succeeded on attempt ${attempt}"
            break
        fi
    elif declare -F captureos_wait_for_displays >/dev/null 2>&1 \
        && captureos_wait_for_displays 2; then
        if declare -F captureos_resolve_display_layout >/dev/null 2>&1; then
            captureos_resolve_display_layout || true
        fi
        if declare -F captureos_arrange_extended_desktop >/dev/null 2>&1; then
            captureos_arrange_extended_desktop || true
            captureos_resolve_display_layout || true
        fi
        echo "X11 display setup succeeded on attempt ${attempt}"
        break
    fi
    echo "waiting for displays (attempt ${attempt}/12)..."
    sleep 5
done

if declare -F captureos_map_touch_to_booth >/dev/null 2>&1; then
    for attempt in $(seq 1 6); do
        if captureos_map_touch_to_booth "${CAPTUREOS_BOOTH_OUTPUT:-}"; then
            echo "touch mapping succeeded on attempt ${attempt}"
            break
        fi
        sleep 3
    done
fi

echo "[$(date '+%F %T')] CaptureOS display setup done"
