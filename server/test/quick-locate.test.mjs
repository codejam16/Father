import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { validateRequest } from '../src/contract.mjs';
import { emptyMemory, TaskSessions } from '../src/task-session.mjs';
import { buildAgentBody, runAgent } from '../src/agent.mjs';
import { canQuickLocate, buildQuickLocateBody, quickLocateDecision, quickLocateMode } from '../src/quick-locate.mjs';
import { loadConfig } from '../src/server.mjs';

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
  for (const question of ['Find the girl', 'Where is the bottle', 'wheres the bottle', 'Where is my bottle?', 'Where’s the blue bag?',
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
  for (const extra of [{ continuationId: randomUUID() }]) {
    assert.equal(canQuickLocate(request(extra), session()), false, JSON.stringify(extra));
  }
  const original = request();
  assert.equal(canQuickLocate({ ...original, guided: true }, session({ memory: { ...emptyMemory(),
    plan: [{ id: 'step1', text: 'Open the lid', completed: false }] } })), false);
});

test('detailed locating preserves configured image detail while removing unrelated response work', () => {
  const input = request({ history: Array.from({ length: 8 }, (_, i) => ({ role: i % 2 ? 'assistant' : 'user', content: `turn ${i}` })) });
  const body = buildQuickLocateBody(input, config.maxOutputTokens, { mode: 'detailed' });
  const normal = buildAgentBody(input, config, session(), false);
  const parts = body.contents.at(-1).parts;
  assert.deepEqual(parts[1], normal.contents.at(-1).parts[1]);
  assert.equal(body.generationConfig.mediaResolution, normal.generationConfig.mediaResolution);
  assert.equal(body.generationConfig.thinkingConfig.thinkingLevel, normal.generationConfig.thinkingConfig.thinkingLevel);
  assert.equal(body.generationConfig.maxOutputTokens, 768);
  assert.equal(buildQuickLocateBody(input, 400).generationConfig.maxOutputTokens, 400);
  assert.deepEqual(body.contents.slice(0, -1), normal.contents.slice(-3, -1));
  assert.equal('annotations' in body.generationConfig.responseJsonSchema.properties, false);
  assert.equal('toolsNeeded' in body.generationConfig.responseJsonSchema.properties, false);
  assert.equal('memory' in body.generationConfig.responseJsonSchema.properties, false);
});

test('bottle locating keeps pointing, close-up and selection geometry without falling back to the full agent', async () => {
  const image = request().image;
  const input = request({ question: 'Where is the bottle', pointedAt: [[200, 300]],
    selection: [100, 100, 900, 900], detailImage: { ...image, box: [100, 100, 600, 600] } });
  assert.deepEqual(quickLocateDecision(input, session()), { eligible: true, reason: 'simple_location' });
  const quick = buildQuickLocateBody(input, 2048, { mode: 'detailed' });
  const normal = buildAgentBody(input, config, session(), false);
  assert.deepEqual(quick.contents.at(-1).parts.slice(1), normal.contents.at(-1).parts.slice(1));
  const context = JSON.parse(quick.contents.at(-1).parts[0].text);
  assert.deepEqual(context.selection, input.selection);
  assert.deepEqual(context.pointedAt, input.pointedAt);
  assert.equal(quick.contents.at(-1).parts.filter((part) => part.inlineData).length, 2);
  const io = transport(answer());
  await runAgent(input, config, session(), io.fetcher);
  assert.equal(io.calls.length, 1);
  assert.equal('action' in io.calls[0].body.generationConfig.responseJsonSchema.properties, false);
});

test('full-path diagnostics report gates without exposing the question or image contents', () => {
  const cases = [
    [request({ includeWebInfo: true, history: [{ role: 'user', content: 'Find buying links for this bottle' }] }), session(), 'research_context'],
    [request({ continuationId: randomUUID() }), session(), 'research_continuation'],
    [request({ guided: true }), session({ memory: { ...emptyMemory(), plan: [{ completed: false }] } }), 'unfinished_guided_plan'],
    [request({ question: 'How do I open it?' }), session(), 'question_form'],
    [request({ question: 'Find the cap' }), session(), 'detailed_or_contextual_task'],
  ];
  for (const [input, state, reason] of cases) assert.deepEqual(quickLocateDecision(input, state), { eligible: false, reason });
});

