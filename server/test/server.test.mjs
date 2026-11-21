import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createApp, loadConfig } from '../src/server.mjs';
import { validateAnswer, validateRequest } from '../src/contract.mjs';
import { analyzeWithGemini, buildGeminiBody } from '../src/gemini.mjs';
import { checkGemini } from '../src/doctor.mjs';
import { extractWebInfo, publicHTTPS } from '../src/web-info.mjs';

// Minimal JPEG envelope for transport validation. No test calls a real model.
const input = (extra = {}) => ({
  frameId: 'frame-1', capturedAt: '2026-11-21T15:00:00Z', question: 'What can you see?', task: '',
  image: { base64: Buffer.from([0xff, 0xd8, 0xff, 0xd9]).toString('base64'), mimeType: 'image/jpeg', width: 480, height: 640 },
  history: [], ...extra,
});

function config(_t, extra = {}) { return { ...loadConfig({}), diagnosticLogPath: null, diagnosticLogger: () => {}, ...extra }; }

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

test('authentication and input validation happen before provider access', async (t) => {
  const settings = config(t, { mode: 'gemini', appToken: 'a-private-test-token', apiKey: 'never-used' });
  let calls = 0;
  const url = await running(t, settings, { analyze: async () => { calls++; throw new Error('Must not run'); } });
  assert.equal((await post(url)).status, 401);
  assert.equal((await post(url, input({ selection: [0, 0, 0, 0] }), settings.appToken)).status, 400);
  assert.equal(calls, 0);
});

test('legacy local quota settings are ignored and more than fifty calls can succeed', async (t) => {
  const settings = { ...loadConfig({ MAX_LIVE_REQUESTS: '1', REQUESTS_PER_MINUTE: '1', BUDGET_FILE: '/unused/allowance.json' }),
    mode: 'gemini', appToken: 'a-private-test-token', apiKey: 'never-used' };
  assert.equal(settings.maxRequests, undefined);
  assert.equal(settings.requestsPerMinute, undefined);
  assert.equal(settings.budgetPath, undefined);
  let calls = 0;
  const url = await running(t, settings, { analyze: async () => {
    calls++;
    return { answer: 'A test answer.', target: null, needsClearerView: false, usage: {} };
  } });
  for (let i = 0; i < 60; i++) assert.equal((await post(url, input(), settings.appToken)).status, 200);
  assert.equal(calls, 60);
});

test('Google quota failures are forwarded without retry and do not block later requests locally', async (t) => {
  const settings = config(t, { mode: 'gemini', appToken: 'a-private-test-token', apiKey: 'never-used' });
  let calls = 0;
  const url = await running(t, settings, { analyze: async () => {
    calls++;
    return analyzeWithGemini(input(), settings, async () => ({ ok: false, status: 429 }));
  } });
  for (let i = 0; i < 2; i++) {
    const response = await post(url, input(), settings.appToken);
    assert.equal(response.status, 429);
    assert.equal((await response.json()).error.code, 'provider_error');
  }
  assert.equal(calls, 2);
});

test('upstream errors do not expose provider credentials', async (t) => {
  const settings = config(t);
  await assert.rejects(analyzeWithGemini(input(), settings, async () => ({ ok: false, status: 403 })),
    (error) => error.status === 502 && !error.message.includes('never-used'));
});

test('Google failures produce actionable messages without forwarding upstream details', async (t) => {
  const settings = config(t, { apiKey: 'private-key-do-not-print' });
  for (const [status, reason, expected] of [
    [400, 'API_KEY_INVALID', /rejected GEMINI_API_KEY/],
    [401, '', /rejected GEMINI_API_KEY/],
    [403, '', /denied access/],
    [404, '', /GEMINI_MODEL/],
    [429, '', /quota or rate limit/],
    [400, 'FAILED_PRECONDITION', /project setup/],
    [400, 'thinkingLevel unsupported', /thinking settings/],
    [400, 'Tool use with response mime type not supported', /Turn off Web info/],
    [400, 'responseJsonSchema unsupported', /structured response/],
    [400, 'image could not be decoded', /camera image/],
    [400, 'invalid argument', /request format/],
    [503, '', /temporarily unable/],
  ]) {
    let calls = 0;
    await assert.rejects(analyzeWithGemini(input(), settings, async () => {
      calls++;
      return { ok: false, status, json: async () => ({ error: {
        message: `${reason}: private-key-do-not-print project-private-data`,
      } }) };
    }), (error) => {
      assert.equal(error.code, 'provider_error');
      assert.equal(error.status, status === 429 ? 429 : 502);
      assert.match(error.message, new RegExp(`Gemini HTTP ${status}`));
      assert.match(error.message, expected);
      assert.doesNotMatch(error.message, /private-key-do-not-print|project-private-data/);
      return true;
    });
    assert.equal(calls, 1);
  }
});

