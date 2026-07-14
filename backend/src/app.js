import fsSync from 'node:fs';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import express from 'express';

import { createAdminRouter } from './admin.js';
import { CameraError, cameraHealth, proxyPreview, requestCapture } from './camera.js';
import { config, paths } from './config.js';
import { getSettings, statements, toPhotoDto, updateSettings } from './db.js';
import { broadcast, sseHandler } from './events.js';
import { log, requestLogger } from './logger.js';

export function createApp() {
  const app = express();
  app.use(express.json());
  app.use(requestLogger);

  // All API routes live on one router mounted at both / and /api:
  // production nginx proxies /api/* here with the prefix stripped (so /
  // is hit), while portable mode (no nginx — the desktop launcher) has
  // the browser call /api/* on this server directly.
  const api = express.Router();
  api.use('/admin', createAdminRouter());

  // In production nginx serves these directly; Express covers dev and
  // portable mode.
  app.use('/photos', express.static(paths.photos, { immutable: true, maxAge: '1y' }));
  app.use('/thumbnails', express.static(paths.thumbnails, { immutable: true, maxAge: '1y' }));

  api.get('/health', async (req, res) => {
    res.json({ ok: true, service: 'captureos-backend', camera: await cameraHealth() });
  });

  api.get('/gallery', (req, res) => {
    const limit = Math.min(Number(req.query.limit) || 100, 500);
    const offset = Math.max(Number(req.query.offset) || 0, 0);
    const rows = statements.gallery.all(limit, offset);
    const { n: total } = statements.galleryCount.get();
    res.json({ total, photos: rows.map(toPhotoDto) });
  });

  api.get('/latest', (req, res) => {
    const row = statements.latest.get();
    if (!row) {
      res.status(404).json({ error: 'no photos yet' });
      return;
    }
    res.json(toPhotoDto(row));
  });

  api.get('/preview', proxyPreview);
  api.get('/events', sseHandler);

  api.post('/capture', async (req, res) => {
    const settings = getSettings();
    let capture;
    try {
      capture = await requestCapture({
        max_width: settings.max_width,
        thumb_width: settings.thumb_width,
        quality: settings.jpeg_quality,
      });
    } catch (err) {
      if (err instanceof CameraError) {
        res.status(err.status).json({ error: err.message });
        return;
      }
      throw err;
    }
    const { lastInsertRowid } = statements.insertPhoto.run(
      capture.photo_id,
      capture.filename,
      capture.thumb_filename,
      capture.width,
      capture.height,
      capture.size_bytes,
      capture.captured_at,
    );
    const photo = toPhotoDto(statements.photoById.get(lastInsertRowid));
    log.info('photo captured', { id: photo.id });
    res.status(201).json(photo);
  });

  api.post('/accept', (req, res) => {
    const photo = requirePendingPhoto(req, res);
    if (!photo) return;
    statements.acceptPhoto.run(new Date().toISOString(), photo.id);
    const accepted = toPhotoDto(statements.photoById.get(photo.id));
    broadcast('photo.accepted', accepted);
    res.json(accepted);
  });

  api.post('/retake', async (req, res) => {
    const photo = requirePendingPhoto(req, res);
    if (!photo) return;
    statements.discardPhoto.run(photo.id);
    await deletePhotoFiles(photo);
    res.json({ ok: true, id: photo.id });
  });

  api.get('/settings', (req, res) => {
    res.json(getSettings());
  });

  api.post('/settings', (req, res) => {
    if (typeof req.body !== 'object' || req.body === null || Array.isArray(req.body)) {
      res.status(400).json({ error: 'expected a JSON object of settings' });
      return;
    }
    const applied = updateSettings(req.body);
    broadcast('settings.updated', applied);
    res.json(getSettings());
  });

  app.use('/api', api);
  app.use('/', api);

  // Portable mode: serve the built frontend ourselves when it exists,
  // so the whole booth runs on this one port without nginx.
  const dist = path.resolve(
    path.dirname(fileURLToPath(import.meta.url)),
    '../../frontend/dist',
  );
  if (fsSync.existsSync(dist)) {
    app.use(express.static(dist));
  }

  return app;
}

function requirePendingPhoto(req, res) {
  const id = Number(req.body?.id);
  if (!Number.isInteger(id)) {
    res.status(400).json({ error: 'body must include a numeric photo id' });
    return null;
  }
  const photo = statements.photoById.get(id);
  if (!photo) {
    res.status(404).json({ error: `photo ${id} not found` });
    return null;
  }
  if (photo.status !== 'pending') {
    res.status(409).json({ error: `photo ${id} is already ${photo.status}` });
    return null;
  }
  return photo;
}

async function deletePhotoFiles(photo) {
  for (const file of [
    path.join(paths.photos, photo.filename),
    path.join(paths.thumbnails, photo.thumb_filename),
  ]) {
    await fs.rm(file, { force: true });
  }
}

// Sweep pending photos the user abandoned (walked away mid-review).
export function sweepStalePending() {
  const cutoff = new Date(Date.now() - config.pendingTtlMs).toISOString();
  for (const photo of statements.stalePending.all(cutoff)) {
    statements.discardPhoto.run(photo.id);
    deletePhotoFiles(photo).catch(() => {});
  }
}