test('fast locating sends one medium-detail image while preserving pointing and primary-image coordinates', async () => {
  const original = request();
  const input = request({ question: 'Where is the bottle?', selection: [100, 100, 900, 900],
    pointedAt: [[200, 300]], detailImage: { ...original.image, box: [100, 100, 600, 600] } });
  const before = structuredClone(input), io = transport(answer());
  await runAgent(input, config, session(), io.fetcher);
  const body = io.calls[0].body, parts = body.contents.at(-1).parts;
  assert.equal(body.generationConfig.mediaResolution, 'MEDIA_RESOLUTION_MEDIUM');
  assert.equal(parts.filter((part) => part.inlineData).length, 1);
  assert.deepEqual(parts.find((part) => part.inlineData).inlineData, { mimeType: input.image.mimeType, data: input.image.base64 });
  const context = JSON.parse(parts[0].text);
  assert.deepEqual(context.selection, input.selection);
  assert.deepEqual(context.pointedAt, input.pointedAt);
  assert.ok(!parts.some((part) => part.text?.startsWith('Second image:')));
  assert.deepEqual(input, before);
  assert.equal(io.calls.length, 1);
});

test('detailed mode restores the extra image without a second generation request', async () => {
  const original = request();
  const input = request({ detailImage: { ...original.image, box: [100, 100, 800, 800] } });
  const io = transport(answer());
  await runAgent(input, { ...config, quickLocateMode: 'detailed' }, session(), io.fetcher);
  const posted = io.calls[0].body;
  assert.equal(posted.contents.at(-1).parts.filter((part) => part.inlineData).length, 2);
  assert.equal(posted.generationConfig.mediaResolution, buildAgentBody(input, config, session(), false).generationConfig.mediaResolution);
  assert.equal(io.calls.length, 1);
});

test('tiny selections keep detailed processing and mode configuration is validated', () => {
  const small = request({ selection: [100, 100, 150, 150] });
  assert.equal(quickLocateMode(small, { quickLocateMode: 'fast' }), 'detailed');
  assert.equal(quickLocateMode(request(), { quickLocateMode: 'fast' }), 'fast');
  assert.equal(quickLocateMode(request(), { quickLocateMode: 'detailed' }), 'detailed');
  assert.equal(loadConfig({}).quickLocateMode, 'fast');
  assert.equal(loadConfig({ QUICK_LOCATE_MODE: ' detailed ' }).quickLocateMode, 'detailed');
  assert.throws(() => loadConfig({ QUICK_LOCATE_MODE: 'blurry' }), /QUICK_LOCATE_MODE/);
});

test('turning guided mode off stops an old plan from forcing a heavy request without deleting the plan', async () => {
  const memory = { ...emptyMemory(), plan: [{ id: 's1', text: 'Open the lid', completed: false }] };
  const input = request({ question: 'Where is the bottle?', guided: false });
  const io = transport(answer());
  const result = await runAgent(input, config, session({ memory }), io.fetcher);
  assert.equal('action' in io.calls[0].body.generationConfig.responseJsonSchema.properties, false);
  assert.deepEqual(result.taskMemory, memory);
  assert.equal(io.calls.length, 1);
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

test('Info-on shopping requests still reach the full assistant with research permission', async () => {
  const input = request({ question: 'Find buying links for this bottle', includeWebInfo: true, researchEnabled: true });
  const io = transport({ ...answer(), action: 'respond', argument: null, sourceIds: [], memory: emptyMemory() });
  await runAgent(input, { ...config, serperApiKey: 'fake-serper' }, session(), io.fetcher);
  const body = io.calls[0].body;
  assert.equal(JSON.parse(body.contents.at(-1).parts[0].text).researchAllowed, true);
  assert.ok(body.generationConfig.responseJsonSchema.properties.action.enum.includes('search_online'));
  assert.equal(io.calls.length, 1);
});

test('simple locating uses one minimal-reasoning camera call with either Info setting and no search', async () => {
  for (const includeWebInfo of [false, true]) {
    for (const researchEnabled of [false, true]) {
      const input = request({ question: 'Where is the bottle?', includeWebInfo, researchEnabled });
      const io = transport(answer());
      const result = await runAgent(input, { ...config, model: 'gemini-3.5-flash-lite', serperApiKey: 'fake-serper' }, session(), io.fetcher);
      assert.equal(io.calls.length, 1);
      assert.equal(io.calls[0].body.generationConfig.thinkingConfig.thinkingLevel, 'MINIMAL');
      assert.equal(result.webInfo, null);
      assert.equal('action' in io.calls[0].body.generationConfig.responseJsonSchema.properties, false);
    }
  }
});
