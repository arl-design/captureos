# Position Chromium kiosk windows on the correct monitor after launch.
# --window-position is unreliable on Pi OS; xdotool + WM_CLASS is the fallback.

captureos_ensure_x_display() {
    export DISPLAY="${DISPLAY:-:0}"
    if [[ -z "${XAUTHORITY:-}" ]]; then
        if [[ -r "${HOME}/.Xauthority" ]]; then
            XAUTHORITY="${HOME}/.Xauthority"
        elif [[ -n "${USER:-}" && -r "/home/${USER}/.Xauthority" ]]; then
            XAUTHORITY="/home/${USER}/.Xauthority"
        fi
        export XAUTHORITY
    fi

    local attempt
    for attempt in $(seq 1 30); do
        if xrandr --query >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "CaptureOS: X display not ready (DISPLAY=${DISPLAY})" >&2
    return 1
}

captureos_wait_for_displays() {
    local want="${1:-2}" count attempt
    captureos_ensure_x_display || return 1
    for attempt in $(seq 1 45); do
        if declare -F captureos_collect_xrandr_displays >/dev/null 2>&1 \
            && captureos_collect_xrandr_displays; then
            count="${#CAPTUREOS_DISPLAY_LINES[@]}"
            (( count >= want )) && return 0
        fi
        sleep 1
    done
    echo "CaptureOS: only ${count:-0} display(s) detected — continuing anyway" >&2
    return 0
}

captureos_kill_kiosk_windows() {
    pkill -f 'captureos-profile-booth' 2>/dev/null || true
    pkill -f 'captureos-profile-gallery' 2>/dev/null || true
    # Give Chromium time to release the profile dirs / windows.
    sleep 1
}

captureos_find_window_by_class() {
    local class="$1" wid
    command -v xdotool >/dev/null 2>&1 || return 1
    wid="$(xdotool search --class "$class" 2>/dev/null | tail -1)"
    [[ -n "$wid" ]] || return 1
    printf '%s' "$wid"
}

captureos_position_window_class() {
    local class="$1" x="$2" y="$3" w="$4" h="$5"
    local wid attempt

    command -v xdotool >/dev/null 2>&1 || return 1

    for attempt in $(seq 1 40); do
        wid="$(captureos_find_window_by_class "$class" || true)"
        [[ -n "$wid" ]] && break
        sleep 0.25
    done
    [[ -n "$wid" ]] || {
        echo "CaptureOS: could not find window class ${class}" >&2
        return 1
    }

    xdotool windowmove "$wid" "$x" "$y" 2>/dev/null || true
    xdotool windowsize "$wid" "$w" "$h" 2>/dev/null || true
    echo "CaptureOS: positioned ${class} window ${wid} at ${x},${y} ${w}x${h}"
    return 0
}

captureos_arrange_extended_desktop() {
    # If two monitors share the same origin they are mirrored — extend them.
    captureos_collect_xrandr_displays || return 0
    ((${#CAPTUREOS_DISPLAY_LINES[@]} < 2)) && return 0

    local entry name w h x y primary
    local -a names=() xs=() ys=()
    for entry in "${CAPTUREOS_DISPLAY_LINES[@]}"; do
        IFS='|' read -r name w h x y primary <<<"$entry"
        names+=("$name")
        xs+=("$x")
        ys+=("$y")
    done

    if [[ "${xs[0]}" == "${xs[1]}" && "${ys[0]}" == "${ys[1]}" ]]; then
        echo "CaptureOS: displays appear mirrored — arranging extended desktop"
        xrandr --output "${names[1]}" --auto --right-of "${names[0]}" 2>/dev/null || \
            xrandr --output "${names[0]}" --auto --left-of "${names[1]}" 2>/dev/null || true
        sleep 1
        captureos_collect_xrandr_displays || true
    fi
}
