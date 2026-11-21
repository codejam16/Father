import test from 'node:test';
import assert from 'node:assert/strict';
import { generateContent } from '../src/gemini.mjs';
import { GEMINI_TIMEOUT_MS, SEARCH_TIMEOUT_MS, ANALYSIS_TIMEOUT_MS } from '../src/timeouts.mjs';

function harness(t) {
  t.mock.method(console, 'log', () => {});
  t.mock.method(console, 'warn', () => {});
  const timeout = new AbortController();
  const records = [];
  t.mock.method(AbortSignal, 'timeout', (milliseconds) => {
    assert.equal(milliseconds, 40_000);
    return timeout.signal;
  });
  return { timeout, records, config: { model: 'gemini-3.8-flash', diagnosticLogger: (record) => records.push(record) } };
}

function waitForAbort(signal) {
  return new Promise((resolve, reject) => {
    signal.addEventListener('abort', () => reject(signal.reason), { once: true });
  });
}

test('a slow Gemini call uses the longer deadline, records its timeout and never retries', async (t) => {
  const { timeout, records, config } = harness(t);
  let calls = 0;
  const pending = generateContent({}, config, async (url, { signal }) => {
    calls++;
    const result = waitForAbort(signal);
    queueMicrotask(() => timeout.abort(new DOMException('Deadline', 'TimeoutError')));
    return result;
  });
  await assert.rejects(pending, (error) => error.status === 504 && /taking too long/.test(error.userMessage));
  assert.equal(calls, 1);
  assert.equal(records[0].transportError, 'timeout');
  assert.equal(records[0].httpStatus, null);
  assert.equal(records[0].timeoutMs, 40_000);
});

test('Gemini deadline also cancels a stalled response body', async (t) => {
  const { timeout, records, config } = harness(t);
  await assert.rejects(generateContent({}, config, async (url, { signal }) => ({
    ok: true, status: 200,
    json() {
      const pending = waitForAbort(signal);
      queueMicrotask(() => timeout.abort(new DOMException('Deadline', 'TimeoutError')));
      return pending;
    },
  })), (error) => error.status === 504 && error.code === 'provider_unavailable');
  assert.equal(records[0].transportError, 'timeout');
});

test('client cancellation interrupts Gemini without a retry or a false provider failure', async (t) => {
  const { records, config } = harness(t);
  const client = new AbortController();
  const reason = new DOMException('Client disconnected', 'AbortError');
  let calls = 0;
  await assert.rejects(generateContent({}, { ...config, signal: client.signal }, async (url, { signal }) => {
    calls++;
    const pending = waitForAbort(signal);
    queueMicrotask(() => client.abort(reason));
    return pending;
  }), (error) => error === reason);
  assert.equal(calls, 1);
  assert.equal(records.length, 0);
});

test('network failures are distinguished from model timeouts without logging credentials', async (t) => {
  const { records, config } = harness(t);
  let calls = 0;
  await assert.rejects(generateContent({}, config, async () => {
    calls++;
    throw new TypeError('Private transport details');
  }), (error) => error.status === 502 && /reach the AI service/.test(error.userMessage));
  assert.equal(calls, 1);
  assert.equal(records[0].transportError, 'network');
  assert.doesNotMatch(JSON.stringify(records), /Private transport details/);
});

test('malformed JSON remains a model output error rather than a transport timeout', async (t) => {
  const { records, config } = harness(t);
  await assert.rejects(generateContent({}, config, async () => new Response('not JSON')),
    (error) => error.status === 502 && error.code === 'invalid_model_output');
  assert.equal(records.length, 0);
});

test('whole-request deadline covers two model calls and a search with processing headroom', () => {
  assert.ok(ANALYSIS_TIMEOUT_MS > 2 * GEMINI_TIMEOUT_MS + SEARCH_TIMEOUT_MS);
});
