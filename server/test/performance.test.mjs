import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { loadConfig } from '../src/server.mjs';
import { validateRequest } from '../src/contract.mjs';
import { emptyMemory } from '../src/task-session.mjs';
import { runAgent } from '../src/agent.mjs';
import { buildGeminiBody, generateContent, modelFor, thinkingLevelFor } from '../src/gemini.mjs';

const config = (extra = {}) => ({ ...loadConfig({ GEMINI_MODEL: 'gemini-3.5-flash-lite' }),
  apiKey: 'fake', diagnosticLogPath: null, ...extra });
const input = (question) => validateRequest({ frameId: 'test', capturedAt: new Date().toISOString(),
  question, history: [], task: '', sessionId: randomUUID(), researchEnabled: false, includeWebInfo: false,
  image: { mimeType: 'image/jpeg', width: 480, height: 640,
    base64: Buffer.from([255, 216, 255, 217]).toString('base64') } });
const state = (memory = emptyMemory()) => ({ memory, sources: [], reports: [], pending: null });
function transport(memory = emptyMemory()) {
  const calls = [];
  return { calls, fetcher: async (url, options) => {
    calls.push({ url, body: JSON.parse(options.body) });
    assert.match(url, /generateContent$/);
    return { ok: true, json: async () => ({ candidates: [{ finishReason: 'STOP', content: { parts: [{
      text: JSON.stringify({ answer: 'Here is the answer.', targetLabel: null, box: null, needsClearerView: false,
        annotations: [], action: 'respond', argument: null, sourceIds: [], memory, userCompletedStepIds: [], toolsNeeded: [] }),
    }] } }], usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 20, thoughtsTokenCount: 2 } }) };
  } };
}

test('full ordinary camera replies use minimal on Flash-Lite without removing image detail', async () => {
  for (const question of ['What am I looking at?', 'What color is this?', 'Hello']) {
    const request = input(question), io = transport();
    await runAgent(request, config(), state(), io.fetcher);
    assert.equal(io.calls.length, 1);
    const posted = io.calls[0].body;
    assert.equal(posted.generationConfig.thinkingConfig.thinkingLevel, 'MINIMAL');
    const original = buildGeminiBody(request, 2048);
    assert.equal(posted.generationConfig.mediaResolution, original.generationConfig.mediaResolution);
  }
});

test('repairs, explanations, fine controls and active guided steps retain low reasoning', async () => {
  for (const question of ['How do I open the bottle?', 'Explain this circuit', 'Why is it leaking?', 'Where is the release button?']) {
    const io = transport();
    await runAgent(input(question), config(), state(), io.fetcher);
    assert.equal(io.calls[0].body.generationConfig.thinkingConfig.thinkingLevel, 'LOW', question);
  }
  const memory = { ...emptyMemory(), plan: [{ id: 's1', text: 'Open the lid', completed: false }] };
  const io = transport(memory);
  await runAgent({ ...input('Done'), guided: true }, config(), state(memory), io.fetcher);
  assert.equal(io.calls[0].body.generationConfig.thinkingConfig.thinkingLevel, 'LOW');
});

test('inactive guided plans do not increase reasoning on ordinary questions', async () => {
  const memory = { ...emptyMemory(), plan: [{ id: 's1', text: 'Open the lid', completed: false }] };
  const io = transport(memory);
  await runAgent({ ...input('What color is this?'), guided: false }, config(), state(memory), io.fetcher);
  assert.equal(io.calls[0].body.generationConfig.thinkingConfig.thinkingLevel, 'MINIMAL');
});

test('model selection never sends unsupported minimal reasoning to the stronger model', async () => {
  const settings = config({ explainModel: 'gemini-3.8-flash' });
  assert.equal(modelFor(input('Hello'), settings).thinkingLevel, 'MINIMAL');
  const selected = modelFor(input('Explain this circuit'), settings);
  assert.equal(selected.model, 'gemini-3.8-flash');
  assert.equal(selected.thinkingLevel, 'LOW');
  const io = transport();
  await generateContent(buildGeminiBody(input('Hello'), 2048), config({ model: 'gemini-3.8-flash', thinkingLevel: 'MINIMAL' }), io.fetcher);
  assert.equal(io.calls[0].body.generationConfig.thinkingConfig.thinkingLevel, 'LOW');
  assert.equal(io.calls.length, 1);
});

test('thinking configuration validates overrides and can restore the prior low setting', async () => {
  assert.equal(loadConfig({}).thinkingLevel, 'AUTO');
  assert.equal(loadConfig({ GEMINI_THINKING_LEVEL: ' low ' }).thinkingLevel, 'LOW');
  assert.throws(() => loadConfig({ GEMINI_THINKING_LEVEL: 'fastest' }), /GEMINI_THINKING_LEVEL/);
  for (const level of ['LOW', 'MEDIUM', 'HIGH']) {
    const io = transport();
    await runAgent(input('Where is the bottle?'), config({ thinkingLevel: level }), state(), io.fetcher);
    assert.equal(io.calls[0].body.generationConfig.thinkingConfig.thinkingLevel, level);
  }
  assert.equal(thinkingLevelFor(undefined, config()), 'LOW'); // Unknown/direct document operations retain their existing policy.
});

test('per-request reasoning does not mutate shared bodies or contaminate later calls', async () => {
  const body = buildGeminiBody(input('Hello'), 2048), io = transport();
  const original = structuredClone(body);
  await generateContent(body, config({ thinkingLevel: 'MINIMAL' }), io.fetcher);
  await generateContent(body, config({ thinkingLevel: 'LOW' }), io.fetcher);
  assert.deepEqual(body, original);
  assert.deepEqual(io.calls.map((call) => call.body.generationConfig.thinkingConfig.thinkingLevel), ['MINIMAL', 'LOW']);
});
