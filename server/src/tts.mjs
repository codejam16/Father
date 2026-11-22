import { APIError } from './contract.mjs';
import { geminiHTTPError } from './provider-error.mjs';

/// Gemini's prebuilt speech voices.
export const ttsVoices = ['Zephyr', 'Puck', 'Charon', 'Kore', 'Fenrir', 'Leda', 'Orus', 'Aoede', 'Callirrhoe', 'Autonoe',
  'Enceladus', 'Iapetus', 'Umbriel', 'Algieba', 'Despina', 'Erinome', 'Algenib', 'Rasalgethi', 'Laomedeia', 'Achernar',
  'Alnilam', 'Schedar', 'Gacrux', 'Pulcherrima', 'Achird', 'Zubenelgenubi', 'Vindemiatrix', 'Sadachbia', 'Sadaltager', 'Sulafat'];
export const ttsModels = ['gemini-3.8-flash-lite-tts', 'gemini-3.8-flash-tts'];

export const speakingStyle = 'Speak like a warm, friendly person helping a friend in the same room: relaxed conversational pace, natural intonation and small pauses, never like an announcer or a robot.';

export function validateSpeakRequest(value, defaultVoice = 'Kore') {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new APIError(400, 'invalid_request', 'Expected a JSON object.');
  if (typeof value.text !== 'string' || !value.text.trim() || value.text.length > 2000) {
    throw new APIError(400, 'invalid_request', 'text must be 1 to 2000 characters.');
  }
  const voice = ttsVoices.includes(value.voice) ? value.voice : defaultVoice;
  return { text: value.text.trim(), voice };
}

export function buildSpeakBody(input, model) {
  return {
    model,
    input: [{
      type: 'user_input',
      content: [{ type: 'text', text: input.text, annotations: [{ type: 'speech_metadata', style: speakingStyle }] }],
    }],
    response_format: { type: 'audio' },
    generation_config: { speech_config: [{ voice: input.voice }] },
  };
}

/// Audio comes back as base64 WAV (or headerless 16-bit PCM). Returns raw 16-bit mono PCM and its sample rate.
export function extractAudio(payload) {
  const blocks = (Array.isArray(payload?.steps) ? payload.steps : [])
    .filter((step) => step?.type === 'model_output')
    .flatMap((step) => (Array.isArray(step.content) ? step.content : []))
    .filter((item) => item?.type === 'audio' && typeof item.data === 'string');
  const last = blocks.at(-1);
  if (!last) return null;
  const bytes = Buffer.from(last.data, 'base64');
  if (bytes.length < 4) return null;
  if (bytes.toString('ascii', 0, 4) !== 'RIFF') return { pcm: bytes, sampleRate: 24000 };
  // Walk the WAV chunks: read the sample rate from "fmt " and the samples from "data".
  let sampleRate = 24000;
  let offset = 12;
  while (offset + 8 <= bytes.length) {
    const id = bytes.toString('ascii', offset, offset + 4);
    const size = bytes.readUInt32LE(offset + 4);
    if (id === 'fmt ' && offset + 16 <= bytes.length) sampleRate = bytes.readUInt32LE(offset + 12);
    if (id === 'data') return { pcm: bytes.subarray(offset + 8, Math.min(bytes.length, offset + 8 + size)), sampleRate };
    offset += 8 + size + (size % 2);
  }
  return null;
}

// Free-tier speech quotas are small (for example 10 requests per day per model), so:
// identical lines are reused, an exhausted model is skipped until Google says it resets, and the
// other voice model is tried before giving up. When both are used up, the phone falls back to its
// own voice immediately instead of waiting for a call that would fail.
const exhaustedUntil = new Map();
const cache = new Map();
const cacheLimit = 100;

export function resetVoiceState() {
  exhaustedUntil.clear();
  cache.clear();
}

function retryAfterMs(response) {
  const header = Number(response.headers?.get?.('retry-after'));
  return Number.isFinite(header) && header > 0 ? header * 1000 : 60 * 60_000;
}

export async function speakWithGemini(input, config, fetcher = fetch) {
  const key = `${input.voice}|${input.text}`;
  if (cache.has(key)) return { ...cache.get(key), cached: true };
  const models = [config.ttsModel, ...ttsModels.filter((model) => model !== config.ttsModel)];
  for (const model of models) {
    if ((exhaustedUntil.get(model) ?? 0) > Date.now()) continue;
    try {
      const result = await speakOnce(input, { ...config, ttsModel: model }, fetcher);
      cache.set(key, result);
      if (cache.size > cacheLimit) cache.delete(cache.keys().next().value);
      return result;
    } catch (error) {
      if (error?.status !== 429 || !error.retryAfterMs) throw error;
      exhaustedUntil.set(model, Date.now() + error.retryAfterMs);
      console.warn(`Gemini voice quota reached for ${model}; skipping it for ${Math.round(error.retryAfterMs / 60_000)} min`);
    }
  }
  throw Object.assign(new APIError(429, 'voice_quota', 'The Gemini voice quota is used up for now.'), { quota: true });
}

async function speakOnce(input, config, fetcher) {
  const timeout = AbortSignal.timeout(20_000);
  const signal = config.signal ? AbortSignal.any([timeout, config.signal]) : timeout;
  const started = Date.now();
  let response;
  try {
    response = await fetcher('https://generativelanguage.googleapis.com/v1beta/interactions', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-goog-api-key': config.apiKey },
      body: JSON.stringify(buildSpeakBody(input, config.ttsModel)),
      signal,
    });
  } catch {
    throw new APIError(504, 'provider_unavailable', 'The voice service did not respond.');
  }
  console.log(`[${config.trace?.requestId ?? 'speak'}] Gemini voice (${config.ttsModel}) HTTP ${response.status} (${Date.now() - started}ms)`);
  if (!response.ok) {
    const wait = response.status === 429 ? retryAfterMs(response) : 0;
    const error = await geminiHTTPError(response, { ...config, model: config.ttsModel }, { operation: 'speech' });
    if (wait) error.retryAfterMs = wait;
    throw error;
  }
  let payload;
  try { payload = await response.json(); } catch {
    throw new APIError(502, 'invalid_model_output', 'The voice service returned an unreadable response.');
  }
  const audio = extractAudio(payload);
  if (!audio || audio.pcm.length < 2) throw new APIError(502, 'invalid_model_output', 'The voice service returned no audio.');
  return { audio: audio.pcm.toString('base64'), sampleRate: audio.sampleRate, encoding: 'pcm_s16le' };
}
