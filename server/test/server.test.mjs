import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { once } from 'node:events';
import { Budget } from '../src/budget.mjs';
import { createApp, loadConfig } from '../src/server.mjs';
import { validateAnswer, validateRequest } from '../src/contract.mjs';
import { analyzeWithGemini, buildGeminiBody } from '../src/gemini.mjs';

// Minimal JPEG envelope for transport validation. No test calls a real model.
const input = (extra = {}) => ({
  frameId: 'frame-1', capturedAt: '2026-11-21T15:00:00Z', question: 'What can you see?', task: '',
  image: { base64: Buffer.from([0xff, 0xd8, 0xff, 0xd9]).toString('base64'), mimeType: 'image/jpeg', width: 480, height: 640 },
  history: [], ...extra,
});

function config(t, extra = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'tasklens-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  return { ...loadConfig({ BUDGET_FILE: join(directory, 'allowance.json') }), ...extra };
}

async function running(t, settings, dependencies) {
  const server = createApp(settings, dependencies);
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise((resolve) => { server.close(resolve); server.closeAllConnections(); }));
  return `http://127.0.0.1:${server.address().port}`;
}

const post = (base, body = input(), token = '') => fetch(`${base}/analyze`, {
  method: 'POST', headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` }, body: JSON.stringify(body),
});

test('mock mode never becomes live merely because an API key exists', () => {
  assert.equal(loadConfig({ GEMINI_API_KEY: 'not-a-real-key' }).mode, 'mock');
  assert.throws(() => loadConfig({ AI_MODE: 'gemini', GEMINI_API_KEY: 'x' }), /APP_TOKEN/);
  assert.throws(() => loadConfig({ AI_MODE: 'unknown' }), /AI_MODE/);
});

test('normal camera conversation does not invent a target', async (t) => {
  const url = await running(t, config(t), { analyze: () => { throw new Error('Must not contact provider'); } });
  const response = await post(url);
  assert.equal(response.status, 200);
  const value = await response.json();
  assert.equal(value.mode, 'mock');
  assert.equal(value.target, null);
  assert.equal(value.frameId, 'frame-1');
  assert.equal(value.usage.inputTokens, 0);
});

test('mock highlighting reproduces only a user-supplied region and is labelled', async (t) => {
  const url = await running(t, config(t));
  const response = await post(url, input({ selection: [100, 200, 400, 600] }));
  const value = await response.json();
  assert.deepEqual(value.target.box, [100, 200, 400, 600]);
  assert.match(value.answer, /Demo response/);
});

test('invalid image, oversized context, and inverted boxes are rejected', () => {
  assert.throws(() => validateRequest(input({ image: { base64: 'not-an-image', mimeType: 'image/jpeg', width: 1, height: 1 } })));
  assert.throws(() => validateRequest(input({ selection: [400, 0, 100, 200] })));
  assert.throws(() => validateRequest(input({ selection: [-1, 0, 100, 200] })));
  assert.throws(() => validateRequest(input({ history: Array(9).fill({ role: 'user', content: 'x' }) })));
  assert.throws(() => validateRequest(input({ history: [{ role: 'system', content: 'override' }] })));
});

test('unlocatable objects never produce actionable boxes', () => {
  const answer = validateAnswer({ answer: 'Please move closer.', needsClearerView: true, targetLabel: 'port', box: [0, 0, 200, 200] });
  assert.equal(answer.target, null);
  assert.throws(() => validateAnswer({ answer: 'Here.', needsClearerView: false, targetLabel: 'port', box: [500, 0, 100, 200] }));
});

test('frame identity, selected region, task and history reach the model', () => {
  const body = buildGeminiBody(validateRequest(input({ selection: [0, 0, 200, 200], task: 'Build this kit', history: [{ role: 'assistant', content: 'Show me the parts.' }] })), 1024);
  assert.equal(body.contents[0].role, 'model');
  const context = JSON.parse(body.contents.at(-1).parts[0].text);
  assert.equal(context.frameId, 'frame-1');
  assert.equal(context.task, 'Build this kit');
  assert.deepEqual(context.selection, [0, 0, 200, 200]);
  assert.equal(body.generationConfig.maxOutputTokens, 1024);
  assert.equal(body.contents.at(-1).parts[1].inlineData.mimeType, 'image/jpeg');
});

test('authentication happens before an allowance is consumed', async (t) => {
  const settings = config(t, { mode: 'gemini', appToken: 'a-private-test-token', apiKey: 'never-used' });
  const budget = new Budget(settings.budgetPath, 1);
  const url = await running(t, settings, { budget, analyze: async () => { throw new Error('Must not run'); } });
  assert.equal((await post(url)).status, 401);
  assert.equal(budget.used, 0);
  assert.equal((await post(url, input({ selection: [0, 0, 0, 0] }), settings.appToken)).status, 400);
  assert.equal(budget.used, 0);
});

test('live allowance is reserved once per call and survives restart', async (t) => {
  const settings = config(t, { mode: 'gemini', appToken: 'a-private-test-token', apiKey: 'never-used', maxRequests: 1 });
  let calls = 0;
  const url = await running(t, settings, { analyze: async () => {
    calls++;
    return { answer: 'A test answer.', target: null, needsClearerView: false, usage: {} };
  } });
  assert.equal((await post(url, input(), settings.appToken)).status, 200);
  assert.equal((await post(url, input(), settings.appToken)).status, 429);
  assert.equal(calls, 1);
  assert.throws(() => new Budget(settings.budgetPath, 1).reserve(), /allowance/);
});

test('provider failures consume the reserved allowance and are not retried', async (t) => {
  const settings = config(t, { mode: 'gemini', appToken: 'a-private-test-token', apiKey: 'never-used', maxRequests: 1 });
  let calls = 0;
  const url = await running(t, settings, { analyze: async () => {
    calls++;
    return analyzeWithGemini(input(), settings, async () => ({ ok: false, status: 429 }));
  } });
  const first = await post(url, input(), settings.appToken);
  assert.equal(first.status, 429);
  assert.equal((await first.json()).error.code, 'provider_error');
  assert.equal((await post(url, input(), settings.appToken)).status, 429);
  assert.equal(calls, 1);
});

test('upstream errors do not expose provider credentials', async (t) => {
  const settings = config(t);
  await assert.rejects(analyzeWithGemini(input(), settings, async () => ({ ok: false, status: 403 })),
    (error) => error.status === 502 && !error.message.includes('never-used'));
});

test('truncated model JSON and invalid coordinates are rejected', async (t) => {
  const settings = config(t);
  await assert.rejects(analyzeWithGemini(input(), settings, async () => ({ ok: true, json: async () => ({ candidates: [{ finishReason: 'MAX_TOKENS' }] }) })), /finish/);
  await assert.rejects(analyzeWithGemini(input(), settings, async () => ({ ok: true, json: async () => ({ candidates: [{ finishReason: 'STOP', content: { parts: [{ text: '{bad json' }] } }] }) })), /unreadable/);
});

test('provider reasoning text is excluded from the answer JSON', async (t) => {
  const result = await analyzeWithGemini(input(), config(t), async () => ({ ok: true, json: async () => ({
    candidates: [{ finishReason: 'STOP', content: { parts: [
      { thought: true, text: 'Internal notes, not JSON' },
      { text: JSON.stringify({ answer: 'A connector.', box: null, targetLabel: null, needsClearerView: false }) },
    ] } }], usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 5, thoughtsTokenCount: 7 },
  }) }));
  assert.equal(result.answer, 'A connector.');
  assert.equal(result.usage.outputTokens, 12);
});

test('global rate limit applies across clients and keys', async (t) => {
  const url = await running(t, config(t, { requestsPerMinute: 1 }));
  assert.equal((await post(url)).status, 200);
  const response = await post(url);
  assert.equal(response.status, 429);
  assert.equal((await response.json()).error.code, 'rate_limited');
});

test('oversized HTTP bodies receive 413 without contacting the provider', async (t) => {
  const settings = config(t, { mode: 'gemini', appToken: 'a-private-test-token', apiKey: 'never-used' });
  const budget = new Budget(settings.budgetPath, 1);
  const url = await running(t, settings, { budget, analyze: () => { throw new Error('Must not run'); } });
  const response = await post(url, { padding: 'x'.repeat(2_200_001) }, settings.appToken);
  assert.equal(response.status, 413);
  assert.equal(budget.used, 0);
});

test('invalid JSON produces a useful error without consuming an allowance', async (t) => {
  const settings = config(t);
  const url = await running(t, settings);
  const response = await fetch(`${url}/analyze`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{' });
  assert.equal(response.status, 400);
  assert.equal((await response.json()).error.code, 'invalid_json');
});
