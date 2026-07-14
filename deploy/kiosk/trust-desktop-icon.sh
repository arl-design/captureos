#!/usr/bin/env bash
# Mark the CaptureOS Desktop launcher as trusted so Pi OS / PCManFM launches
# it immediately on double-click (no "Execute / Open?" dialog).
# Installed to autostart and run once after install when a user session exists.

set -euo pipefail

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

HOME="${HOME:-$(getent passwd "$(id -un)" | cut -d: -f6)}"
DESKTOP_DIR="$(resolve_desktop_dir "$HOME")"
FILE="$DESKTOP_DIR/captureos.desktop"

[[ -f "$FILE" ]] || exit 0

chmod +x "$FILE" 2>/dev/null || true

if command -v gio >/dev/null 2>&1; then
    gio set "$FILE" metadata::trusted true 2>/dev/null || true
    if command -v sha256sum >/dev/null 2>&1; then
        gio set "$FILE" metadata::xfce-exe-checksum \
            "$(sha256sum "$FILE" | awk '{print $1}')" 2>/dev/null || true
    fi
fi
