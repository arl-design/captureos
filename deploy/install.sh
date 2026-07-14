#!/usr/bin/env bash
# CaptureOS installer for Raspberry Pi OS (Lite or Desktop).
# Run as root from the repo checkout:  sudo captureos/deploy/install.sh
#
# Installs to /opt/captureos, sets up nginx + systemd services, and
# creates the dedicated `captureos` service user.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR=/opt/captureos

if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo $0" >&2
    exit 1
fi

echo "==> Installing OS packages"
apt-get update -qq
# Note: do NOT request the standalone `npm` package here. The NodeSource
# nodejs package (22.x, required below for node:sqlite) bundles npm and
# declares `Conflicts: npm`, so asking for both makes apt unsolvable.
apt-get install -y -qq nginx nodejs python3-pil rpicam-apps-lite \
    chromium-browser 2>/dev/null ||
    apt-get install -y -qq nginx nodejs python3-pil chromium

# Ensure npm is available. NodeSource's nodejs bundles it; a distro nodejs
# may not, in which case the standalone package is safe to install (no
# NodeSource nodejs is present to conflict with).
command -v npm >/dev/null 2>&1 || apt-get install -y -qq npm

NODE_MAJOR=$(node -e 'console.log(process.versions.node.split(".")[0])')
if (( NODE_MAJOR < 22 )); then
    echo "!! Node $NODE_MAJOR found; CaptureOS needs >= 22.5 (node:sqlite)." >&2
    echo "   Install NodeSource 22.x, then re-run." >&2
    exit 1
fi

echo "==> Creating service user and directories"
id captureos &>/dev/null || useradd --system --create-home captureos
mkdir -p "$APP_DIR" "$APP_DIR/data/photos" "$APP_DIR/data/thumbnails"

echo "==> Copying application"
cp -r "$REPO_DIR/camera-service" "$REPO_DIR/backend" "$APP_DIR/"

echo "==> Installing backend dependencies"
(cd "$APP_DIR/backend" && npm install --omit=dev --silent)

echo "==> Building frontend"
(cd "$REPO_DIR/frontend" && npm install --silent && npm run build)
mkdir -p "$APP_DIR/frontend"
cp -r "$REPO_DIR/frontend/dist" "$APP_DIR/frontend/"

chown -R captureos:captureos "$APP_DIR/data"

echo "==> Installing launcher, icon, and desktop entry"
install -m 755 "$REPO_DIR/deploy/kiosk/captureos-launch.sh" "$APP_DIR/captureos-launch.sh"
install -m 644 "$REPO_DIR/deploy/desktop/captureos-icon.png" "$APP_DIR/captureos-icon.png"
install -m 644 "$REPO_DIR/deploy/desktop/captureos.desktop" \
    /usr/share/applications/captureos.desktop

# Give the invoking user a double-tap Desktop icon and boot autostart.
KIOSK_USER="${SUDO_USER:-}"
if [[ -n "$KIOSK_USER" ]]; then
    KIOSK_HOME="$(getent passwd "$KIOSK_USER" | cut -d: -f6)"
    if [[ -d "$KIOSK_HOME" ]]; then
        install -o "$KIOSK_USER" -g "$KIOSK_USER" -m 755 -d \
            "$KIOSK_HOME/Desktop" "$KIOSK_HOME/.config/autostart"
        install -o "$KIOSK_USER" -g "$KIOSK_USER" -m 755 \
            "$REPO_DIR/deploy/desktop/captureos.desktop" \
            "$KIOSK_HOME/Desktop/captureos.desktop"
        install -o "$KIOSK_USER" -g "$KIOSK_USER" -m 644 \
            "$REPO_DIR/deploy/desktop/captureos.desktop" \
            "$KIOSK_HOME/.config/autostart/captureos.desktop"
    fi
fi

echo "==> Configuring nginx"
cp "$REPO_DIR/deploy/nginx/captureos.conf" /etc/nginx/sites-available/captureos
ln -sf /etc/nginx/sites-available/captureos /etc/nginx/sites-enabled/captureos
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

echo "==> Installing systemd services"
cp "$REPO_DIR"/deploy/systemd/*.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now captureos-camera captureos-backend

echo
echo "CaptureOS installed."
echo "  Booth UI:   http://localhost/#/"
echo "  Gallery:    http://localhost/#/gallery"
echo "  API health: http://localhost/api/health"
echo
echo "Tap the 'CaptureOS Photo Booth' icon on the Desktop to launch the"
echo "kiosk (it also autostarts on boot via ~/.config/autostart)."
