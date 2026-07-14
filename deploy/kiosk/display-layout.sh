# CaptureOS multi-monitor layout helper.
# Sourced by captureos-launch.sh. Resolves which physical display gets the
# booth UI (touchscreen) and which gets the gallery (wall display).
#
# Override via /etc/captureos/display.conf, ~/.config/captureos/display.conf,
# or environment variables (env wins).
#
#   CAPTUREOS_BOOTH_OUTPUT=HDMI-2
#   CAPTUREOS_GALLERY_OUTPUT=HDMI-1
#
# Or explicit pixel geometry (x,y,width,height):
#
#   CAPTUREOS_BOOTH_GEOM=1920,0,1024,600
#   CAPTUREOS_GALLERY_GEOM=0,0,1920,1080
#
# Run `captureos-launch.sh --list-displays` to see detected outputs.

captureos_load_display_config() {
    local f
    for f in /etc/captureos/display.conf \
             "${XDG_CONFIG_HOME:-$HOME/.config}/captureos/display.conf"; do
        [[ -r "$f" ]] || continue
        # shellcheck disable=SC1090
        . "$f"
    done
}

# Parse "1920x1080+0+0" -> sets reply vars: _w _h _x _y
captureos_parse_mode() {
    local mode="$1"
    _w="${mode%%x*}"
    local rest="${mode#*x}"
    _h="${rest%%+*}"
    rest="${rest#*+}"
    _x="${rest%%+*}"
    _y="${rest#*+}"
}

