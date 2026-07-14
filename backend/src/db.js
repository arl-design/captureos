import fs from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';

import { paths } from './config.js';

fs.mkdirSync(path.dirname(paths.db), { recursive: true });

export const db = new DatabaseSync(paths.db);

db.exec(`
  PRAGMA journal_mode = WAL;
  PRAGMA busy_timeout = 5000;

  CREATE TABLE IF NOT EXISTS photos (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    photo_id       TEXT NOT NULL UNIQUE,
    filename       TEXT NOT NULL,
    thumb_filename TEXT NOT NULL,
    width          INTEGER NOT NULL,
    height         INTEGER NOT NULL,
    size_bytes     INTEGER NOT NULL,
    status         TEXT NOT NULL DEFAULT 'pending'
                   CHECK (status IN ('pending', 'accepted', 'discarded')),
    captured_at    TEXT NOT NULL,
    accepted_at    TEXT
  );

  CREATE INDEX IF NOT EXISTS idx_photos_status_captured
    ON photos (status, captured_at DESC);

  CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
  );
`);

// Secret settings: stored alongside the rest but never returned by the
// public GET /settings, and only changeable through the admin API.
const SECRET_SETTINGS = {
  admin_pin: '1234',
};

const DEFAULT_SETTINGS = {
  countdown_seconds: 3,
  preview_hold_seconds: 4,
  jpeg_quality: 92,
  max_width: 2028,
  thumb_width: 480,
  gallery_title: 'LEGO MiniFigure Booth',
  slideshow_interval_seconds: 6,
  gallery_mode: 'grid',
};

// Settings whose values must come from a fixed set.
const SETTING_ENUMS = {
  gallery_mode: ['grid', 'slideshow'],
};

const insertSetting = db.prepare(
  'INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)',
);
for (const [key, value] of Object.entries({ ...DEFAULT_SETTINGS, ...SECRET_SETTINGS })) {
  insertSetting.run(key, JSON.stringify(value));
}

export function getSettings() {
  const rows = db.prepare('SELECT key, value FROM settings').all();
  const out = {};
  for (const { key, value } of rows) {
    if (key in SECRET_SETTINGS) continue;
    try {
      out[key] = JSON.parse(value);
    } catch {
      out[key] = value;
    }
  }
  return out;
}

export function getSecretSetting(key) {
  const row = db.prepare('SELECT value FROM settings WHERE key = ?').get(key);
  return row ? JSON.parse(row.value) : SECRET_SETTINGS[key];
}

export function setSecretSetting(key, value) {
  if (!(key in SECRET_SETTINGS)) throw new Error(`unknown secret setting ${key}`);
  db.prepare(
    `INSERT INTO settings (key, value) VALUES (?, ?)
     ON CONFLICT (key) DO UPDATE SET value = excluded.value`,
  ).run(key, JSON.stringify(value));
}

export function updateSettings(patch) {
  const known = new Set(Object.keys(DEFAULT_SETTINGS));
  const upsert = db.prepare(
    `INSERT INTO settings (key, value) VALUES (?, ?)
     ON CONFLICT (key) DO UPDATE SET value = excluded.value`,
  );
  const applied = {};
  for (const [key, value] of Object.entries(patch)) {
    if (!known.has(key)) continue;
    const allowed = SETTING_ENUMS[key];
    if (allowed && !allowed.includes(value)) continue;
    upsert.run(key, JSON.stringify(value));
    applied[key] = value;
  }
  return applied;
}

export function toPhotoDto(row) {
  return {
    id: row.id,
    photoId: row.photo_id,
    url: `/photos/${row.filename}`,
    thumbUrl: `/thumbnails/${row.thumb_filename}`,
    width: row.width,
    height: row.height,
    sizeBytes: row.size_bytes,
    status: row.status,
    capturedAt: row.captured_at,
    acceptedAt: row.accepted_at,
  };
}

export const statements = {
  insertPhoto: db.prepare(`
    INSERT INTO photos
      (photo_id, filename, thumb_filename, width, height, size_bytes,
       status, captured_at)
    VALUES (?, ?, ?, ?, ?, ?, 'pending', ?)
  `),
  photoById: db.prepare('SELECT * FROM photos WHERE id = ?'),
  acceptPhoto: db.prepare(`
    UPDATE photos SET status = 'accepted', accepted_at = ?
    WHERE id = ? AND status = 'pending'
  `),
  discardPhoto: db.prepare(`
    UPDATE photos SET status = 'discarded'
    WHERE id = ? AND status = 'pending'
  `),
  gallery: db.prepare(`
    SELECT * FROM photos WHERE status = 'accepted'
    ORDER BY captured_at DESC LIMIT ? OFFSET ?
  `),
  galleryCount: db.prepare(
    "SELECT COUNT(*) AS n FROM photos WHERE status = 'accepted'",
  ),
  latest: db.prepare(`
    SELECT * FROM photos WHERE status = 'accepted'
    ORDER BY captured_at DESC LIMIT 1
  `),
  stalePending: db.prepare(`
    SELECT * FROM photos WHERE status = 'pending' AND captured_at < ?
  `),
  allPhotos: db.prepare(`
    SELECT * FROM photos ORDER BY captured_at DESC LIMIT ? OFFSET ?
  `),
  photoCounts: db.prepare(`
    SELECT status, COUNT(*) AS n FROM photos GROUP BY status
  `),
  removeAccepted: db.prepare(`
    UPDATE photos SET status = 'discarded'
    WHERE id = ? AND status = 'accepted'
  `),
};
