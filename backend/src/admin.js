// Admin API (admin console): PIN-protected administration, diagnostics,
// configuration backups, photo management, and log access.
//
// Auth model, sized for a LAN kiosk appliance: the operator logs in with a
// PIN (a secret setting, default 1234) and receives a random bearer token
// held in memory for 8 hours. Login attempts are rate limited. Production
// nginx additionally restricts /api/admin to private-network addresses.

import { randomBytes, timingSafeEqual } from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { backup } from 'node:sqlite';

import express from 'express';

import { cameraHealth } from './camera.js';
import { config, paths } from './config.js';
import {
  db,
  getSecretSetting,
  getSettings,
  setSecretSetting,
  statements,
  toPhotoDto,
  updateSettings,
} from './db.js';
import { broadcast } from './events.js';
import { log, tailLog } from './logger.js';

const TOKEN_TTL_MS = 8 * 60 * 60 * 1000;
const MAX_ATTEMPTS = 5;
const LOCKOUT_MS = 30_000;
const KEEP_BACKUPS = 10;

const BACKUPS_DIR = path.join(config.dataRoot, 'backups');
const startedAt = Date.now();

const tokens = new Map(); // token -> expiry epoch ms
let failedAttempts = 0;
let lockedUntil = 0;

function safeEqual(a, b) {
  const ba = Buffer.from(String(a));
  const bb = Buffer.from(String(b));
  return ba.length === bb.length && timingSafeEqual(ba, bb);
}

function requireAuth(req, res, next) {
  const token = (req.headers.authorization ?? '').replace(/^Bearer\s+/i, '');
  const expiry = tokens.get(token);
  if (!expiry || expiry < Date.now()) {
    tokens.delete(token);
    res.status(401).json({ error: 'admin authentication required' });
    return;
  }
  next();
}

export function createAdminRouter() {
  const router = express.Router();

  router.post('/login', (req, res) => {
    if (Date.now() < lockedUntil) {
      res.status(429).json({
        error: 'too many attempts — try again shortly',
        retryAfterMs: lockedUntil - Date.now(),
      });
      return;
    }
    const pin = String(req.body?.pin ?? '');
    if (!safeEqual(pin, getSecretSetting('admin_pin'))) {
      failedAttempts += 1;
      if (failedAttempts >= MAX_ATTEMPTS) {
        lockedUntil = Date.now() + LOCKOUT_MS;
        failedAttempts = 0;
        log.warn('admin login locked out');
      }
      res.status(401).json({ error: 'incorrect PIN' });
      return;
    }
    failedAttempts = 0;
    const token = randomBytes(24).toString('hex');
    tokens.set(token, Date.now() + TOKEN_TTL_MS);
    log.info('admin login');
    res.json({ token, expiresInMs: TOKEN_TTL_MS });
  });

  router.use(requireAuth);

  router.get('/diagnostics', async (req, res) => {
    const counts = { pending: 0, accepted: 0, discarded: 0 };
    for (const { status, n } of statements.photoCounts.all()) counts[status] = n;

    let disk = null;
    try {
      const s = await fsp.statfs(config.dataRoot);
      disk = {
        totalBytes: s.blocks * s.bsize,
        freeBytes: s.bavail * s.bsize,
      };
    } catch {
      // statfs unsupported — leave null
    }

    let dbBytes = 0;
    try {
      dbBytes = fs.statSync(paths.db).size;
    } catch {
      // fresh instance
    }

    res.json({
      camera: await cameraHealth(),
      photos: counts,
      disk,
      database: { path: paths.db, sizeBytes: dbBytes },
      uptimeSeconds: Math.floor((Date.now() - startedAt) / 1000),
      node: process.version,
      memoryRss: process.memoryUsage.rss(),
    });
  });

  router.get('/photos', (req, res) => {
    const limit = Math.min(Number(req.query.limit) || 200, 1000);
    const offset = Math.max(Number(req.query.offset) || 0, 0);
    res.json({ photos: statements.allPhotos.all(limit, offset).map(toPhotoDto) });
  });

  router.delete('/photos/:id', async (req, res) => {
    const id = Number(req.params.id);
    const photo = statements.photoById.get(id);
    if (!photo) {
      res.status(404).json({ error: `photo ${id} not found` });
      return;
    }
    if (photo.status === 'accepted') statements.removeAccepted.run(id);
    else statements.discardPhoto.run(id);
    for (const file of [
      path.join(paths.photos, photo.filename),
      path.join(paths.thumbnails, photo.thumb_filename),
    ]) {
      await fsp.rm(file, { force: true });
    }
    broadcast('photo.removed', { id });
    log.info('photo deleted by admin', { id });
    res.json({ ok: true, id });
  });

  // Admin settings: same whitelist as the public endpoint, plus PIN change.
  router.get('/settings', (req, res) => res.json(getSettings()));

  router.post('/settings', (req, res) => {
    const applied = updateSettings(req.body ?? {});
    broadcast('settings.updated', applied);
    res.json(getSettings());
  });

  router.post('/pin', (req, res) => {
    const pin = String(req.body?.pin ?? '');
    if (!/^\d{4,8}$/.test(pin)) {
      res.status(400).json({ error: 'PIN must be 4-8 digits' });
      return;
    }
    setSecretSetting('admin_pin', pin);
    log.info('admin PIN changed');
    res.json({ ok: true });
  });

  router.post('/backup', async (req, res) => {
    fs.mkdirSync(BACKUPS_DIR, { recursive: true });
    const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
    const filename = `captureos-${stamp}.sqlite`;
    try {
      await backup(db, path.join(BACKUPS_DIR, filename));
    } catch (err) {
      log.error('backup failed', { error: String(err) });
      res.status(500).json({ error: `backup failed: ${err.message}` });
      return;
    }
    // Prune oldest beyond KEEP_BACKUPS.
    const all = fs.readdirSync(BACKUPS_DIR).filter((f) => f.endsWith('.sqlite')).sort();
    for (const stale of all.slice(0, Math.max(all.length - KEEP_BACKUPS, 0))) {
      fs.rmSync(path.join(BACKUPS_DIR, stale), { force: true });
    }
    log.info('backup created', { filename });
    res.status(201).json({ ok: true, filename });
  });

  router.get('/backups', (req, res) => {
    let files = [];
    try {
      files = fs
        .readdirSync(BACKUPS_DIR)
        .filter((f) => f.endsWith('.sqlite'))
        .sort()
        .reverse()
        .map((f) => ({
          filename: f,
          sizeBytes: fs.statSync(path.join(BACKUPS_DIR, f)).size,
        }));
    } catch {
      // no backups yet
    }
    res.json({ backups: files });
  });

  router.get('/backups/:file', (req, res) => {
    const file = path.basename(req.params.file); // no traversal
    const full = path.join(BACKUPS_DIR, file);
    if (!file.endsWith('.sqlite') || !fs.existsSync(full)) {
      res.status(404).json({ error: 'backup not found' });
      return;
    }
    res.download(full);
  });

  router.get('/logs', (req, res) => {
    const lines = Math.min(Number(req.query.lines) || 200, 1000);
    res.json({
      backend: tailLog(log.file, lines),
      camera: tailLog(path.join(log.dir, 'camera.log'), lines),
    });
  });

  return router;
}
