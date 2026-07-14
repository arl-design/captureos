#!/usr/bin/env bash
# CaptureOS bootstrap — takes a FRESH Raspberry Pi OS install all the way
# to a running booth in one command. It installs the prerequisites that
# install.sh assumes (a recent Node, git), fetches the code if needed, then
# runs the full installer.
#
# Run as your NORMAL user (not root) so the desktop icon lands on your
# Desktop. It calls sudo itself for the steps that need root.
#
#   From a checkout:
#     ./deploy/bootstrap.sh
#
#   Standalone one-liner (clones the repo for you):
#     bash <(curl -fsSL https://raw.githubusercontent.com/arl-design/captureos/main/deploy/bootstrap.sh)
#
# Overridable via environment:
#   CAPTUREOS_REPO    git URL to clone if not run from a checkout
#   CAPTUREOS_BRANCH  branch to use (default: main)
#   CAPTUREOS_SRC     where to clone (default: ~/captureos)

set -euo pipefail

REPO_URL="${CAPTUREOS_REPO:-https://github.com/arl-design/captureos.git}"
REPO_BRANCH="${CAPTUREOS_BRANCH:-main}"
CLONE_DIR="${CAPTUREOS_SRC:-$HOME/captureos}"
NODE_MAJOR=22

say() { printf '\n\033[1;33m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] && die "Run as your normal user, not root (it uses sudo itself).
   e.g.  ./captureos/deploy/bootstrap.sh"

command -v sudo >/dev/null 2>&1 || die "sudo is required."

# --- 1. base tools -------------------------------------------------------

say "Updating package lists"
sudo apt-get update -qq

say "Installing base tools (git, curl)"
sudo apt-get install -y -qq git curl ca-certificates

# --- 2. Node >= 22.5 (for node:sqlite) -----------------------------------

# The real requirement is that `node:sqlite` loads; test that directly
# rather than parsing versions.
if node -e 'require("node:sqlite")' >/dev/null 2>&1; then
    say "Node $(node --version) already supports node:sqlite — keeping it"
else
    say "Installing Node ${NODE_MAJOR}.x from NodeSource"
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
    sudo apt-get install -y nodejs
    node -e 'require("node:sqlite")' >/dev/null 2>&1 \
        || die "Node still can't load node:sqlite after install ($(node --version))."
    say "Node $(node --version) installed"
fi

# --- 3. locate or fetch the source --------------------------------------

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"
if [[ -n "$SELF" && -f "$(dirname "$SELF")/install.sh" ]]; then
    SRC_DIR="$(readlink -f "$(dirname "$SELF")/..")"   # repo root (deploy/..)
    say "Using this checkout: $SRC_DIR"
else
    if [[ -d "$CLONE_DIR/.git" ]]; then
        say "Updating existing checkout at $CLONE_DIR"
        git -C "$CLONE_DIR" fetch --quiet origin "$REPO_BRANCH"
        git -C "$CLONE_DIR" checkout --quiet "$REPO_BRANCH"
        git -C "$CLONE_DIR" pull --ff-only --quiet origin "$REPO_BRANCH"
    else
        say "Cloning $REPO_URL ($REPO_BRANCH) into $CLONE_DIR"
        git clone --branch "$REPO_BRANCH" "$REPO_URL" "$CLONE_DIR"
    fi
    SRC_DIR="$CLONE_DIR"
fi

INSTALLER="$SRC_DIR/deploy/install.sh"
[[ -f "$INSTALLER" ]] || die "installer not found at $INSTALLER"

# --- 4. camera sanity check (non-fatal) ---------------------------------

if command -v rpicam-hello >/dev/null 2>&1; then
    if rpicam-hello --list-cameras 2>/dev/null | grep -qi 'Available cameras\|imx\|ov'; then
        say "Camera detected"
    else
        printf '\033[1;33m   (no camera detected yet — CaptureOS will run in dev mode until one is)\033[0m\n'
    fi
fi

# --- 5. run the installer (needs root; keeps SUDO_USER = you) ------------

say "Running the CaptureOS installer"
sudo "$INSTALLER"

say "Bootstrap complete — tap the 'CaptureOS Photo Booth' desktop icon to start."
