import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { TaskSessions, emptyMemory, mergeMemory } from '../src/task-session.mjs';
import { runAgent } from '../src/agent.mjs';
import { extractResearch, publicURL } from '../src/research.mjs';
import { validateRequest } from '../src/contract.mjs';
import { createApp, loadConfig } from '../src/server.mjs';
import { Budget } from '../src/budget.mjs';

const config = { model: 'test-model', maxOutputTokens: 2048, apiKey: 'not-real', maxResearchSteps: 2 };
const request = (extra = {}) => validateRequest({
  sessionId: randomUUID(), frameId: randomUUID(), capturedAt: new Date().toISOString(),
  task: 'Identify and use this product', question: 'How do I clean this filter?',
  image: { mimeType: 'image/jpeg', base64: Buffer.from([255, 216, 255, 217]).toString('base64'), width: 480, height: 640 },
  ...extra,
});
const decision = (extra = {}) => ({
  action: 'respond', argument: null, answer: 'A bottle.', targetLabel: null, box: null,
  needsClearerView: false, sourceIds: [], memory: emptyMemory(), ...extra,
});
const payload = (value, candidate = {}) => ({
  candidates: [{ finishReason: 'STOP', content: { parts: [{ text: typeof value === 'string' ? value : JSON.stringify(value) }] }, ...candidate }],
  usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 5 },
});
const searchPayload = () => payload('The manufacturer describes the removable filter.', {
  groundingMetadata: {
    groundingChunks: [{ web: { uri: 'https://docs.vendor.com/manual.pdf', title: 'Manufacturer manual' } }],
    groundingSupports: [{ segment: { text: 'The filter is removable.' }, groundingChunkIndices: [0] }],
    searchEntryPoint: { renderedContent: '<div>Google Search suggestions</div>' },
  },
});
const readPayload = () => payload('The diagram shows the filter below the handle.', {
  urlContextMetadata: { urlMetadata: [{ retrievedUrl: 'https://docs.vendor.com/manual.pdf', urlRetrievalStatus: 'URL_RETRIEVAL_STATUS_SUCCESS' }] },
});
function fake(...responses) {
  const calls = [];
  const fetcher = async (url, options) => {
    calls.push({ url, body: JSON.parse(options.body) });
    assert.ok(responses.length, 'Unexpected provider call');
    const item = responses.shift();
    if (item instanceof Error) throw item;
    return { ok: true, json: async () => item };
  };
  return { fetcher, calls };
}
const execute = (sessions, input, transport, settings = config) => sessions.run(input, (session) => runAgent(input, settings, session, transport.fetcher));

test('simple identification uses one decision call and keeps established task context across turns', async () => {
  const sessions = new TaskSessions();
  const input = request();
  const memory = { goal: 'Clean the filter', facts: ['User says this is model A'], openQuestions: [], plan: [{ id: 'check', text: 'Check the label' }] };
  const transport = fake(payload(decision({ memory })), payload(decision({ memory })));
  const first = await execute(sessions, input, transport);
  assert.equal(first.action, 'respond');
  assert.equal(transport.calls.length, 1);
  assert.equal(transport.calls[0].body.tools, undefined);
  await execute(sessions, { ...input, frameId: 'new', history: [] }, transport);
  const context = JSON.parse(transport.calls[1].body.contents.at(-1).parts[0].text);
  assert.deepEqual(context.taskMemory.facts, memory.facts);
});

test('search uses grounded metadata, then requires a fresh camera frame before highlighting', async () => {
  const sessions = new TaskSessions();
  const input = request();
  let extraCalls = 0;
  const transport = fake(
    payload(decision({ action: 'search_online', argument: 'manufacturer model A filter manual', answer: 'Let me check the manual.' })),
    searchPayload(), payload(decision({ sourceIds: ['s1'], targetLabel: 'Filter', box: [100, 200, 400, 600] })),
  );
  const settings = { ...config, reserveAdditionalCall: () => extraCalls++ };
  const first = await execute(sessions, input, transport, settings);
  assert.equal(first.action, 'refresh_camera');
  assert.equal(first.target, null);
  assert.equal(first.sources[0].id, 's1');
  assert.deepEqual(first.researchReports[0].supports[0].sourceIds, ['s1']);
  assert.match(first.researchReports[0].searchSuggestionsHTML, /Google/);
  assert.deepEqual(transport.calls[1].body.tools, [{ google_search: {} }]);
  assert.equal(transport.calls[1].body.generationConfig.responseJsonSchema, undefined);
  await assert.rejects(execute(sessions, { ...input, continuationId: first.continuationId }, transport), /fresh camera frame/);
  assert.equal(transport.calls.length, 2);
  const final = await execute(sessions, { ...input, frameId: 'fresh-frame', continuationId: first.continuationId }, transport, settings);
  assert.equal(final.target.label, 'Filter');
  assert.equal(final.continuationId, null);
  assert.equal(extraCalls, 1);
  assert.match(transport.calls[2].body.contents.at(-1).parts[0].text, /manufacturer/i);
  await assert.rejects(execute(sessions, { ...input, frameId: 'again', continuationId: first.continuationId }, transport), /expired/);
});

