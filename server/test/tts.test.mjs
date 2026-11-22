import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createApp, loadConfig } from '../src/server.mjs';
import { buildSpeakBody, extractAudio, resetVoiceState, speakWithGemini, validateSpeakRequest } from '../src/tts.mjs';

const config = (extra = {}) => ({ ...loadConfig({}), diagnosticLogPath: null, diagnosticLogger: () => {}, ...extra });

function wav(samples, sampleRate = 24000) {
  const data = Buffer.alloc(samples.length * 2);
  samples.forEach((value, index) => data.writeInt16LE(value, index * 2));
  const header = Buffer.alloc(44);
  header.write('RIFF', 0); header.writeUInt32LE(36 + data.length, 4); header.write('WAVE', 8);
  header.write('fmt ', 12); header.writeUInt32LE(16, 16); header.writeUInt16LE(1, 20); header.writeUInt16LE(1, 22);
  header.writeUInt32LE(sampleRate, 24); header.writeUInt32LE(sampleRate * 2, 28); header.writeUInt16LE(2, 32); header.writeUInt16LE(16, 34);
  header.write('data', 36); header.writeUInt32LE(data.length, 40);
  return Buffer.concat([header, data]);
}

const audioPayload = (bytes) => ({ steps: [{ type: 'model_output', content: [{ type: 'audio', data: bytes.toString('base64') }] }] });

test('speak requests are validated and unknown voices fall back to the default', () => {
  assert.deepEqual(validateSpeakRequest({ text: ' Hello there. ', voice: 'Aoede' }), { text: 'Hello there.', voice: 'Aoede' });
  assert.equal(validateSpeakRequest({ text: 'Hi', voice: 'NotAVoice' }, 'Kore').voice, 'Kore');
  assert.throws(() => validateSpeakRequest({ text: '' }));
  assert.throws(() => validateSpeakRequest({ text: 'x'.repeat(2001) }));
});

test('speech bodies ask for a natural, friendly delivery in the chosen voice', () => {
  const body = buildSpeakBody({ text: 'Turn the screw left.', voice: 'Puck' }, 'gemini-3.8-flash-lite-tts');
  assert.equal(body.model, 'gemini-3.8-flash-lite-tts');
  assert.equal(body.input[0].content[0].text, 'Turn the screw left.');
  assert.match(body.input[0].content[0].annotations[0].style, /warm, friendly/);
  assert.deepEqual(body.generation_config.speech_config, [{ voice: 'Puck' }]);
});

test('audio is extracted from WAV (with its sample rate) and from raw PCM', () => {
  const fromWav = extractAudio(audioPayload(wav([1, -2, 3], 22050)));
  assert.equal(fromWav.sampleRate, 22050);
  assert.equal(fromWav.pcm.length, 6);
  assert.equal(fromWav.pcm.readInt16LE(2), -2);
  const raw = extractAudio(audioPayload(Buffer.from([1, 0, 2, 0])));
  assert.equal(raw.sampleRate, 24000);
  assert.equal(extractAudio({ steps: [] }), null);
});

test('gemini voice returns base64 PCM, and mock mode tells the phone to use its own voice', async (t) => {
  resetVoiceState();
  let request;
  const result = await speakWithGemini({ text: 'Hi', voice: 'Kore' }, config({ apiKey: 'k' }), async (url, options) => {
    request = { url, body: JSON.parse(options.body) };
    return { ok: true, status: 200, json: async () => audioPayload(wav([5, 6])) };
  });
  assert.equal(request.url, 'https://generativelanguage.googleapis.com/v1beta/interactions');
  assert.equal(result.sampleRate, 24000);
  assert.equal(Buffer.from(result.audio, 'base64').length, 4);

  const server = createApp(config(), { speak: () => { throw new Error('Must not contact provider'); } });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise((resolve) => { server.close(resolve); server.closeAllConnections(); }));
  const response = await fetch(`http://127.0.0.1:${server.address().port}/speak`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ text: 'Hello' }),
  });
  assert.equal(response.status, 200);
  assert.equal((await response.json()).audio, null);
});

test('voice settings are checked at startup', () => {
  assert.equal(loadConfig({}).ttsModel, 'gemini-3.8-flash-lite-tts');
  assert.throws(() => loadConfig({ GEMINI_TTS_MODEL: 'gemini-1-tts' }), /GEMINI_TTS_MODEL/);
  assert.throws(() => loadConfig({ GEMINI_TTS_VOICE: 'Robot' }), /GEMINI_TTS_VOICE/);
});

test('voice quota: repeats are cached, an exhausted model is skipped, the other model is tried', async () => {
  resetVoiceState();
  const calls = [];
  const limited = (model) => ({ ok: false, status: 429, headers: { get: (name) => (name === 'retry-after' ? '3600' : null) },
    json: async () => ({ error: { message: `Rate limit exceeded for model ${model}` } }) });
  const ok = { ok: true, status: 200, json: async () => audioPayload(wav([1, 2])) };
  const fetcher = async (url, options) => {
    const model = JSON.parse(options.body).model;
    calls.push(model);
    return model === 'gemini-3.8-flash-lite-tts' ? limited(model) : ok;
  };
  const settings = config({ apiKey: 'k' });
  const first = await speakWithGemini({ text: 'Hello', voice: 'Kore' }, settings, fetcher);
  assert.deepEqual(calls, ['gemini-3.8-flash-lite-tts', 'gemini-3.8-flash-tts']);
  assert.ok(first.audio);
  const again = await speakWithGemini({ text: 'Hello', voice: 'Kore' }, settings, fetcher);
  assert.equal(again.cached, true);
  assert.equal(calls.length, 2);
  await speakWithGemini({ text: 'Next line', voice: 'Kore' }, settings, fetcher);
  assert.deepEqual(calls.slice(2), ['gemini-3.8-flash-tts']);

  resetVoiceState();
  const allLimited = async (url, options) => limited(JSON.parse(options.body).model);
  await assert.rejects(speakWithGemini({ text: 'Hi', voice: 'Kore' }, settings, allLimited), (error) => error.quota === true);
});
