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
    xinput x11-xserver-utils xdotool \
    chromium-browser 2>/dev/null ||
    apt-get install -y -qq nginx nodejs python3-pil xinput x11-xserver-utils xdotool chromium

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
install -m 755 "$REPO_DIR/deploy/kiosk/captureos-gui.sh" "$APP_DIR/captureos-gui.sh"
install -m 644 "$REPO_DIR/deploy/kiosk/display-layout.sh" "$APP_DIR/display-layout.sh"
install -m 755 "$REPO_DIR/deploy/kiosk/trust-desktop-icon.sh" "$APP_DIR/trust-desktop-icon.sh"
install -m 755 "$REPO_DIR/deploy/kiosk/map-touch-input.sh" "$APP_DIR/map-touch-input.sh"
install -m 644 "$REPO_DIR/deploy/kiosk/touch-input.sh" "$APP_DIR/touch-input.sh"
install -m 644 "$REPO_DIR/deploy/kiosk/window-position.sh" "$APP_DIR/window-position.sh"
install -m 644 "$REPO_DIR/deploy/desktop/captureos-icon.png" "$APP_DIR/captureos-icon.png"
install -m 644 "$REPO_DIR/deploy/desktop/captureos.desktop" \
    /usr/share/applications/captureos.desktop
install -d -m 755 /etc/captureos
if [[ ! -f /etc/captureos/display.conf ]]; then
    install -m 644 "$REPO_DIR/deploy/kiosk/display.conf.example" \
        /etc/captureos/display.conf
fi

echo "==> Allowing passwordless service control for the kiosk user"
install -d -m 755 /etc/polkit-1/rules.d
install -m 644 "$REPO_DIR/deploy/polkit/50-captureos-systemd.rules" \
    /etc/polkit-1/rules.d/50-captureos-systemd.rules

# A terminal command that always works, even if a Desktop icon doesn't show
# (headless/Lite, renamed Desktop folder, or a file manager that refuses
# untrusted launchers). Users can just run `captureos`.
ln -sf "$APP_DIR/captureos-launch.sh" /usr/local/bin/captureos

# Refresh the application menu so "CaptureOS Photo Booth" appears there.
command -v update-desktop-database >/dev/null 2>&1 \
    && update-desktop-database /usr/share/applications 2>/dev/null || true

# Give the invoking user a double-tap Desktop icon and boot autostart.
KIOSK_USER="${SUDO_USER:-}"
if [[ -n "$KIOSK_USER" ]]; then
    KIOSK_HOME="$(getent passwd "$KIOSK_USER" | cut -d: -f6)"
    if [[ -d "$KIOSK_HOME" ]]; then
        # Desktop folder can be localised (XDG_DESKTOP_DIR); resolve it as the
        # kiosk user so $HOME expands correctly, falling back to ~/Desktop,
        # which the installer creates if missing.
        DESKTOP_DIR="$(sudo -u "$KIOSK_USER" sh -c \
            '. "$HOME/.config/user-dirs.dirs" 2>/dev/null; \
             printf %s "${XDG_DESKTOP_DIR:-$HOME/Desktop}"')"
        [[ -n "$DESKTOP_DIR" ]] || DESKTOP_DIR="$KIOSK_HOME/Desktop"

        install -o "$KIOSK_USER" -g "$KIOSK_USER" -m 755 -d \
            "$DESKTOP_DIR" "$KIOSK_HOME/.config/autostart"
        # -C keeps the Desktop file (and its trusted metadata) when unchanged.
        install -C -o "$KIOSK_USER" -g "$KIOSK_USER" -m 755 \
            "$REPO_DIR/deploy/desktop/captureos.desktop" \
            "$DESKTOP_DIR/captureos.desktop"
        # Boot straight into the booth: dedicated autostart entry (hidden
        # from menus) that runs the launcher on login.
        install -o "$KIOSK_USER" -g "$KIOSK_USER" -m 644 \
            "$REPO_DIR/deploy/desktop/captureos-autostart.desktop" \
            "$KIOSK_HOME/.config/autostart/captureos-autostart.desktop"
        # Remove the older reused app entry if a previous install left one.
        rm -f "$KIOSK_HOME/.config/autostart/captureos.desktop"
        install -C -o "$KIOSK_USER" -g "$KIOSK_USER" -m 644 \
            "$REPO_DIR/deploy/desktop/captureos-trust.desktop" \
            "$KIOSK_HOME/.config/autostart/captureos-trust.desktop"
        install -C -o "$KIOSK_USER" -g "$KIOSK_USER" -m 644 \
            "$REPO_DIR/deploy/desktop/captureos-touch.desktop" \
            "$KIOSK_HOME/.config/autostart/captureos-touch.desktop"

        # Mark the Desktop icon trusted (needs the user's D-Bus session).
        KIOSK_UID="$(id -u "$KIOSK_USER")"
        if ! sudo -u "$KIOSK_USER" \
            XDG_RUNTIME_DIR="/run/user/${KIOSK_UID}" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${KIOSK_UID}/bus" \
            "$APP_DIR/trust-desktop-icon.sh"; then
            echo "   (trust will retry at next login — or run on the Pi desktop:"
            echo "    /opt/captureos/trust-desktop-icon.sh)"
        fi
    fi
fi

echo "==> Enabling boot straight into the booth (desktop auto-login)"
# Boot to the graphical desktop and auto-login the kiosk user so the
# autostart entry launches CaptureOS with no keyboard/login step. Set
# CAPTUREOS_NO_AUTOLOGIN=1 before running to skip this.
if [[ "${CAPTUREOS_NO_AUTOLOGIN:-0}" == "1" ]]; then
    echo "   Skipped (CAPTUREOS_NO_AUTOLOGIN=1)."
elif [[ -z "$KIOSK_USER" ]]; then
    echo "   No target user (run via sudo as the kiosk user) — skipped."
elif command -v raspi-config >/dev/null 2>&1; then
    # B4 = boot to Desktop with autologin, for the primary user.
    if raspi-config nonint do_boot_behaviour B4 2>/dev/null; then
        echo "   Desktop auto-login enabled for the primary user."
    else
        echo "   Could not set it automatically. Run:"
        echo "     sudo raspi-config  ->  System Options  ->  Boot / Auto Login"
        echo "     ->  Desktop Autologin"
    fi
else
    # Fallback for non-raspi-config systems using LightDM.
    if [[ -d /etc/lightdm ]]; then
        install -d -m 755 /etc/lightdm/lightdm.conf.d
        cat >/etc/lightdm/lightdm.conf.d/60-captureos-autologin.conf <<EOF
[Seat:*]
autologin-user=$KIOSK_USER
autologin-user-timeout=0
EOF
        systemctl set-default graphical.target 2>/dev/null || true
        echo "   LightDM auto-login configured for '$KIOSK_USER'."
    else
        echo "   raspi-config and LightDM not found — enable desktop autologin"
        echo "   manually so the booth starts without logging in."
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
echo "The Pi now boots straight into the photo booth (desktop auto-login +"
echo "autostart). Reboot to try it:  sudo reboot"
echo
echo "You can also launch it manually with any of:"
echo "  * the 'CaptureOS Photo Booth' icon on the Desktop"
echo "  * the 'CaptureOS Photo Booth' entry in the application menu"
echo "  * the 'captureos' command in a terminal"
echo
echo "The desktop icon should launch with one tap (no Execute/Open dialog)."
echo "If it still prompts, on the Pi desktop run:"
echo "  /opt/captureos/trust-desktop-icon.sh"
echo "then right-click the icon -> Allow Launching (once)."
echo "Or use the app menu entry — it never prompts."
