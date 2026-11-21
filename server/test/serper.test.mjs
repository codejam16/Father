import test from 'node:test';
import assert from 'node:assert/strict';
import { searchWithSerper, extractSerperResults } from '../src/serper.mjs';
import { runAgent } from '../src/agent.mjs';
import { TaskSessions, emptyMemory } from '../src/task-session.mjs';
import { validateRequest } from '../src/contract.mjs';
import { loadConfig } from '../src/server.mjs';
import { analyzeWithGemini } from '../src/gemini.mjs';
import { randomUUID } from 'node:crypto';

const result = { organic: [{ title: 'Bottle listing', link: 'https://shop.vendor.com/bottle', snippet: 'Similar bottle costs CAD 25.' }] };
const config = { model: 'test', maxOutputTokens: 1024, apiKey: 'gemini-secret', serperApiKey: 'serper-secret',
  trace: { requestId: 'test', calls: 0, searchCalls: 0 } };
const input = () => validateRequest({ sessionId: randomUUID(), frameId: randomUUID(), capturedAt: new Date().toISOString(),
  question: 'What does a bottle like this cost?', includeWebInfo: true,
  image: { base64: Buffer.from([255,216,255,217]).toString('base64'), mimeType: 'image/jpeg', width: 480, height: 640 } });
const modelResponse = (decision) => ({ ok: true, json: async () => ({ candidates: [{ finishReason: 'STOP', content: { parts: [{ text: JSON.stringify({
  action: 'search_online', argument: 'bottle price Canada', answer: 'Let me check current listings.',
  targetLabel: null, box: null, needsClearerView: false, sourceIds: [], webSummary: null, memory: emptyMemory(), ...decision,
}) }] } }] }) });

test('one Serper search uses the fixed endpoint and sends only the query with its own key', async () => {
  let count = 0;
  const settings = { ...config, trace: { requestId: 'test', calls: 0, searchCalls: 0 } };
  const value = await searchWithSerper(' bottle price Canada ', settings, [], async (url, options) => {
    count++;
    assert.equal(url, 'https://google.serper.dev/search');
    assert.equal(options.method, 'POST');
    assert.equal(options.redirect, 'error');
    assert.equal(options.headers['X-API-KEY'], 'serper-secret');
    assert.deepEqual(JSON.parse(options.body), { q: 'bottle price Canada', num: 5, gl: 'ca', hl: 'en' });
    assert.doesNotMatch(JSON.stringify(options), /gemini-secret|base64|history/);
    return { ok: true, status: 200, json: async () => result };
  });
  assert.equal(count, 1);
  assert.equal(settings.trace.calls, 0);
  assert.equal(settings.trace.searchCalls, 1);
  assert.deepEqual(value.report.supports[0].sourceIds, ['s1']);
  assert.match(value.report.text, /snippets, not documents/);
  assert.equal(value.report.searchSuggestionsHTML, null);
});

test('search results preserve source IDs, deduplicate links and exclude unsafe or generated URLs', () => {
  const existing = [{ id: 's1', title: 'Earlier source', url: 'https://docs.vendor.com/manual' }];
  const value = extractSerperResults({ organic: [
    { title: 'Duplicate old source', link: existing[0].url, snippet: 'A short excerpt' },
    ...result.organic, ...result.organic,
    { link: 'https://127.0.0.1/admin', snippet: 'Unsafe' },
    { link: 'javascript:alert(1)' },
    { link: 'https://user:password@shop.vendor.com/' },
    { title: 'Missing URL', snippet: 'Look at https://made-up.vendor.com' },
  ] }, existing);
  assert.equal(value.sources.length, 2);
  assert.equal(value.sources[1].id, 's2');
  assert.equal(value.report.supports.length, 2);
  assert.equal(existing.length, 1);
  assert.doesNotMatch(JSON.stringify(value), /127\.0\.0\.1|javascript|password|made-up/);
});

test('missing key and cancelled search make zero external requests', async () => {
  let calls = 0;
  const fetcher = async () => { calls++; throw new Error('must not run'); };
  await assert.rejects(searchWithSerper('test', {}, [], fetcher), (error) => error.code === 'search_not_configured');
  const controller = new AbortController(); controller.abort();
  await assert.rejects(searchWithSerper('test', { ...config, signal: controller.signal }, [], fetcher));
  assert.equal(calls, 0);
});

