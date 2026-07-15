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

# Pin Chromium booth/gallery windows via labwc actions.
# The old attribute form (output= / fullscreen=) is NOT valid labwc config —
# use MoveTo + ResizeTo + ToggleFullscreen. Must NOT start Chromium already
# fullscreen: MoveToOutput is a no-op on fullscreen windows.
captureos_apply_labwc_window_rules() {
    local booth_out gallery_out bx by bw bh gx gy gw gh
    booth_out="$(captureos_to_wlr_output "${CAPTUREOS_BOOTH_OUTPUT:-}")"
    gallery_out="$(captureos_to_wlr_output "${CAPTUREOS_GALLERY_OUTPUT:-}")"
    bx="${CAPTUREOS_BOOTH_X:-0}"
    by="${CAPTUREOS_BOOTH_Y:-0}"
    bw="${CAPTUREOS_BOOTH_W:-1024}"
    bh="${CAPTUREOS_BOOTH_H:-600}"
    gx="${CAPTUREOS_GALLERY_X:-0}"
    gy="${CAPTUREOS_GALLERY_Y:-0}"
    gw="${CAPTUREOS_GALLERY_W:-1920}"
    gh="${CAPTUREOS_GALLERY_H:-1080}"
    [[ -n "$booth_out" ]] || return 0

    local rc="${XDG_CONFIG_HOME:-$HOME/.config}/labwc/rc.xml"
    mkdir -p "$(dirname "$rc")"

    python3 - "$rc" "$booth_out" "$gallery_out" \
        "$bx" "$by" "$bw" "$bh" "$gx" "$gy" "$gw" "$gh" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

(rc_path, booth_out, gallery_out,
 bx, by, bw, bh, gx, gy, gw, gh) = sys.argv[1:12]
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
        title = rule.get("title") or ""
        if ident.startswith("CaptureOS") or title.startswith("CaptureOS"):
            rules.remove(rule)
    if len(list(rules)) == 0:
        root.remove(rules)

# Prefer cursor-based placement so warp-before-launch also works.
placement = None
for child in root:
    if child.tag.split("}", 1)[-1] == "placement":
        placement = child
        break
if placement is None:
    placement = ET.SubElement(root, f"{ns}placement")
policy = None
for child in placement:
    if child.tag.split("}", 1)[-1] == "policy":
        policy = child
        break
if policy is None:
    policy = ET.SubElement(placement, f"{ns}policy")
policy.text = "cursor"

rules = None
for child in root:
    if child.tag.split("}", 1)[-1] == "windowRules":
        rules = child
        break
if rules is None:
    rules = ET.SubElement(root, f"{ns}windowRules")


def add_action(rule, name, **attrs):
    action = ET.SubElement(rule, f"{ns}action")
    action.set("name", name)
    for k, v in attrs.items():
        action.set(k, str(v))


def add_rule(*, ident=None, title=None, x=None, y=None, w=None, h=None, output=None):
    rule = ET.SubElement(rules, f"{ns}windowRule")
    if ident:
        rule.set("identifier", ident)
    if title:
        rule.set("title", title)
    rule.set("serverDecoration", "no")
    # Order matters: MoveToOutput is a no-op on maximized/fullscreen
    # windows, so relocate FIRST while the window is still normal, then
    # fullscreen it (fullscreen fills whichever output it is on).
    if output:
        add_action(rule, "MoveToOutput", output=output)
    if x is not None and y is not None:
        add_action(rule, "MoveTo", x=x, y=y)
    if w is not None and h is not None:
        add_action(rule, "ResizeTo", width=w, height=h)
    add_action(rule, "ToggleFullscreen")


# Match by WM_CLASS (--class) AND by document title (more reliable).
add_rule(ident="CaptureOS-Booth*", x=bx, y=by, w=bw, h=bh, output=booth_out or None)
add_rule(title="CaptureOS Booth*", x=bx, y=by, w=bw, h=bh, output=booth_out or None)
if gallery_out:
    add_rule(ident="CaptureOS-Gallery*", x=gx, y=gy, w=gw, h=gh, output=gallery_out)
    add_rule(title="CaptureOS Gallery*", x=gx, y=gy, w=gw, h=gh, output=gallery_out)

tree.write(path, encoding="unicode", xml_declaration=True)
print(
    f"CaptureOS: labwc rules booth@{bx},{by} {bw}x{bh}->{booth_out} "
    f"gallery@{gx},{gy} {gw}x{gh}->{gallery_out or '(n/a)'}"
)
PY

    if command -v labwc >/dev/null 2>&1; then
        labwc --reconfigure 2>/dev/null || pkill -HUP labwc 2>/dev/null || true
        sleep 0.5
    fi
    return 0
}

