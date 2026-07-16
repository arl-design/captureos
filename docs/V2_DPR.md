# CaptureOS v2 DPR — NMI Design Language Port

**Status:** Ready for implementation  
**Type:** Design-only refresh (no new product features)  
**Base:** v1 working tree (this repo / tag `v1.0-handoff` when available)  
**Sources:** [`V2_HANDOFF.md`](./V2_HANDOFF.md), NMI Photo Booth Guest Interface Design Spec  
**Date:** 2026-07-16

---

## 1. Objective

Port the **NMI guest-interface design language** (palette, typography, buttons, motion, voice, green-means-action) into CaptureOS so this booth feels cohesive with other NMI Activation surfaces.

This is **not** a port of the NMI AI style / print / coin journey. Those screens and backends belong to a different project. CaptureOS keeps its existing capture → accept → gallery workflow.

---

## 2. Non-goals

Do **not** implement in this DPR:

- AI style generation, regenerate, upscaling
- Print / coin pipeline or “Your coin is printing” as a real feature
- Backend, camera-service, or deploy/kiosk script rewrites
- API or photo lifecycle changes
- New hash routes
- Window title prefix changes that break labwc rules
- Breaking `/opt/captureos/data` compatibility

If design work accidentally breaks kiosk/touch/dual-screen, revert frontend changes or restore `v1.0-handoff` on the Pi — do not “fix” by editing `deploy/kiosk/*` unless titles were changed incorrectly.

---

## 3. Product truth (unchanged)

```
ready → countdown → capturing → review → (accept | retake)
                              ↘ saved → auto-return to ready
```

| Surface | Route | Role |
|---------|-------|------|
| Booth (touch) | `/#/` | Guest capture UI |
| Gallery (wall) | `/#/gallery` | Live grid |
| Slideshow | `/#/slideshow` | Full-screen showcase |
| Admin | `/#/admin` | Operator PIN UI |

Architecture remains: nginx → frontend static + `/api` → backend → camera-service. Dual Chromium kiosk unchanged.

---

## 4. Design principles (must keep)

1. **Green means “do this.”** Primary button, headline accent word, progress/countdown fill. Nothing decorative is green.
2. **Purple is atmosphere**, never action (radial wash, eyebrow labels).
3. **No red anywhere.** Errors: neutral ⚠️ + normal text. Offline connection dot only: `#f5a623` (6px, operator-facing).
4. **One primary button per screen.** Alternatives are ghost.
5. **Second person, short copy.** “Looking good!” not “Photo captured successfully.” Guest text says **minifig** / **Minifigure** — never the toy brand name.
6. **Screens breathe in** (opacity + scale 0.97→1). Only the idle Start button pulses.
7. **Public Sans, self-hosted** (Pi may be offline). Heavy tight headlines are the brand.

---

## 5. Design tokens (replace v1 black & yellow)

Implement in `frontend/src/styles.css` `:root` (and migrate all `--yellow` / `--red` call sites):

```css
:root {
  --bg:          #0c0a12;
  --surface:     #161222;
  --line:        rgba(255,255,255,0.06);
  --line-strong: rgba(255,255,255,0.12);

  --purple:      #32165D;
  --purple-lt:   #BD8DFF;

  --green:       #5CDDAD;
  --green-dim:   rgba(92,221,173,0.10);
  --green-glow:  rgba(92,221,173,0.25);
  --green-ink:   #06231a;           /* text on primary buttons */

  --text:        #ECE9F3;
  --text-dim:    #6a6182;

  --warn:        #f5a623;           /* offline connection dot ONLY */

  --font:        'Public Sans', 'Segoe UI', system-ui, -apple-system, sans-serif;
  --radius-sm:   12px;
  --radius-md:   20px;
  --radius-lg:   28px;
}
```

### Token migration map (v1 → v2)

| v1 token / role | v2 |
|-----------------|-----|
| `--yellow` (action / brand bar / FAB) | `--green` for actions; purple wash for atmosphere |
| `--yellow-deep` | drop or map to darker green border only if needed |
| `--bg` / `--panel` / `--card` | `--bg` / `--surface`; cards only where interaction needs a container |
| `--border` | `--line` / `--line-strong` |
| `--muted` | `--text-dim` |
| `--green` (old status) | `--green` (NMI Gateway Green) — reserve for action/status-ok carefully |
| `--red` (errors, bad dot) | remove; errors → neutral UI; bad dot → `--warn` |
| system font stack | Public Sans via `--font` |

Legacy aliases may be kept temporarily during the CSS pass if they reduce churn, but **no yellow or red should remain visible** when done.

---

## 6. Typography

Self-host Public Sans under e.g. `frontend/public/fonts/` and `@font-face` in `styles.css`. Do not rely on Google Fonts at runtime on the Pi.

