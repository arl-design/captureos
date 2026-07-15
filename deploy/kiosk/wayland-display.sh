# CaptureOS Wayland display helper (Pi OS Bookworm+ / labwc).
# Applies dual extended-desktop layout via wlr-randr and persists it in
# kanshi so Screen Configuration does not need to be set by hand each boot.

captureos_is_wayland_session() {
    [[ -n "${WAYLAND_DISPLAY:-}" || "${XDG_SESSION_TYPE:-}" == "wayland" ]] \
        || [[ -n "${XDG_RUNTIME_DIR:-}" && -S "${XDG_RUNTIME_DIR}/wayland-0" ]]
}

# Autostart often does not set WAYLAND_DISPLAY; wlr-randr needs it.
captureos_ensure_wayland_env() {
    if [[ -z "${WAYLAND_DISPLAY:-}" && -n "${XDG_RUNTIME_DIR:-}" ]]; then
        if [[ -S "${XDG_RUNTIME_DIR}/wayland-1" ]]; then
            export WAYLAND_DISPLAY=wayland-1
        elif [[ -S "${XDG_RUNTIME_DIR}/wayland-0" ]]; then
            export WAYLAND_DISPLAY=wayland-0
        fi
    fi
    if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
        export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    fi
}

# xrandr names (HDMI-1) vs wlr-randr names (HDMI-A-1). On Pi OS
# XWayland, xrandr already reports HDMI-A-* — leave those alone.
captureos_to_wlr_output() {
    local name="$1"
    case "$name" in
        HDMI-A-*|DSI-*|DPI-*)
            printf '%s' "$name"
            ;;
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
    # Prefer names that xrandr actually lists (Pi XWayland uses HDMI-A-*).
    if xrandr --query 2>/dev/null | grep -q "^${name} connected"; then
        printf '%s' "$name"
        return 0
    fi
    case "$name" in
        HDMI-A-[0-9]*)
            local alt="HDMI-${name#HDMI-A-}"
            if xrandr --query 2>/dev/null | grep -q "^${alt} connected"; then
                printf '%s' "$alt"
                return 0
            fi
            ;;
        HDMI-[0-9]*)
            local alt="HDMI-A-${name#HDMI-}"
            if xrandr --query 2>/dev/null | grep -q "^${alt} connected"; then
                printf '%s' "$alt"
                return 0
            fi
            ;;
    esac
    printf '%s' "$name"
}

# Pin Chromium booth/gallery windows to the correct outputs via labwc.
# xdotool cannot move Chromium --kiosk windows under XWayland (they report
# 10x10 @ 10,10), so window rules are the reliable path on Pi OS Bookworm+.
captureos_apply_labwc_window_rules() {
    local booth_out gallery_out
    booth_out="$(captureos_to_wlr_output "${CAPTUREOS_BOOTH_OUTPUT:-}")"
    gallery_out="$(captureos_to_wlr_output "${CAPTUREOS_GALLERY_OUTPUT:-}")"
    [[ -n "$booth_out" ]] || return 0

    local rc="${XDG_CONFIG_HOME:-$HOME/.config}/labwc/rc.xml"
    mkdir -p "$(dirname "$rc")"

    python3 - "$rc" "$booth_out" "$gallery_out" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

rc_path, booth_out, gallery_out = sys.argv[1:4]
path = Path(rc_path)
ns = "{http://openbox.org/3.4/rc}"
ET.register_namespace("", "http://openbox.org/3.4/rc")

if path.is_file():
    tree = ET.parse(path)
    root = tree.getroot()
else:
    root = ET.Element(f"{ns}openbox_config")
    tree = ET.ElementTree(root)

# Drop previous CaptureOS window rules (clean re-apply).
for rules in list(root):
    if rules.tag.split("}", 1)[-1] != "windowRules":
        continue
    for rule in list(rules):
        if rule.tag.split("}", 1)[-1] != "windowRule":
            continue
        ident = rule.get("identifier") or ""
        if ident.startswith("CaptureOS-"):
            rules.remove(rule)
    if len(list(rules)) == 0:
        root.remove(rules)

rules = None
for child in root:
    if child.tag.split("}", 1)[-1] == "windowRules":
        rules = child
        break
if rules is None:
    rules = ET.SubElement(root, f"{ns}windowRules")

def add_rule(ident, output):
    if not output:
        return
    rule = ET.SubElement(rules, f"{ns}windowRule")
    rule.set("identifier", ident)
    rule.set("output", output)
    rule.set("fullscreen", "yes")

add_rule("CaptureOS-Booth", booth_out)
add_rule("CaptureOS-Gallery", gallery_out or "")

tree.write(path, encoding="unicode", xml_declaration=True)
print(f"CaptureOS: labwc window rules booth->{booth_out} gallery->{gallery_out or '(n/a)'}")
PY

    if command -v labwc >/dev/null 2>&1; then
        labwc --reconfigure 2>/dev/null || pkill -HUP labwc 2>/dev/null || true
        sleep 0.5
    fi
    return 0
}

