#!/usr/bin/env bash
# Mark the CaptureOS Desktop launcher as trusted so Pi OS / PCManFM launches
# it on double-click without an Execute / Open dialog.
# Runs at login (autostart) and after install.

set -euo pipefail

LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/captureos"
LOG_FILE="$LOG_DIR/trust-desktop.log"
WAIT_SEC=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --wait) WAIT_SEC="${2:-15}"; shift 2 ;;
        *) shift ;;
    esac
done

log() {
    mkdir -p "$LOG_DIR"
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"
}

resolve_desktop_dir() {
    local home="$1"
    if [[ -r "$home/.config/user-dirs.dirs" ]]; then
        # shellcheck disable=SC1091
        . "$home/.config/user-dirs.dirs" 2>/dev/null || true
        if [[ -n "${XDG_DESKTOP_DIR:-}" ]]; then
            eval echo "$XDG_DESKTOP_DIR"
            return
        fi
    fi
    echo "$home/Desktop"
}

file_uri() {
    local path="$1"
    python3 -c 'import pathlib, sys, urllib.parse; print(pathlib.Path(sys.argv[1]).resolve().as_uri())' "$path" 2>/dev/null \
        || printf 'file://%s' "$(readlink -f "$path" | sed 's/ /%20/g')"
}

trust_desktop_file() {
    local file="$1"
    local uri trusted="" checksum=""

    chmod +x "$file" 2>/dev/null || true

    if ! command -v gio >/dev/null 2>&1; then
        log "gio missing — cannot mark $file trusted"
        return 1
    fi

    uri="$(file_uri "$file")"

    if command -v sha256sum >/dev/null 2>&1; then
        checksum="$(sha256sum "$file" | awk '{print $1}')"
        # PCManFM on Pi OS: set checksum BEFORE trusted.
        gio set "$uri" metadata::xfce-exe-checksum "$checksum" 2>/dev/null \
            || gio set "$file" metadata::xfce-exe-checksum "$checksum" 2>/dev/null \
            || true
    fi

    gio set "$uri" metadata::trusted true 2>/dev/null \
        || gio set "$file" metadata::trusted true 2>/dev/null \
        || gio set "$uri" metadata::trusted yes 2>/dev/null \
        || true

    trusted="$(gio info -a metadata::trusted "$uri" 2>/dev/null | awk -F= '/metadata::trusted/ {print $2}' | tr -d " '")"
    if [[ "$trusted" == "true" || "$trusted" == "yes" ]]; then
        log "trusted $file"
        return 0
    fi

    log "could not verify trust on $file (gio metadata::trusted=${trusted:-unset})"
    return 1
}

# PCManFM "Execute file?" dialog: quick_exec=1 launches executables and
# launchers directly instead of asking Execute / Open every time.
enable_quick_exec() {
    local conf_dir="${XDG_CONFIG_HOME:-$HOME/.config}/libfm"
    local conf="$conf_dir/libfm.conf"
    mkdir -p "$conf_dir"
    if [[ ! -f "$conf" ]]; then
        printf '[config]\nquick_exec=1\n' >"$conf"
        log "created $conf with quick_exec=1"
    elif grep -q '^quick_exec=' "$conf"; then
        if ! grep -q '^quick_exec=1' "$conf"; then
            sed -i 's/^quick_exec=.*/quick_exec=1/' "$conf"
            log "set quick_exec=1 in $conf"
        fi
    elif grep -q '^\[config\]' "$conf"; then
        sed -i '/^\[config\]/a quick_exec=1' "$conf"
        log "added quick_exec=1 to $conf"
    else
        printf '\n[config]\nquick_exec=1\n' >>"$conf"
        log "appended [config] quick_exec=1 to $conf"
    fi
    # Desktop is drawn by pcmanfm; ask it to reload so the change is live.
    command -v pcmanfm >/dev/null 2>&1 && pcmanfm --reconfigure 2>/dev/null || true
}

HOME="${HOME:-$(getent passwd "$(id -un)" | cut -d: -f6)}"
DESKTOP_DIR="$(resolve_desktop_dir "$HOME")"
FILE="$DESKTOP_DIR/captureos.desktop"

enable_quick_exec || true

if (( WAIT_SEC > 0 )); then
    log "waiting up to ${WAIT_SEC}s for $FILE"
    for _ in $(seq 1 "$WAIT_SEC"); do
        [[ -f "$FILE" ]] && break
        sleep 1
    done
fi

[[ -f "$FILE" ]] || {
    log "no desktop file at $FILE — skipped"
    exit 0
}

trust_desktop_file "$FILE" || true