test('a turn can search, read one known document, and inspect a fresh frame within five provider calls', async () => {
  const sessions = new TaskSessions(); const input = request();
  const transport = fake(
    payload(decision({ action: 'search_online', argument: 'filter manual' })), searchPayload(),
    payload(decision({ action: 'read_source', argument: 's1' })), readPayload(),
    payload(decision({ sourceIds: ['s1'] })),
  );
  const first = await execute(sessions, input, transport);
  const second = await execute(sessions, { ...input, frameId: 'second', continuationId: first.continuationId }, transport);
  await execute(sessions, { ...input, frameId: 'third', continuationId: second.continuationId }, transport);
  assert.equal(transport.calls.length, 5);
  assert.deepEqual(transport.calls[3].body.tools, [{ url_context: {} }]);
  assert.match(transport.calls[3].body.contents[0].parts[0].text, /https:\/\/docs.vendor.com\/manual.pdf/);
  assert.deepEqual(transport.calls[4].body.generationConfig.responseJsonSchema.properties.action.enum, ['respond', 'ask_clarification', 'request_view']);
});

test('tool limits and research switches prevent extra external calls even if the model requests them', async () => {
  for (const [input, settings] of [
    [request({ researchEnabled: false }), config],
    [request(), { ...config, webResearchEnabled: false }],
  ]) {
    const transport = fake(payload(decision({ action: 'search_online', argument: 'query' })));
    await assert.rejects(execute(new TaskSessions(), input, transport, settings), /research limit/);
    assert.equal(transport.calls.length, 1);
  }
  const sessions = new TaskSessions(); const input = request();
  const transport = fake(payload(decision({ action: 'search_online', argument: 'query' })), searchPayload(),
    payload(decision({ action: 'search_online', argument: 'again' })));
  const first = await execute(sessions, input, transport, { ...config, maxResearchSteps: 1 });
  await assert.rejects(execute(sessions, { ...input, frameId: 'fresh', continuationId: first.continuationId }, transport,
    { ...config, maxResearchSteps: 1 }), /research limit/);
  assert.equal(transport.calls.length, 3);
});

test('unknown actions, invented citations and arbitrary read URLs cannot execute tools', async () => {
  for (const value of [
    decision({ action: 'execute_code', argument: 'danger' }),
    decision({ sourceIds: ['invented'] }),
    decision({ action: 'read_source', argument: 'https://internal.local/secret' }),
  ]) {
    const transport = fake(payload(value));
    await assert.rejects(execute(new TaskSessions(), request(), transport));
    assert.equal(transport.calls.length, 1);
  }
});

test('search text without provider source metadata is never presented as verified research', async () => {
  const transport = fake(payload(decision({ action: 'search_online', argument: 'query' })),
    payload('I searched and found https://made-up.vendor.com'));
  await assert.rejects(execute(new TaskSessions(), request(), transport), /usable source links/);
});

test('paywalled or failed URL retrieval cannot be claimed as a read document', () => {
  assert.throws(() => extractResearch(payload('I read it', { urlContextMetadata: { urlMetadata: [{
    retrievedUrl: 'https://docs.vendor.com/manual.pdf', urlRetrievalStatus: 'URL_RETRIEVAL_STATUS_PAYWALL',
  }] } }), 'I read it', [], 'read_source', 'https://docs.vendor.com/manual.pdf'), /could not be read/);
});

test('sources exclude credentials, local URLs, IPs and non-HTTPS schemes', () => {
  for (const url of ['http://docs.vendor.com', 'https://name:secret@docs.vendor.com', 'https://127.0.0.1',
    'https://[::1]', 'https://internal.local', 'file:///etc/passwd', 'javascript:alert(1)', 'https://docs.vendor.com:8787']) {
    assert.equal(publicURL(url), null);
  }
  assert.equal(publicURL('https://docs.vendor.com/manual.pdf'), 'https://docs.vendor.com/manual.pdf');
});

test('asking for a better view suppresses even a model-generated target', async () => {
  const transport = fake(payload(decision({ action: 'request_view', targetLabel: 'Guess', box: [0, 0, 100, 100] })));
  const result = await execute(new TaskSessions(), request(), transport);
  assert.equal(result.needsClearerView, true);
  assert.equal(result.target, null);
});

test('only explicit user confirmation completes existing plan steps; changed steps lose completion', async () => {
  const sessions = new TaskSessions(); const input = request();
  const memory = { ...emptyMemory(), plan: [{ id: 'step1', text: 'Check the label', completed: true }] };
  const transport = fake(payload(decision({ memory })), payload(decision({ memory })));
  const first = await execute(sessions, input, transport);
  assert.equal(first.taskMemory.plan[0].completed, false);
  const second = await execute(sessions, { ...input, frameId: 'new', confirmedStepIds: ['step1'] }, transport);
  assert.equal(second.taskMemory.plan[0].completed, true);
  assert.equal(mergeMemory(second.taskMemory, { ...memory, plan: [{ id: 'step1', text: 'A different task' }] }).plan[0].completed, false);
  assert.throws(() => mergeMemory(emptyMemory(), { ...memory, plan: [memory.plan[0], memory.plan[0]] }), /invalid task/);
});

