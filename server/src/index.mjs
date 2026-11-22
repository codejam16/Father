import { createApp, loadConfig } from './server.mjs';

try {
  const config = loadConfig();
  const server = createApp(config);
  server.listen(config.port, config.host, () => {
    console.log(`TaskLens backend: http://${config.host}:${config.port} (${config.mode})`);
    if (config.mode === 'gemini') {
      console.log(`Google model: ${config.model}`);
      console.log(`Reasoning policy: ${config.thinkingLevel.toLowerCase()} (auto uses minimal for basic Flash-Lite questions).`);
      console.log(`Simple locating: ${config.quickLocateMode} (fast sends one medium-detail image; detailed keeps the configured image detail and close-up).`);
      console.log(`Google error log: ${config.diagnosticLogPath}`);
      console.log(config.webResearchEnabled && config.serperApiKey
        ? 'Web search: Serper (one search request per search action).'
        : 'Web search is off or not configured. Set SERPER_API_KEY in server/.env to enable it. Camera questions still work.');
    }
    console.log(config.mode === 'mock' ? 'Demo replies only; no AI API requests.' : 'Google enforces API quotas; no local request allowance or rate limit. Quota/auth errors are not retried; transient busy errors use bounded retries.');
  });
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
