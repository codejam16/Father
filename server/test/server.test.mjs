import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createApp, loadConfig } from '../src/server.mjs';
import { APIError, validateAnnotations, validateAnswer, validateRequest } from '../src/contract.mjs';
import { analyzeWithGemini, buildGeminiBody, generateWithSchemaFallback, looksLikeExplanation, modelFor } from '../src/gemini.mjs';
import { checkGemini } from '../src/doctor.mjs';
import { extractWebInfo, publicHTTPS } from '../src/web-info.mjs';

// Minimal JPEG envelope for transport validation. No test calls a real model.
const input = (extra = {}) => ({
  frameId: 'frame-1', capturedAt: '2026-11-21T15:00:00Z', question: 'What can you see?', task: '',
  image: { base64: Buffer.from([0xff, 0xd8, 0xff, 0xd9]).toString('base64'), mimeType: 'image/jpeg', width: 480, height: 640 },
  history: [], ...extra,
});

function config(_t, extra = {}) { return { ...loadConfig({}), diagnosticLogPath: null, diagnosticLogger: () => {}, retryDelayMs: 0, ...extra }; }

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
    // Only Google's temporary overload errors are retried (twice), never quota or request errors.
    // Google "busy" errors get two retries; a rejected answer format gets one simpler retry.
    assert.equal(calls, status >= 500 ? 3 : /structured response/.test(String(expected)) ? 2 : 1);
  }
});

