#!/usr/bin/env bash
# Map USB touch controllers to the booth display. Runs at login and from the
# CaptureOS launcher so taps land on the shutter button, not the gallery TV.

set -euo pipefail

APP_DIR=/opt/captureos
LAYOUT_SH="$APP_DIR/display-layout.sh"
TOUCH_SH="$APP_DIR/touch-input.sh"

export DISPLAY="${DISPLAY:-:0}"
export XAUTHORITY="${XAUTHORITY:-${HOME}/.Xauthority}"

[[ -f "$LAYOUT_SH" ]] && source "$LAYOUT_SH"
[[ -f "$TOUCH_SH" ]] && source "$TOUCH_SH"

if declare -F captureos_resolve_display_layout >/dev/null 2>&1; then
    captureos_resolve_display_layout || true
fi

if declare -F captureos_map_touch_to_booth >/dev/null 2>&1; then
    captureos_map_touch_to_booth "${CAPTUREOS_BOOTH_OUTPUT:-}" || true
fi
