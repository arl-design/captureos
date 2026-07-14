# CaptureOS Wayland display helper (Pi OS Bookworm+ / labwc).
# Applies dual extended-desktop layout via wlr-randr and persists it in
# kanshi so Screen Configuration does not need to be set by hand each boot.

captureos_is_wayland_session() {
    [[ -n "${WAYLAND_DISPLAY:-}" || "${XDG_SESSION_TYPE:-}" == "wayland" ]]
}

# xrandr names (HDMI-1) vs wlr-randr names (HDMI-A-1) on Raspberry Pi OS.
captureos_to_wlr_output() {
    local name="$1"
    case "$name" in
        HDMI-[0-9]*)
            printf 'HDMI-A-%s' "${name#HDMI-}"
            ;;
        *)
            printf '%s' "$name"
            ;;
    esac
}

captureos_to_xrandr_output() {
    local name="$1"
    case "$name" in
        HDMI-A-[0-9]*)
            printf 'HDMI-%s' "${name#HDMI-A-}"
            ;;
        *)
            printf '%s' "$name"
            ;;
    esac
}

# Parse wlr-randr -- output lines like:
#   HDMI-A-1 "Monitor Name" 1920x1080@60Hz
#     Position: 0,0
#     Enabled: yes
captureos_collect_wlr_displays() {
    CAPTUREOS_DISPLAY_LINES=()
    command -v wlr-randr >/dev/null 2>&1 || return 1

    local name="" w="" h="" x=0 y=0 primary=0 enabled=1 rate=60
    local line
    while IFS= read -r line; do
        if [[ "$line" =~ ^([A-Za-z0-9-]+)[[:space:]]+\".*\"[[:space:]]+([0-9]+)x([0-9]+)(@([0-9.]+)Hz)? ]]; then
            if [[ -n "$name" && -n "$w" && -n "$h" && "$enabled" == "1" ]]; then
                CAPTUREOS_DISPLAY_LINES+=("${name}|${w}|${h}|${x}|${y}|${primary}|${rate}")
            fi
            name="${BASH_REMATCH[1]}"
            w="${BASH_REMATCH[2]}"
            h="${BASH_REMATCH[3]}"
            rate="${BASH_REMATCH[5]:-60}"
            x=0
            y=0
            enabled=1
            continue
        fi
        [[ -n "$name" ]] || continue
        if [[ "$line" =~ Position:[[:space:]]*([0-9]+),([0-9]+) ]]; then
            x="${BASH_REMATCH[1]}"
            y="${BASH_REMATCH[2]}"
        elif [[ "$line" =~ Enabled:[[:space:]]*(yes|no) ]]; then
            [[ "${BASH_REMATCH[1]}" == "yes" ]] && enabled=1 || enabled=0
        fi
    done < <(wlr-randr 2>/dev/null)

    if [[ -n "$name" && -n "$w" && -n "$h" && "$enabled" == "1" ]]; then
        CAPTUREOS_DISPLAY_LINES+=("${name}|${w}|${h}|${x}|${y}|${primary}|${rate}")
    fi

    ((${#CAPTUREOS_DISPLAY_LINES[@]} > 0))
}

captureos_wlr_set_output() {
    local output="$1" x="$2" y="$3" w="$4" h="$5" rate="${6:-60}"
    local ok=0

    if [[ -n "$w" && -n "$h" ]]; then
        wlr-randr --output "$output" --on --mode "${w}x${h}@${rate}" --pos "${x},${y}" 2>/dev/null && ok=1
        (( ok == 0 )) && wlr-randr --output "$output" --on --mode "${w}x${h}" --pos "${x},${y}" 2>/dev/null && ok=1
    fi
    if (( ok == 0 )); then
        wlr-randr --output "$output" --on --auto --pos "${x},${y}" 2>/dev/null && ok=1
    fi
    if (( ok == 0 )); then
        wlr-randr --output "$output" --on 2>/dev/null && ok=1
    fi
    (( ok == 1 ))
}

# Apply extended desktop on Wayland (gallery left/top, booth beside it).
captureos_apply_wayland_layout() {
    command -v wlr-randr >/dev/null 2>&1 || return 1

    local gallery_out booth_out
    gallery_out="$(captureos_to_wlr_output "${CAPTUREOS_GALLERY_OUTPUT:-}")"
    booth_out="$(captureos_to_wlr_output "${CAPTUREOS_BOOTH_OUTPUT:-}")"
    [[ -n "$gallery_out" && -n "$booth_out" ]] || return 1
    [[ "$gallery_out" != "$booth_out" ]] || return 1

    echo "CaptureOS: applying Wayland layout gallery=${gallery_out} booth=${booth_out}"
    captureos_wlr_set_output "$gallery_out" \
        "${CAPTUREOS_GALLERY_X:-0}" "${CAPTUREOS_GALLERY_Y:-0}" \
        "${CAPTUREOS_GALLERY_W:-}" "${CAPTUREOS_GALLERY_H:-}" || true
    captureos_wlr_set_output "$booth_out" \
        "${CAPTUREOS_BOOTH_X:-0}" "${CAPTUREOS_BOOTH_Y:-0}" \
        "${CAPTUREOS_BOOTH_W:-}" "${CAPTUREOS_BOOTH_H:-}" || true

    sleep 1
    return 0
}

# Write kanshi profile so Pi OS keeps dual-screen layout across reboot.
captureos_write_kanshi_config() {
    [[ "${CAPTUREOS_MANAGE_KANSHI:-1}" == "1" ]] || return 0

    local gallery_out booth_out kanshi_dir kanshi_file
    gallery_out="$(captureos_to_wlr_output "${CAPTUREOS_GALLERY_OUTPUT:-}")"
    booth_out="$(captureos_to_wlr_output "${CAPTUREOS_BOOTH_OUTPUT:-}")"
    [[ -n "$gallery_out" && -n "$booth_out" ]] || return 0

    kanshi_dir="${XDG_CONFIG_HOME:-$HOME/.config}/kanshi"
    kanshi_file="$kanshi_dir/config"
    mkdir -p "$kanshi_dir"

    local gallery_mode booth_mode gallery_rate booth_rate
    gallery_mode="${CAPTUREOS_GALLERY_W:-1920}x${CAPTUREOS_GALLERY_H:-1080}"
    booth_mode="${CAPTUREOS_BOOTH_W:-1024}x${CAPTUREOS_BOOTH_H:-600}"
    gallery_rate="${CAPTUREOS_GALLERY_RATE:-60}"
    booth_rate="${CAPTUREOS_BOOTH_RATE:-60}"

    local content
    content="$(cat <<EOF
# CaptureOS dual-display profile (auto-generated — do not edit by hand;
# adjust /etc/captureos/display.conf and re-run setup-displays.sh).
profile {
    output ${gallery_out} enable mode ${gallery_mode}@${gallery_rate} position ${CAPTUREOS_GALLERY_X:-0},${CAPTUREOS_GALLERY_Y:-0} transform normal
    output ${booth_out} enable mode ${booth_mode}@${booth_rate} position ${CAPTUREOS_BOOTH_X:-0},${CAPTUREOS_BOOTH_Y:-0} transform normal
}
EOF
)"
    # Leave the file alone when it already matches — rewriting (and HUPing
    # kanshi) mid-session can shuffle windows around.
    if [[ -f "$kanshi_file" ]] && [[ "$(cat "$kanshi_file")" == "$content" ]]; then
        return 0
    fi
    printf '%s\n' "$content" >"$kanshi_file"
    echo "CaptureOS: wrote kanshi profile to $kanshi_file"

    if pgrep -x kanshi >/dev/null 2>&1; then
        pkill -HUP kanshi 2>/dev/null || true
    fi
    return 0
}

captureos_wait_for_wayland_displays() {
    local want="${1:-2}" timeout="${2:-10}" count attempt
    for attempt in $(seq 1 "$timeout"); do
        if captureos_collect_wlr_displays; then
            count="${#CAPTUREOS_DISPLAY_LINES[@]}"
            (( count >= want )) && return 0
        fi
        sleep 1
    done
    echo "CaptureOS: only ${count:-0} Wayland display(s) ready" >&2
    return 0
}

# Full Wayland setup: detect layout, extend desktop, persist kanshi.
captureos_setup_wayland_displays() {
    captureos_is_wayland_session || return 1
    command -v wlr-randr >/dev/null 2>&1 || return 1

    captureos_wait_for_wayland_displays 2 "${CAPTUREOS_DISPLAY_WAIT:-8}" || true

    if declare -F captureos_resolve_display_layout >/dev/null 2>&1; then
        if captureos_collect_wlr_displays 2>/dev/null; then
            CAPTUREOS_DISPLAY_BACKEND=wlr-randr
        fi
        captureos_resolve_display_layout || return 1
    fi

    # If both outputs share the same origin they are mirrored — extend them.
    if captureos_collect_wlr_displays && ((${#CAPTUREOS_DISPLAY_LINES[@]} >= 2)); then
        local entry name w h x y primary rate
        local -a xs=() ys=()
        for entry in "${CAPTUREOS_DISPLAY_LINES[@]}"; do
            IFS='|' read -r name w h x y primary rate <<<"$entry"
            xs+=("$x")
            ys+=("$y")
        done
        if [[ "${xs[0]}" == "${xs[1]}" && "${ys[0]}" == "${ys[1]}" ]]; then
            echo "CaptureOS: Wayland displays mirrored — switching to extended"
            captureos_auto_assign_displays
            captureos_apply_display_entry GALLERY "$CAPTUREOS_AUTO_GALLERY"
            captureos_apply_display_entry BOOTH "$CAPTUREOS_AUTO_BOOTH"
            CAPTUREOS_GALLERY_X=0
            CAPTUREOS_GALLERY_Y=0
            CAPTUREOS_BOOTH_X=$((CAPTUREOS_GALLERY_X + CAPTUREOS_GALLERY_W))
            CAPTUREOS_BOOTH_Y="${CAPTUREOS_GALLERY_Y}"
        fi
    fi

    captureos_apply_wayland_layout || true
    captureos_write_kanshi_config || true
    captureos_resolve_display_layout || true
    return 0
}