| Element | Size | Weight | Tracking |
|---------|------|--------|----------|
| Eyebrow badge | 11px | 700 | `0.35em`, uppercase |
| Idle headline | `clamp(52px, 8vw, 96px)` | 900 | `-0.03em` |
| Countdown numeral | `clamp(120px, 28vmin, 280px)` | 900 | — |
| Screen titles | `clamp(22px, 4vw, 36px)` | 800 | `-0.02em` |
| Primary button | 22px | 800 | `-0.01em` |
| Body / sub | `clamp(16px, 2vw, 20px)` | 400 | — |

Rules:

- Max **one** accent color word per headline (green on the action word).
- Tracking never tighter than `-0.03em`.
- Prefer `clamp()` / `vw` / `vmin` — do not freeze sizes to fixed px for the 1024×600 booth.
- Under ~800px wide, tighten section padding from ~48px toward ~24px (landscape booth grid may already use % padding — keep touch clearances).

---

## 7. Buttons & motion

### Buttons

```css
.btn { /* shared */ border-radius: 999px; font-weight: 800; letter-spacing: -0.01em; }
.btn:active { transform: scale(0.95); }

.btn-primary {
  background: var(--green);
  color: var(--green-ink);   /* NOT white */
  padding: 24px 64px;
  font-size: 22px;
  box-shadow: 0 0 0 0 var(--green-glow), 0 8px 32px rgba(92,221,173,0.2);
}

.btn-ghost {
  background: transparent;
  color: var(--text);
  border: 1.5px solid var(--line-strong);
  padding: 18px 40px;
  font-size: 16px;
}
```

Idle Start only: `.btn-primary.pulse` with the 2.4s green glow pulse from the design spec.

### Screen transitions

```css
.screen { opacity: 0; transform: scale(0.97); pointer-events: none;
  transition: opacity 0.5s cubic-bezier(0.4, 0, 0.2, 1),
              transform 0.5s cubic-bezier(0.4, 0, 0.2, 1); }
.screen.on { opacity: 1; transform: scale(1); pointer-events: auto; }
```

Kiosk hygiene (ensure present):

```css
* { -webkit-tap-highlight-color: transparent; }
html, body { height: 100%; overflow: hidden; }
body { user-select: none; }
```

---

## 8. Screen mapping (spec language → CaptureOS)

| Spec id | CaptureOS phase/UI | Implement |
|---------|-------------------|-----------|
| `s-idle` | `ready` home | Yes — NMI idle language |
| `s-countdown` | `countdown` | Yes — giant numeral + SVG ring |
| `s-capturing` | `capturing` | Yes — spinner + hold-still copy |
| `s-review` | `review` | Yes — Looking good / Use This Photo / Retake |
| `s-styles` | — | **Out of scope** |
| `s-upscaling` | — | **Out of scope** |
| `s-done` | `saved` | Yes — gallery-honest done state (not print/coin) |
| `s-error` | error UI | Yes — Oops / Try Again, no red |

### Guest copy (required)

| Screen | Copy |
|--------|------|
| Idle headline | Become a **minifig** (accent on last word) |
| Idle sub | One short line (e.g. pose and tap Start — keep second person) |
| Idle CTA | **Start** (pulsing primary) |
| Capturing | “Capturing…” / “Hold still and keep smiling!” |
| Review title | “Looking good!” |
| Review primary | **Use This Photo** |
| Review secondary | *Retake* (ghost) |
| Done | Honest gallery wording, e.g. “You’re in the gallery!” + short sub — **not** “Your coin is printing” |
| Error | ⚠️ “Oops” / “Something went wrong. Please try again.” → **Try Again** |

Do not promise durations unless measured on hardware.

### Operator chrome (keep, restyle)

These are CaptureOS-specific and stay for ops/touch ergonomics:

- Top bar / brand mark (demote yellow bar; no yellow chrome)
- Gear → system status sheet (camera ok / version)
- Bottom nav: Home / Full Screen / Gallery
- Tap-to-focus preview + fixed-focus notice
- On-booth gallery grid

Restyle with NMI tokens. Active nav / action affordances follow green-means-action; do not paint the whole nav green.

---

## 9. Surface-by-surface work

### 9.1 Booth (`frontend/src/booth/Booth.tsx` + booth CSS)

- Replace yellow FAB capture control on idle with a single pulsing **Start** primary button (camera icon optional inside or beside — still one primary).
- Idle background: purple radial wash  
  `radial-gradient(ellipse 120% 80% at 50% -5%, #1e1338 0%, var(--bg) 55%)`
- Countdown: SVG ring that drains over the countdown; numeral uses type scale from §6.
- Capturing: replace identity-of-flash-as-brand with quiet spinner + copy (a brief white flash for shutter feel is OK if it isn’t a red/yellow brand moment).
- Review / saved: primary + ghost pattern; breathe-in transitions.
- Errors: dedicated Oops treatment; remove red banners.
- Preserve phase machine and `api.capture` / `accept` / `retake` / focus / health — **behavior unchanged**.
- Preserve landscape grid that keeps shutter clear of bottom nav (touch Y-offset bug was real — do not regress).