# Parse real wlr-randr output. The current mode is NOT on the header line:
#   HDMI-A-1 "Dell Inc. DELL S2721QS (HDMI-A-1)"
#     Enabled: yes
#     Modes:
#       1920x1080 px, 60.000000 Hz (preferred, current)
#     Position: 0,0
#     Transform: normal
captureos_collect_wlr_displays() {
    CAPTUREOS_DISPLAY_LINES=()
    command -v wlr-randr >/dev/null 2>&1 || return 1

    local name="" w="" h="" x=0 y=0 enabled=1 rate=60
    local line
    while IFS= read -r line; do
        # Header: output name at column 0 followed by the quoted description.
        if [[ "$line" =~ ^([A-Za-z0-9][A-Za-z0-9-]*)[[:space:]]+\" ]]; then
            if [[ -n "$name" && -n "$w" && -n "$h" && "$enabled" == "1" ]]; then
                CAPTUREOS_DISPLAY_LINES+=("${name}|${w}|${h}|${x}|${y}|0|${rate}")
            fi
            name="${BASH_REMATCH[1]}"
            w=""
            h=""
            x=0
            y=0
            enabled=1
            rate=60
            continue
        fi
        [[ -n "$name" ]] || continue
        if [[ "$line" =~ Enabled:[[:space:]]*(yes|no) ]]; then
            [[ "${BASH_REMATCH[1]}" == "yes" ]] && enabled=1 || enabled=0
        elif [[ "$line" =~ ([0-9]+)x([0-9]+)[[:space:]]*px,[[:space:]]*([0-9.]+)[[:space:]]*Hz.*current ]]; then
            w="${BASH_REMATCH[1]}"
            h="${BASH_REMATCH[2]}"
            rate="${BASH_REMATCH[3]}"
        elif [[ "$line" =~ Position:[[:space:]]*(-?[0-9]+),(-?[0-9]+) ]]; then
            x="${BASH_REMATCH[1]}"
            y="${BASH_REMATCH[2]}"
        fi
    done < <(wlr-randr 2>/dev/null)

    if [[ -n "$name" && -n "$w" && -n "$h" && "$enabled" == "1" ]]; then
        CAPTUREOS_DISPLAY_LINES+=("${name}|${w}|${h}|${x}|${y}|0|${rate}")
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
        "${CAPTUREOS_GALLERY_W:-}" "${CAPTUREOS_GALLERY_H:-}" \
        "${CAPTUREOS_GALLERY_RATE:-60}" || true
    captureos_wlr_set_output "$booth_out" \
        "${CAPTUREOS_BOOTH_X:-0}" "${CAPTUREOS_BOOTH_Y:-0}" \
        "${CAPTUREOS_BOOTH_W:-}" "${CAPTUREOS_BOOTH_H:-}" \
        "${CAPTUREOS_BOOTH_RATE:-60}" || true

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
    captureos_ensure_wayland_env
    captureos_is_wayland_session || return 1

    # Prefer reading layout from xrandr when it works (Pi XWayland reports
    # HDMI-A-* there). wlr-randr often fails from autostart without
    # WAYLAND_DISPLAY, which previously left us guessing blindly.
    if declare -F captureos_collect_xrandr_displays >/dev/null 2>&1 \
        && captureos_collect_xrandr_displays \
        && ((${#CAPTUREOS_DISPLAY_LINES[@]} >= 1)); then
        CAPTUREOS_DISPLAY_BACKEND=xrandr
        if declare -F captureos_resolve_display_layout >/dev/null 2>&1; then
            captureos_resolve_display_layout || true
        fi
        if declare -F captureos_arrange_extended_desktop >/dev/null 2>&1; then
            captureos_arrange_extended_desktop || true
            captureos_resolve_display_layout || true
        fi
    fi

    if command -v wlr-randr >/dev/null 2>&1; then
        captureos_wait_for_wayland_displays 2 "${CAPTUREOS_DISPLAY_WAIT:-5}" || true
        if captureos_collect_wlr_displays 2>/dev/null \
            && ((${#CAPTUREOS_DISPLAY_LINES[@]} >= 2)); then
            CAPTUREOS_DISPLAY_BACKEND=wlr-randr
            if declare -F captureos_resolve_display_layout >/dev/null 2>&1; then
                captureos_resolve_display_layout || true
            fi
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
            captureos_apply_wayland_layout || true
            captureos_write_kanshi_config || true
        fi
    fi

    if declare -F captureos_resolve_display_layout >/dev/null 2>&1; then
        captureos_resolve_display_layout || true
    fi
    captureos_apply_labwc_window_rules || true
    return 0
}