test('session locks prevent overlapping questions and failures do not commit partial memory', async () => {
  const sessions = new TaskSessions(); const input = request();
  let release;
  const first = sessions.run(input, async (session) => {
    session.memory.goal = 'Should not persist';
    await new Promise((resolve) => { release = resolve; });
    throw new Error('failed');
  });
  await assert.rejects(sessions.run(input, async () => {}), /still processing/);
  release(); await assert.rejects(first, /failed/);
  await sessions.run(input, async (session) => assert.equal(session.memory.goal, ''));
});

test('task changes, inactivity expiry and bounded eviction discard old context', async () => {
  let now = 0;
  const sessions = new TaskSessions({ limit: 1, ttl: 100, now: () => now });
  const input = request();
  await sessions.run(input, async (session) => { session.memory.goal = 'old'; });
  await sessions.run({ ...input, task: 'different task' }, async (session) => assert.equal(session.memory.goal, ''));
  now = 200;
  await assert.rejects(sessions.run({ ...input, continuationId: randomUUID() }, async () => {}), /expired/);
  await sessions.run(input, async (session) => { session.memory.goal = 'old'; });
  await sessions.run(request(), async () => {});
  assert.equal(sessions.entries.size, 1);
  await sessions.run(input, async (session) => assert.equal(session.memory.goal, ''));
});

test('invalid session and confirmation fields are rejected before provider access', () => {
  for (const extra of [{ sessionId: 'bad' }, { researchEnabled: 'true' }, { confirmedStepIds: ['x'.repeat(41)] },
    { sessionId: null, continuationId: randomUUID() }]) assert.throws(() => request(extra));
});

test('HTTP research reserves each provider call and never invokes a tool after allowance exhaustion', async (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'tasklens-agent-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const settings = loadConfig({ AI_MODE: 'gemini', GEMINI_API_KEY: 'fake-key', APP_TOKEN: 'private-test-token',
    BUDGET_FILE: join(directory, 'allowance.json'), MAX_LIVE_REQUESTS: '1' });
  const budget = new Budget(settings.budgetPath, 1);
  const transport = fake(payload(decision({ action: 'search_online', argument: 'query' })));
  const server = createApp(settings, { budget, agent: (input, config, session) => runAgent(input, config, session, transport.fetcher) });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(() => new Promise((resolve) => { server.close(resolve); server.closeAllConnections(); }));
  const response = await fetch(`http://127.0.0.1:${server.address().port}/analyze`, {
    method: 'POST', headers: { 'content-type': 'application/json', authorization: 'Bearer private-test-token' }, body: JSON.stringify(request()),
  });
  assert.equal(response.status, 429);
  assert.equal((await response.json()).error.code, 'request_allowance_exhausted');
  assert.equal(transport.calls.length, 1);
  assert.equal(budget.used, 1);
});

test('full HTTP search/read/refresh flow charges exactly five model calls and retains the final source and frame', async (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'tasklens-agent-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const settings = loadConfig({ AI_MODE: 'gemini', GEMINI_API_KEY: 'fake-key', APP_TOKEN: 'private-test-token',
    BUDGET_FILE: join(directory, 'allowance.json'), MAX_LIVE_REQUESTS: '5' });
  const budget = new Budget(settings.budgetPath, 5);
  const transport = fake(
    payload(decision({ action: 'search_online', argument: 'filter manual' })), searchPayload(),
    payload(decision({ action: 'read_source', argument: 's1' })), readPayload(),
    payload(decision({ sourceIds: ['s1'], targetLabel: 'Filter', box: [100, 200, 400, 600] })),
  );
  const server = createApp(settings, { budget, agent: (input, config, session) => runAgent(input, config, session, transport.fetcher) });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(() => new Promise((resolve) => { server.close(resolve); server.closeAllConnections(); }));
  const input = request();
  const send = async (extra) => {
    const result = await fetch(`http://127.0.0.1:${server.address().port}/analyze`, {
      method: 'POST', headers: { 'content-type': 'application/json', authorization: 'Bearer private-test-token' },
      body: JSON.stringify({ ...input, ...extra }),
    });
    return { status: result.status, value: await result.json() };
  };
  const first = await send({});
  assert.equal(first.status, 200);
  const second = await send({ frameId: 'fresh-2', continuationId: first.value.continuationId });
  assert.equal(second.status, 200);
  const third = await send({ frameId: 'fresh-3', continuationId: second.value.continuationId });
  assert.equal(third.status, 200);
  assert.equal(third.value.frameId, 'fresh-3');
  assert.equal(third.value.target.label, 'Filter');
  assert.equal(third.value.researchReports.length, 2);
  assert.equal(budget.used, 5);
  assert.equal(transport.calls.length, 5);
  assert.equal((await send({ frameId: 'next-question' })).status, 429);
  assert.equal(transport.calls.length, 5);
});