### 9.2 Gallery & slideshow

- Header/accent: purple-lt for eyebrows/labels; green only for true actions (if any).
- NEW badge, progress bar, confetti/burst: remove yellow/red; no decorative green.
- Keep Ken Burns / SSE / `gallery_mode` behavior.

### 9.3 Admin

- Token restyle only: accents, buttons, meters, login screen.
- Offline/error coloring follows no-red rule.
- PIN flow and tabs unchanged.

### 9.4 Branding & assets

| Item | Action |
|------|--------|
| `frontend/src/lib/meta.ts` | Update tagline/version for v2; guest-facing strings must not use toy brand name. Keep `APP_NAME` pattern so window titles remain `CaptureOS Booth` / `CaptureOS Gallery` / `CaptureOS Admin`. |
| `frontend/src/gallery/Gallery.tsx` | Default wall title currently hardcodes toy-brand booth name — align with meta / minifig wording. |
| `frontend/src/components/Icons.tsx` | Drive fills/strokes from CSS vars (`--icon-contrast` / green/purple as appropriate). |
| `frontend/index.html` | Font preload optional; **keep** synchronous title script; do not rename title prefixes. |
| `deploy/desktop/captureos-icon.png` | Optional refresh to NMI palette if easy; not blocking. |
| README / `docs/screenshot-*.png` | Update after UI lands. |

### 9.5 Do not touch

- `backend/`, `camera-service/`
- `deploy/kiosk/*` (and related launcher/display scripts)
- Hash routes, SSE contract, SQLite schema, install paths

---

## 10. Implementation order (for coding agent)

1. **Branch** from current main / v1 freeze: `cursor/<name>-97f5` (or project convention).
2. **Tokens + Public Sans + button/motion primitives** in `styles.css` (+ font files).
3. **Global sweep:** replace visible yellow/red usages across booth, gallery, slideshow, admin.
4. **Booth guest journey** structure/copy in `Booth.tsx` (idle → error mapping in §8).
5. **Gallery / slideshow / admin** polish pass.
6. **meta + Gallery title + icons** branding pass.
7. `cd frontend && npm install && npm run build`
8. Smoke: booth flow, gallery, slideshow, admin login.
9. Commit / push / PR; update screenshots + README when look is stable.

---

## 11. Acceptance criteria

- [ ] No yellow brand chrome remains; palette matches NMI tokens
- [ ] No red in the UI; offline uses `#f5a623` dot only
- [ ] Public Sans loads from self-hosted files
- [ ] Idle: Become a **minifig** + pulsing green **Start** + purple wash
- [ ] Exactly one primary (green) CTA per guest screen
- [ ] Countdown uses large type + draining ring
- [ ] Review: “Looking good!” / Use This Photo / Retake (ghost)
- [ ] Done copy is gallery-honest (no print/coin claims)
- [ ] Error: Oops + Try Again, no red
- [ ] Capture / accept / retake / gallery SSE still work
- [ ] Window titles still match labwc (`CaptureOS Booth*`, `CaptureOS Gallery*`)
- [ ] `npm run build` succeeds
- [ ] Landscape booth: Start/shutter not occluded by bottom nav
- [ ] No AI styles / upscaling / print UI added

---

## 12. Test plan

### Local (no Pi)

```bash
cd camera-service && python3 camera_service.py &
cd backend && npm install && npm run dev &
cd frontend && npm install && npm run dev
```

- Booth: `http://localhost:5173/#/`
- Gallery: `http://localhost:5173/#/gallery`
- Slideshow: `http://localhost:5173/#/slideshow`
- Admin: `http://localhost:5173/#/admin` (default PIN `1234`)

Walk every phase; confirm copy, one primary CTA, no red/yellow regressions.

### Hardware (before event cutover)

- `npm run build` + `sudo ./deploy/install.sh` on Pi
- Dual-screen: booth touch + gallery TV
- Touch accuracy on Start / Use This Photo / Retake
- Gallery + slideshow on 1080p
- Confirm v1 fallback still tagged if production needs rollback

---

## 13. Rollback

1. UI-only issue → fix `frontend/`, redeploy `dist`
2. Kiosk/touch broken → diff against v1; restore titles / undo accidental `deploy/` edits
3. Need working booth now → Pi: `git checkout v1.0-handoff && sudo ./deploy/install.sh`

---

## 14. One-line summary for implementers

**Copy v1 as-is, then restyle CaptureOS’s existing guest + wall + admin UI to the NMI design language (tokens, Public Sans, green-means-action, guest copy). Do not build the NMI AI/print journey.**
