import test from 'node:test';
import assert from 'node:assert/strict';
import { validateRequest, validateAnswer } from '../src/contract.mjs';
import { buildGeminiBody } from '../src/gemini.mjs';

const bottle = { id: 'bottle', label: 'Bottle', parentId: null, source: 'assistant', state: 'visible',
  box: [100, 100, 900, 900], isFocused: true };
const input = (extra = {}) => ({ frameId: 'frame', capturedAt: new Date().toISOString(), question: 'How do I open it?',
  image: { mimeType: 'image/jpeg', width: 480, height: 640, base64: Buffer.from([255, 216, 255, 217]).toString('base64') },
  knownTargets: [bottle], ...extra });
const answer = (targets, extra = {}) => ({ answer: 'Press the release button.', box: null, targetLabel: null,
  needsClearerView: false, targets, ...extra });
const button = { id: 'button', label: 'Release button', parentId: 'bottle', box: [200, 300, 300, 400] };

test('follow-up context includes the existing bottle ID and current frame coordinates', () => {
  const request = validateRequest(input());
  const body = buildGeminiBody(request, 2048);
  const context = JSON.parse(body.contents.at(-1).parts[0].text);
  assert.equal(context.knownTargets[0].id, 'bottle');
  assert.deepEqual(context.knownTargets[0].box, bottle.box);
  assert.ok(body.generationConfig.responseJsonSchema.required.includes('targets'));
  assert.match(body.systemInstruction.parts[0].text, /without replacing its parent/);
});

test('a new child target can refer to a parent remembered from an earlier question', () => {
  const result = validateAnswer(answer([button]), [bottle]);
  assert.equal(result.targets[0].parentId, 'bottle');
  assert.equal(result.targets[0].id, 'button');
  assert.deepEqual(result.target.box, button.box);
});

test('multiple new related targets are validated and ordered parent-first', () => {
  const parent = { id: 'bottle', parentId: null, label: 'Bottle', box: bottle.box };
  const result = validateAnswer(answer([button, parent]));
  assert.deepEqual(result.targets.map((target) => target.id), ['bottle', 'button']);
});

test('duplicate IDs, unknown parents, cycles, excess targets and invalid boxes are rejected', () => {
  for (const targets of [
    [button, button], [button],
    [{ ...button, parentId: 'other' }, { ...button, id: 'other', parentId: 'button' }],
    Array.from({ length: 5 }, (_, i) => ({ ...button, id: `id${i}`, parentId: null })),
    [{ ...button, parentId: null, box: [500, 0, 100, 100] }],
  ]) assert.throws(() => validateAnswer(answer(targets)));
});

test('invisible objects have no stale coordinates and cannot be sent as active selections', () => {
  const dormant = { ...bottle, state: 'dormant', box: null };
  const request = validateRequest(input({ knownTargets: [dormant] }));
  assert.equal(request.knownTargets[0].box, null);
  assert.throws(() => validateRequest(input({ knownTargets: [{ ...bottle, state: 'dormant' }] })));
  assert.throws(() => validateRequest(input({ knownTargets: [dormant], selections: [{ ...bottle }] })));
});

test('several explicit manual selections are attached to one fresh image', () => {
  const second = { ...bottle, id: 'lid', label: 'Lid', parentId: 'bottle', isFocused: false };
  const request = validateRequest(input({ knownTargets: [bottle, second], selections: [bottle, second] }));
  assert.equal(request.selections.length, 2);
  assert.deepEqual(request.selections.map((target) => target.id), ['bottle', 'lid']);
});

test('uncertain views suppress every returned target, with legacy answers still accepted', () => {
  assert.deepEqual(validateAnswer(answer([button], { needsClearerView: true }), [bottle]).targets, []);
  const legacy = validateAnswer({ answer: 'A bottle.', box: bottle.box, targetLabel: 'Bottle', needsClearerView: false });
  assert.equal(legacy.target.label, 'Bottle');
});
