import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));

export const config = {
  port: Number(process.env.PORT ?? 3000),
  cameraServiceUrl: process.env.CAMERA_SERVICE_URL ?? 'http://127.0.0.1:5000',
  dataRoot: process.env.CAPTUREOS_DATA ?? path.resolve(here, '../../data'),
  // Pending photos the user never accepted or retook are swept after this.
  pendingTtlMs: Number(process.env.PENDING_TTL_MS ?? 5 * 60 * 1000),
};

export const paths = {
  db: path.join(config.dataRoot, 'captureos.sqlite'),
  photos: path.join(config.dataRoot, 'photos'),
  thumbnails: path.join(config.dataRoot, 'thumbnails'),
};