# Fill CAPTUREOS_DISPLAY_LINES with "name|w|h|x|y|primary" entries.
captureos_collect_xrandr_displays() {
    CAPTUREOS_DISPLAY_LINES=()
    command -v xrandr >/dev/null 2>&1 || return 1
    local line name primary mode w h x y
    while IFS= read -r line; do
        [[ "$line" == *" connected "* ]] || continue
        name="${line%% *}"
        primary=0
        [[ "$line" == *" connected primary "* ]] && primary=1
        mode="$(sed -n 's/.* connected \(primary \)\?\([0-9][0-9]*x[0-9][0-9]*+[0-9]*+[0-9]*\).*/\2/p' <<<"$line")"
        [[ -n "$mode" ]] || continue
        captureos_parse_mode "$mode"
        CAPTUREOS_DISPLAY_LINES+=("${name}|${_w}|${_h}|${_x}|${_y}|${primary}")
    done < <(xrandr --query 2>/dev/null)
    ((${#CAPTUREOS_DISPLAY_LINES[@]} > 0))
}

captureos_lookup_display() {
    local want="$1" entry name w h x y primary
    for entry in "${CAPTUREOS_DISPLAY_LINES[@]}"; do
        IFS='|' read -r name w h x y primary <<<"$entry"
        [[ "$name" == "$want" ]] || continue
        CAPTUREOS_RESOLVED_NAME="$name"
        CAPTUREOS_RESOLVED_W="$w"
        CAPTUREOS_RESOLVED_H="$h"
        CAPTUREOS_RESOLVED_X="$x"
        CAPTUREOS_RESOLVED_Y="$y"
        return 0
    done
    return 1
}

captureos_parse_geom() {
    local geom="$1" label="$2"
    IFS=',' read -r CAPTUREOS_RESOLVED_X CAPTUREOS_RESOLVED_Y \
        CAPTUREOS_RESOLVED_W CAPTUREOS_RESOLVED_H <<<"$geom"
    if [[ -z "${CAPTUREOS_RESOLVED_X:-}" || -z "${CAPTUREOS_RESOLVED_Y:-}" \
        || -z "${CAPTUREOS_RESOLVED_W:-}" || -z "${CAPTUREOS_RESOLVED_H:-}" ]]; then
        echo "CaptureOS: invalid ${label} geometry '$geom' (want x,y,width,height)" >&2
        return 1
    fi
}

# Heuristic: gallery on the main / wall display (primary if set, else largest),
# booth on the other panel (usually the 1024x600 touchscreen).
captureos_auto_assign_displays() {
    local entry name w h x y primary area best_booth="" best_gallery=""
    local primary_entry="" booth_area=999999999 gallery_area=0
    for entry in "${CAPTUREOS_DISPLAY_LINES[@]}"; do
        IFS='|' read -r name w h x y primary <<<"$entry"
        area=$((w * h))
        if [[ "$primary" == 1 ]]; then
            primary_entry="$entry"
        fi
        if (( area > gallery_area )); then
            gallery_area=$area
            best_gallery="$entry"
        fi
    done
    if [[ -n "$primary_entry" ]]; then
        best_gallery="$primary_entry"
    fi
    for entry in "${CAPTUREOS_DISPLAY_LINES[@]}"; do
        IFS='|' read -r name w h x y primary <<<"$entry"
        [[ "$entry" == "$best_gallery" ]] && continue
        area=$((w * h))
        if (( area < booth_area )); then
            booth_area=$area
            best_booth="$entry"
        fi
    done
    if [[ -z "$best_booth" ]]; then
        for entry in "${CAPTUREOS_DISPLAY_LINES[@]}"; do
            [[ "$entry" == "$best_gallery" ]] && continue
            best_booth="$entry"
            break
        done
    fi
    if [[ -z "$best_booth" ]]; then
        best_booth="$best_gallery"
    fi
    CAPTUREOS_AUTO_BOOTH="$best_booth"
    CAPTUREOS_AUTO_GALLERY="$best_gallery"
}

captureos_apply_display_entry() {
    local prefix="$1" entry name w h x y primary
    entry="$2"
    IFS='|' read -r name w h x y primary <<<"$entry"
    printf -v "CAPTUREOS_${prefix}_OUTPUT" '%s' "$name"
    printf -v "CAPTUREOS_${prefix}_X" '%s' "$x"
    printf -v "CAPTUREOS_${prefix}_Y" '%s' "$y"
    printf -v "CAPTUREOS_${prefix}_W" '%s' "$w"
    printf -v "CAPTUREOS_${prefix}_H" '%s' "$h"
}

# Sets CAPTUREOS_BOOTH_{X,Y,W,H,OUTPUT} and CAPTUREOS_GALLERY_{X,Y,W,H,OUTPUT}.
# Returns 0 on success, 1 if no layout could be resolved.
captureos_resolve_display_layout() {
    captureos_load_display_config

    if captureos_collect_xrandr_displays; then
        CAPTUREOS_DISPLAY_BACKEND=xrandr
    else
        CAPTUREOS_DISPLAY_BACKEND=none
        echo "CaptureOS: xrandr unavailable — using legacy TOUCH_WIDTH positioning" >&2
        CAPTUREOS_BOOTH_X=0
        CAPTUREOS_BOOTH_Y=0
        CAPTUREOS_BOOTH_W="${TOUCH_WIDTH:-1024}"
        CAPTUREOS_BOOTH_H="${TOUCH_HEIGHT:-600}"
        CAPTUREOS_GALLERY_X="${TOUCH_WIDTH:-1024}"
        CAPTUREOS_GALLERY_Y=0
        CAPTUREOS_GALLERY_W="${GALLERY_WIDTH:-1920}"
        CAPTUREOS_GALLERY_H="${GALLERY_HEIGHT:-1080}"
        return 0
    fi

    captureos_auto_assign_displays

    # --- booth -----------------------------------------------------------
    if [[ -n "${CAPTUREOS_BOOTH_GEOM:-}" ]]; then
        captureos_parse_geom "$CAPTUREOS_BOOTH_GEOM" "CAPTUREOS_BOOTH_GEOM"
        CAPTUREOS_BOOTH_X="$CAPTUREOS_RESOLVED_X"
        CAPTUREOS_BOOTH_Y="$CAPTUREOS_RESOLVED_Y"
        CAPTUREOS_BOOTH_W="$CAPTUREOS_RESOLVED_W"
        CAPTUREOS_BOOTH_H="$CAPTUREOS_RESOLVED_H"
        CAPTUREOS_BOOTH_OUTPUT="${CAPTUREOS_BOOTH_OUTPUT:-manual}"
    elif [[ -n "${CAPTUREOS_BOOTH_OUTPUT:-}" ]]; then
        captureos_lookup_display "$CAPTUREOS_BOOTH_OUTPUT" || {
            echo "CaptureOS: unknown booth output '$CAPTUREOS_BOOTH_OUTPUT'" >&2
            return 1
        }
        CAPTUREOS_BOOTH_OUTPUT="$CAPTUREOS_RESOLVED_NAME"
        CAPTUREOS_BOOTH_X="$CAPTUREOS_RESOLVED_X"
        CAPTUREOS_BOOTH_Y="$CAPTUREOS_RESOLVED_Y"
        CAPTUREOS_BOOTH_W="$CAPTUREOS_RESOLVED_W"
        CAPTUREOS_BOOTH_H="$CAPTUREOS_RESOLVED_H"
    else
        captureos_apply_display_entry BOOTH "$CAPTUREOS_AUTO_BOOTH"
    fi

    # --- gallery ---------------------------------------------------------
    if [[ -n "${CAPTUREOS_GALLERY_GEOM:-}" ]]; then
        captureos_parse_geom "$CAPTUREOS_GALLERY_GEOM" "CAPTUREOS_GALLERY_GEOM"
        CAPTUREOS_GALLERY_X="$CAPTUREOS_RESOLVED_X"
        CAPTUREOS_GALLERY_Y="$CAPTUREOS_RESOLVED_Y"
        CAPTUREOS_GALLERY_W="$CAPTUREOS_RESOLVED_W"
        CAPTUREOS_GALLERY_H="$CAPTUREOS_RESOLVED_H"
        CAPTUREOS_GALLERY_OUTPUT="${CAPTUREOS_GALLERY_OUTPUT:-manual}"
    elif [[ -n "${CAPTUREOS_GALLERY_OUTPUT:-}" ]]; then
        captureos_lookup_display "$CAPTUREOS_GALLERY_OUTPUT" || {
            echo "CaptureOS: unknown gallery output '$CAPTUREOS_GALLERY_OUTPUT'" >&2
            return 1
        }
        CAPTUREOS_GALLERY_OUTPUT="$CAPTUREOS_RESOLVED_NAME"
        CAPTUREOS_GALLERY_X="$CAPTUREOS_RESOLVED_X"
        CAPTUREOS_GALLERY_Y="$CAPTUREOS_RESOLVED_Y"
        CAPTUREOS_GALLERY_W="$CAPTUREOS_RESOLVED_W"
        CAPTUREOS_GALLERY_H="$CAPTUREOS_RESOLVED_H"
    else
        captureos_apply_display_entry GALLERY "$CAPTUREOS_AUTO_GALLERY"
    fi

    return 0
}

captureos_print_displays() {
    captureos_load_display_config
    if ! captureos_collect_xrandr_displays; then
        echo "No xrandr displays found (is a graphical session running?)"
        return 1
    fi
    captureos_auto_assign_displays
    echo "Connected displays (via xrandr):"
    local entry name w h x y primary
    for entry in "${CAPTUREOS_DISPLAY_LINES[@]}"; do
        IFS='|' read -r name w h x y primary <<<"$entry"
        printf '  %-12s %4dx%-4d at +%-5s+%-5s%s\n' \
            "$name" "$w" "$h" "$x" "$y" "$([[ "$primary" == 1 ]] && echo ' [primary]' || true)"
    done
    echo
    IFS='|' read -r _ bw bh bx by _ <<<"$CAPTUREOS_AUTO_BOOTH"
    IFS='|' read -r _ gw gh gx gy _ <<<"$CAPTUREOS_AUTO_GALLERY"
    echo "Auto-assignment (primary/largest -> gallery, other -> booth):"
    echo "  Booth:   ${CAPTUREOS_AUTO_BOOTH%%|*}  ->  ${bx},${by} ${bw}x${bh}"
    echo "  Gallery: ${CAPTUREOS_AUTO_GALLERY%%|*}  ->  ${gx},${gy} ${gw}x${gh}"
    echo
    echo "To override, create ~/.config/captureos/display.conf:"
    echo "  CAPTUREOS_BOOTH_OUTPUT=${CAPTUREOS_AUTO_BOOTH%%|*}"
    echo "  CAPTUREOS_GALLERY_OUTPUT=${CAPTUREOS_AUTO_GALLERY%%|*}"
}