test('a momentary Google overload is retried and then succeeds', async (t) => {
  let calls = 0;
  const result = await analyzeWithGemini(input(), config(t), async () => {
    calls++;
    if (calls === 1) return { ok: false, status: 503, json: async () => ({ error: { message: 'overloaded' } }) };
    return { ok: true, json: async () => ({ candidates: [{ finishReason: 'STOP', content: { parts: [
      { text: JSON.stringify({ answer: 'A connector.', box: null, targetLabel: null, needsClearerView: false }) },
    ] } }] }) };
  });
  assert.equal(calls, 2);
  assert.equal(result.answer, 'A connector.');
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

test('answers box what they are about, and identify the device instead of asking', () => {
  const answer = validateAnswer({ answer: 'Click System Settings.', needsClearerView: false, targetLabel: 'System Settings icon', box: [100, 100, 300, 300] });
  assert.deepEqual(answer.target.box, [100, 100, 300, 300]);
  const body = buildGeminiBody({ task: '', question: 'How do I change my wallpaper?', capturedAt: new Date().toISOString(), frameId: 'f',
    selection: null, history: [], includeWebInfo: false, image: { mimeType: 'image/jpeg', base64: '/9j/2Q==' } }, 512);
  const text = body.systemInstruction.parts[0].text;
  assert.match(text, /most useful things you do/);
  assert.match(text, /never ask the user to confirm something the image already shows/);
});

test('per-question search is an explicit boolean opt-in for compatible clients', () => {
  assert.equal(validateRequest(input()).searchEveryQuestion, false);
  assert.equal(validateRequest(input({ searchEveryQuestion: true })).searchEveryQuestion, true);
  assert.equal(validateRequest(input({ searchEveryQuestion: false })).searchEveryQuestion, false);
  assert.throws(() => validateRequest(input({ searchEveryQuestion: 'true' })), /searchEveryQuestion/);
});

test('validation failures log a redacted reason and send a specific friendly message to the phone', async (t) => {
  const logs = [];
  t.mock.method(console, 'warn', (message) => logs.push(message));
  const settings = config(t, { mode: 'gemini', appToken: 'private-test-token', apiKey: 'private-model-key' });
  const url = await running(t, settings, { analyze: async () => {
    throw new APIError(502, 'invalid_action', 'Invalid citation; diagnostic private-model-key');
  } });
  const response = await post(url, input(), settings.appToken);
  assert.equal(response.status, 502);
  const value = await response.json();
  assert.match(value.error.userMessage, /interpret the AI/);
  assert.doesNotMatch(JSON.stringify(value), /Invalid citation|private-model-key/);
  const rejected = logs.find((line) => line.includes('Request rejected:'));
  assert.match(rejected, /invalid_action/);
  assert.match(rejected, /Invalid citation/);
  assert.doesNotMatch(rejected, /private-model-key/);
});

test('questions use high image detail and can carry a fingertip close-up', () => {
  const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0xff, 0xd9]).toString('base64');
  const image = { base64: jpeg, mimeType: 'image/jpeg', width: 720, height: 1280 };
  const request = validateRequest({ frameId: 'f', capturedAt: new Date().toISOString(), question: 'Which key is this?', task: '',
    image, detailImage: { ...image, width: 432, height: 432, box: [500, 300, 700, 700] } });
  assert.deepEqual(request.detailImage.box, [500, 300, 700, 700]);
  assert.throws(() => validateRequest({ frameId: 'f', capturedAt: new Date().toISOString(), question: 'x', task: '',
    image, detailImage: { ...image, box: [700, 300, 500, 700] } }));
  const body = buildGeminiBody({ ...request, history: [], includeWebInfo: false }, 512);
  const parts = body.contents.at(-1).parts;
  assert.equal(parts.filter((part) => part.inlineData).length, 2);
  assert.match(parts.find((part) => part.text?.startsWith('Second image')).text, /FIRST image's coordinates/);
  assert.equal(body.generationConfig.mediaResolution, 'MEDIA_RESOLUTION_HIGH');
  assert.match(body.systemInstruction.parts[0].text, /keyboard keys/);
  const plain = buildGeminiBody({ ...request, detailImage: null, history: [], includeWebInfo: false }, 512);
  assert.equal(plain.contents.at(-1).parts.filter((part) => part.inlineData).length, 1);
});

test('explanations of diagrams come with a validated visual walkthrough', () => {
  const answer = validateAnswer({ answer: 'Current leaves the + terminal, passes the resistor and reaches B.', needsClearerView: false,
    targetLabel: null, box: null, annotations: [
      { caption: 'Battery + terminal', box: [100, 100, 200, 200], path: null },
      { caption: 'Current flows through the resistor to B', box: null, path: [[150, 200], [150, 600], [500, 600]] },
      { caption: 'Broken beat', box: [900, 0, 100, 100], path: [[1, 2, 3]] },
      { caption: '', box: [0, 0, 10, 10], path: null },
    ] });
  assert.equal(answer.annotations.length, 2);
  assert.equal(answer.annotations[0].say, 'Battery + terminal');
  const spoken = validateAnnotations([{ caption: 'Resistor', say: '  Then it passes through the resistor. ', box: [1, 1, 50, 50], path: null }]);
  assert.equal(spoken[0].say, 'Then it passes through the resistor.');
  assert.deepEqual(answer.annotations[1].path, [[150, 200], [150, 600], [500, 600]]);
  assert.deepEqual(validateAnnotations(undefined), []);
  const flat = validateAnnotations([{ caption: 'Along the wire', box: null, path: [100, 200, 100, 700, 400, 700] }]);
  assert.deepEqual(flat[0].path, [[100, 200], [100, 700], [400, 700]]);
  assert.deepEqual(validateAnnotations([{ caption: 'Odd', box: null, path: [1, 2, 3] }]), []);
  const unclear = validateAnswer({ answer: 'Move closer.', needsClearerView: true, targetLabel: null, box: null,
    annotations: [{ caption: 'x', box: [0, 0, 10, 10], path: null }] });
  assert.deepEqual(unclear.annotations, []);
  const body = buildGeminiBody({ task: '', question: 'Explain this circuit', capturedAt: new Date().toISOString(), frameId: 'f',
    selection: null, history: [], includeWebInfo: false, image: { mimeType: 'image/jpeg', base64: '/9j/2Q==' } }, 512);
  assert.ok(body.generationConfig.responseJsonSchema.required.includes('annotations'));
  assert.match(body.systemInstruction.parts[0].text, /placed ON the drawn lines/);
});

test('answer schemas avoid nested size-limited arrays that Gemini rejects as too complex', () => {
  const body = buildGeminiBody({ task: '', question: 'Explain this', capturedAt: new Date().toISOString(), frameId: 'f',
    selection: null, history: [], includeWebInfo: false, image: { mimeType: 'image/jpeg', base64: '/9j/2Q==' } }, 512);
  const beat = body.generationConfig.responseJsonSchema.properties.annotations;
  assert.equal(beat.maxItems, undefined);
  assert.equal(beat.items.properties.path.items.type, 'number');
  assert.equal(beat.items.properties.path.maxItems, undefined);
});

test('a rejected answer format is retried once without the walkthrough and tools fields', async (t) => {
  const bodies = [];
  const tooComplex = { ok: false, status: 400, json: async () => ({ error: { code: 400, status: 'INVALID_ARGUMENT',
    message: 'The specified schema produces a constraint that has too many states for serving.' } }) };
  const ok = { ok: true, json: async () => ({ candidates: [{ finishReason: 'STOP', content: { parts: [
    { text: JSON.stringify({ answer: 'A resistor.', box: null, targetLabel: null, needsClearerView: false }) }] } }] }) };
  const body = buildGeminiBody({ task: '', question: 'What is this?', capturedAt: new Date().toISOString(), frameId: 'f',
    selection: null, history: [], includeWebInfo: false, image: { mimeType: 'image/jpeg', base64: '/9j/2Q==' } }, 512);
  const settings = { ...loadConfig({}), diagnosticLogPath: null, diagnosticLogger: () => {}, retryDelayMs: 0 };
  await generateWithSchemaFallback(body, settings, async (url, options) => {
    bodies.push(JSON.parse(options.body));
    return bodies.length === 1 ? tooComplex : ok;
  });
  assert.equal(bodies.length, 2);
  assert.ok('annotations' in bodies[0].generationConfig.responseJsonSchema.properties);
  assert.ok(!('annotations' in bodies[1].generationConfig.responseJsonSchema.properties));
  assert.ok(!bodies[1].generationConfig.responseJsonSchema.required.includes('annotations'));
});

test('walkthrough beats can carry labels, connections, zoom bubbles and shaded regions', () => {
  const [labelled, linked, shaded] = validateAnnotations([
    { caption: 'The resistor', say: 'This is R1.', box: [100, 100, 200, 300], path: null, label: '  R1 · 220 Ω ', to: null, zoom: true, region: null },
    { caption: 'Switch controls the LED', say: 'The switch turns the LED on.', box: [300, 100, 400, 200], path: null, label: null, to: [600, 500, 700, 650], zoom: false, region: null },
    { caption: 'One loop', say: 'Everything in this loop is in series.', box: null, path: null, label: null, to: null, zoom: false, region: [100, 100, 100, 900, 800, 900, 800, 100] },
  ]);
  assert.equal(labelled.label, 'R1 · 220 Ω');
  assert.equal(labelled.zoom, true);
  assert.deepEqual(linked.to, [600, 500, 700, 650]);
  assert.equal(shaded.region.length, 4);
  assert.equal(shaded.zoom, false);
  // A connection or zoom needs a box; a region needs at least three points.
  const [noBox] = validateAnnotations([{ caption: 'x', say: 'x', box: null, path: [1, 1, 50, 50], label: null, to: [1, 1, 5, 5], zoom: true, region: null }]);
  assert.equal(noBox.to, null);
  assert.equal(noBox.zoom, false);
  assert.deepEqual(validateAnnotations([{ caption: 'x', say: 'x', box: null, path: null, label: null, to: null, zoom: false, region: [1, 1, 5, 5] }]), []);
});

test('explanation questions are recognised and sent to the stronger model', () => {
  for (const question of ['How does the current go from A to B?', 'Explain this circuit', 'Trace the signal', 'walk me through this chart', 'how does this gear work?'])
    assert.ok(looksLikeExplanation(question), question);
  for (const question of ['What is this?', 'How do I open the cover?', 'Where can I buy this?'])
    assert.ok(!looksLikeExplanation(question), question);
  const settings = { ...loadConfig({ GEMINI_MODEL: 'gemini-3.5-flash-lite' }) };
  assert.equal(settings.explainModel, 'gemini-3.8-flash');
  assert.equal(modelFor({ question: 'Explain this diagram' }, settings).model, 'gemini-3.8-flash');
  assert.equal(modelFor({ question: 'What is this?' }, settings).model, 'gemini-3.5-flash-lite');
  assert.equal(loadConfig({ EXPLAIN_MODEL: 'same' }).explainModel, null);
  const body = buildGeminiBody({ task: '', question: 'Explain', capturedAt: new Date().toISOString(), frameId: 'f',
    selection: null, history: [], includeWebInfo: false, image: { mimeType: 'image/jpeg', base64: '/9j/2Q==' } }, 512);
  assert.match(body.systemInstruction.parts[0].text, /REQUIRED for any "from X to Y"/);
});

test('if the explanation model is busy, the regular model answers instead', async () => {
  const models = [];
  const settings = { ...loadConfig({ GEMINI_MODEL: 'gemini-3.5-flash-lite' }), diagnosticLogPath: null, diagnosticLogger: () => {}, retryDelayMs: 0 };
  const body = buildGeminiBody({ task: '', question: 'Explain this circuit', capturedAt: new Date().toISOString(), frameId: 'f',
    selection: null, history: [], includeWebInfo: false, image: { mimeType: 'image/jpeg', base64: '/9j/2Q==' } }, 512);
  const busy = { ok: false, status: 503, json: async () => ({ error: { code: 503, message: 'high demand' } }) };
  const ok = { ok: true, json: async () => ({ candidates: [{ finishReason: 'STOP', content: { parts: [
    { text: JSON.stringify({ answer: 'It flows from A to B.', box: null, targetLabel: null, needsClearerView: false }) }] } }] }) };
  await generateWithSchemaFallback(body, modelFor({ question: 'Explain this circuit' }, settings), async (url) => {
    models.push(url.match(/models\/([^:]+):/)[1]);
    return url.includes('gemini-3.8-flash') ? busy : ok;
  });
  assert.deepEqual(models, ['gemini-3.8-flash', 'gemini-3.8-flash', 'gemini-3.5-flash-lite']);
});
