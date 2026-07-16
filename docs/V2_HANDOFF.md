# CaptureOS v2 Handoff

**Purpose:** Start a new repository for CaptureOS v2 while keeping v1 frozen as a working backup.  
**v1 repo:** [arl-design/captureos](https://github.com/arl-design/captureos)  
**v1 install path on Pi:** `/opt/captureos`  
**Last v1 commit at handoff:** `66cc864` — *Fix dual-screen: hybrid ozone (gallery XWayland, booth Wayland)*  
**Handoff date:** 2026-07-16

---

## 1. Why v2 exists

v1 is a **complete, shippable photo booth** (capture workflow, gallery, slideshow, admin, Pi installer, dual-display kiosk). It works end-to-end but accumulated **platform-specific complexity** around Raspberry Pi OS + labwc + dual Chromium windows + touch alignment. That layer is fragile, hard to test off-Pi, and tightly coupled to shell scripts.

**Keep v1 intact** as the fallback you can flash, `git pull`, and run for an event. **Start v2** to simplify the kiosk/display stack, reduce bash/shell surface area, and make dual-screen + touch reliable without fighting the compositor.

---

## 2. v1 freeze checklist (do this before v2 work)

On the v1 repo:

```bash
# Tag the last known-good release
git tag -a v1.0-handoff -m "CaptureOS v1 handoff — keep as backup"
git push origin v1.0-handoff

# Optional: create a v1 maintenance branch
git branch v1-maintenance
git push origin v1-maintenance
```

On the Pi (production booth):

```bash
cd ~/captureos
git fetch --tags
git checkout v1.0-handoff   # or stay on main at 66cc864+
sudo ./deploy/install.sh
```

**Do not delete** `/opt/captureos/data` when experimenting with v2 — photos, SQLite DB, and settings live there.

---

## 3. Reference hardware (v1 production)

| Role | Device | Notes |
|------|--------|-------|
| Compute | Raspberry Pi 5 (8 GB) | Pi OS 64-bit **Desktop**, labwc (Bookworm/Trixie) |
| Camera | Arducam IMX219 (CSI) | Fixed focus — no tap-to-focus; user adjusts lens ring |
| Booth display | QDtech MPI7003 1024×600 HDMI touchscreen | USB touch; was on HDMI-A-1 after cable swap |
| Gallery display | 1920×1080 HDMI TV | HDMI-A-2 |
| **Upcoming** | DSI touch panel (customer turn-in) | Different/smaller resolution — v1 auto-prefers DSI for booth |

**Important:** `HDMI-A-1` / `HDMI-A-2` are **physical Pi ports**, not logical “booth/TV” roles. v1 assigns by resolution (smallest → booth) or DSI presence, not port name.

---

## 4. What v1 does well (preserve in v2)

### Application stack (solid — carry forward)

| Layer | Tech | Status |
|-------|------|--------|
| Frontend | React + TypeScript + Vite, hash routing | ✅ Booth, gallery, slideshow, admin |
| Backend | Node 22+, Express, `node:sqlite` | ✅ API, SSE, settings, admin, backups |
| Camera | Python 3, Pillow, rpicam-still | ✅ Capture pipeline; dev camera for laptop dev |
| Deploy | nginx :80, systemd, `/opt/captureos` | ✅ One-shot install + autostart |

### Features complete in v1

- Capture workflow: preview → countdown → capture → accept/retake
- Live gallery via SSE (`photo.accepted`, `photo.removed`)
- Slideshow mode with Ken Burns, new-photo interrupt
- Admin UI (`/#/admin`, default PIN **1234**)
- SQLite settings, photo lifecycle (pending → accepted)
- Synthetic dev camera for development without Pi hardware

See `docs/ARCHITECTURE.md` for design rationale.

### API surface (stable contract for v2)

Public: `/health`, `/preview`, `/capture`, `/accept`, `/retake`, `/gallery`, `/latest`, `/settings`, `/events`  
Admin: `/api/admin/*` (PIN auth, LAN-restricted in nginx)

Full route list in root `README.md`.

---

## 5. What v1 struggles with (v2 should fix)

### Dual-display kiosk (highest pain)

**Goal:** Gallery on wall TV, booth on touchscreen, both fullscreen, no browser chrome.

**What we tried (chronological):**

| Approach | Result |
|----------|--------|
| Chromium `--kiosk` | Fullscreen OK, but **both windows on one screen** (unmovable under labwc) |
| `--app` + labwc `windowRules` | Dual-screen sometimes works, tab bar hidden |
| `--window-position` + xdotool/wmctrl | Works for **XWayland** windows only |
| labwc `MoveToOutput` / `MoveTo` / `ToggleFullscreen` | Correct XML, but **unreliable for native Wayland Chromium** on Pi OS |
| Native Wayland (`--ozone-platform=wayland`) | **Touch alignment fixed** (critical) |
| Hybrid ozone (v1 latest) | **Gallery = x11**, **Booth = wayland** — intended fix; verify on hardware |

**Root cause:** Pi OS Chromium + labwc does not consistently honor window rules for native Wayland clients. xinput/CTM fixes **do not work** under XWayland. xdotool/wmctrl **cannot see** native Wayland windows.

### Touch input

- Correct fix: booth Chromium on **native Wayland** + labwc `<touch mapToOutput="…" mouseEmulation="no" />` in `~/.config/labwc/rc.xml`
- Wrong fix: `xinput map-to-output` / coordinate transformation matrix on XWayland (ignored)
- Stale USB port names (`USB 1-1` vs `USB 3-1`) caused touch mapping to revert — v1 purges stale entries

### Boot / autostart races

- Second monitor not ready at autostart → both windows on one screen until manual relaunch
- `flock` launcher lock prevents duplicate launches (autostart + desktop icon + labwc autostart)
- Logs: `~/.local/state/captureos/launcher.log`, `display-setup.log`

### Known benign log noise

- `--no-decommit-pooled-pages` unrecognized (Pi Chromium wrapper vs real binary path)
- `only 0 Wayland display(s) ready` from early autostart context
- GCM DEPRECATED_ENDPOINT from Chromium

---

## 6. v1 runtime layout

```
/opt/captureos/
├── camera-service/       # Python, port 5000
├── backend/              # Node, port 3000
├── frontend/dist/        # Static build served by nginx
├── captureos-launch.sh   # Main kiosk launcher
├── setup-displays.sh     # Boot-time display + touch setup
├── display-layout.sh     # xrandr/wlr-randr resolution logic
├── wayland-display.sh    # labwc rules, kanshi, wlr-randr
├── touch-input.sh        # labwc touch + xinput (X11 only)
├── window-position.sh    # xdotool/wmctrl placement
└── data/                 # RUNTIME — photos, DB, logs (not in git)
    ├── captureos.sqlite
    ├── photos/
    ├── thumbnails/
    └── logs/
```

Config overrides:

- `/etc/captureos/display.conf` — display assignment, touch device
- `~/.config/captureos/display.conf` — per-user override
- `~/.config/labwc/rc.xml` — touch mapping + window rules (auto-written by launcher)

---

## 7. v1 boot sequence

```
Power on
  → Pi OS desktop autologin (raspi-config B4)
  → ~/.config/autostart/captureos-00-display.desktop  → setup-displays.sh
  → ~/.config/autostart/captureos-autostart.desktop   → captureos-gui.sh → captureos-launch.sh
  → ~/.config/labwc/autostart                         → same (with flock lock)
  → systemd: captureos-camera + captureos-backend
  → captureos-launch.sh:
       1. Wait for /api/health
       2. Resolve display layout (booth vs gallery)
       3. Apply labwc window rules + kanshi
       4. Launch gallery (ozone=x11) then booth (ozone=wayland)
       5. xdotool placement for XWayland gallery
       6. Map touch to booth output
```

---

## 8. v1 launcher behavior (as of 66cc864)

### Chromium flags (both windows)

- **No `--kiosk`** — breaks dual-screen on labwc
- **`--app=URL`** — hides tab bar
- **`--class=CaptureOS-Booth`** / **`CaptureOS-Gallery`** — WM_CLASS / Wayland app_id
- Keyring skip: `--password-store=basic`, `--use-mock-keychain`

### Hybrid ozone (dual-head Wayland session)

| Window | Default platform | Placement |
|--------|------------------|-----------|
| Gallery | `x11` (XWayland) | xdotool + wmctrl + labwc rules |
| Booth | `wayland` | Cursor warp + labwc rules; touch works |

Overrides:

```bash
CAPTUREOS_OZONE_PLATFORM=wayland   # force both (legacy; touch OK, dual-screen bad)
CAPTUREOS_BOOTH_OZONE=wayland
CAPTUREOS_GALLERY_OZONE=x11
```

### Display auto-assign logic

1. DSI/DPI panel → booth (any resolution)
2. Else smallest panel → booth
3. Largest remaining → gallery
4. Extended desktop: gallery at `0,0`, booth to the right

Run `captureos-launch.sh --list-displays` and `--diagnose` on the Pi.

---

## 9. v1 operator cheat sheet

```bash
# Update v1 in place
cd ~/captureos && git pull && sudo ./deploy/install.sh

# Restart booth UI only
pkill -f captureos-profile
captureos

# Admin
# Browser: http://localhost/#/admin  PIN: 1234

# Exit kiosk windows
# Alt+F4  or  pkill -f captureos-profile

# Debug
captureos-launch.sh --diagnose
captureos-launch.sh --list-displays
captureos-launch.sh --list-inputs
tail -50 ~/.local/state/captureos/launcher.log
tail -50 ~/.local/state/captureos/display-setup.log
wlrctl toplevel list | grep -i capture
```

---

## 10. v1 frontend routes

| Hash route | Window title (for labwc rules) | Display |
|------------|----------------------------------|---------|
| `/#/` | CaptureOS Booth | Touchscreen |
| `/#/gallery` | CaptureOS Gallery | Wall TV |
| `/#/slideshow` | CaptureOS Gallery | Wall TV (slideshow) |
| `/#/admin` | CaptureOS Admin | Either (LAN admin) |

Title is set synchronously in `frontend/index.html` before React loads so labwc can match on first map.

---

## 11. Recommended v2 directions

Pick one primary strategy; avoid re-implementing all v1 shell hacks.

### Option A — Single compositor-native approach (preferred long-term)

- One display server contract: **Wayland only**
- Replace dual Chromium with:
  - **Electron/Tauri** multi-window app with explicit `screen` APIs, or
  - **One Chromium** + CSS “virtual dual UI” (only if same machine drives both via two fullscreen windows in one process), or
  - **Cage / labwc with a dedicated kiosk wrapper** that owns window placement in code (not rc.xml)
- Touch: libinput → compositor config, tested per target panel

### Option B — Split processes by display

- Booth: fullscreen webview on Wayland (touch)
- Gallery: separate lightweight client (could even be mpv + image poll, or second webview on X11)
- Keeps v1 hybrid idea but **explicitly documents** two different runtimes

### Option C — Hardware video out

- Pi dual HDMI: use **kms/DRM** to assign planes to connectors from a single app
- Heavy lift; only if v2 targets Pi exclusively

### What to copy verbatim into v2

| Copy | Rewrite |
|------|---------|
| `backend/` (API, SQLite, SSE) | Kiosk shell scripts |
| `camera-service/` + pipeline | `display-layout.sh`, `wayland-display.sh`, most of `captureos-launch.sh` |
| `frontend/` UI components & workflow | Hash routing (consider proper routes in v2) |
| nginx + systemd unit patterns | labwc rc.xml generation |
| `data/` schema & photo lifecycle | xdotool placement loops |

### v2 repo bootstrap suggestion

```bash
# New repo (example name)
git clone https://github.com/arl-design/captureos captureos-v1-backup
# Keep local copy; do not develop v2 in v1 repo

mkdir captureos-v2 && cd captureos-v2
git init

# Copy application core only
cp -r ../captureos-v1-backup/backend .
cp -r ../captureos-v1-backup/camera-service .
cp -r ../captureos-v1-backup/frontend .
cp -r ../captureos-v1-backup/deploy/nginx .
cp -r ../captureos-v1-backup/deploy/systemd .
cp ../captureos-v1-backup/LICENSE .

# Add fresh deploy/kiosk designed for v2
# Point README at v2 goals; link back to v1 tag for fallback
```

**Data compatibility:** v2 backend should read existing `/opt/captureos/data/captureos.sqlite` and photo dirs if schema unchanged.

---

## 12. v2 acceptance criteria (suggested)

1. **Dual display:** After cold boot, gallery on wall + booth on touch with zero manual steps
2. **Touch:** Tap targets on booth accurate (Preview, shutter, Accept)
3. **No browser chrome** on either display
4. **Autostart:** Power → booth ready in &lt; 60 s (document target)
5. **DSI panel:** Customer turn-in monitor works without editing HDMI port names
6. **Fallback:** Document how to run v1 tag on same Pi if v2 fails before an event
7. **Dev mode:** Full stack runs on laptop without Pi (keep dev camera)

---

## 13. Open v1 issues (verify on hardware after 66cc864)

- [ ] Hybrid ozone actually splits gallery to TV after cold boot (not just manual relaunch)
- [ ] Customer DSI booth panel — auto-assign untested on real hardware
- [ ] Occasional PCManFM “Execute” prompt on desktop icon
- [ ] Preview latency — still one `rpicam-still` per frame (~Phase 2 picamera2 loop in ARCHITECTURE.md)
- [ ] IMX219 fixed focus — tap-to-focus UI shows message; lens ring is manual

---

## 14. Key v1 files reference

| File | Role |
|------|------|
| `deploy/kiosk/captureos-launch.sh` | Services + Chromium + placement |
| `deploy/kiosk/setup-displays.sh` | Login/boot display + touch |
| `deploy/kiosk/display-layout.sh` | Monitor detection & booth/gallery assign |
| `deploy/kiosk/wayland-display.sh` | wlr-randr, kanshi, labwc window rules |
| `deploy/kiosk/touch-input.sh` | labwc `<touch>` + xinput fallback |
| `deploy/kiosk/window-position.sh` | xdotool/wmctrl |
| `deploy/install.sh` | Pi installer → `/opt/captureos` |
| `deploy/bootstrap.sh` | curl \| bash one-liner entry |
| `frontend/index.html` | Early window title for labwc |
| `frontend/src/booth/Booth.tsx` | Touch UI, capture workflow |
| `frontend/src/App.tsx` | Hash routes + title updates |
| `camera-service/camera_service.py` | HTTP camera + MJPEG preview |
| `backend/src/server.js` | Express entry |
| `docs/ARCHITECTURE.md` | v1 architecture deep dive |

---

## 15. Contacts & context

- **Product:** LEGO MiniFigure Photo Booth (modular platform; LEGO is reference skin)
- **v1 GitHub:** `arl-design/captureos`
- **Install:** `bash deploy/bootstrap.sh` or `sudo deploy/install.sh`
- **Service user:** `captureos` (systemd); kiosk user is whoever ran `sudo ./deploy/install.sh`

---

## 16. One-paragraph summary for the v2 agent

CaptureOS v1 is a three-process photo booth (Python camera, Node API, React UI) installed to `/opt/captureos` on a Pi 5 with two HDMI displays. The app logic is stable; the pain is **kiosk mode**: two Chromium windows must open on different monitors with correct touch on the booth panel under **Pi OS Desktop + labwc + Wayland**. Do not use `--kiosk`. Booth needs **native Wayland** for touch; gallery placement works via **XWayland + xdotool**. labwc window rules alone are insufficient. v2 should preserve the backend/camera/frontend core and replace the bash/labwc/Chromium placement layer with something testable and explicit. Freeze v1 at tag `v1.0-handoff` before starting v2 in a new repo.
