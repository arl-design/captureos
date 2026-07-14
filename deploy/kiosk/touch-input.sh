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


changed = False
existing = None
for touch in list(root):
    if touch.tag.split("}", 1)[-1] != "touch":
        continue
    if attr(touch, "deviceName") == device:
        if existing is None:
            existing = touch
        else:
            root.remove(touch)  # duplicate entry
            changed = True

if existing is None:
    existing = ET.SubElement(root, f"{ns}touch")
    existing.set("deviceName", device)
    changed = True

if attr(existing, "mapToOutput") != map_output:
    existing.set("mapToOutput", map_output)
    changed = True
if attr(existing, "mouseEmulation") != emulation:
    # Also corrects entries an older CaptureOS wrote with emulation on.
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

    local mapped=0

    if declare -F captureos_is_wayland_session >/dev/null 2>&1 \
        && captureos_is_wayland_session \
        && declare -F captureos_apply_labwc_touch >/dev/null 2>&1; then
        captureos_apply_labwc_touch "$output" "${CAPTUREOS_TOUCH_LIBINPUT:-}" && mapped=1
    fi

    if command -v xinput >/dev/null 2>&1; then
        local xoutput="$output"
        if declare -F captureos_to_xrandr_output >/dev/null 2>&1; then
            xoutput="$(captureos_to_xrandr_output "$output")"
        fi
        if xrandr --query 2>/dev/null | grep -q "^${xoutput} connected"; then
            local id name
            if [[ -n "${CAPTUREOS_TOUCH_DEVICE_ID:-}" ]]; then
                if xinput map-to-output "$CAPTUREOS_TOUCH_DEVICE_ID" "$xoutput" 2>/dev/null; then
                    echo "CaptureOS: mapped touch id ${CAPTUREOS_TOUCH_DEVICE_ID} -> ${xoutput}"
                    mapped=1
                fi
            elif [[ -n "${CAPTUREOS_TOUCH_DEVICE:-}" ]]; then
                if xinput map-to-output "$CAPTUREOS_TOUCH_DEVICE" "$xoutput" 2>/dev/null; then
                    echo "CaptureOS: mapped touch '${CAPTUREOS_TOUCH_DEVICE}' -> ${xoutput}"
                    mapped=1
                fi
            else
                while IFS=$'\t' read -r id name; do
                    [[ -n "$id" ]] || continue
                    if xinput map-to-output "$id" "$xoutput" 2>/dev/null; then
                        echo "CaptureOS: mapped touch '${name}' (id ${id}) -> ${xoutput}"
                        mapped=1
                    fi
                done < <(captureos_list_touch_devices)
            fi
        fi
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
