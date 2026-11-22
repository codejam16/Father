import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { TaskSessions, emptyMemory, mergeMemory, applyUserCompletedSteps } from '../src/task-session.mjs';
import { runAgent } from '../src/agent.mjs';
import { extractResearch, publicURL } from '../src/research.mjs';
import { validateRequest } from '../src/contract.mjs';
import { createApp, loadConfig } from '../src/server.mjs';

const config = { model: 'test-model', maxOutputTokens: 2048, apiKey: 'not-real', serperApiKey: 'fake-serper-key', maxResearchSteps: 2 };
const request = (extra = {}) => validateRequest({
  sessionId: randomUUID(), frameId: randomUUID(), capturedAt: new Date().toISOString(),
  task: 'Identify and use this product', question: 'How do I clean this filter?',
  image: { mimeType: 'image/jpeg', base64: Buffer.from([255, 216, 255, 217]).toString('base64'), width: 480, height: 640 },
  includeWebInfo: true, ...extra,
});
const decision = (extra = {}) => ({
  action: 'respond', argument: null, answer: 'A bottle.', targetLabel: null, box: null,
  needsClearerView: false, sourceIds: [], memory: emptyMemory(), ...extra,
});
const payload = (value, candidate = {}) => ({
  candidates: [{ finishReason: 'STOP', content: { parts: [{ text: typeof value === 'string' ? value : JSON.stringify(value) }] }, ...candidate }],
  usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 5 },
});
const searchPayload = () => ({ organic: [{
  title: 'Manufacturer manual', link: 'https://docs.vendor.com/manual.pdf',
  snippet: 'The manufacturer says the filter is removable.',
}] });
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
  const transport = fake(
    payload(decision({ action: 'search_online', argument: 'manufacturer model A filter manual', answer: 'Let me check the manual.' })),
    searchPayload(), payload(decision({ sourceIds: ['s1'], targetLabel: 'Filter', box: [100, 200, 400, 600] })),
  );
  const settings = config;
  const first = await execute(sessions, input, transport, settings);
  assert.equal(first.action, 'refresh_camera');
  assert.equal(first.target, null);
  assert.equal(first.sources[0].id, 's1');
  assert.deepEqual(first.researchReports[0].supports[0].sourceIds, ['s1']);
  assert.equal(first.researchReports[0].searchSuggestionsHTML, null);
  assert.equal(first.researchReports[0].provider, 'serper');
  assert.equal(transport.calls[1].url, 'https://google.serper.dev/search');
  assert.equal(transport.calls[1].body.q, 'manufacturer model A filter manual');
  assert.equal(transport.calls[1].body.tools, undefined);
  assert.equal(transport.calls[1].body.generationConfig, undefined);
  await assert.rejects(execute(sessions, { ...input, continuationId: first.continuationId }, transport), /fresh camera frame/);
  assert.equal(transport.calls.length, 2);
  const final = await execute(sessions, { ...input, frameId: 'fresh-frame', continuationId: first.continuationId }, transport, settings);
  assert.equal(final.target.label, 'Filter');
  assert.equal(final.continuationId, null);
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
  const result = await execute(new TaskSessions(), request(), transport);
  assert.equal(result.action, 'respond');
  assert.equal(result.webInfo, null);
  assert.deepEqual(result.sources, []);
  assert.equal(transport.calls.length, 2);
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

test('full HTTP search/read/refresh flow uses five calls and retains the final source and frame', async (t) => {
  const settings = loadConfig({ AI_MODE: 'gemini', GEMINI_API_KEY: 'fake-key', APP_TOKEN: 'private-test-token',
    SERPER_API_KEY: 'fake-serper-key', MAX_LIVE_REQUESTS: '1', REQUESTS_PER_MINUTE: '1' });
  const transport = fake(
    payload(decision({ action: 'search_online', argument: 'filter manual' })), searchPayload(),
    payload(decision({ action: 'read_source', argument: 's1' })), readPayload(),
    payload(decision({ sourceIds: ['s1'], targetLabel: 'Filter', box: [100, 200, 400, 600] })),
  );
  const server = createApp(settings, { agent: (input, config, session) => runAgent(input, config, session, transport.fetcher) });
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
  assert.equal(transport.calls.length, 5);
  const next = fake(payload(decision()));
  transport.fetcher = next.fetcher;
  assert.equal((await send({ frameId: 'next-question' })).status, 200);
  assert.equal(next.calls.length, 1);
});

