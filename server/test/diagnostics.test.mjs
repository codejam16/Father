import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { geminiHTTPError } from '../src/provider-error.mjs';
import { logGoogleError, redactDiagnostic } from '../src/diagnostics.mjs';
import { generateContent } from '../src/gemini.mjs';

const googleError = {
  error: {
    code: 429, status: 'RESOURCE_EXHAUSTED',
    message: 'Quota exceeded for metric: generate_content_free_tier_requests; limit: 0. Please retry in 36.2s.',
    details: [
      { '@type': 'type.googleapis.com/google.rpc.QuotaFailure', violations: [{
        quotaMetric: 'generativelanguage.googleapis.com/generate_content_free_tier_requests',
        quotaId: 'GenerateRequestsPerMinutePerProjectPerModel-FreeTier',
        quotaDimensions: { model: 'gemini-3.5-flash-lite', location: 'global' }, quotaValue: '0',
      }] },
      { '@type': 'type.googleapis.com/google.rpc.RetryInfo', retryDelay: '36s' },
    ],
  },
};

test('original Google quota body and retry information reach diagnostics unchanged', async () => {
  const records = [];
  const error = await geminiHTTPError(new Response(JSON.stringify(googleError), {
    status: 429, headers: { 'retry-after': '36', 'x-request-id': 'google-request-id' },
  }), { model: 'gemini-3.5-flash-lite', diagnosticLogger: (event) => records.push(event) },
  { requestId: 'app-request-id', callId: 'call-id', callNumber: 2, operation: 'search_online' });
  assert.equal(error.status, 429);
  assert.equal(error.code, 'provider_error');
  assert.deepEqual(records[0].googleResponse, googleError);
  assert.equal(records[0].retryAfter, '36');
  assert.equal(records[0].googleRequestId, 'google-request-id');
  assert.equal(records[0].model, 'gemini-3.5-flash-lite');
  assert.equal(records[0].callNumber, 2);
  assert.equal(records[0].operation, 'search_online');
  assert.doesNotMatch(error.message, /GenerateRequestsPerMinute|google-request-id/);
});

test('configured secrets and credential fields are redacted without dropping quota diagnostics', async () => {
  const key = 'private-api-key-secret'; const token = 'private-app-token-secret';
  const records = [];
  const payload = structuredClone(googleError);
  payload.error.message += ` key=${key} encoded=${encodeURIComponent(key)} Bearer abc123-secret-token ${token}`;
  payload.error.details.push({ apiKey: key, authorization: 'Bearer secret', app_token: token, quotaValue: '15' });
  await geminiHTTPError(new Response(JSON.stringify(payload), { status: 429 }), {
    apiKey: key, appToken: token, diagnosticLogger: (record) => records.push(record),
  });
  const serialized = JSON.stringify(records);
  assert.doesNotMatch(serialized, /private-api-key-secret|private-app-token-secret|abc123-secret-token/);
  assert.match(serialized, /GenerateRequestsPerMinutePerProjectPerModel/);
  assert.equal(records[0].googleResponse.error.details[2].quotaValue, '15');
  assert.equal(records[0].googleResponse.error.details[2].apiKey, '[REDACTED]');
});

test('non-JSON Google responses and unavailable bodies are clearly logged', async () => {
  const records = [];
  const config = { diagnosticLogger: (event) => records.push(event) };
  await geminiHTTPError(new Response('<html>Service unavailable</html>', { status: 503 }), config);
  assert.equal(records[0].googleResponse, '<html>Service unavailable</html>');
  await geminiHTTPError({ status: 429, json: async () => { throw new Error('body unreadable'); } }, config);
  assert.equal(records[1].googleResponse, '[Response body unavailable]');
});

test('recognized API key patterns are redacted even without explicit config', () => {
  const apiKey = 'AIza' + 's'.repeat(35);
  assert.equal(redactDiagnostic({ message: `Invalid key: ${apiKey}` }).message, 'Invalid key: [REDACTED]');
});

test('Serper credentials are redacted from diagnostic fields and echoed messages', () => {
  const records = [];
  logGoogleError({ 'X-API-KEY': 'search-secret', serperApiKey: 'search-secret', message: 'echo search-secret' },
    { serperApiKey: 'search-secret', diagnosticLogger: (record) => records.push(record) });
  assert.doesNotMatch(JSON.stringify(records), /search-secret/);
  assert.equal(records[0]['X-API-KEY'], '[REDACTED]');
});

test('Google error records persist locally with owner-only access and bounded rotation', (t) => {
  t.mock.method(console, 'error', () => {});
  const directory = mkdtempSync(join(tmpdir(), 'tasklens-errors-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const path = join(directory, 'provider-errors.jsonl');
  const config = { apiKey: 'very-private-secret', diagnosticLogPath: path };
  logGoogleError({ httpStatus: 429, googleResponse: { ...googleError, echo: 'very-private-secret' } }, config);
  const saved = JSON.parse(readFileSync(path, 'utf8').trim());
  assert.equal(saved.httpStatus, 429);
  assert.equal(saved.googleResponse.echo, '[REDACTED]');
  assert.equal(statSync(path).mode & 0o777, 0o600);
  writeFileSync(path, 'x'.repeat(1_000_000));
  logGoogleError({ httpStatus: 503 }, config);
  assert.ok(existsSync(`${path}.1`));
  assert.equal(JSON.parse(readFileSync(path, 'utf8').trim()).httpStatus, 503);
});

test('per-call trace distinguishes camera and search calls and retains Google 429 without retrying', async (t) => {
  t.mock.method(console, 'log', () => {});
  const records = []; const trace = { requestId: 'one-user-question', calls: 0 };
  const config = { model: 'gemini-3.5-flash-lite', trace, diagnosticLogger: (event) => records.push(event) };
  let calls = 0;
  const fetcher = async () => {
    calls++;
    return calls === 1 ? new Response(JSON.stringify({ candidates: [{ finishReason: 'STOP' }] }), { status: 200 })
      : new Response(JSON.stringify(googleError), { status: 429 });
  };
  await generateContent({}, config, fetcher);
  await assert.rejects(generateContent({ tools: [{ google_search: {} }] }, config, fetcher), (error) => error.status === 429);
  assert.equal(calls, 2);
  assert.equal(trace.calls, 2);
  assert.equal(records[0].requestId, trace.requestId);
  assert.equal(records[0].operation, 'search_online');
  assert.deepEqual(records[0].googleResponse, googleError);
});

test('spoken provider messages are conversational while developer errors and original logs retain detail', async () => {
  for (const [status, reason, expected] of [
    [429, '', /limiting requests/], [503, '', /busy right now/],
    [401, 'API_KEY_INVALID', /connection settings/], [404, '', /connection settings/],
    [400, 'image could not be decoded', /camera view/], [400, 'schema unsupported', /get an answer/],
  ]) {
    const records = [];
    const error = await geminiHTTPError(new Response(JSON.stringify({ error: {
      code: status, message: reason || 'Actual Google error', details: [{ quotaMetric: 'technical-metric' }],
    } }), { status }), { diagnosticLogger: (record) => records.push(record) });
    assert.match(error.userMessage, expected);
    assert.doesNotMatch(error.userMessage, /HTTP|API_KEY|quotaMetric|technical-metric|schema|backend|\.env|generationConfig/);
    assert.match(error.message, new RegExp(`Gemini HTTP ${status}`));
    assert.equal(records[0].googleResponse.error.details[0].quotaMetric, 'technical-metric');
  }
});
