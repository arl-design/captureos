// Size-rotated file logger (reliability requirement: "Rotate logs automatically").
// Keeps captureos-backend.log plus .1/.2 rotations under data/logs.

import fs from 'node:fs';
import path from 'node:path';

import { config } from './config.js';

const LOG_DIR = path.join(config.dataRoot, 'logs');
const LOG_FILE = path.join(LOG_DIR, 'backend.log');
const MAX_BYTES = 1024 * 1024;
const KEEP = 2;

fs.mkdirSync(LOG_DIR, { recursive: true });

function rotateIfNeeded() {
  try {
    if (fs.statSync(LOG_FILE).size < MAX_BYTES) return;
  } catch {
    return; // no log yet
  }
  for (let i = KEEP; i >= 1; i--) {
    const from = i === 1 ? LOG_FILE : `${LOG_FILE}.${i - 1}`;
    fs.rmSync(`${LOG_FILE}.${i}`, { force: true });
    try {
      fs.renameSync(from, `${LOG_FILE}.${i}`);
    } catch {
      // nothing to rotate at this level
    }
  }
}

function write(level, message, extra) {
  rotateIfNeeded();
  const line = JSON.stringify({
    ts: new Date().toISOString(),
    level,
    msg: message,
    ...(extra ?? {}),
  });
  try {
    fs.appendFileSync(LOG_FILE, line + '\n');
  } catch {
    // never let logging take the service down
  }
  if (level === 'error') console.error(line);
}

export const log = {
  info: (msg, extra) => write('info', msg, extra),
  warn: (msg, extra) => write('warn', msg, extra),
  error: (msg, extra) => write('error', msg, extra),
  file: LOG_FILE,
  dir: LOG_DIR,
};

/** Express middleware: one log line per completed request. */
export function requestLogger(req, res, next) {
  const start = Date.now();
  res.on('finish', () => {
    // Health checks and static photo fetches would drown the log.
    if (req.path === '/health' || req.path.startsWith('/photos')
      || req.path.startsWith('/thumbnails')) return;
    log.info('request', {
      method: req.method,
      path: req.path,
      status: res.statusCode,
      ms: Date.now() - start,
    });
  });
  next();
}

/** Read the last `lines` lines of a log file (with its rotations). */
export function tailLog(file, lines = 200) {
  const chunks = [];
  for (const candidate of [`${file}.1`, file]) {
    try {
      chunks.push(fs.readFileSync(candidate, 'utf8'));
    } catch {
      // rotation may not exist
    }
  }
  const all = chunks.join('').split('\n').filter(Boolean);
  return all.slice(-lines);
}
