import { createServer } from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { APIError, validateRequest } from './contract.mjs';
import { analyzeWithGemini, demoAnswer } from './gemini.mjs';
import { Budget } from './budget.mjs';

function integer(value, fallback, max) {
  const number = value === undefined ? fallback : Number(value);
  if (!Number.isInteger(number) || number < 1 || number > max) throw new Error('Invalid numeric server setting.');
  return number;
}

export function loadConfig(env = process.env) {
  const mode = env.AI_MODE ?? 'mock';
  if (!['mock', 'gemini'].includes(mode)) throw new Error('AI_MODE must be mock or gemini.');
  const model = env.GEMINI_MODEL ?? 'gemini-3.8-flash';
  if (!['gemini-3.8-flash', 'gemini-3.5-flash-lite'].includes(model)) throw new Error('Select a supported Gemini Flash model.');
  const config = {
    mode, model, apiKey: env.GEMINI_API_KEY ?? '', appToken: env.APP_TOKEN ?? '',
    port: integer(env.PORT, 8787, 65535), host: env.HOST ?? '127.0.0.1',
    maxRequests: integer(env.MAX_LIVE_REQUESTS, 50, 1000),
    requestsPerMinute: integer(env.REQUESTS_PER_MINUTE, 10, 60),
    maxOutputTokens: integer(env.MAX_OUTPUT_TOKENS, 2048, 4096),
    budgetPath: env.BUDGET_FILE ?? fileURLToPath(new URL('../.data/allowance.json', import.meta.url)),
  };
  if (mode === 'gemini' && (!config.apiKey || config.appToken.length < 16)) {
    throw new Error('Gemini mode requires GEMINI_API_KEY and an APP_TOKEN of at least 16 characters.');
  }
  return config;
}

function authorized(request, token) {
  if (!token) return true; // Credential-free mock mode only; live startup rejects empty tokens.
  const provided = Buffer.from(request.headers.authorization ?? '');
  const expected = Buffer.from(`Bearer ${token}`);
  return provided.length === expected.length && timingSafeEqual(provided, expected);
}

async function readJSON(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let length = 0;
    let oversized = false;
    request.on('data', (chunk) => {
      if (oversized) return;
      length += chunk.length;
      if (length > 2_200_000) {
        oversized = true;
        chunks.length = 0;
        reject(new APIError(413, 'request_too_large', 'Image request is too large.'));
      } else { chunks.push(chunk); }
    });
    request.on('error', reject);
    request.on('end', () => {
      if (oversized) return;
      try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); } catch {
        reject(new APIError(400, 'invalid_json', 'Expected a JSON request body.'));
      }
    });
  });
}

export function createApp(config, { analyze = analyzeWithGemini, budget = new Budget(config.budgetPath, config.maxRequests) } = {}) {
  let recent = [];
  const server = createServer(async (request, response) => {
    const send = (status, data) => {
      if (response.destroyed) return;
      response.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
      response.end(JSON.stringify(data));
    };
    try {
      if (request.method === 'GET' && request.url === '/health') {
        return send(200, { status: 'ok', mode: config.mode });
      }
      if (request.method !== 'POST' || request.url !== '/analyze') {
        throw new APIError(404, 'not_found', 'Endpoint not found.');
      }
      if (!authorized(request, config.appToken)) throw new APIError(401, 'unauthorized', 'Check the connection token in Settings.');
      if (!request.headers['content-type']?.startsWith('application/json')) throw new APIError(415, 'invalid_content_type', 'Use application/json.');
      const now = Date.now();
      recent = recent.filter((time) => now - time < 60_000);
      if (recent.length >= config.requestsPerMinute) throw new APIError(429, 'rate_limited', 'Please wait before asking another question.');
      recent.push(now);
      const input = validateRequest(await readJSON(request));
      if (config.mode === 'gemini') budget.reserve();
      const result = config.mode === 'gemini' ? await analyze(input, config) : demoAnswer(input);
      return send(200, { frameId: input.frameId, mode: config.mode, ...result });
    } catch (error) {
      if (error instanceof APIError && error.code === 'provider_error') console.error(error.message);
      if (error instanceof APIError) return send(error.status, { error: { code: error.code, message: error.message } });
      console.error('Request failed:', error?.name ?? 'UnknownError');
      send(500, { error: { code: 'internal_error', message: 'The backend could not process this request.' } });
    }
  });
  server.requestTimeout = 25_000;
  server.headersTimeout = 10_000;
  return server;
}
