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
    for attempt in $(seq 1 "${CAPTUREOS_X_WAIT:-15}"); do
        if xrandr --query >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "CaptureOS: X display not ready (DISPLAY=${DISPLAY})" >&2
    return 1
}

captureos_wait_for_displays() {
    local want="${1:-2}" timeout="${2:-10}" count attempt
    captureos_ensure_x_display || return 1
    for attempt in $(seq 1 "$timeout"); do
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

    # Chromium under XWayland/labwc often ignores move while fullscreen and
    # reports a fake 10x10 geometry. Drop fullscreen/maximized, move + size
    # with both xdotool and wmctrl, then fullscreen again.
    if command -v wmctrl >/dev/null 2>&1; then
        wmctrl -i -r "$wid" -b remove,fullscreen,maximized_vert,maximized_horz 2>/dev/null || true
    fi
    xdotool windowstate --remove FULLSCREEN "$wid" 2>/dev/null || true
    xdotool windowstate --remove MAXIMIZED_VERT "$wid" 2>/dev/null || true
    xdotool windowstate --remove MAXIMIZED_HORZ "$wid" 2>/dev/null || true
    sleep 0.3
    xdotool windowmove --sync "$wid" "$x" "$y" 2>/dev/null \
        || xdotool windowmove "$wid" "$x" "$y" 2>/dev/null || true
    xdotool windowsize --sync "$wid" "$w" "$h" 2>/dev/null \
        || xdotool windowsize "$wid" "$w" "$h" 2>/dev/null || true
    if command -v wmctrl >/dev/null 2>&1; then
        # wmctrl -e gravity,x,y,w,h
        wmctrl -i -r "$wid" -e "0,${x},${y},${w},${h}" 2>/dev/null || true
    fi
    sleep 0.3
    if command -v wmctrl >/dev/null 2>&1; then
        wmctrl -i -r "$wid" -b add,fullscreen 2>/dev/null || true
    else
        xdotool windowstate --add FULLSCREEN "$wid" 2>/dev/null || true
    fi

    local geom
    geom="$(xdotool getwindowgeometry --shell "$wid" 2>/dev/null | tr '\n' ' ')"
    echo "CaptureOS: positioned ${class} window ${wid} at ${x},${y} ${w}x${h} (now: ${geom:-unknown})"
    return 0
}

# True when the window's center sits inside the target rectangle.
# Reject fake Chromium/XWayland 10x10 geometry (not a trusted reading).
captureos_window_on_target() {
    local wid="$1" tx="$2" ty="$3" tw="$4" th="$5"
    local X="" Y="" WIDTH="" HEIGHT="" SCREEN=""
    eval "$(xdotool getwindowgeometry --shell "$wid" 2>/dev/null)" || return 1
    [[ -n "$X" && -n "$Y" ]] || return 1
    if (( ${WIDTH:-0} < 100 || ${HEIGHT:-0} < 100 )); then
        return 1
    fi
    local cx=$((X + WIDTH / 2)) cy=$((Y + HEIGHT / 2))
    (( cx >= tx && cx < tx + tw && cy >= ty && cy < ty + th ))
}

# Prefer reading from _NET_FRAME_EXTENTS / wmctrl geometry when available.
captureos_window_center() {
    local wid="$1"
    local X="" Y="" WIDTH="" HEIGHT=""
    if command -v wmctrl >/dev/null 2>&1; then
        local line
        line="$(wmctrl -lG 2>/dev/null | awk -v id="$(printf '0x%08x' "$wid")" 'tolower($1)==tolower(id) {print}')"
        if [[ -n "$line" ]]; then
            # id desktop x y w h host title...
            read -r _ _ X Y WIDTH HEIGHT _ <<<"$line"
        fi
    fi
    if [[ -z "$X" || -z "$WIDTH" ]] || (( WIDTH < 100 )); then
        eval "$(xdotool getwindowgeometry --shell "$wid" 2>/dev/null)" || return 1
    fi
    (( ${WIDTH:-0} >= 100 && ${HEIGHT:-0} >= 100 )) || return 1
    printf '%s %s' "$((X + WIDTH / 2))" "$((Y + HEIGHT / 2))"
}

captureos_fullscreen_window() {
    local wid="$1"
    [[ -n "$wid" ]] || return 1

    # Never send F11 if already fullscreen — a second F11 toggles OUT of
    # fullscreen and leaves a windowed Chromium with an offset touch UI.
    local state
    state="$(xprop -id "$wid" _NET_WM_STATE 2>/dev/null || true)"
    if [[ "$state" == *_NET_WM_STATE_FULLSCREEN* ]]; then
        return 0
    fi

    if command -v wmctrl >/dev/null 2>&1; then
        wmctrl -i -r "$wid" -b add,fullscreen 2>/dev/null || true
    fi
    xdotool windowstate --add FULLSCREEN "$wid" 2>/dev/null || true

    state="$(xprop -id "$wid" _NET_WM_STATE 2>/dev/null || true)"
    if [[ "$state" == *_NET_WM_STATE_FULLSCREEN* ]]; then
        return 0
    fi

    # Last resort only when still not fullscreen.
    xdotool windowactivate --sync "$wid" 2>/dev/null || true
    xdotool key --window "$wid" F11 2>/dev/null || true
    return 0
}

captureos_fullscreen_window_class() {
    local class="$1" wid
    wid="$(captureos_find_window_by_class "$class" || true)"
    [[ -n "$wid" ]] || return 1
    captureos_fullscreen_window "$wid"
}

# Keep checking (and re-placing) a kiosk window until it really sits on
# its target display. At boot Chromium often starts before the second
# monitor is arranged, so a single positioning pass lands both windows
# on one screen; this loop catches up once the layout settles.
captureos_ensure_window_layout() {
    local class="$1" x="$2" y="$3" w="$4" h="$5" tries="${6:-8}"
    local i wid cx cy
    command -v xdotool >/dev/null 2>&1 || return 1

    for i in $(seq 1 "$tries"); do
        wid="$(captureos_find_window_by_class "$class" || true)"
        if [[ -n "$wid" ]]; then
            if read -r cx cy < <(captureos_window_center "$wid"); then
                if (( cx >= x && cx < x + w && cy >= y && cy < y + h )); then
                    captureos_fullscreen_window "$wid" || true
                    echo "CaptureOS: ${class} verified at ${x},${y} center=${cx},${cy} (attempt ${i}) — fullscreen"
                    return 0
                fi
            fi
            captureos_position_window_class "$class" "$x" "$y" "$w" "$h" || true
            if read -r cx cy < <(captureos_window_center "$wid"); then
                if (( cx >= x && cx < x + w && cy >= y && cy < y + h )); then
                    captureos_fullscreen_window "$wid" || true
                    echo "CaptureOS: ${class} moved to ${x},${y} center=${cx},${cy} (attempt ${i}) — fullscreen"
                    return 0
                fi
            fi
        fi
        sleep 2
    done
    echo "CaptureOS: ${class} still not at ${x},${y} after ${tries} attempts" >&2
    # Last-ditch: still fullscreen wherever it is so the UI isn't windowed.
    captureos_fullscreen_window_class "$class" || true
    return 1
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
