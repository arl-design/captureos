import { useCallback, useEffect, useRef, useState } from 'react';

import { CameraIcon, ExpandIcon, GearIcon, HomeIcon, PhotosIcon } from '../components/Icons';
import { api, subscribe } from '../lib/api';
import { APP_NAME, APP_TAGLINE, APP_VERSION, formatTime } from '../lib/meta';
import type { Photo, Settings } from '../lib/types';

// Capture workflow per the capture workflow:
//   ready -> countdown -> capturing -> review -> (accept | retake)
type Phase = 'ready' | 'countdown' | 'capturing' | 'review' | 'saved';
type Tab = 'home' | 'preview' | 'gallery';

// Live MJPEG preview. Chromium does not reliably abort a multipart-stream
// <img> connection when the element unmounts, so leaked streams pile up
// against the per-host connection limit until API calls hang. Clearing
// src on unmount forces the abort.
function CaptureButton({
  className,
  onCapture,
}: {
  className?: string;
  onCapture: () => void;
}) {
  const handlePointerUp = (e: React.PointerEvent) => {
    e.preventDefault();
    e.stopPropagation();
    onCapture();
  };
  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      e.stopPropagation();
      onCapture();
    }
  };
  return (
    <button
      type="button"
      className={className}
      onPointerUp={handlePointerUp}
      onKeyDown={handleKeyDown}
      aria-label="Capture"
    >
      <CameraIcon size="55%" />
    </button>
  );
}

function PreviewStream({ className }: { className?: string }) {
  const ref = useRef<HTMLImageElement>(null);
  // src is managed entirely by the effect (not JSX) so that the stream
  // restarts after StrictMode's mount/unmount/mount cycle, which reuses
  // the same DOM element.
  useEffect(() => {
    const img = ref.current;
    if (img) img.src = api.previewUrl;
    return () => {
      if (img) img.src = '';
    };
  }, []);
  return <img ref={ref} className={className} alt="Live preview" />;
}

// Live preview with tap-to-focus: tapping tells the camera to autofocus
// on that spot (shown with a brief yellow ring).
function TapFocusPreview({
  variant,
}: {
  variant: 'card' | 'stage';
}) {
  const ref = useRef<HTMLImageElement>(null);
  const [ring, setRing] = useState<{ left: number; top: number; key: number } | null>(null);

  useEffect(() => {
    const img = ref.current;
    if (img) img.src = api.previewUrl;
    return () => {
      if (img) img.src = '';
    };
  }, []);

  useEffect(() => {
    if (!ring) return;
    const timer = setTimeout(() => setRing(null), 1200);
    return () => clearTimeout(timer);
  }, [ring]);

  const handlePointerDown = (e: React.PointerEvent<HTMLDivElement>) => {
    const img = ref.current;
    if (!img) return;
    const rect = img.getBoundingClientRect();
    if (rect.width === 0 || rect.height === 0) return;
    const px = e.clientX - rect.left;
    const py = e.clientY - rect.top;
    // The stream renders with object-fit: cover — undo the crop so the
    // tap maps to the actual camera frame coordinates.
    const nw = img.naturalWidth || 640;
    const nh = img.naturalHeight || 480;
    const scale = Math.max(rect.width / nw, rect.height / nh);
    const dispW = nw * scale;
    const dispH = nh * scale;
    const x = (px + (dispW - rect.width) / 2) / dispW;
    const y = (py + (dispH - rect.height) / 2) / dispH;
    if (x < 0 || x > 1 || y < 0 || y > 1) return;
    setRing({ left: px, top: py, key: Date.now() });
    api.focus(x, y).catch(() => {});
  };

  return (
    <div
      className={`tap-focus ${variant === 'stage' ? 'stage-fill' : 'card-fill'}`}
      onPointerDown={handlePointerDown}
    >
      <img
        ref={ref}
        className={variant === 'stage' ? 'stage preview-stream' : 'preview-stream'}
        alt="Live preview — tap to focus"
      />
      {ring && (
        <span
          key={ring.key}
          className="focus-ring"
          style={{ left: ring.left, top: ring.top }}
        />
      )}
    </div>
  );
}