test('doctor checks metadata only and does not claim generation access', async (t) => {
  const settings = config(t, { apiKey: 'private-key-do-not-print' });
  const result = await checkGemini(settings, async (url, options) => {
    assert.equal(url, `https://generativelanguage.googleapis.com/v1beta/models/${settings.model}`);
    assert.equal(options.method, 'GET');
    assert.equal(options.headers['x-goog-api-key'], settings.apiKey);
    assert.equal(options.body, undefined);
    return { ok: true, json: async () => ({ supportedGenerationMethods: ['generateContent'] }) };
  });
  assert.match(result, /does not verify generation permission/);
  assert.doesNotMatch(result, /private-key-do-not-print/);
});

test('doctor handles rejected keys, incompatible models and network errors safely', async (t) => {
  const settings = config(t, { apiKey: 'private-key-do-not-print' });
  await assert.rejects(checkGemini(settings, async () => ({ ok: false, status: 403,
    json: async () => ({ error: { message: settings.apiKey } }),
  })), /Gemini HTTP 403: Google denied access/);
  await assert.rejects(checkGemini(settings, async () => ({ ok: true,
    json: async () => ({ supportedGenerationMethods: ['embedContent'] }),
  })), /does not advertise generateContent/);
  await assert.rejects(checkGemini(settings, async () => { throw new Error(settings.apiKey); }), /Could not reach Google/);
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

test('oversized HTTP bodies receive 413 without contacting the provider', async (t) => {
  const settings = config(t, { mode: 'gemini', appToken: 'a-private-test-token', apiKey: 'never-used' });
  const url = await running(t, settings, { analyze: () => { throw new Error('Must not run'); } });
  const response = await post(url, { padding: 'x'.repeat(2_200_001) }, settings.appToken);
  assert.equal(response.status, 413);
});

test('invalid JSON produces a useful error', async (t) => {
  const settings = config(t);
  const url = await running(t, settings);
  const response = await fetch(`${url}/analyze`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{' });
  assert.equal(response.status, 400);
  assert.equal((await response.json()).error.code, 'invalid_json');
});

test('HTTP errors expose friendly speech text rather than developer diagnostics', async (t) => {
  const settings = config(t, { mode: 'gemini', apiKey: 'fake-key', appToken: 'private-test-token' });
  const url = await running(t, settings, { analyze: async () => analyzeWithGemini(input(), settings, async () => ({
    ok: false, status: 429, json: async () => ({ error: { message: 'quotaMetric: private-project request limit' } }),
  })) });
  const response = await post(url, input(), settings.appToken);
  const value = await response.json();
  assert.equal(response.status, 429);
  assert.equal(value.error.code, 'provider_error');
  assert.equal(value.error.message, value.error.userMessage);
  assert.match(value.error.userMessage, /limiting requests/);
  assert.doesNotMatch(JSON.stringify(value), /Gemini HTTP|quotaMetric|private-project|GEMINI_API_KEY/);
});

test('web lookup is explicit, opt-in and validated for old and new clients', async (t) => {
  const oldRequest = validateRequest(input());
  assert.equal(oldRequest.includeWebInfo, false);
  assert.equal(buildGeminiBody(oldRequest, 1024).tools, undefined);
  assert.equal(buildGeminiBody(oldRequest, 1024).generationConfig.responseJsonSchema.properties.webSummary, undefined);
  assert.throws(() => validateRequest(input({ includeWebInfo: 'true' })), /boolean/);
  const newRequest = validateRequest(input({ includeWebInfo: true }));
  const body = buildGeminiBody(newRequest, 1024);
  assert.equal(body.tools, undefined);
  assert.ok(body.generationConfig.responseJsonSchema.required.includes('webSummary'));
  assert.match(body.systemInstruction.parts[0].text, /SIMILAR products/);
  const settings = config(t, { mode: 'gemini', appToken: 'a-private-test-token' });
  const url = await running(t, settings, { analyze: async (request) => {
    assert.equal(request.includeWebInfo, true);
    return { answer: 'A bottle.', target: null, needsClearerView: false, webInfo: null };
  } });
  assert.equal((await post(url, input({ includeWebInfo: true }), settings.appToken)).status, 200);
});

test('web cards use actual grounding links and suppress unsupported summaries', () => {
  const candidate = { groundingMetadata: {
    groundingChunks: [
      { web: { title: 'Bottle listing', uri: 'https://shop.example.com/bottle' } },
      { web: { title: 'Duplicate', uri: 'https://shop.example.com/bottle' } },
      { web: { title: 'Unsafe', uri: 'javascript:alert(1)' } },
    ],
    groundingSupports: [{ groundingChunkIndices: [0], segment: { text: 'Similar bottle costs CAD 25.' } }],
    searchEntryPoint: { renderedContent: '<div>Google search suggestions</div>' },
  } };
  const answer = { webSummary: 'A similar bottle costs CAD 25 at the listed retailer.', url: 'https://invented.example.com' };
  const info = extractWebInfo(candidate, answer);
  assert.equal(info.sources.length, 1);
  assert.equal(info.sources[0].url, 'https://shop.example.com/bottle');
  assert.equal(info.summary, answer.webSummary);
  assert.match(info.searchSuggestionHTML, /Google search suggestions/);
  assert.doesNotMatch(JSON.stringify(info), /invented/);
  assert.equal(extractWebInfo({}, answer), null);
  candidate.groundingMetadata.groundingSupports = [];
  assert.equal(extractWebInfo(candidate, answer), null);
  candidate.groundingMetadata.groundingSupports = [null];
  assert.equal(extractWebInfo(candidate, answer), null);
  candidate.groundingMetadata.groundingChunks = [{ web: { uri: 'http://localhost/admin' } }];
  assert.equal(extractWebInfo(candidate, answer), null);
});

test('source URLs reject local, credential-bearing and executable destinations', () => {
  for (const url of ['javascript:alert(1)', 'file:///etc/hosts', 'http://example.com',
    'https://localhost/a', 'https://box.local/a', 'https://box.internal/a', 'https://127.0.0.1/a',
    'https://169.254.169.254/a', 'https://[::1]/a', 'https://user:password@example.com',
    'https://example.com:8787/', 'https://0x7f000001/']) {
    assert.equal(publicHTTPS(url), null, url);
  }
  assert.equal(publicHTTPS('https://shop.example.com/bottle'), 'https://shop.example.com/bottle');
});

test('legacy web cards use Serper evidence and never a built-in Gemini search tool', async (t) => {
  for (const enabled of [false, true]) {
    const settings = config(t, { serperApiKey: 'fake-serper-key' });
    const calls = [];
    const result = await analyzeWithGemini(input({ includeWebInfo: enabled }), settings, async (url, options) => {
      const body = JSON.parse(options.body);
      calls.push({ url, body });
      assert.equal(body.tools, undefined);
      if (url === 'https://google.serper.dev/search') {
        return { ok: true, json: async () => ({ organic: [{ title: 'Bottle', link: 'https://shop.vendor.com/bottle', snippet: 'Similar bottle: CAD 25.' }] }) };
      }
      const final = calls.length > 1;
      return { ok: true, json: async () => ({ candidates: [{ finishReason: 'STOP', content: { parts: [{ text: JSON.stringify({
        answer: 'A bottle.', targetLabel: null, box: null, needsClearerView: false,
        searchQuery: enabled && !final ? 'bottle Canada price' : null,
        sourceIds: final ? ['s1'] : [], webSummary: final ? 'Similar bottle: CAD 25.' : null,
      }) }] } }] }) };
    });
    assert.equal(calls.length, enabled ? 3 : 1);
    assert.equal(result.webInfo !== null, enabled);
    if (enabled) {
      assert.match(result.webInfo.summary, /CAD 25/);
      assert.equal(result.webInfo.sources[0].url, 'https://shop.vendor.com/bottle');
      assert.match(calls[2].body.contents.at(-1).parts[0].text, /snippets/);
    }
  }
});

test('mock mode never searches even when Web info was requested', async (t) => {
  const settings = config(t);
  const url = await running(t, settings, { analyze: () => { throw new Error('Must not call Gemini'); } });
  const response = await post(url, input({ includeWebInfo: true }));
  assert.equal(response.status, 200);
  const result = await response.json();
  assert.equal(result.mode, 'mock');
  assert.equal(result.webInfo, null);
});

test('incidental search results do not create an automatic web info strip', () => {
  const candidate = { groundingMetadata: {
    groundingChunks: [{ web: { title: 'Incidental result', uri: 'https://example.com/page' } }],
    groundingSupports: [{ groundingChunkIndices: [0] }],
  } };
  for (const webSummary of [undefined, null, '', '   ']) {
    assert.equal(extractWebInfo(candidate, { webSummary }), null);
  }
});

test('per-question search is an explicit boolean opt-in for compatible clients', () => {
  assert.equal(validateRequest(input()).searchEveryQuestion, false);
  assert.equal(validateRequest(input({ searchEveryQuestion: true })).searchEveryQuestion, true);
  assert.equal(validateRequest(input({ searchEveryQuestion: false })).searchEveryQuestion, false);
  assert.throws(() => validateRequest(input({ searchEveryQuestion: 'true' })), /searchEveryQuestion/);
});
