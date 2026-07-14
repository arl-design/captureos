import { createApp, sweepStalePending } from './app.js';
import { config } from './config.js';

const app = createApp();

app.listen(config.port, () => {
  console.log(`CaptureOS backend on :${config.port}`);
  console.log(`  camera service: ${config.cameraServiceUrl}`);
  console.log(`  data root:      ${config.dataRoot}`);
});

setInterval(sweepStalePending, 60_000).unref();