test('rejected Serper keys and exhausted credits produce distinct safe errors without retries', async () => {
  for (const [status, code] of [[401, 'search_auth'], [403, 'search_auth'], [402, 'search_quota'], [429, 'search_quota'], [503, 'search_unavailable']]) {
    let calls = 0;
    await assert.rejects(searchWithSerper('test', config, [], async () => {
      calls++;
      return { ok: false, status, json: async () => { throw new Error('Do not expose upstream body or credentials'); } };
    }), (error) => {
      assert.equal(error.code, code);
      assert.doesNotMatch(error.message + error.userMessage, /serper-secret|gemini-secret|Do not expose/);
      return true;
    });
    assert.equal(calls, 1);
  }
});

test('malformed and empty Serper responses cannot be presented as completed research', async () => {
  for (const payload of [null, [], { organic: [] }, { organic: [{ link: 'http://localhost' }] }]) {
    await assert.rejects(searchWithSerper('test', config, [], async () => ({ ok: true, json: async () => payload })));
  }
  await assert.rejects(searchWithSerper('test', config, [], async () => ({ ok: true, json: async () => { throw new Error(); } })));
  await assert.rejects(searchWithSerper('test', config, [], async () => { throw new Error('serper-secret'); }),
    (error) => error.code === 'search_unavailable' && !error.message.includes('serper-secret'));
});

test('search credit failure ends the turn cleanly and does not disable later camera questions', async () => {
  const sessions = new TaskSessions(); const request = input(); let calls = 0;
  const fetcher = async (url, options) => {
    calls++;
    if (url === 'https://google.serper.dev/search') return { ok: false, status: 429 };
    assert.equal(options.headers['x-goog-api-key'], config.apiKey);
    assert.equal(JSON.parse(options.body).tools, undefined);
    return modelResponse(calls > 2 ? { action: 'respond', argument: null, answer: 'A bottle.' } : {});
  };
  const first = await sessions.run(request, (session) => runAgent(request, config, session, fetcher));
  assert.equal(first.action, 'respond');
  assert.equal(first.continuationId, null);
  assert.equal(first.webInfo, null);
  assert.equal(first.target, null);
  assert.match(first.answer, /Web search/);
  assert.equal(calls, 2);
  const next = { ...request, frameId: randomUUID(), question: 'What am I looking at?' };
  const second = await sessions.run(next, (session) => runAgent(next, config, session, fetcher));
  assert.equal(second.answer, 'A bottle.');
  assert.equal(calls, 3);
});

test('without Serper configuration the agent can still answer from the camera in one call', async () => {
  const request = input(); let calls = 0;
  const settings = { ...config, serperApiKey: '' };
  const value = await new TaskSessions().run(request, (session) => runAgent(request, settings, session, async (_, options) => {
    calls++;
    const body = JSON.parse(options.body);
    assert.equal(JSON.parse(body.contents.at(-1).parts[0].text).researchAllowed, false);
    assert.equal(body.tools, undefined);
    return modelResponse({ action: 'respond', argument: null, answer: 'A bottle.' });
  }));
  assert.equal(value.answer, 'A bottle.');
  assert.equal(calls, 1);
});

test('Serper locale and key configuration load independently of Gemini access', () => {
  const value = loadConfig({ SERPER_API_KEY: ' private-key ', SERPER_COUNTRY: 'ca', SERPER_LANGUAGE: 'fr' });
  assert.equal(value.serperApiKey, 'private-key');
  assert.equal(value.serperLanguage, 'fr');
  assert.throws(() => loadConfig({ SERPER_COUNTRY: 'https://example.com' }), /SERPER_COUNTRY/);
});

test('legacy research switches and missing key prevent searches even if the model requests one', async () => {
  for (const [extra, settings] of [
    [{ researchEnabled: false }, config], [{}, { ...config, webResearchEnabled: false }], [{}, { ...config, serperApiKey: '' }],
  ]) {
    let calls = 0;
    const value = await analyzeWithGemini({ ...input(), ...extra }, settings, async (url, options) => {
      calls++;
      assert.match(url, /generativelanguage\.googleapis\.com/);
      const body = JSON.parse(options.body);
      assert.equal(body.tools, undefined);
      assert.equal(JSON.parse(body.contents.at(-1).parts[0].text).researchAvailable, false);
      return modelResponse({ searchQuery: 'try to search anyway', action: 'respond', argument: null, answer: 'A bottle.' });
    });
    assert.equal(value.webInfo, null);
    assert.equal(calls, 1);
  }
});
