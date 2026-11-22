import { createServer } from 'node:http';
import { timingSafeEqual, randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { APIError, validateRequest } from './contract.mjs';
import { analyzeWithGemini, demoAnswer } from './gemini.mjs';
import { TaskSessions } from './task-session.mjs';
import { runAgent } from './agent.mjs';
import { checkStepWithGemini, demoCheck, validateCheckRequest } from './step-check.mjs';
import { speakWithGemini, ttsModels, ttsVoices, validateSpeakRequest } from './tts.mjs';
import { demoToolsScan, scanToolsWithGemini, validateToolsRequest } from './tools.mjs';
import { ANALYSIS_TIMEOUT_MS } from './timeouts.mjs';
import { redactDiagnostic } from './diagnostics.mjs';

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
    invalid_action: "I couldn't interpret the AI's response. Please ask your question again.",
    invalid_task_state: "I couldn't update the task details. Please ask your question again.",
    invalid_model_output: "The AI returned an unreadable answer. Please ask again.",
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
  // Stronger model for explanations (walkthroughs); "same" uses GEMINI_MODEL for everything.
  const explainModel = (env.EXPLAIN_MODEL ?? 'gemini-3.8-flash') === 'same' ? null : (env.EXPLAIN_MODEL ?? 'gemini-3.8-flash');
  if (explainModel && !['gemini-3.8-flash', 'gemini-3.5-flash-lite'].includes(explainModel)) throw new Error('EXPLAIN_MODEL must be gemini-3.8-flash, gemini-3.5-flash-lite or same.');
  const config = {
    mode, model, explainModel, apiKey: env.GEMINI_API_KEY ?? '', appToken: env.APP_TOKEN ?? '',
    port: integer(env.PORT, 8787, 65535), host: env.HOST ?? '127.0.0.1',
    maxOutputTokens: integer(env.MAX_OUTPUT_TOKENS, 2048, 4096),
    diagnosticLogPath: fileURLToPath(new URL('../.data/provider-errors.jsonl', import.meta.url)),
    webResearchEnabled: env.ENABLE_WEB_RESEARCH !== 'false',
    serperApiKey: env.SERPER_API_KEY?.trim() ?? '',
    ttsEnabled: env.ENABLE_GEMINI_VOICE !== 'false',
    ttsModel: env.GEMINI_TTS_MODEL ?? 'gemini-3.8-flash-lite-tts',
    ttsVoice: env.GEMINI_TTS_VOICE ?? 'Kore',
    serperCountry: env.SERPER_COUNTRY ?? 'ca',
    serperLanguage: env.SERPER_LANGUAGE ?? 'en',
    maxResearchSteps: integer(env.MAX_RESEARCH_STEPS, 2, 2),
  };
  if (!ttsModels.includes(config.ttsModel)) throw new Error(`GEMINI_TTS_MODEL must be one of: ${ttsModels.join(', ')}.`);
  if (!ttsVoices.includes(config.ttsVoice)) throw new Error('GEMINI_TTS_VOICE must be a Gemini prebuilt voice name, for example Kore.');
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
  analyze = analyzeWithGemini, agent = runAgent, check = checkStepWithGemini, speak = speakWithGemini, scanTools = scanToolsWithGemini,
  sessions = new TaskSessions(),
} = {}) {
  const server = createServer(async (request, response) => {
    const started = Date.now();
    const trace = { requestId: randomUUID().slice(0, 8), calls: 0, searchCalls: 0 };
    const controller = new AbortController();
    const deadline = setTimeout(() => controller.abort(), ANALYSIS_TIMEOUT_MS);
    response.on('finish', () => clearTimeout(deadline));
    const route = ['/analyze', '/check', '/speak', '/tools', '/health'].includes(request.url) ? request.url : '/other';
    console.log(`[${new Date().toISOString()}] Request received: ${route} [${trace.requestId}]`);
    response.on('close', () => {
      clearTimeout(deadline);
      if (!response.writableFinished) {
        controller.abort();
        console.warn(`Request disconnected: ${route} after ${Date.now() - started}ms`);
      }
    });
    const send = (status, data) => {
      const circle = data.error || route === '/speak' || route === '/tools' ? '' : data.target ? ` circle="${String(data.target.label).slice(0, 60)}"` : ' circle=none';
      const step = data.status ? ` step=${data.status}` : '';
      const beats = Array.isArray(data.annotations) && data.annotations.length ? data.annotations : null;
      const walkthrough = beats ? ` walkthrough=${beats.length} steps (paths=${beats.filter((b) => b.path).length}`
        + ` boxes=${beats.filter((b) => b.box).length} labels=${beats.filter((b) => b.label).length}`
        + ` arrows=${beats.filter((b) => b.to).length} zoom=${beats.filter((b) => b.zoom).length}`
        + ` shaded=${beats.filter((b) => b.region).length})` : (route === '/analyze' && !data.error ? ' walkthrough=none' : '');
      console.log(`Request completed: ${route} [${trace.requestId}] googleCalls=${trace.calls} serperSearches=${trace.searchCalls} HTTP ${status} ${data.error?.code ?? 'ok'}${step}${circle}${walkthrough} (${Date.now() - started}ms)`);
      if (response.destroyed) return;
      response.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
      response.end(JSON.stringify(data));
    };
    try {
      if (request.method === 'GET' && request.url === '/health') {
        return send(200, { status: 'ok', mode: config.mode });
      }
      if (request.method !== 'POST' || !['/analyze', '/check', '/speak', '/tools'].includes(request.url)) {
        throw new APIError(404, 'not_found', 'Endpoint not found.');
      }
      if (!authorized(request, config.appToken)) throw new APIError(401, 'unauthorized', 'Check the connection token in Settings.');
      if (!request.headers['content-type']?.startsWith('application/json')) throw new APIError(415, 'invalid_content_type', 'Use application/json.');
      if (request.url === '/speak') {
        const input = validateSpeakRequest(await readJSON(request), config.ttsVoice);
        // Mock mode has no cloud voice: the phone falls back to its own voice.
        if (config.mode !== 'gemini' || !config.ttsEnabled) return send(200, { mode: config.mode, audio: null });
        try {
          const result = await speak(input, { ...config, signal: controller.signal, trace });
          return send(200, { mode: config.mode, voice: input.voice, ...result });
        } catch (error) {
          // Out of voice quota: answer at once so the phone uses its own voice without waiting.
          if (error?.quota) return send(200, { mode: config.mode, audio: null, reason: 'voice_quota' });
          throw error;
        }
      }
      if (request.url === '/tools') {
        const input = validateToolsRequest(await readJSON(request));
        const result = config.mode === 'gemini'
          ? await scanTools(input, { ...config, signal: controller.signal, trace })
          : demoToolsScan(input);
        return send(200, { mode: config.mode, ...result });
      }
      if (request.url === '/check') {
        const input = validateCheckRequest(await readJSON(request));
        const result = config.mode === 'gemini'
          ? await check(input, { ...config, signal: controller.signal, trace })
          : demoCheck(input);
        return send(200, { stepId: input.stepId, mode: config.mode, ...result });
      }
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
      if (error instanceof APIError) {
        // Fixed validation messages, not model replies, query text or images.
        const detail = redactDiagnostic({ code: error.code, reason: error.message },
          [config.apiKey, config.appToken, config.serperApiKey]);
        console.warn(`[${trace.requestId}] Request rejected: ${JSON.stringify(detail)}`);
        const message = userErrorMessage(error);
        return send(error.status, { error: { code: error.code, message, userMessage: message } });
      }
      console.error('Request failed:', error?.name ?? 'UnknownError');
      send(500, { error: { code: 'internal_error', message: "I couldn't finish that request. Please try again.", userMessage: "I couldn't finish that request. Please try again." } });
    }
  });
  // This limits receiving the upload; ANALYSIS_TIMEOUT_MS bounds processing.
  server.requestTimeout = 55_000;
  server.headersTimeout = 10_000;
  return server;
}
