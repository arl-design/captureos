import { config } from './config.js';

export class CameraError extends Error {
  constructor(message, status = 502) {
    super(message);
    this.status = status;
  }
}

export async function cameraHealth() {
  try {
    const res = await fetch(`${config.cameraServiceUrl}/health`, {
      signal: AbortSignal.timeout(2000),
    });
    return await res.json();
  } catch {
    return { ok: false, camera: 'disconnected' };
  }
}

export async function requestCapture(options) {
  let res;
  try {
    res = await fetch(`${config.cameraServiceUrl}/capture`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(options),
      signal: AbortSignal.timeout(15_000),
    });
  } catch (err) {
    throw new CameraError(`camera service unreachable: ${err.message}`, 503);
  }
  const body = await res.json().catch(() => ({}));
  if (!res.ok || !body.ok) {
    throw new CameraError(body.error ?? `camera capture failed (${res.status})`);
  }
  return body;
}

// Pipe the MJPEG preview stream through to the client.
export async function proxyPreview(req, res) {
  let upstream;
  try {
    // Only abort when the browser disconnects — a timeout signal would
    // also cut the long-lived stream itself.
    upstream = await fetch(`${config.cameraServiceUrl}/preview`, {
      signal: abortOnClose(req),
    });
  } catch {
    res.status(503).json({ error: 'camera preview unavailable' });
    return;
  }
  res.status(upstream.status);
  res.set('Content-Type', upstream.headers.get('content-type') ?? 'image/jpeg');
  res.set('Cache-Control', 'no-store');
  try {
    for await (const chunk of upstream.body) {
      res.write(chunk);
    }
  } catch {
    // client or camera went away — nothing to do
  }
  res.end();
}

function abortOnClose(req) {
  const controller = new AbortController();
  req.on('close', () => controller.abort());
  return controller.signal;
}
