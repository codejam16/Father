import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createApp, loadConfig } from '../src/server.mjs';
import { findPicture, keyWords, titleMatches, validatePictureRequest } from '../src/picture.mjs';
import { validateAnswer } from '../src/contract.mjs';

const config = (extra = {}) => ({ ...loadConfig({}), diagnosticLogPath: null, diagnosticLogger: () => {}, retryDelayMs: 0, ...extra });
const json = (body) => ({ ok: true, json: async () => body });

test('picture requests need a short phrase', () => {
  assert.deepEqual(validatePictureRequest({ query: '  Phillips   screwdriver ' }), { query: 'Phillips screwdriver', context: '' });
  assert.throws(() => validatePictureRequest({ query: '' }));
  assert.throws(() => validatePictureRequest({ query: 'x'.repeat(81) }));
});

test('answers can ask for a reference picture', () => {
  const base = { answer: 'You need a spudger.', targetLabel: null, box: null, needsClearerView: false, annotations: [] };
  assert.equal(validateAnswer({ ...base, pictureOf: ' spudger  tool ' }).pictureOf, 'spudger tool');
  assert.equal(validateAnswer({ ...base, pictureOf: null }).pictureOf, null);
  assert.equal(validateAnswer(base).pictureOf, null);
});

test('pictures must be named after the thing asked for', () => {
  assert.deepEqual(keyWords('a small pair of tweezers'), ['tweezer']);
  assert.equal(titleMatches('Tweezers', 'tweezers'), true);
  assert.equal(titleMatches('File:Precision_tweezers_01.jpg', 'fine tweezers'), true);
  assert.equal(titleMatches('Robotic hand', 'tweezers'), false);
  assert.equal(titleMatches('Screwdriver', 'Phillips #1 screwdriver'), true);
});

test('without a search key: the exact Wikipedia article first, never an unrelated one', async () => {
  const urls = [];
  const result = await findPicture({ query: 'tweezers', context: '' }, config(), async (url) => {
    urls.push(String(url));
    return json({ query: { pages: [{ index: 1, title: 'Tweezers', thumbnail: { source: 'https://upload.wikimedia.org/tweezers.jpg' } }] } });
  });
  assert.match(urls[0], /en\.wikipedia\.org.*titles=tweezers/);
  assert.equal(result.picture.imageUrl, 'https://upload.wikimedia.org/tweezers.jpg');

  // Search results that don't name the item are skipped: no picture rather than a wrong one.
  const none = await findPicture({ query: 'tweezers', context: 'fix a robot lamp' }, config(), async () =>
    json({ query: { pages: [{ index: 1, title: 'Robotic hand', thumbnail: { source: 'https://upload.wikimedia.org/robot.jpg' },
      imageinfo: [{ thumburl: 'https://upload.wikimedia.org/robot.jpg', mime: 'image/jpeg' }] }] } }));
  assert.equal(none.picture, null);
});

test('Commons photos named after the item are used when there is no article', async () => {
  const result = await findPicture({ query: 'precision tweezers', context: '' }, config(), async (url) => {
    if (String(url).includes('commons.wikimedia.org')) {
      return json({ query: { pages: [
        { index: 1, title: 'File:Lab robot.jpg', imageinfo: [{ thumburl: 'https://upload.wikimedia.org/robot.jpg', mime: 'image/jpeg' }] },
        { index: 2, title: 'File:Precision tweezers.jpg', imageinfo: [{ thumburl: 'https://upload.wikimedia.org/pt.jpg', mime: 'image/jpeg' }] },
      ] } });
    }
    return json({ query: { pages: [{ title: 'precision tweezers', missing: true }] } });
  });
  assert.equal(result.picture.imageUrl, 'https://upload.wikimedia.org/pt.jpg');
  assert.equal(result.picture.source, 'Wikimedia Commons');
});

test('with a search key, Google Images comes first; http and svg images are skipped', async () => {
  const result = await findPicture({ query: 'spudger', context: '' }, config({ serperApiKey: 'k' }), async (url) => {
    assert.match(String(url), /serper\.dev\/images/);
    return json({ images: [
      { imageUrl: 'http://insecure.example/a.jpg' }, { imageUrl: 'https://x.example/icon.svg' },
      { imageUrl: 'https://shop.example/robot.jpg', title: 'Robot arm', source: 'Shop' },
      { imageUrl: 'https://shop.example/spudger.jpg', title: 'Spudger', source: 'Shop' },
    ] });
  });
  assert.equal(result.picture.imageUrl, 'https://shop.example/spudger.jpg');
});

test('no picture found is not an error', async (t) => {
  const server = createApp(config(), { picture: async () => ({ picture: null }) });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise((resolve) => { server.close(resolve); server.closeAllConnections(); }));
  const response = await fetch(`http://127.0.0.1:${server.address().port}/picture`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ query: 'nothing' }),
  });
  assert.equal(response.status, 200);
  assert.equal((await response.json()).picture, null);
});