# Warp the seat cursor to an output's center so new windows map there.
# labwc places new windows on the output under the cursor.
captureos_warp_cursor_to() {
    local x="${1:-0}" y="${2:-0}" w="${3:-100}" h="${4:-100}"
    local cx=$((x + w / 2)) cy=$((y + h / 2))
    echo "CaptureOS: warping cursor to ${cx},${cy}"
    captureos_warp_cursor_absolute "$cx" "$cy"
}

# Prefer output-aware warping on Wayland; fall back to desktop coords.
captureos_warp_cursor_to_output() {
    local output="${1:-}" x="${2:-0}" y="${3:-0}" w="${4:-100}" h="${5:-100}"
    local cx=$((x + w / 2)) cy=$((y + h / 2))
    if [[ -n "$output" ]] \
        && declare -F captureos_is_wayland_session >/dev/null 2>&1 \
        && captureos_is_wayland_session \
        && command -v wlr-randr >/dev/null 2>&1; then
        local wlr_out ox oy ow oh
        wlr_out="$(captureos_to_wlr_output "$output")"
        if captureos_lookup_wlr_output_rect "$wlr_out"; then
            ox="$CAPTUREOS_WLR_OUT_X"
            oy="$CAPTUREOS_WLR_OUT_Y"
            ow="$CAPTUREOS_WLR_OUT_W"
            oh="$CAPTUREOS_WLR_OUT_H"
            cx=$((ox + ow / 2))
            cy=$((oy + oh / 2))
            echo "CaptureOS: warping cursor to output ${wlr_out} center ${cx},${cy}"
            captureos_warp_cursor_absolute "$cx" "$cy"
            return 0
        fi
    fi
    captureos_warp_cursor_to "$x" "$y" "$w" "$h"
}

captureos_lookup_wlr_output_rect() {
    local want="$1" entry name w h x y primary rate
    CAPTUREOS_WLR_OUT_X=""
    CAPTUREOS_WLR_OUT_Y=""
    CAPTUREOS_WLR_OUT_W=""
    CAPTUREOS_WLR_OUT_H=""
    captureos_collect_wlr_displays || return 1
    for entry in "${CAPTUREOS_DISPLAY_LINES[@]}"; do
        IFS='|' read -r name w h x y primary rate <<<"$entry"
        [[ "$name" == "$want" ]] || continue
        CAPTUREOS_WLR_OUT_X="$x"
        CAPTUREOS_WLR_OUT_Y="$y"
        CAPTUREOS_WLR_OUT_W="$w"
        CAPTUREOS_WLR_OUT_H="$h"
        return 0
    done
    return 1
}

captureos_warp_cursor_absolute() {
    local cx="${1:-0}" cy="${2:-0}"
    # xdotool only moves the XWayland pointer — still useful for X11 ozone.
    if command -v xdotool >/dev/null 2>&1; then
        xdotool mousemove --sync "$cx" "$cy" 2>/dev/null \
            || xdotool mousemove "$cx" "$cy" 2>/dev/null || true
    fi
    if command -v wlrctl >/dev/null 2>&1; then
        # wlrctl pointer move is relative; hop to the desktop origin first.
        wlrctl pointer move -8000 -8000 2>/dev/null || true
        wlrctl pointer move "$cx" "$cy" 2>/dev/null || true
    fi
    sleep 0.3
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