test('optional web cards reuse verified task research without adding implicit search to camera decisions', async () => {
  const sessions = new TaskSessions(); const input = request({ includeWebInfo: true });
  const transport = fake(payload(decision({ action: 'search_online', argument: 'filter manual', webSummary: null })),
    searchPayload(), payload(decision({ sourceIds: ['s1'], webSummary: 'Manufacturer instructions describe a removable filter.' })));
  const first = await execute(sessions, input, transport);
  const final = await execute(sessions, { ...input, frameId: 'fresh', continuationId: first.continuationId }, transport);
  assert.equal(transport.calls.length, 3);
  assert.equal(transport.calls[0].body.tools, undefined);
  assert.equal(transport.calls[2].body.tools, undefined);
  assert.ok(transport.calls[0].body.generationConfig.responseJsonSchema.required.includes('webSummary'));
  assert.equal(final.webInfo.sources[0].url, 'https://docs.vendor.com/manual.pdf');
  assert.match(final.webInfo.summary, /removable filter/);
});

test('steps the user says they finished are marked complete, unknown ids are ignored', () => {
  const memory = { goal: 'Change wallpaper', facts: [], openQuestions: [], plan: [
    { id: 's1', text: 'Open System Settings', completed: false },
    { id: 's2', text: 'Click Wallpaper', completed: false },
  ] };
  const updated = applyUserCompletedSteps(memory, ['s1', 'nope', 42]);
  assert.deepEqual(updated.plan.map((step) => step.completed), [true, false]);
  assert.equal(applyUserCompletedSteps(memory, undefined), memory);
});

test('eligible questions search only when the model selects research, without repeating on continuation', async () => {
  const sessions = new TaskSessions();
  // The enabled info toggle permits research but never forces it.
  const input = request({ searchEveryQuestion: true, includeWebInfo: true });
  const transport = fake(
    payload(decision({ action: 'search_online', argument: 'filter cleaning manufacturer manual' })), searchPayload(),
    payload(decision({ sourceIds: ['s1'], webSummary: 'Manufacturer cleaning instructions.' })),
    payload(decision({ action: 'search_online', argument: 'filter replacement intervals manufacturer' })), searchPayload(),
  );
  const first = await execute(sessions, input, transport);
  assert.ok(!transport.calls[0].body.generationConfig.responseJsonSchema.required.includes('searchQuery'));
  assert.equal(transport.calls[0].body.generationConfig.responseJsonSchema.properties.sourceIds.maxItems, 0);
  const final = await execute(sessions, { ...input, continuationId: first.continuationId, frameId: 'fresh' }, transport);
  assert.equal(final.action, 'respond');
  assert.equal(final.webInfo.sources[0].url, 'https://docs.vendor.com/manual.pdf');
  assert.equal(final.webInfo.summary, 'Manufacturer cleaning instructions.');
  assert.equal(transport.calls.filter((call) => call.url === 'https://google.serper.dev/search').length, 1);
  assert.ok(transport.calls[2].body.generationConfig.responseJsonSchema.properties.action.enum.includes('respond'));
  // A follow-up question in the same session gets its own search, even with older evidence present.
  await execute(sessions, { ...input, question: 'When should I replace it?', frameId: 'next-question' }, transport);
  assert.equal(transport.calls.filter((call) => call.url === 'https://google.serper.dev/search').length, 2);
});

test('info off blocks search even when a stale client requests always-search', async () => {
  const transport = fake(payload(decision({ action: 'search_online', argument: 'filter manual' })));
  await assert.rejects(execute(new TaskSessions(), request({ searchEveryQuestion: true, includeWebInfo: false }), transport), /research limit/);
  assert.equal(transport.calls.length, 1);
  assert.deepEqual(transport.calls[0].body.generationConfig.responseJsonSchema.properties.action.enum,
    ['respond', 'ask_clarification', 'request_view']);
});

test('optional search does not bypass missing credentials or an administrator research switch', async () => {
  for (const extra of [{ serperApiKey: '' }, { webResearchEnabled: false }]) {
    const transport = fake(payload(decision()));
    const result = await execute(new TaskSessions(), request({ searchEveryQuestion: true }), transport, { ...config, ...extra });
    assert.equal(result.action, 'respond');
    assert.equal(transport.calls.length, 1);
    assert.deepEqual(transport.calls[0].body.generationConfig.responseJsonSchema.properties.action.enum,
      ['respond', 'ask_clarification', 'request_view']);
  }
});

test('a camera answer is accepted without a search query even with info enabled', async () => {
  const transport = fake(payload(decision({ answer: 'The bottle is on your left.' })));
  const result = await execute(new TaskSessions(), request({ searchEveryQuestion: true, question: 'Where is the bottle?' }), transport);
  assert.equal(result.action, 'respond');
  assert.equal(result.answer, 'The bottle is on your left.');
  assert.equal(transport.calls.length, 1);
});

