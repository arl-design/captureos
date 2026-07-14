# CaptureOS touch-input helper — maps USB touch controllers to the booth
# display so taps on the touchscreen hit the shutter button, not the gallery.
#
# Override in display.conf:
#   CAPTUREOS_TOUCH_DEVICE="ILITEK ILITEK-TP"
#   CAPTUREOS_TOUCH_DEVICE_ID=8

captureos_list_touch_devices() {
    command -v xinput >/dev/null 2>&1 || return 1
    local line id name lower props
    while IFS= read -r line; do
        [[ "$line" =~ id=([0-9]+) ]] || continue
        id="${BASH_REMATCH[1]}"
        name="${line%%id=*}"
        name="${name//[$'\t↳']/}"
        name="${name#"${name%%[![:space:]]*}"}"
        name="${name%"${name##*[![:space:]]}"}"
        [[ -n "$name" ]] || continue
        lower="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"

        if [[ "$lower" == *keyboard* || "$lower" == *mouse* \
            || "$lower" == *trackball* || "$lower" == *trackpad* \
            || "$lower" == *cec* || "$lower" == *consumer*control* \
            || "$lower" == *power*button* || "$lower" == *sleep*button* ]]; then
            continue
        fi

        if [[ "$lower" == *touch* || "$lower" == *touchscreen* \
            || "$lower" == *egalax* || "$lower" == *ilitek* \
            || "$lower" == *goodix* || "$lower" == *usbtouch* \
            || "$lower" == *multitouch* || "$lower" == *hid*multi* ]]; then
            printf '%s\t%s\n' "$id" "$name"
            continue
        fi

        props="$(xinput list-props "$id" 2>/dev/null || true)"
        if [[ "$props" == *"Abs MT Position X"* || "$props" == *"Abs X"* ]] \
            && [[ "$props" != *"Mouse Left Handed"* ]]; then
            printf '%s\t%s\n' "$id" "$name"
        fi
    done < <(xinput list 2>/dev/null)
}

# Map touch device(s) to the booth monitor (CAPTUREOS_BOOTH_OUTPUT).
captureos_map_touch_to_booth() {
    local output="${1:-${CAPTUREOS_BOOTH_OUTPUT:-}}"
    [[ -n "$output" ]] || return 0

    if declare -F captureos_load_display_config >/dev/null 2>&1; then
        captureos_load_display_config
    fi

    export DISPLAY="${DISPLAY:-:0}"
    export XAUTHORITY="${XAUTHORITY:-${HOME}/.Xauthority}"

    if ! command -v xinput >/dev/null 2>&1; then
        echo "CaptureOS: xinput not installed — touch may hit the wrong screen" >&2
        return 1
    fi
    if ! xrandr --query 2>/dev/null | grep -q "^${output} connected"; then
        echo "CaptureOS: booth output '$output' is not connected" >&2
        return 1
    fi

    local mapped=0 id name entry
    if [[ -n "${CAPTUREOS_TOUCH_DEVICE_ID:-}" ]]; then
        if xinput map-to-output "$CAPTUREOS_TOUCH_DEVICE_ID" "$output" 2>/dev/null; then
            echo "CaptureOS: mapped touch id ${CAPTUREOS_TOUCH_DEVICE_ID} -> ${output}"
            mapped=1
        fi
    elif [[ -n "${CAPTUREOS_TOUCH_DEVICE:-}" ]]; then
        if xinput map-to-output "$CAPTUREOS_TOUCH_DEVICE" "$output" 2>/dev/null; then
            echo "CaptureOS: mapped touch '${CAPTUREOS_TOUCH_DEVICE}' -> ${output}"
            mapped=1
        fi
    else
        while IFS=$'\t' read -r id name; do
            [[ -n "$id" ]] || continue
            if xinput map-to-output "$id" "$output" 2>/dev/null; then
                echo "CaptureOS: mapped touch '${name}' (id ${id}) -> ${output}"
                mapped=1
            fi
        done < <(captureos_list_touch_devices)
    fi

    if (( mapped == 0 )); then
        echo "CaptureOS: no touch device mapped — run captureos-launch.sh --list-inputs" >&2
        return 1
    fi
    return 0
}

captureos_print_inputs() {
    export DISPLAY="${DISPLAY:-:0}"
    export XAUTHORITY="${XAUTHORITY:-${HOME}/.Xauthority}"

    echo "Touch / pointer devices (via xinput):"
    if ! command -v xinput >/dev/null 2>&1; then
        echo "  xinput not installed (apt install xinput)"
        return 1
    fi
    local id name
    while IFS=$'\t' read -r id name; do
        printf '  id=%-3s  %s\n' "$id" "$name"
    done < <(captureos_list_touch_devices)

    if declare -F captureos_resolve_display_layout >/dev/null 2>&1; then
        captureos_resolve_display_layout 2>/dev/null || true
    fi
    echo
    echo "Booth output for touch mapping: ${CAPTUREOS_BOOTH_OUTPUT:-unknown}"
    echo
    echo "To override, add to ~/.config/captureos/display.conf:"
    echo '  CAPTUREOS_TOUCH_DEVICE="device name from above"'
    echo "  # or: CAPTUREOS_TOUCH_DEVICE_ID=8"
}
