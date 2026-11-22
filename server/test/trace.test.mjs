import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createApp, loadConfig } from '../src/server.mjs';
import { buildTraceBody, traceWithGemini, validateTrace, validateTraceRequest } from '../src/trace.mjs';

const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0xff, 0xd9]).toString('base64');
const image = { base64: jpeg, mimeType: 'image/jpeg', width: 480, height: 640 };
const config = (extra = {}) => ({ ...loadConfig({}), diagnosticLogPath: null, diagnosticLogger: () => {}, retryDelayMs: 0, ...extra });
const rough = [[750, 200], [650, 600], [300, 700]];

test('trace requests need a crop and a rough route of [y, x] points', () => {
  const input = validateTraceRequest({ image, rough, what: 'From A to B', question: 'How do I go from A to B?' });
  assert.deepEqual(input.rough, rough);
  assert.throws(() => validateTraceRequest({ image, rough: [[10, 10]] }));
  assert.throws(() => validateTraceRequest({ image, rough: [[10, 1200], [5, 5]] }));
  const body = buildTraceBody(input, 4096);
  assert.match(body.systemInstruction.parts[0].text, /EXISTING drawn line/);
  assert.match(body.systemInstruction.parts[0].text, /one point at EVERY corner/);
  const sent = JSON.parse(body.contents[0].parts[0].text);
  assert.deepEqual(sent.start, [750, 200]);
  assert.deepEqual(sent.end, [300, 700]);
});

test('traced routes are kept only when they are valid points', () => {
  assert.deepEqual(validateTrace({ found: true, points: [750, 200, 760, 640, 420, 480, 470, 720, 300, 700] }),
    [[750, 200], [760, 640], [420, 480], [470, 720], [300, 700]]);
  assert.equal(validateTrace({ found: false, points: [] }), null);
  assert.equal(validateTrace({ found: true, points: [1, 2, 3] }), null);
  assert.equal(validateTrace({ found: true, points: [1, 2, 3, 2000] }), null);
});

test('tracing asks the explanation model and returns its route', async () => {
  const models = [];
  const result = await traceWithGemini(validateTraceRequest({ image, rough }), config({ apiKey: 'k', mode: 'gemini' }), async (url) => {
    models.push(String(url).match(/models\/([^:]+)/)[1]);
    return { ok: true, json: async () => ({ candidates: [{ finishReason: 'STOP',
      content: { parts: [{ text: JSON.stringify({ found: true, points: [750, 200, 760, 640, 300, 700] }) }] } }] }) };
  });
  assert.deepEqual(result.path, [[750, 200], [760, 640], [300, 700]]);
  assert.equal(models[0], 'gemini-3.8-flash');
});

test('mock mode keeps the rough route without contacting the provider', async (t) => {
  const server = createApp(config(), { traceRoute: () => { throw new Error('Must not contact provider'); } });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise((resolve) => { server.close(resolve); server.closeAllConnections(); }));
  const response = await fetch(`http://127.0.0.1:${server.address().port}/trace`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ image, rough }),
  });
  assert.equal(response.status, 200);
  assert.deepEqual((await response.json()).path, rough);
});
