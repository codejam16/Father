import { createApp, loadConfig } from './server.mjs';

try {
  const config = loadConfig();
  const server = createApp(config);
  server.listen(config.port, config.host, () => {
    console.log(`TaskLens backend: http://${config.host}:${config.port} (${config.mode})`);
    console.log(config.mode === 'mock' ? 'Demo replies only; no AI API requests.' : `Persistent request allowance: ${config.maxRequests}. No automatic provider retries.`);
  });
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
