# CaptureOS v2 Handoff — Design Refresh Fork

**Scope:** v2 is a **full copy of v1’s working code**. Same backend, camera, deploy, kiosk scripts, and behavior. **Only the design language changes** (visual identity, typography, colors, layout polish, icons).

**v1 repo (backup — do not delete):** [arl-design/captureos](https://github.com/arl-design/captureos)  
**v1 install path on Pi:** `/opt/captureos`  
**Snapshot to copy from:** tag `v1.0-handoff` (or `main` at handoff commit `5dc3458+`)  
**Handoff date:** 2026-07-16

---

## 1. What v2 is / isn’t

| v2 **is** | v2 **is not** |
|-----------|----------------|
| Fork of final working v1 | Rewrite of backend, camera, or kiosk stack |
| New repo + new visual design | API or workflow changes (unless design forces it) |
| Same Pi install flow (`deploy/install.sh`) | Breaking `/opt/captureos/data` compatibility |
| Same dual-screen + touch behavior | New display/touch debugging |

**Keep v1 frozen** as the event fallback. If v2 design work breaks something, `git checkout v1.0-handoff` on the Pi and reinstall.

---

## 2. v1 freeze (do once)

```bash
# In arl-design/captureos (v1)
git tag -a v1.0-handoff -m "CaptureOS v1 — working backup before design v2"
git push origin v1.0-handoff
git branch v1-maintenance && git push origin v1-maintenance   # optional
```

On the Pi (lock production to v1 until v2 is ready):

```bash
cd ~/captureos && git fetch --tags && git checkout v1.0-handoff
sudo ./deploy/install.sh
```

---

## 3. Create the v2 repo (copy everything)

```bash
# Clone the frozen v1 snapshot
git clone --branch v1.0-handoff https://github.com/arl-design/captureos.git captureos-v2
cd captureos-v2

# New remote (example)
git remote rename origin v1-upstream
git remote add origin https://github.com/arl-design/captureos-v2.git
git push -u origin HEAD:main
```

Or GitHub: **Use this template / Duplicate repository** from `captureos` at tag `v1.0-handoff`.

**Copy the whole tree** — do not strip `deploy/`, `backend/`, or `camera-service/`. v2 installs the same way:

```bash
sudo ./deploy/install.sh
# or: ./deploy/bootstrap.sh
```

**Data on Pi:** Reinstalling v2 over v1 keeps `data/` (photos, SQLite, settings) if you don’t wipe `/opt/captureos/data`.

---

## 4. What to change for v2 (design only)

### Primary files (start here)

| File | What it controls |
|------|------------------|
| **`frontend/src/styles.css`** | Entire design system — CSS variables (`:root`), booth, gallery, slideshow, admin |
| **`frontend/src/lib/meta.ts`** | App name, tagline, version string |
| **`frontend/src/components/Icons.tsx`** | Inline SVG icons (stroke/fill colors use `--icon-contrast`) |
| **`frontend/index.html`** | `<title>`, viewport, early window titles for labwc |

### v1 design tokens (replace these)

```css
/* frontend/src/styles.css :root — current v1 “black & yellow” */
--yellow: #ffd400;
--yellow-deep: #eab800;
--bg: #0a0a0c;
--panel: #141417;
--card: #1b1b1f;
--border: #2b2b31;
--text: #f5f5f7;
--muted: #9a9aa2;
--green: #2ecc40;
--red: #e5484d;
```

### Component files (structure stays; class names / copy may change)

| File | UI surface |
|------|------------|
| `frontend/src/booth/Booth.tsx` | Touch booth — top bar, preview, shutter, accept/retake, nav |
| `frontend/src/gallery/Gallery.tsx` | Wall grid + header |
| `frontend/src/gallery/Slideshow.tsx` | Full-screen slideshow, Ken Burns, new-photo banner |
| `frontend/src/admin/Admin.tsx` | PIN login, settings, diagnostics, photos, backups |
| `frontend/src/App.tsx` | Hash routes only — rarely needs design edits |

### Branding strings

```ts
// frontend/src/lib/meta.ts
export const APP_NAME = 'CaptureOS';
export const APP_TAGLINE = 'LEGO MiniFigure Booth';
export const APP_VERSION = 'captureOS v0.1.0-prototype';
```

Update for v2 product name / event branding. Window titles derive from `APP_NAME` and routes (`CaptureOS Booth`, `CaptureOS Gallery`) — **keep that pattern** so dual-screen labwc rules keep working.

### Assets

| Path | Notes |
|------|-------|
| `deploy/desktop/captureos-icon.png` | Desktop / menu icon |
| `docs/screenshot-*.png` | README only |

### Do **not** change (unless you know why)

- `deploy/kiosk/*` — dual-screen, touch, Chromium launch (fragile but working)
- `backend/`, `camera-service/` — API and capture pipeline
- Hash routes: `/#/`, `/#/gallery`, `/#/slideshow`, `/#/admin`
- Window title prefixes: `CaptureOS Booth*`, `CaptureOS Gallery*` (labwc + launcher)
- `frontend/index.html` synchronous title script (before React load)

---

## 5. Design workflow

```bash
# Local dev (no Pi)
cd camera-service && python3 camera_service.py &
cd backend && npm install && npm run dev &
cd frontend && npm install && npm run dev
# Booth: http://localhost:5173/#/
# Gallery: http://localhost:5173/#/gallery
```

After CSS/component changes:

```bash
cd frontend && npm run build
sudo ./deploy/install.sh   # on Pi, or copy dist/ to /opt/captureos/frontend/dist
```

**Test on real hardware:** dual display + touch — design changes shouldn’t touch kiosk scripts, but verify after any `index.html` or meta/title changes.

---

## 6. v1 stack reference (unchanged in v2)

Same architecture as v1 — see `docs/ARCHITECTURE.md`.

```
nginx :80 → frontend static + /api → backend :3000 → camera-service :5000
Chromium ×2: booth (touch) + gallery (wall)
```

| Service | Directory |
|---------|-----------|
| Frontend | `frontend/` |
| Backend | `backend/` |
| Camera | `camera-service/` |
| Installer / kiosk | `deploy/` |

---

## 7. Hardware (unchanged)

| Role | Device |
|------|--------|
| Pi 5, Pi OS 64-bit Desktop, labwc | |
| Arducam IMX219 (CSI) | Fixed focus — lens ring manual |
| Booth | 1024×600 HDMI touch (QDtech MPI7003) or future DSI panel |
| Gallery | 1920×1080 HDMI TV |

Display assignment: auto (DSI → booth, else smallest → booth). Config: `/etc/captureos/display.conf` — see `deploy/kiosk/display.conf.example`.

**Kiosk note (v1 behavior, copied as-is):** hybrid ozone — gallery on XWayland (`x11`), booth on native Wayland for correct touch. Do not re-enable Chromium `--kiosk`.

---

## 8. Operator commands (same as v1)

```bash
captureos                          # launch booth + gallery
pkill -f captureos-profile         # exit kiosk windows
captureos-launch.sh --diagnose
tail -40 ~/.local/state/captureos/launcher.log
```

Admin: `http://localhost/#/admin` — default PIN **1234**

---

## 9. v2 checklist

- [ ] v1 tagged `v1.0-handoff`, Pi can revert to it
- [ ] v2 repo created from full v1 copy
- [ ] New design tokens in `styles.css`
- [ ] `meta.ts` + icon + desktop PNG updated
- [ ] `npm run build` + Pi install tested
- [ ] Dual-screen: gallery on TV, booth on touch
- [ ] Touch hits shutter / Accept correctly
- [ ] Gallery + slideshow look correct on 1080p wall
- [ ] README/screenshots updated for v2 look

---

## 10. If something breaks in v2

1. **UI only broken** → fix `frontend/`; redeploy dist  
2. **Kiosk / touch / dual-screen broken** → you likely edited `deploy/` or titles — diff against `v1.0-handoff`  
3. **Need working booth now** → Pi: `git checkout v1.0-handoff && sudo ./deploy/install.sh`

---

## 11. One-line summary

**v2 = clone v1 at `v1.0-handoff`, new GitHub repo, change `frontend/src/styles.css` + branding + icons; ship everything else unchanged.**
