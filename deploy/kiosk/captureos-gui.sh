#!/usr/bin/env bash
# GUI entry point for the desktop icon / app menu (sets DISPLAY for Pi OS).
export DISPLAY="${DISPLAY:-:0}"
export XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"
exec /usr/local/bin/captureos "$@"
