import { useEffect, useRef, useState } from 'react';

import type { Photo } from '../lib/types';

interface Props {
  photos: Photo[];
  title: string;
  intervalSeconds: number;
  /** id of a photo that just arrived over SSE — interrupts the cycle */
  newPhotoId: number | null;
}

// Full-screen showcase: crossfading Ken Burns cycle through the gallery.
// A freshly accepted photo interrupts the rotation and gets a celebration
// banner before the cycle resumes.
export function Slideshow({ photos, title, intervalSeconds, newPhotoId }: Props) {
  const [index, setIndex] = useState(0);
  // gen increments on every slide change so animations restart even when
  // the cycle wraps back to the same photo.
  const [gen, setGen] = useState(0);
  const [celebrating, setCelebrating] = useState(false);
  const indexRef = useRef(index);
  indexRef.current = index;

  const n = photos.length;

  // Rotation timer. Paused while celebrating a new arrival.
  useEffect(() => {
    if (n < 2 || celebrating) return;
    const timer = setInterval(() => {
      setIndex((indexRef.current + 1) % n);
      setGen((g) => g + 1);
    }, Math.max(intervalSeconds, 2) * 1000);
    return () => clearInterval(timer);
  }, [n, intervalSeconds, celebrating]);

  // New photo interrupt: it was prepended, so jump to slot 0. The parent
  // clears newPhotoId a few seconds later, which ends the celebration —
  // an internal timeout wouldn't survive that prop change (its effect
  // cleanup would cancel it).
  useEffect(() => {
    if (newPhotoId === null) {
      setCelebrating(false);
      return;
    }
    setIndex(0);
    setGen((g) => g + 1);
    setCelebrating(true);
  }, [newPhotoId]);

  if (n === 0) {
    return <div className="gallery-empty">Waiting for the first photo…</div>;
  }

  const current = photos[index % n];
  const previous = photos[(index - 1 + n) % n];

  return (
    <div className="slideshow">
      {n > 1 && (
        <img
          className="slide under"
          src={previous.url}
          alt=""
          aria-hidden
        />
      )}
      <img
        key={gen}
        className={`slide over ${gen % 2 ? 'kb-a' : 'kb-b'}`}
        src={current.url}
        alt={`Capture ${current.photoId}`}
      />

      {celebrating && (
        <div className="celebrate" aria-live="polite">
          <div className="burst" aria-hidden>
            {Array.from({ length: 10 }, (_, i) => (
              <span key={i} style={{ ['--i' as string]: i }} />
            ))}
          </div>
          <div className="new-banner">New photo!</div>
        </div>
      )}

      <div className="slide-chrome">
        <span className="slide-title">{title}</span>
        <span className="slide-counter">
          {(index % n) + 1} / {n}
        </span>
      </div>
      {!celebrating && n > 1 && (
        <div
          key={`bar-${gen}`}
          className="slide-progress"
          style={{ animationDuration: `${Math.max(intervalSeconds, 2)}s` }}
        />
      )}
    </div>
  );
}
