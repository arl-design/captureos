import { useEffect, useState } from 'react';

import { CameraIcon, ClockIcon, GearIcon, PhotosIcon, WifiIcon } from '../components/Icons';
import { api, subscribe } from '../lib/api';
import { APP_NAME, APP_VERSION, formatDate, formatTime } from '../lib/meta';
import type { Photo, Settings } from '../lib/types';
import { Slideshow } from './Slideshow';

type Mode = 'grid' | 'slideshow';

interface Props {
  /** Lock the display to one mode regardless of the gallery_mode setting
      (used by the /#/slideshow route). */
  forceMode?: Mode;
}

// Wall-display gallery. In grid mode: a live, uniform grid of captures,
// newest first with a NEW badge. In slideshow mode: full-screen Ken Burns
// showcase. The mode follows the `gallery_mode` setting live over SSE, so
// an operator can flip the wall display from any browser on the LAN.
export function Gallery({ forceMode }: Props) {
  const [photos, setPhotos] = useState<Photo[]>([]);
  const [title, setTitle] = useState('LEGO MiniFigure Booth');
  const [mode, setMode] = useState<Mode>('grid');
  const [interval, setIntervalSeconds] = useState(6);
  const [justAdded, setJustAdded] = useState<number | null>(null);
  const [systemOk, setSystemOk] = useState(true);

  useEffect(() => {
    api.gallery().then((g) => setPhotos(g.photos)).catch(() => {});

    const applySettings = (s: Partial<Settings>) => {
      if (s.gallery_title !== undefined) setTitle(s.gallery_title);
      if (s.slideshow_interval_seconds !== undefined) {
        setIntervalSeconds(s.slideshow_interval_seconds);
      }
      if (s.gallery_mode !== undefined) setMode(s.gallery_mode);
    };
    api.settings().then(applySettings).catch(() => {});

    return subscribe({
      'photo.accepted': (data) => {
        const photo = data as Photo;
        setPhotos((prev) =>
          prev.some((p) => p.id === photo.id) ? prev : [photo, ...prev],
        );
        setJustAdded(photo.id);
      },
      'photo.removed': (data) => {
        const { id } = data as { id: number };
        setPhotos((prev) => prev.filter((p) => p.id !== id));
      },
      'settings.updated': (data) => applySettings(data as Partial<Settings>),
    });
  }, []);

  useEffect(() => {
    if (justAdded === null) return;
    const timer = setTimeout(() => setJustAdded(null), 4000);
    return () => clearTimeout(timer);
  }, [justAdded]);

  // Footer health dot.
  useEffect(() => {
    let cancelled = false;
    const check = () =>
      api
        .health()
        .then((h) => !cancelled && setSystemOk(h.ok && h.camera.ok))
        .catch(() => !cancelled && setSystemOk(false));
    check();
    const timer = setInterval(check, 15_000);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, []);

  // forceMode is applied at render time (not baked into state) so that
  // hash navigation between /#/gallery and /#/slideshow — which reuses
  // this same mounted component — takes effect immediately.
  if ((forceMode ?? mode) === 'slideshow') {
    return (
      <div className="gallery slideshow-mode">
        <Slideshow
          photos={photos}
          title={title}
          intervalSeconds={interval}
          newPhotoId={justAdded}
        />
      </div>
    );
  }

  return (
    <div className="gallery">
      <header className="wall-header">
        <div className="wall-logo">
          <CameraIcon size="1.6em" />
        </div>
        <div className="wall-title">
          <h1>{APP_NAME}</h1>
          <p>{title}</p>
        </div>
        <div className="wall-meta">
          <div className="wall-stat">
            <PhotosIcon size="1.5em" />
            <div>
              <strong>{photos.length}</strong>
              <span>{photos.length === 1 ? 'Photo' : 'Photos'}</span>
            </div>
          </div>
          <div className="wall-divider" />
          <WallClock />
        </div>
      </header>

      <main className="wall-body">
        <h2 className="section-title">Live Gallery</h2>
        {photos.length === 0 ? (
          <div className="gallery-empty">Waiting for the first photo…</div>
        ) : (
          <div className="wall-grid">
            {photos.map((p, i) => (
              <figure
                key={p.id}
                className={`card ${i === 0 ? 'newest' : ''} ${justAdded === p.id ? 'pop' : ''}`}
              >
                {i === 0 && <span className="new-badge">NEW</span>}
                <img src={p.thumbUrl} alt={`Capture ${p.photoId}`} loading="lazy" />
                <figcaption>{formatTime(p.capturedAt)}</figcaption>
              </figure>
            ))}
          </div>
        )}
      </main>

      <footer className="wall-footer">
        <span className="footer-status">
          <span className={`dot ${systemOk ? 'good' : 'bad'}`} />
          {systemOk ? 'System Ready' : 'System Degraded'}
        </span>
        <span className="footer-version">{APP_VERSION}</span>
        <span className="footer-right">
          <span className="footer-item">
            <WifiIcon size="1.2em" /> Connected
          </span>
          <a className="footer-item" href="#/admin">
            <GearIcon size="1.2em" /> Admin
          </a>
        </span>
      </footer>
    </div>
  );
}

function WallClock() {
  const [now, setNow] = useState(() => new Date());
  useEffect(() => {
    const timer = setInterval(() => setNow(new Date()), 1000);
    return () => clearInterval(timer);
  }, []);
  return (
    <div className="wall-stat">
      <ClockIcon size="1.5em" />
      <div>
        <strong>{formatTime(now)}</strong>
        <span>{formatDate(now)}</span>
      </div>
    </div>
  );
}
