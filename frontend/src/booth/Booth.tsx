import { useCallback, useEffect, useRef, useState } from 'react';

import { CameraIcon, ExpandIcon, GearIcon, HomeIcon, PhotosIcon } from '../components/Icons';
import { api, subscribe } from '../lib/api';
import { APP_NAME, APP_TAGLINE, APP_VERSION, formatTime } from '../lib/meta';
import type { Photo, Settings } from '../lib/types';

// Capture workflow:
//   ready -> countdown -> capturing -> review -> (accept | retake)
//                              ↘ saved → ready
//   any failure -> error → ready
type Phase = 'ready' | 'countdown' | 'capturing' | 'review' | 'saved' | 'error';
type Tab = 'home' | 'preview' | 'gallery';

const RING_R = 54;
const RING_C = 2 * Math.PI * RING_R;

function CaptureButton({
  className,
  onCapture,
}: {
  className?: string;
  onCapture: () => void;
}) {
  const handleClick = (e: React.MouseEvent | React.PointerEvent) => {
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
      onClick={handleClick}
      onKeyDown={handleKeyDown}
      aria-label="Start capture"
    >
      <CameraIcon size="55%" />
    </button>
  );
}

function PreviewStream({ className }: { className?: string }) {
  const ref = useRef<HTMLImageElement>(null);
  useEffect(() => {
    const img = ref.current;
    if (img) img.src = api.previewUrl;
    return () => {
      if (img) img.src = '';
    };
  }, []);
  return <img ref={ref} className={className} alt="Live preview" />;
}

function TapFocusPreview({
  variant,
}: {
  variant: 'card' | 'stage';
}) {
  const ref = useRef<HTMLImageElement>(null);
  const [ring, setRing] = useState<{ left: number; top: number; key: number } | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

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

  useEffect(() => {
    if (!notice) return;
    const timer = setTimeout(() => setNotice(null), 3500);
    return () => clearTimeout(timer);
  }, [notice]);

  const handlePointerDown = (e: React.PointerEvent<HTMLDivElement>) => {
    const img = ref.current;
    if (!img) return;
    const rect = img.getBoundingClientRect();
    if (rect.width === 0 || rect.height === 0) return;
    const px = e.clientX - rect.left;
    const py = e.clientY - rect.top;
    const nw = img.naturalWidth || 640;
    const nh = img.naturalHeight || 480;
    const scale = Math.max(rect.width / nw, rect.height / nh);
    const dispW = nw * scale;
    const dispH = nh * scale;
    const x = (px + (dispW - rect.width) / 2) / dispW;
    const y = (py + (dispH - rect.height) / 2) / dispH;
    if (x < 0 || x > 1 || y < 0 || y > 1) return;
    setRing({ left: px, top: py, key: Date.now() });
    api
      .focus(x, y)
      .then((r) => {
        if (r.af_supported === false) {
          setNotice('Fixed-focus camera — turn the lens ring to adjust focus');
        }
      })
      .catch(() => {});
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
      {notice && <div className="focus-notice">{notice}</div>}
    </div>
  );
}

function CountdownRing({ count, total }: { count: number; total: number }) {
  const progress = total <= 0 ? 0 : Math.max(0, count / total);
  const offset = RING_C * (1 - progress);
  return (
    <div className="overlay countdown-wrap">
      <div className="countdown-ring">
        <svg viewBox="0 0 120 120" aria-hidden>
          <circle className="ring-track" cx="60" cy="60" r={RING_R} />
          <circle
            className="ring-fill"
            cx="60"
            cy="60"
            r={RING_R}
            strokeDasharray={RING_C}
            strokeDashoffset={offset}
          />
        </svg>
        <span className="countdown-num" key={count}>{count}</span>
      </div>
    </div>
  );
}

export function Booth() {
  const [tab, setTab] = useState<Tab>('home');
  const [phase, setPhase] = useState<Phase>('ready');
  const [count, setCount] = useState(3);
  const [countdownTotal, setCountdownTotal] = useState(3);
  const [photo, setPhoto] = useState<Photo | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [cameraOk, setCameraOk] = useState<boolean | null>(null);
  const [showStatus, setShowStatus] = useState(false);
  const settings = useRef<Settings | null>(null);

  useEffect(() => {
    api.settings().then((s) => (settings.current = s)).catch(() => {});
  }, []);

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
    setPhase('error');
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

  useEffect(() => {
    if (phase !== 'countdown') return;
    if (count <= 0) {
      doCapture();
      return;
    }
    const timer = setTimeout(() => setCount((c) => c - 1), 1000);
    return () => clearTimeout(timer);
  }, [phase, count, doCapture]);

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
    const total = settings.current?.countdown_seconds ?? 3;
    setCountdownTotal(total);
    setCount(total);
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

  const clearError = () => {
    setError(null);
    setPhoto(null);
    setPhase('ready');
  };

  if (phase === 'error') {
    return (
      <div className="booth-takeover error-screen screen on">
        <div className="error-glyph" aria-hidden>⚠️</div>
        <h2>Oops</h2>
        <p>{error || 'Something went wrong. Please try again.'}</p>
        <button type="button" className="btn btn-primary" onClick={clearError}>
          Try Again
        </button>
      </div>
    );
  }

  if (phase !== 'ready') {
    return (
      <div className={`booth-takeover${phase === 'saved' ? ' done-glow' : ''} screen on`}>
        {(phase === 'countdown' || phase === 'capturing') && (
          <PreviewStream className="stage" />
        )}
        {phase === 'countdown' && (
          <CountdownRing count={count} total={countdownTotal} />
        )}
        {phase === 'capturing' && (
          <>
            <div className="overlay flash" />
            <div className="overlay capturing-overlay">
              <div className="spinner" aria-hidden />
              <h2>Capturing...</h2>
              <p>Hold still and keep smiling!</p>
            </div>
          </>
        )}
        {(phase === 'review' || phase === 'saved') && photo && (
          <img className="stage contain" src={photo.url} alt="Your capture" />
        )}
        {phase === 'review' && (
          <div className="review-panel">
            <h2>Looking good!</h2>
            <div className="review-actions">
              <button type="button" className="btn btn-primary" onClick={accept}>
                Use This Photo
              </button>
              <button type="button" className="btn btn-ghost" onClick={retake}>
                Retake
              </button>
            </div>
          </div>
        )}
        {phase === 'saved' && (
          <div className="done-panel">
            <h2>You&apos;re in the gallery!</h2>
            <p>Your minifig just hit the wall.</p>
          </div>
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
        <main className="booth-home screen on">
          <div className="booth-heading">
            <span className="booth-eyebrow">{APP_TAGLINE}</span>
            <h1>
              Become a <span className="accent">minifig</span>
            </h1>
            <p>Pose up and tap Start when you&apos;re ready.</p>
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
            <button
              type="button"
              className="btn btn-primary pulse"
              onClick={startCountdown}
            >
              Start
            </button>
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
          <div className="status-card" onClick={(e) => e.stopPropagation()}>
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
