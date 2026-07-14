# CaptureOS Architecture

```
                 ┌────────────────────────────────────────────┐
                 │                  nginx :80                 │
                 │  /            → frontend/dist (static)     │
                 │  /photos/…    → data/photos (disk)         │
                 │  /thumbnails/…→ data/thumbnails (disk)     │
                 │  /api/…       → backend :3000              │
                 └───────┬───────────────────────┬────────────┘
        Chromium kiosk   │                       │   Chromium kiosk
        (touch panel)    │                       │   (32" wall display)
        http://…/#/      │                       │   http://…/#/gallery
                         ▼                       ▼
                 ┌──────────────────────────────────────┐
                 │        backend (Express, :3000)      │
                 │  routes: capture/accept/retake/…     │
                 │  SQLite (node:sqlite) — photos,      │
                 │  settings                            │
                 │  SSE hub — pushes photo.accepted     │
                 └───────────────┬──────────────────────┘
                                 │ HTTP (localhost)
                                 ▼
                 ┌──────────────────────────────────────┐
                 │    camera-service (Python, :5000)    │
                 │  rpicam-still / libcamera-still,     │
                 │  dev-mode synthetic camera fallback  │
                 │  pipeline: validate → crop → resize  │
                 │  → thumbnail → save                  │
                 └──────────────────────────────────────┘
```

## Design decisions

**Three independent processes, HTTP between them.** Each service operates
independently and recovers automatically: systemd restarts a crashed service
in ~2 s without taking the others down. The camera process owning the
hardware also isolates libcamera crashes from the API.

**`node:sqlite` instead of a native npm driver.** Node 22 ships a built-in
synchronous SQLite binding, so the backend has exactly one npm dependency
(Express) and nothing to compile on the Pi. WAL mode keeps reads (gallery)
from blocking writes (capture).

**Camera pipeline lives in Python.** Pillow does validate/crop/resize/
thumbnail in one place, next to the capture code, and the backend passes
pipeline parameters (quality, sizes) per request so all tunable settings
still live in the backend's SQLite `settings` table.

**Pending → accepted photo lifecycle.** `POST /capture` writes files and a
`pending` DB row. The gallery only ever queries `accepted` rows, so a photo
the user retakes never flashes on the wall display. Retakes delete files
immediately; abandoned pending photos are swept after a TTL.

**SSE, not WebSockets or polling.** The gallery must refresh in under one
second. A snappy wall display was a core goal. A single `EventSource` on `/api/events`
gets a `photo.accepted` push the moment the user taps Accept — no polling
load, no WebSocket dependency, and nginx passes it through with
`proxy_buffering off`.

**Hash routing in the frontend.** One static bundle serves both displays
(`/#/` booth, `/#/gallery` wall) with zero server-side routing config.

**Dev-mode camera.** With no libcamera binary present (or
`CAMERA_FORCE_DEV=1`), the camera service synthesizes animated frames and
placeholder captures, so the full stack — including preview streaming and
the capture pipeline — runs on a laptop or CI.

## Preview latency note (Phase 1 limitation)

Preview frames are currently produced by invoking `rpicam-still --immediate`
per frame, which will not hit a <150 ms preview target on real
hardware. The planned Phase 2+ fix is a persistent `picamera2` capture loop
inside the camera service (same HTTP interface, so nothing else changes).
The MJPEG endpoint and dev camera already stream at 12 fps.

## Data layout

```
data/
├── captureos.sqlite      # photos + settings (WAL)
├── photos/               # full-resolution JPEGs
└── thumbnails/           # 480px-wide JPEGs for the gallery grid
```

## Feature status

- **Platform foundation** — camera service, backend, SQLite, React
  frontend, nginx, systemd. Complete.
- **Capture workflow** — idle → live preview → countdown → capture →
  accept/retake → live gallery. Complete. The booth touch UI targets the
  10.1" 1024×600 landscape touchscreen (iPistBit, HDMI + USB touch,
  driver-free) with a stacked fallback layout for small portrait panels.
- **Animated gallery, branding, slideshow** — complete. Full-screen
  slideshow with crossfade + Ken Burns rotation, per-slide progress bar, and
  a new-photo interrupt (celebration banner + brick confetti) driven by the
  same SSE channel. The wall display follows the `gallery_mode` setting
  live — `POST /settings {"gallery_mode": "slideshow"}` flips it from any
  LAN browser with no kiosk restart — and `/#/slideshow` pins the mode.
- **Administration, diagnostics, backups** — complete. `/#/admin` is a
  PIN-protected console (Settings, Diagnostics, Photos, Backups, Logs).
  Auth is a secret `admin_pin` setting (default 1234, changeable in the UI,
  never exposed by public `GET /settings`) exchanged for an 8-hour
  in-memory bearer token, with login rate limiting; production nginx
  additionally restricts `/api/admin/` to RFC1918 addresses. Backups use
  `node:sqlite`'s native backup into `data/backups/` (last 10 kept). Both
  services write size-rotated logs under `data/logs/`, and admin photo
  deletion broadcasts `photo.removed` so every display drops the photo live.

## Roadmap

Not yet built: a plugin system (image post-processing modules such as a
themed frame compositor), optional cloud sync, and multi-booth networking.
The single-process HTTP boundaries between services are the intended
extension points.
