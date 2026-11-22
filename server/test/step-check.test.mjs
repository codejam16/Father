import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createApp, loadConfig } from '../src/server.mjs';
import { buildCheckBody, checkStepWithGemini, validateCheck, validateCheckRequest } from '../src/step-check.mjs';
import { validateRequest } from '../src/contract.mjs';
import { buildAgentBody } from '../src/agent.mjs';
import { emptyMemory } from '../src/task-session.mjs';

const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0xff, 0xd9]).toString('base64');
const frame = (id) => ({ frameId: id, capturedAt: new Date().toISOString(), image: { base64: jpeg, mimeType: 'image/jpeg', width: 480, height: 640 } });
const checkInput = (extra = {}) => ({ stepId: 'step-2', step: 'Unscrew the four screws on the back cover.', goal: 'Replace the fan', task: '', frames: [frame('a'), frame('b'), frame('c')], ...extra });
const config = (extra = {}) => ({ ...loadConfig({}), diagnosticLogPath: null, diagnosticLogger: () => {}, retryDelayMs: 0, ...extra });

async function running(t, settings, dependencies) {
  const server = createApp(settings, dependencies);
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise((resolve) => { server.close(resolve); server.closeAllConnections(); }));
  return `http://127.0.0.1:${server.address().port}`;
}

const postCheck = (base, body) => fetch(`${base}/check`, {
  method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
});

test('check requests accept one to three valid frames only', () => {
  assert.equal(validateCheckRequest(checkInput()).frames.length, 3);
  assert.throws(() => validateCheckRequest(checkInput({ frames: [] })));
  assert.throws(() => validateCheckRequest(checkInput({ frames: [frame('a'), frame('b'), frame('c'), frame('d')] })));
  assert.throws(() => validateCheckRequest(checkInput({ stepId: 'bad id!' })));
  assert.throws(() => validateCheckRequest(checkInput({ frames: [{ ...frame('a'), image: { base64: 'nope', mimeType: 'image/jpeg', width: 1, height: 1 } }] })));
});

test('mock checks only confirm when the user says the step is done', async (t) => {
  const url = await running(t, config(), { check: () => { throw new Error('Must not contact provider'); } });
  const waiting = await (await postCheck(url, checkInput())).json();
  assert.equal(waiting.status, 'in_progress');
  assert.equal(waiting.stepId, 'step-2');
  const done = await (await postCheck(url, checkInput({ userSaysDone: true }))).json();
  assert.equal(done.status, 'done');
  assert.equal(done.mode, 'mock');
});

test('check results are validated, with friendly fallbacks and lenient positions', () => {
  assert.throws(() => validateCheck({ status: 'finished', feedback: '' }));
  const problem = validateCheck({ status: 'problem', feedback: '', targetLabel: 'screw', box: [900, 0, 100, 100] });
  assert.match(problem.feedback, /doesn't look right/);
  assert.equal(problem.target, null);
  const located = validateCheck({ status: 'problem', feedback: 'Wrong screw.', targetLabel: 'screw', box: [400, 400, 500, 500] });
  assert.deepEqual(located.target.box, [400, 400, 500, 500]);
});

test('check bodies send every frame in order and a small structured answer', async () => {
  const input = validateCheckRequest(checkInput());
  const body = buildCheckBody(input, 2048);
  assert.equal(body.contents[0].parts.filter((part) => part.inlineData).length, 3);
  assert.ok(body.generationConfig.maxOutputTokens <= 1024);
  assert.match(body.systemInstruction.parts[0].text, /CURRENT STEP/);
  assert.match(body.systemInstruction.parts[0].text, /NEXT step/);
  assert.match(body.systemInstruction.parts[0].text, /most useful things you do/);
  const withNext = buildCheckBody(validateCheckRequest(checkInput({ nextStep: 'Lift the cover off.' })), 2048);
  assert.equal(JSON.parse(withNext.contents[0].parts[0].text).nextStep, 'Lift the cover off.');
  let calls = 0;
  const result = await checkStepWithGemini(input, config(), async () => {
    calls++;
    return { ok: true, json: async () => ({ candidates: [{ finishReason: 'STOP', content: { parts: [
      { text: JSON.stringify({ status: 'done', feedback: 'All four screws are out.', targetLabel: null, box: null }) },
    ] } }] }) };
  });
  assert.equal(calls, 1);
  assert.equal(result.status, 'done');
});

test('guided questions ask for one step at a time', () => {
  const request = validateRequest({ frameId: 'f', capturedAt: new Date().toISOString(), question: 'My fan is loud', task: '',
    image: frame('f').image, sessionId: '11111111-1111-4111-8111-111111111111', guided: true });
  assert.equal(request.guided, true);
  const session = { memory: emptyMemory(), sources: [], reports: [] };
  const body = buildAgentBody(request, config(), session, false);
  assert.ok(body.systemInstruction.parts.some((part) => /ONLY the first step/.test(part.text)));
  assert.ok(body.systemInstruction.parts.some((part) => /highlight where to act/.test(part.text)));
  const plain = buildAgentBody({ ...request, guided: false }, config(), session, false);
  assert.ok(!plain.systemInstruction.parts.some((part) => /ONLY the first step/.test(part.text)));
});
