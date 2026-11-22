import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createApp, loadConfig } from '../src/server.mjs';
import { buildToolsBody, mergeScan, scanToolsWithGemini, validateTools, validateToolsRequest } from '../src/tools.mjs';
import { buildAgentBody } from '../src/agent.mjs';
import { validateRequest } from '../src/contract.mjs';
import { emptyMemory } from '../src/task-session.mjs';

const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0xff, 0xd9]).toString('base64');
const image = { base64: jpeg, mimeType: 'image/jpeg', width: 480, height: 640 };
const config = (extra = {}) => ({ ...loadConfig({}), diagnosticLogPath: null, diagnosticLogger: () => {}, retryDelayMs: 0, ...extra });

test('tool lists are cleaned: short names, no duplicates, at most eight, visible only when true', () => {
  const items = validateTools([
    { name: ' Phillips  screwdriver ', visible: true }, { name: 'phillips screwdriver', visible: false },
    { name: '', visible: true }, { name: 'x'.repeat(61), visible: true }, { name: 'Spudger', visible: 'yes' },
    ...Array.from({ length: 10 }, (_, i) => ({ name: `Part ${i}`, visible: false })),
  ]);
  assert.deepEqual(items[0], { name: 'Phillips screwdriver', visible: true });
  assert.deepEqual(items[1], { name: 'Spudger', visible: false });
  assert.equal(items.length, 8);
  assert.deepEqual(validateTools(undefined), []);
});

test('guided requests ask for a tools list only when steps start', () => {
  const request = validateRequest({ frameId: 'f', capturedAt: new Date().toISOString(), question: 'How do I replace the fan?', task: '',
    image, sessionId: '11111111-1111-4111-8111-111111111111', guided: true });
  const body = buildAgentBody(request, config(), { memory: emptyMemory(), sources: [], reports: [] }, false);
  assert.ok(body.generationConfig.responseJsonSchema.required.includes('toolsNeeded'));
  assert.ok(body.systemInstruction.parts.some((part) => /toolsNeeded/.test(part.text)));
});

test('a tool scan keeps the phone list and only takes visibility from the model', async () => {
  const merged = mergeScan(['Phillips screwdriver', 'Spudger'], [{ name: 'phillips screwdriver', visible: true }, { name: 'Hammer', visible: true }], ' Spudger is missing. ');
  assert.deepEqual(merged, { items: [{ name: 'Phillips screwdriver', visible: true }, { name: 'Spudger', visible: false }], note: 'Spudger is missing.' });
  const input = validateToolsRequest({ items: ['Phillips screwdriver'], goal: 'Replace fan', image });
  assert.equal(buildToolsBody(input, 2048).contents[0].parts.filter((part) => part.inlineData).length, 1);
  assert.throws(() => validateToolsRequest({ items: [], image }));
  const result = await scanToolsWithGemini(input, config(), async () => ({ ok: true, json: async () => ({ candidates: [{ finishReason: 'STOP',
    content: { parts: [{ text: JSON.stringify({ items: [{ name: 'Phillips screwdriver', visible: true }], note: null }) }] } }] }) }));
  assert.equal(result.items[0].visible, true);
});

test('mock mode answers tool scans without contacting the provider', async (t) => {
  const server = createApp(config(), { scanTools: () => { throw new Error('Must not contact provider'); } });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise((resolve) => { server.close(resolve); server.closeAllConnections(); }));
  const response = await fetch(`http://127.0.0.1:${server.address().port}/tools`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ items: ['Spudger'], image }),
  });
  assert.equal(response.status, 200);
  assert.equal((await response.json()).items[0].visible, true);
});
