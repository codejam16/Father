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
    Array.from({ length: 7 }, (_, i) => ({ ...button, id: `id${i}`, parentId: null })),
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

test('all-object answers support six separate primary detections with no group box', () => {
  const bottles = Array.from({ length: 6 }, (_, i) => ({ id: `bottle${i}`, parentId: null,
    label: `Bottle ${i + 1}`, box: [100, i * 150 + 10, 600, i * 150 + 110], kind: 'object', emphasis: 'primary' }));
  const result = validateAnswer(answer(bottles), []);
  assert.equal(result.targets.length, 6);
  assert.ok(result.targets.every((target) => target.emphasis === 'primary'));
  assert.equal(buildGeminiBody(validateRequest(input()), 2048).generationConfig.responseJsonSchema.properties.targets.maxItems, 6);
});

test('opening a bottle targets its button while its parent remains contextual', () => {
  const parent = { id: 'bottle', parentId: null, label: 'Bottle', box: bottle.box, kind: 'object', emphasis: 'context' };
  const child = { ...button, kind: 'part', emphasis: 'primary' };
  const result = validateAnswer(answer([child, parent], { targetLabel: 'Bottle', box: bottle.box }));
  assert.deepEqual(result.target.box, button.box);
  assert.equal(result.targets.find((target) => target.id === 'bottle').emphasis, 'context');
  assert.equal(result.targets.find((target) => target.id === 'button').kind, 'part');
});

test('an explicit empty target array clears a stale legacy pointer', () => {
  const result = validateAnswer(answer([], { targetLabel: 'Old bottle', box: bottle.box }));
  assert.equal(result.target, null); assert.deepEqual(result.targets, []);
});

test('parts cannot reuse a classified bottle identity or simply copy its whole region', () => {
  const known = { ...bottle, kind: 'object' };
  for (const target of [
    { ...button, id: 'bottle', parentId: null, kind: 'part' },
    { ...button, box: bottle.box, kind: 'part' },
    { ...button, box: [950, 950, 990, 990], kind: 'part' },
  ]) assert.throws(() => validateAnswer(answer([target]), [known]));
});

test('an unclassified manual selection can be resolved as a specific component', () => {
  const selected = { ...bottle, source: 'user', label: 'Selection 1' };
  const request = validateRequest(input({ knownTargets: [selected] }));
  const result = validateAnswer(answer([{ id: 'bottle', label: 'Release button', parentId: null,
    box: button.box, kind: 'part', emphasis: 'primary' }]), request.knownTargets);
  assert.equal(result.targets[0].kind, 'part');
});

test('duplicate aliases and target sets that exceed capacity through hidden ancestors are rejected', () => {
  const one = { id: 'one', label: 'Bottle left', box: bottle.box, parentId: null, kind: 'object', emphasis: 'primary' };
  assert.throws(() => validateAnswer(answer([one, { ...one, id: 'two', label: 'Bottle right' }])));
  const children = Array.from({ length: 6 }, (_, i) => ({ ...button, id: `button${i}`,
    box: [200, 150 + i * 100, 250, 180 + i * 100], kind: 'part' }));
  assert.throws(() => validateAnswer(answer(children), [bottle]));
});

test('selection coordinates must belong to the same fresh-frame inventory and IDs stay unique', () => {
  assert.throws(() => validateRequest(input({ selections: [bottle, bottle] })));
  assert.throws(() => validateRequest(input({ selections: [{ ...bottle, box: button.box }] })));
  assert.throws(() => validateRequest(input({ knownTargets: [{ ...bottle, kind: 'imaginary' }] })));
});

test('highlight instructions cover plural intent, actual opening mechanisms and hidden components', () => {
  const text = buildGeminiBody(validateRequest(input()), 2048).systemInstruction.parts[0].text;
  assert.match(text, /Not every bottle has a push button/);
  assert.match(text, /separate primary target for every clearly visible bottle/);
  assert.match(text, /Do not let an old focus restrict an explicit plural/);
  assert.match(text, /emphasis="context"/);
});
