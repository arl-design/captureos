# CaptureOS touch-input helper — maps USB touch controllers to the booth
# display so taps on the touchscreen hit the shutter button, not the gallery.
#
# Override in display.conf:
#   CAPTUREOS_TOUCH_DEVICE="ILITEK ILITEK-TP"
#   CAPTUREOS_TOUCH_DEVICE_ID=8
#   CAPTUREOS_TOUCH_LIBINPUT="10-0038 generic ft5x06 (79)"

captureos_list_libinput_touch_devices() {
    command -v libinput >/dev/null 2>&1 || return 1
    local block="" name
    while IFS= read -r line; do
        if [[ "$line" == "Device:"* ]]; then
            if [[ -n "$block" ]] && [[ "$block" == *"Capabilities:"*"touch"* ]]; then
                name="${block#Device:}"
                name="${name%%$'\n'*}"
                name="${name#"${name%%[![:space:]]*}"}"
                name="${name%"${name##*[![:space:]]}"}"
                [[ -n "$name" ]] && printf '%s\n' "$name"
            fi
            block="$line"
            continue
        fi
        block+=$'\n'"$line"
    done < <(libinput list-devices 2>/dev/null)
    if [[ -n "$block" ]] && [[ "$block" == *"Capabilities:"*"touch"* ]]; then
        name="${block#Device:}"
        name="${name%%$'\n'*}"
        name="${name#"${name%%[![:space:]]*}"}"
        name="${name%"${name##*[![:space:]]}"}"
        [[ -n "$name" ]] && printf '%s\n' "$name"
    fi
}

# Persist touch -> booth mapping in labwc rc.xml (Pi OS Wayland).
captureos_apply_labwc_touch() {
    local output="$1" device="${2:-}"
    [[ -n "$output" ]] || return 1
    [[ "${CAPTUREOS_MANAGE_LABWC_TOUCH:-1}" == "1" ]] || return 0

    if [[ -z "$device" ]]; then
        if [[ -n "${CAPTUREOS_TOUCH_LIBINPUT:-}" ]]; then
            device="$CAPTUREOS_TOUCH_LIBINPUT"
        else
            device="$(captureos_list_libinput_touch_devices | head -1)"
        fi
    fi
    [[ -n "$device" ]] || return 1

    if declare -F captureos_to_wlr_output >/dev/null 2>&1; then
        output="$(captureos_to_wlr_output "$output")"
    fi

    local rc="${XDG_CONFIG_HOME:-$HOME/.config}/labwc/rc.xml"
    mkdir -p "$(dirname "$rc")"

    # Multitouch (mouseEmulation=no) is the mode that works with the
    # dual-screen kiosk; override with CAPTUREOS_TOUCH_MOUSE_EMULATION=yes.
    local emulation="${CAPTUREOS_TOUCH_MOUSE_EMULATION:-no}"

    python3 - "$rc" "$device" "$output" "$emulation" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

rc_path, device, map_output, emulation = sys.argv[1:5]
path = Path(rc_path)
ns = "{http://openbox.org/3.4/rc}"
# Keep <touch .../> instead of <ns0:touch .../> — labwc reads plain names.
ET.register_namespace("", "http://openbox.org/3.4/rc")

if path.is_file():
    tree = ET.parse(path)
    root = tree.getroot()
else:
    root = ET.Element(f"{ns}openbox_config")
    tree = ET.ElementTree(root)


def attr(el, name):
    return el.get(name) or el.get(f"{ns}{name}")


def base_name(name: str) -> str:
    """Strip trailing '(USB …)' so the same screen keeps one mapping across ports."""
    if " (USB " in name:
        return name.rsplit(" (USB ", 1)[0].strip()
    return name.strip()


changed = False
want_base = base_name(device)
existing = None

for touch in list(root):
    if touch.tag.split("}", 1)[-1] != "touch":
        continue
    name = attr(touch, "deviceName") or ""
    mapped_to = attr(touch, "mapToOutput") or ""
    # Drop stale USB-port variants, and any touch still aimed at a
    # non-booth output (classic cause of "tap too low" on dual HDMI).
    same_panel = base_name(name) == want_base or name == device
    wrong_output = mapped_to and mapped_to != map_output
    if same_panel or wrong_output:
        if existing is None and name == device and not wrong_output:
            existing = touch
        else:
            root.remove(touch)
            changed = True
            print(f"CaptureOS: removed stale touch entry '{name}' -> {mapped_to or '?'}")

if existing is None:
    existing = ET.SubElement(root, f"{ns}touch")
    existing.set("deviceName", device)
    changed = True

if attr(existing, "deviceName") != device:
    existing.set("deviceName", device)
    changed = True
if attr(existing, "mapToOutput") != map_output:
    existing.set("mapToOutput", map_output)
    changed = True
if attr(existing, "mouseEmulation") != emulation:
    existing.set("mouseEmulation", emulation)
    changed = True

if changed:
    tree.write(path, encoding="unicode", xml_declaration=True)
    print(f"CaptureOS: labwc touch '{device}' -> {map_output} (mouseEmulation={emulation})")
else:
    print(f"CaptureOS: labwc touch '{device}' already -> {map_output}")
sys.exit(0 if changed else 3)
PY
    local rc_status=$?

    # Only poke labwc when the config actually changed — reconfiguring
    # mid-launch can disturb freshly-placed kiosk windows.
    if [[ $rc_status -eq 0 ]] && command -v labwc >/dev/null 2>&1; then
        labwc --reconfigure 2>/dev/null || pkill -HUP labwc 2>/dev/null || true
    fi
    return 0
}

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
            || "$lower" == *multitouch* || "$lower" == *hid*multi* \
            || "$lower" == *qdtech* || "$lower" == *mpi7003* ]]; then
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