export function Booth() {
  const [tab, setTab] = useState<Tab>('home');
  const [phase, setPhase] = useState<Phase>('ready');
  const [count, setCount] = useState(3);
  const [photo, setPhoto] = useState<Photo | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [cameraOk, setCameraOk] = useState<boolean | null>(null);
  const [showStatus, setShowStatus] = useState(false);
  const settings = useRef<Settings | null>(null);

  useEffect(() => {
    api.settings().then((s) => (settings.current = s)).catch(() => {});
  }, []);

  // Camera status dot: poll /health.
  useEffect(() => {
    let cancelled = false;
    const check = () =>
      api
        .health()
        .then((h) => !cancelled && setCameraOk(h.camera.ok))
        .catch(() => !cancelled && setCameraOk(false));
    check();
    const timer = setInterval(check, 15_000);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, []);

  const fail = useCallback((err: unknown) => {
    setError(err instanceof Error ? err.message : String(err));
    setPhase('ready');
  }, []);

  const doCapture = useCallback(() => {
    setPhase('capturing');
    api
      .capture()
      .then((p) => {
        setPhoto(p);
        setPhase('review');
      })
      .catch(fail);
  }, [fail]);

  // Countdown ticker (3 — 2 — 1 — shoot).
  useEffect(() => {
    if (phase !== 'countdown') return;
    if (count <= 0) {
      doCapture();
      return;
    }
    const timer = setTimeout(() => setCount((c) => c - 1), 1000);
    return () => clearTimeout(timer);
  }, [phase, count, doCapture]);

  // After a successful save, linger briefly then return to ready.
  useEffect(() => {
    if (phase !== 'saved') return;
    const timer = setTimeout(() => {
      setPhoto(null);
      setPhase('ready');
    }, 2500);
    return () => clearTimeout(timer);
  }, [phase]);

  const startCountdown = useCallback(() => {
    setError(null);
    setCount(settings.current?.countdown_seconds ?? 3);
    setPhase('countdown');
  }, []);

  const accept = () => {
    if (!photo) return;
    api
      .accept(photo.id)
      .then(() => setPhase('saved'))
      .catch(fail);
  };

  const retake = () => {
    if (photo) api.retake(photo.id).catch(() => {});
    setPhoto(null);
    setPhase('ready');
  };

  // Countdown / flash / review / saved take over the whole screen.
  if (phase !== 'ready') {
    return (
      <div className="booth-takeover">
        {(phase === 'countdown' || phase === 'capturing') && (
          <PreviewStream className="stage" />
        )}
        {phase === 'countdown' && (
          <div className="overlay countdown" key={count}>{count}</div>
        )}
        {phase === 'capturing' && <div className="overlay flash" />}
        {(phase === 'review' || phase === 'saved') && photo && (
          <img className="stage contain" src={photo.url} alt="Your capture" />
        )}
        {phase === 'review' && (
          <div className="review-actions">
            <button className="btn accept" onClick={accept}>Accept ✓</button>
            <button className="btn retake" onClick={retake}>Retake ↻</button>
          </div>
        )}
        {phase === 'saved' && (
          <div className="overlay saved-banner">Added to the gallery!</div>
        )}
      </div>
    );
  }

  return (
    <div className="booth">
      <header className="booth-topbar">
        <span className="booth-brand">{APP_NAME}</span>
        <button
          className="icon-btn"
          aria-label="System status"
          onClick={() => setShowStatus((v) => !v)}
        >
          <GearIcon size="1.25em" />
        </button>
      </header>

      {tab === 'home' && (
        <main className="booth-home">
          <div className="booth-heading">
            <h1>{APP_TAGLINE}</h1>
            <p>Build. Pose. Capture!</p>
          </div>
          <div className="preview-card">
            <TapFocusPreview variant="card" />
            <div className="camera-status">
              <span className={`dot ${cameraOk === false ? 'bad' : 'good'}`} />
              {cameraOk === false ? 'Camera Offline' : 'Camera Ready'}
            </div>
          </div>
          {error && <div className="error-banner">{error}</div>}
          <div className="capture-zone">
            <CaptureButton
              className="capture-fab capture-fab-inline"
              onCapture={startCountdown}
            />
          </div>
        </main>
      )}

      {tab === 'preview' && (
        <main className="booth-preview">
          <TapFocusPreview variant="stage" />
          <CaptureButton className="capture-fab floating" onCapture={startCountdown} />
        </main>
      )}

      {tab === 'gallery' && <BoothGallery />}

      {showStatus && (
        <div className="status-sheet" onClick={() => setShowStatus(false)}>
          <div className="status-card">
            <h3>System</h3>
            <p>
              <span className={`dot ${cameraOk === false ? 'bad' : 'good'}`} />
              {cameraOk === false ? 'Camera Offline' : 'Camera Ready'}
            </p>
            <p className="muted">{APP_VERSION}</p>
          </div>
        </div>
      )}

      <nav className="booth-nav">
        <button className={tab === 'home' ? 'active' : ''} onClick={() => setTab('home')}>
          <HomeIcon size="1.4em" />
          Home
        </button>
        <button className={tab === 'preview' ? 'active' : ''} onClick={() => setTab('preview')}>
          <ExpandIcon size="1.4em" />
          Full Screen
        </button>
        <button className={tab === 'gallery' ? 'active' : ''} onClick={() => setTab('gallery')}>
          <PhotosIcon size="1.4em" />
          Gallery
        </button>
      </nav>
    </div>
  );
}

// Compact on-booth gallery: two-column grid of recent captures.
function BoothGallery() {
  const [photos, setPhotos] = useState<Photo[]>([]);

  useEffect(() => {
    api.gallery(60).then((g) => setPhotos(g.photos)).catch(() => {});
    return subscribe({
      'photo.accepted': (data) => {
        const p = data as Photo;
        setPhotos((prev) => (prev.some((q) => q.id === p.id) ? prev : [p, ...prev]));
      },
      'photo.removed': (data) => {
        const { id } = data as { id: number };
        setPhotos((prev) => prev.filter((p) => p.id !== id));
      },
    });
  }, []);

  if (photos.length === 0) {
    return <main className="booth-gallery empty">No photos yet</main>;
  }
  return (
    <main className="booth-gallery">
      {photos.map((p) => (
        <figure key={p.id}>
          <img src={p.thumbUrl} alt={`Capture ${p.photoId}`} loading="lazy" />
          <figcaption>{formatTime(p.capturedAt)}</figcaption>
        </figure>
      ))}
    </main>
  );
}