test('a chosen search ends cleanly on empty results rather than continuing to search', async () => {
  const transport = fake(payload(decision({ action: 'search_online', argument: 'uncertain object' })), { organic: [] });
  const result = await execute(new TaskSessions(), request({ searchEveryQuestion: true }), transport);
  assert.equal(result.action, 'respond');
  assert.equal(result.continuationId, null);
  assert.equal(result.webInfo, null);
  assert.equal(transport.calls.length, 2);
});

test('uncited search links remain available as related results without becoming answer citations', async () => {
  const input = request({ searchEveryQuestion: true, includeWebInfo: true });
  const sessions = new TaskSessions();
  const transport = fake(payload(decision({ action: 'search_online', argument: 'reusable water bottle' })),
    searchPayload(), payload(decision({ answer: 'It looks like a bottle.', webSummary: null })));
  const first = await execute(sessions, input, transport);
  const final = await execute(sessions, { ...input, frameId: 'fresh', continuationId: first.continuationId }, transport);
  assert.deepEqual(final.sourceIds, []);
  assert.equal(final.webInfo.summary, 'Related search results');
  assert.equal(final.webInfo.sources[0].url, 'https://docs.vendor.com/manual.pdf');
  // No new research in a later camera-only turn must not revive old links as fresh results.
  const offline = fake(payload(decision()));
  const later = await execute(sessions, { ...input, frameId: 'later', question: 'What color is it?' }, offline,
    { ...config, webResearchEnabled: false });
  assert.equal(later.webInfo, null);
});

test('a respond action cannot be turned into a search by an unused legacy query', async () => {
  const input = request({ searchEveryQuestion: true, includeWebInfo: true });
  const transport = fake(payload(decision({ action: 'respond', searchQuery: 'unused filter cleaning', answer: 'Press the visible latch.' })));
  const result = await execute(new TaskSessions(), input, transport);
  assert.equal(result.action, 'respond');
  assert.equal(result.answer, 'Press the visible latch.');
  assert.equal(transport.calls.length, 1);
});

test('unused arguments on final answers cannot execute a tool or suppress a usable answer', async () => {
  for (const argument of ['', 's1', 'https://internal.local/secret']) {
    const transport = fake(payload(decision({ argument })));
    const result = await execute(new TaskSessions(), request(), transport);
    assert.equal(result.action, 'respond');
    assert.equal(result.answer, 'A bottle.');
    assert.equal(transport.calls.length, 1);
  }
});

test('invalid explicit search arguments never fall back to sending private user text', async () => {
  for (const argument of ['', ' ', 'x'.repeat(501), null]) {
    const transport = fake(payload(decision({ action: 'search_online', argument })));
    await assert.rejects(execute(new TaskSessions(), request({
      question: 'Private question with account credentials' }), transport), /invalid research arguments/);
    assert.equal(transport.calls.length, 1);
  }
});

test('turning info off on a continuation forbids additional searches and document reads', async () => {
  for (const action of ['search_online', 'read_source']) {
    const sessions = new TaskSessions(), input = request();
    const firstCalls = fake(payload(decision({ action: 'search_online', argument: 'manufacturer manual' })), searchPayload());
    const first = await execute(sessions, input, firstCalls);
    const disabled = fake(payload(decision({ action, argument: action === 'read_source' ? 's1' : 'more details' })));
    await assert.rejects(execute(sessions, { ...input, frameId: 'fresh-disabled', includeWebInfo: false,
      researchEnabled: false, continuationId: first.continuationId }, disabled), /research limit/);
    assert.equal(disabled.calls.length, 1);
  }
});

test('visual questions and ordinary conversation remain single-call answers with either toggle state', async () => {
  for (const includeWebInfo of [false, true]) {
    for (const question of ['Where is the bottle?', 'Find all bottles.', 'How do I press this visible button?', 'Hello']) {
      const transport = fake(payload(decision()));
      await execute(new TaskSessions(), request({ includeWebInfo, question }), transport);
      assert.equal(transport.calls.length, 1);
      const context = JSON.parse(transport.calls[0].body.contents.at(-1).parts[0].text);
      if (question === 'Where is the bottle?') {
        assert.equal('action' in transport.calls[0].body.generationConfig.responseJsonSchema.properties, false);
      } else {
        assert.equal(context.researchAllowed, includeWebInfo);
        assert.match(transport.calls[0].body.systemInstruction.parts.at(-1).text, includeWebInfo ? /web info/i : /permitted only/);
      }
    }
  }
});
