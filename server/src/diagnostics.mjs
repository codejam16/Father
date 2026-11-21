import { appendFileSync, chmodSync, existsSync, mkdirSync, renameSync, statSync } from 'node:fs';
import { dirname } from 'node:path';

export function redactDiagnostic(value, secrets = []) {
  const redactText = (value) => {
    let text = value;
    for (const secret of secrets.filter((secret) => typeof secret === 'string' && secret.length > 0)) {
      text = text.replaceAll(secret, '[REDACTED]').replaceAll(encodeURIComponent(secret), '[REDACTED]');
    }
    return text.replace(/AIza[A-Za-z0-9_-]{20,}/g, '[REDACTED]')
      .replace(/Bearer\s+[A-Za-z0-9._~+\/-]+/gi, 'Bearer [REDACTED]');
  };
  const visit = (value) => {
    if (typeof value === 'string') return redactText(value);
    if (Array.isArray(value)) return value.map(visit);
    if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, item]) => [
      key, /^(api[-_]?key|key|x-goog-api-key|x-api-key|serper[-_]?api[-_]?key|authorization|app[-_]?token|access[-_]?token|password|token)$/i.test(key)
        ? '[REDACTED]' : visit(item),
    ]));
    return value;
  };
  return visit(value);
}

export function logGoogleError(event, config = {}) {
  const safe = redactDiagnostic(event, [config.apiKey, config.appToken, config.serperApiKey]);
  if (config.diagnosticLogger) { config.diagnosticLogger(safe); return; }
  console.error('GOOGLE ERROR — original response (credentials redacted):\n' + JSON.stringify(safe, null, 2));
  if (!config.diagnosticLogPath) return;
  try {
    const path = config.diagnosticLogPath;
    mkdirSync(dirname(path), { recursive: true });
    // One small backup; diagnostics must not grow without bound.
    if (existsSync(path) && statSync(path).size >= 1_000_000) renameSync(path, `${path}.1`);
    appendFileSync(path, JSON.stringify(safe) + '\n', { mode: 0o600 });
    chmodSync(path, 0o600);
  } catch {
    console.warn('Could not save Google error diagnostics; the error is printed above.');
  }
}
