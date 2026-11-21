import { createServer } from 'node:http';
import { timingSafeEqual, randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { APIError, validateRequest } from './contract.mjs';
import { analyzeWithGemini, demoAnswer } from './gemini.mjs';
import { TaskSessions } from './task-session.mjs';
import { runAgent } from './agent.mjs';

// Developer diagnostics stay in logs; these short messages are safe to read aloud.
function userErrorMessage(error) {
  if (error.userMessage) return error.userMessage;
  const messages = {
    unauthorized: "I couldn't connect. Please check the app's connection settings.",
    provider_unavailable: 'The AI service is taking too long to respond. Please try again.',
    request_timeout: 'That took too long. Please try again.',
    source_unavailable: "I couldn't open that document. Please try another source.",
    search_unverified: "I couldn't find a useful source. Could you give me a little more detail?",
    tool_limit: "I couldn't finish researching that. Try a more specific question.",
    task_expired: "I've lost the previous task context. Please ask your question again.",
    research_expired: 'That research session expired. Please ask your question again.',
    task_changed: 'The task changed. Please ask your question again.',
    fresh_frame_required: 'Please show me the object again.',
    task_busy: "I'm still working on your previous question. Please wait a moment.",
    tasks_busy: "I'm busy right now. Please try again in a moment.",
    invalid_request: "I couldn't use that camera view or question. Please try again.",
    request_too_large: "I couldn't use that camera view. Please try showing it again.",
  };
  return messages[error.code] ?? "I couldn't finish that request. Please try again.";
}

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
    maxOutputTokens: integer(env.MAX_OUTPUT_TOKENS, 2048, 4096),
    diagnosticLogPath: fileURLToPath(new URL('../.data/provider-errors.jsonl', import.meta.url)),
    webResearchEnabled: env.ENABLE_WEB_RESEARCH !== 'false',
    serperApiKey: env.SERPER_API_KEY?.trim() ?? '',
    serperCountry: env.SERPER_COUNTRY ?? 'ca',
    serperLanguage: env.SERPER_LANGUAGE ?? 'en',
    maxResearchSteps: integer(env.MAX_RESEARCH_STEPS, 2, 2),
  };
  if (!/^[a-z]{2}$/.test(config.serperCountry) || !/^[a-z]{2}(-[a-zA-Z]{2})?$/.test(config.serperLanguage)) {
    throw new Error('Use a two-letter SERPER_COUNTRY and a valid SERPER_LANGUAGE code.');
  }
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

export function createApp(config, {
  analyze = analyzeWithGemini, agent = runAgent,
  sessions = new TaskSessions(),
} = {}) {
  const server = createServer(async (request, response) => {
    const started = Date.now();
    const trace = { requestId: randomUUID().slice(0, 8), calls: 0, searchCalls: 0 };
    const controller = new AbortController();
    const deadline = setTimeout(() => controller.abort(), 45_000);
    response.on('finish', () => clearTimeout(deadline));
    const route = request.url === '/analyze' ? '/analyze' : request.url === '/health' ? '/health' : '/other';
    console.log(`[${new Date().toISOString()}] Request received: ${route} [${trace.requestId}]`);
    response.on('close', () => {
      clearTimeout(deadline);
      if (!response.writableFinished) {
        controller.abort();
        console.warn(`Request disconnected: ${route} after ${Date.now() - started}ms`);
      }
    });
    const send = (status, data) => {
      console.log(`Request completed: ${route} [${trace.requestId}] googleCalls=${trace.calls} serperSearches=${trace.searchCalls} HTTP ${status} ${data.error?.code ?? 'ok'} (${Date.now() - started}ms)`);
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
      const input = validateRequest(await readJSON(request));
      let result;
      if (config.mode === 'gemini') {
        const callConfig = { ...config, signal: controller.signal, trace };
        if (input.sessionId) {
          result = await sessions.run(input, async (session) => {
            const result = await agent(input, callConfig, session);
            controller.signal.throwIfAborted();
            return result;
          });
        } else {
          result = await analyze(input, callConfig);
        }
      } else { result = demoAnswer(input); }
      return send(200, { frameId: input.frameId, mode: config.mode, ...result });
    } catch (error) {
      if (controller.signal.aborted) {
        return send(504, { error: { code: 'request_timeout', message: 'That took too long. Please try again.', userMessage: 'That took too long. Please try again.' } });
      }
      if (error instanceof APIError && error.code === 'provider_error') console.error(error.message);
      if (error instanceof APIError) {
        const message = userErrorMessage(error);
        return send(error.status, { error: { code: error.code, message, userMessage: message } });
      }
      console.error('Request failed:', error?.name ?? 'UnknownError');
      send(500, { error: { code: 'internal_error', message: "I couldn't finish that request. Please try again.", userMessage: "I couldn't finish that request. Please try again." } });
    }
  });
  server.requestTimeout = 55_000;
  server.headersTimeout = 10_000;
  return server;
}
