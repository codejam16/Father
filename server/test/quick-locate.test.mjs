import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { validateRequest } from '../src/contract.mjs';
import { emptyMemory, TaskSessions } from '../src/task-session.mjs';
import { buildAgentBody, runAgent } from '../src/agent.mjs';
import { canQuickLocate, buildQuickLocateBody } from '../src/quick-locate.mjs';

const config = { model: 'test-model', maxOutputTokens: 2048, apiKey: 'fake-key' };
const request = (extra = {}) => validateRequest({
  sessionId: randomUUID(), frameId: randomUUID(), capturedAt: new Date().toISOString(),
  task: '', question: 'Find the girl', image: { mimeType: 'image/jpeg', width: 480, height: 640,
    base64: Buffer.from([255, 216, 255, 217]).toString('base64') },
  researchEnabled: false, includeWebInfo: false, ...extra,
});
const session = (extra = {}) => ({ memory: emptyMemory(), sources: [], reports: [], pending: null, ...extra });
const answer = (extra = {}) => ({ answer: 'The girl is on the left.', targetLabel: 'Girl on the left',
  box: [100, 100, 900, 400], needsClearerView: false, ...extra });
function transport(result) {
  const calls = [];
  return { calls, fetcher: async (url, options) => {
    calls.push({ url, body: JSON.parse(options.body) });
    assert.match(url, /generateContent$/); // Never a search, document or voice request.
    return { ok: true, json: async () => ({ candidates: [{ finishReason: 'STOP',
      content: { parts: [{ text: JSON.stringify(result) }] } }],
      usageMetadata: { promptTokenCount: 20, candidatesTokenCount: 15 } }) };
  } };
}

test('short explicit location questions qualify without depending on an existing conversation', () => {
  for (const question of ['Find the girl', 'Where is my bottle?', 'Where’s the blue bag?',
    'Can you please find the girl in the red shirt?', 'Show me the chair', 'Locate my backpack.']) {
    assert.equal(canQuickLocate(request({ question }), session()), true, question);
  }
});

test('research, pronouns, multiple tasks and precise controls retain the full assistant', () => {
  for (const question of ['Find links to the MacBook Air M2', 'Find a bottle to buy',
    'Where can I buy it?', 'Find it', 'Find the other bottle', 'Find the girl and explain her outfit',
    'Find all bottles', 'Find the cap', 'Where is the push button?', 'Show me the circuit',
    'Find the best water bottle', 'Find details about the Mac', 'Where is Montreal?',
    'How do I open the bottle?', 'Hello']) {
    assert.equal(canQuickLocate(request({ question }), session()), false, question);
  }
  for (const extra of [{ includeWebInfo: true }, { researchEnabled: true }, { continuationId: randomUUID() },
    { selection: [100, 100, 900, 900] }, { pointedAt: [[200, 300]] }]) {
    assert.equal(canQuickLocate(request(extra), session()), false, JSON.stringify(extra));
  }
  const original = request();
  const detail = { ...original.image, box: [100, 100, 800, 800] };
  assert.equal(canQuickLocate(request({ detailImage: detail }), session()), false);
  assert.equal(canQuickLocate(original, session({ memory: { ...emptyMemory(),
    plan: [{ id: 'step1', text: 'Open the lid', completed: false }] } })), false);
});

test('a location request keeps the original image detail but removes unrelated response work', () => {
  const input = request({ history: Array.from({ length: 8 }, (_, i) => ({ role: i % 2 ? 'assistant' : 'user', content: `turn ${i}` })) });
  const body = buildQuickLocateBody(input, config.maxOutputTokens);
  const normal = buildAgentBody(input, config, session(), false);
  const parts = body.contents.at(-1).parts;
  assert.deepEqual(parts[1], normal.contents.at(-1).parts[1]);
  assert.equal(body.generationConfig.mediaResolution, normal.generationConfig.mediaResolution);
  assert.equal(body.generationConfig.thinkingConfig.thinkingLevel, normal.generationConfig.thinkingConfig.thinkingLevel);
  assert.equal(body.generationConfig.maxOutputTokens, 768);
  assert.equal(buildQuickLocateBody(input, 400).generationConfig.maxOutputTokens, 400);
  assert.deepEqual(JSON.parse(parts[0].text).history, input.history.slice(-2));
  assert.equal('annotations' in body.generationConfig.responseJsonSchema.properties, false);
  assert.equal('toolsNeeded' in body.generationConfig.responseJsonSchema.properties, false);
  assert.equal('memory' in body.generationConfig.responseJsonSchema.properties, false);
});

test('the real agent routes a quick locate through one provider call and preserves task memory', async () => {
  const input = request();
  const memory = { goal: 'Identify objects', facts: ['Established fact'], openQuestions: [],
    plan: [{ id: 'past', text: 'An earlier finished step', completed: true }] };
  const state = session({ memory });
  const io = transport(answer({ toolsNeeded: [{ name: 'Unrequested tool' }], memory: emptyMemory(),
    action: 'search_online', sourceIds: ['invented'], annotations: [{ caption: 'Unrequested diagram' }] }));
  const result = await runAgent(input, config, state, io.fetcher);
  assert.equal(io.calls.length, 1);
  assert.deepEqual(result.target, { label: 'Girl on the left', box: [100, 100, 900, 400] });
  assert.deepEqual(result.taskMemory, memory);
  assert.deepEqual(state.memory, memory);
  assert.deepEqual(result.annotations, []);
  assert.deepEqual(result.toolsNeeded, []);
  assert.deepEqual(result.sourceIds, []);
  assert.equal(result.webInfo, null);
  assert.equal(result.continuationId, null);
  assert.equal(result.action, 'respond');
});

test('uncertain or ambiguous quick results do not create speculative pointers', async () => {
  for (const extra of [{ needsClearerView: true }, { box: null, targetLabel: null, answer: 'Which girl do you mean?' }]) {
    const io = transport(answer(extra));
    const result = await runAgent(request(), config, session(), io.fetcher);
    assert.equal(result.target, null);
    assert.equal(io.calls.length, 1);
  }
});

test('invalid quick coordinates fail without a repair call or committing invented memory', async () => {
  const input = request(), sessions = new TaskSessions();
  const io = transport(answer({ box: [900, 100, 100, 400], memory: { goal: 'invented' } }));
  await assert.rejects(sessions.run(input, (state) => runAgent(input, config, state, io.fetcher)), /invalid target position/);
  assert.equal(io.calls.length, 1);
  assert.deepEqual(sessions.entries.get(input.sessionId).memory, emptyMemory());
});

test('Info-on requests still reach the existing full assistant with research permission', async () => {
  const input = request({ includeWebInfo: true, researchEnabled: true });
  const io = transport({ ...answer(), action: 'respond', argument: null, sourceIds: [], memory: emptyMemory() });
  await runAgent(input, { ...config, serperApiKey: 'fake-serper' }, session(), io.fetcher);
  const body = io.calls[0].body;
  assert.equal(JSON.parse(body.contents.at(-1).parts[0].text).researchAllowed, true);
  assert.ok(body.generationConfig.responseJsonSchema.properties.action.enum.includes('search_online'));
  assert.equal(io.calls.length, 1);
});