# Apply an absolute Coordinate Transformation Matrix that constrains a
# touch device to the booth rectangle of the extended desktop. More
# reliable than map-to-output alone under XWayland (wrong name / stale CTM).
captureos_apply_touch_ctm() {
    local id="$1" ox="${2:-0}" oy="${3:-0}" ow="${4:-0}" oh="${5:-0}"
    [[ -n "$id" && "$ow" -gt 0 && "$oh" -gt 0 ]] || return 1
    command -v xinput >/dev/null 2>&1 || return 1

    local line dw dh
    line="$(xrandr 2>/dev/null | awk '/current/{print; exit}')"
    # "Screen 0: ... current 2944 x 1080, ..."
    dw="$(awk '{for(i=1;i<=NF;i++) if($i=="current"){print $(i+1); exit}}' <<<"$line")"
    dh="$(awk '{for(i=1;i<=NF;i++) if($i=="current"){print $(i+3); exit}}' <<<"$line")"
    dw="${dw%,}"
    dh="${dh%,}"
    [[ -n "$dw" && -n "$dh" && "$dw" -gt 0 && "$dh" -gt 0 ]] || return 1

    local a c e f
    a="$(awk -v ow="$ow" -v dw="$dw" 'BEGIN{printf "%.6f", ow/dw}')"
    c="$(awk -v ox="$ox" -v dw="$dw" 'BEGIN{printf "%.6f", ox/dw}')"
    e="$(awk -v oh="$oh" -v dh="$dh" 'BEGIN{printf "%.6f", oh/dh}')"
    f="$(awk -v oy="$oy" -v dh="$dh" 'BEGIN{printf "%.6f", oy/dh}')"

    if xinput set-prop "$id" "Coordinate Transformation Matrix" \
        "$a" 0 "$c" 0 "$e" "$f" 0 0 1 2>/dev/null; then
        echo "CaptureOS: CTM id=${id} -> booth ${ow}x${oh}+${ox}+${oy} on ${dw}x${dh} (${a} 0 ${c} 0 ${e} ${f} 0 0 1)"
        return 0
    fi
    return 1
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

    local mapped=0
    local bx="${CAPTUREOS_BOOTH_X:-0}" by="${CAPTUREOS_BOOTH_Y:-0}"
    local bw="${CAPTUREOS_BOOTH_W:-0}" bh="${CAPTUREOS_BOOTH_H:-0}"

    if declare -F captureos_is_wayland_session >/dev/null 2>&1 \
        && captureos_is_wayland_session \
        && declare -F captureos_apply_labwc_touch >/dev/null 2>&1; then
        local libdev
        if [[ -n "${CAPTUREOS_TOUCH_LIBINPUT:-}" ]]; then
            captureos_apply_labwc_touch "$output" "$CAPTUREOS_TOUCH_LIBINPUT" && mapped=1
        else
            while IFS= read -r libdev; do
                [[ -n "$libdev" ]] || continue
                captureos_apply_labwc_touch "$output" "$libdev" && mapped=1
            done < <(captureos_list_libinput_touch_devices)
            (( mapped == 0 )) && captureos_apply_labwc_touch "$output" "" && mapped=1
        fi
    fi

    if command -v xinput >/dev/null 2>&1; then
        local xoutput="$output"
        if declare -F captureos_to_xrandr_output >/dev/null 2>&1; then
            xoutput="$(captureos_to_xrandr_output "$output")"
        fi
        local -a candidates=("$xoutput")
        if [[ "$xoutput" == HDMI-A-* ]]; then
            candidates+=("HDMI-${xoutput#HDMI-A-}")
        elif [[ "$xoutput" == HDMI-* ]]; then
            candidates+=("HDMI-A-${xoutput#HDMI-}")
        fi

        local id name try_out
        local -a ids=()
        if [[ -n "${CAPTUREOS_TOUCH_DEVICE_ID:-}" ]]; then
            ids+=("$CAPTUREOS_TOUCH_DEVICE_ID")
        elif [[ -n "${CAPTUREOS_TOUCH_DEVICE:-}" ]]; then
            while IFS=$'\t' read -r id name; do
                [[ "$name" == "$CAPTUREOS_TOUCH_DEVICE" ]] && ids+=("$id")
            done < <(captureos_list_touch_devices)
            # Name may be unique enough for xinput by string.
            ids+=("$CAPTUREOS_TOUCH_DEVICE")
        else
            while IFS=$'\t' read -r id name; do
                [[ -n "$id" ]] && ids+=("$id")
            done < <(captureos_list_touch_devices)
        fi

        for id in "${ids[@]}"; do
            [[ -n "$id" ]] || continue
            # Prefer an explicit matrix over the booth geometry (works even
            # when map-to-output output names differ under XWayland).
            if (( bw > 0 && bh > 0 )) && captureos_apply_touch_ctm "$id" "$bx" "$by" "$bw" "$bh"; then
                mapped=1
                continue
            fi
            for try_out in "${candidates[@]}"; do
                xrandr --query 2>/dev/null | grep -q "^${try_out} connected" || continue
                xinput set-prop "$id" "Coordinate Transformation Matrix" \
                    1 0 0 0 1 0 0 0 1 2>/dev/null || true
                if xinput map-to-output "$id" "$try_out" 2>/dev/null; then
                    echo "CaptureOS: mapped touch id/name '${id}' -> ${try_out}"
                    mapped=1
                    break
                fi
            done
        done
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

    if command -v libinput >/dev/null 2>&1; then
        echo
        echo "Touch devices (via libinput — use for labwc / Screen Configuration):"
        local dev
        while IFS= read -r dev; do
            [[ -n "$dev" ]] && printf '  %s\n' "$dev"
        done < <(captureos_list_libinput_touch_devices)
    fi

    if declare -F captureos_resolve_display_layout >/dev/null 2>&1; then
        captureos_resolve_display_layout 2>/dev/null || true
    fi
    echo
    echo "Booth output for touch mapping: ${CAPTUREOS_BOOTH_OUTPUT:-unknown}"
    echo
    echo "To override, add to ~/.config/captureos/display.conf:"
    echo '  CAPTUREOS_TOUCH_DEVICE="device name from above"'
    echo "  # or: CAPTUREOS_TOUCH_DEVICE_ID=8"
    echo '  # Wayland/labwc: CAPTUREOS_TOUCH_LIBINPUT="libinput device name"'
}
