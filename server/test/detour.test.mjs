import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { once } from 'node:events';
import { loadCatalog, validatePOI, normalizeMunicipal, normalizeOSM, LandmarkService, distance } from '../src/landmarks.mjs';
import { DetourStories } from '../src/detour-story.mjs';
import { createApp, loadConfig } from '../src/server.mjs';

const catalog = loadCatalog();
const centre = { latitude: 45.505, longitude: -73.57 };
const mapped = { type: 'node', id: 123, lat: 45.505, lon: -73.57,
  tags: { name: 'Mapped public sculpture', tourism: 'artwork', artist_name: 'An artist', wikipedia: 'en:Public sculpture', wikidata: 'Q123' } };

test('curated landmarks have real numeric coordinates, source references and matching app/backend copies', () => {
  assert.ok(catalog.landmarks.length >= 20 && catalog.landmarks.length <= 50);
  assert.equal(new Set(catalog.landmarks.map((p) => p.id)).size, catalog.landmarks.length);
  for (const poi of catalog.landmarks) {
    validatePOI(poi); assert.ok(distance(centre, poi) < 3500); assert.ok(poi.source_urls.every((u) => u.startsWith('https:')));
    assert.equal(poi.license, 'CC BY 4.0'); assert.ok(poi.verified_facts.length);
  }
  assert.equal(readFileSync(new URL('../data/montreal-landmarks.json', import.meta.url), 'utf8'),
    readFileSync(new URL('../../ios/TaskLens/montreal-landmarks.json', import.meta.url), 'utf8'));
});

test('municipal normalization uses the inspected source field names and factual metadata', () => {
  const row = { NoInterne: 9, Titre: 'Source', CoordonneeLatitude: '45.50', CoordonneeLongitude: '-73.57',
    Artistes: [{ Prenom: 'Patrick', Nom: 'Coutu' }], MateriauxAng: 'Bronze', DateFinProduction: '/Date(1291352400000-0500)/', Parc: 'Parc Benny' };
  const result = normalizeMunicipal(row);
  assert.equal(result.latitude, 45.5); assert.equal(result.longitude, -73.57);
  assert.ok(result.verified_facts.includes('Artist: Patrick Coutu.'));
  assert.ok(result.verified_facts.includes('Production date recorded: 2010.'));
  assert.equal(result.routable, true);
  assert.equal(normalizeMunicipal({ ...row, Batiment: 'An indoor venue' }).routable, false);
  assert.equal(normalizeMunicipal({ ...row, CoordonneeLatitude: '' }), null);
  assert.equal(normalizeMunicipal({ ...row, CoordonneeLatitude: 'not a latitude' }), null);
});

test('OSM discovery excludes private and unnamed objects and distinguishes polygon centres from entrances', () => {
  const poi = normalizeOSM(mapped);
  assert.equal(poi.id, 'osm_node_123'); assert.equal(poi.routable, true);
  assert.ok(poi.source_urls.includes('https://en.wikipedia.org/wiki/Public_sculpture'));
  assert.ok(poi.source_urls.includes('https://www.wikidata.org/wiki/Q123'));
  assert.match(poi.description, /not been verified/);
  const way = normalizeOSM({ ...mapped, type: 'way', center: { lat: mapped.lat, lon: mapped.lon } });
  assert.equal(way.routable, false); assert.match(way.coordinate_kind, /not an entrance/);
  assert.equal(normalizeOSM({ ...mapped, tags: { ...mapped.tags, access: 'private' } }), null);
  assert.equal(normalizeOSM({ ...mapped, tags: { tourism: 'artwork' } }), null);
});

test('Overpass queries are bounded, cached across requests, and source coordinates are validated first', async () => {
  let calls = 0;
  const service = new LandmarkService({ catalog, fetcher: async (url, options) => {
    calls++; assert.equal(url, 'https://overpass-api.de/api/interpreter'); assert.equal(options.redirect, 'error');
    const query = new URLSearchParams(options.body).get('data');
    assert.match(query, /out center 200/); assert.match(query, /timeout:8/);
    return new Response(JSON.stringify({ elements: [mapped] }));
  } });
  const [one, two] = await Promise.all([service.nearby(45.505, -73.57, 1000), service.nearby(45.505, -73.57, 1000)]);
  assert.equal(calls, 1); assert.equal(one.landmarks[0].id, 'osm_node_123'); assert.deepEqual(two, one);
  await assert.rejects(service.nearby(NaN, -73, 1000));
  await assert.rejects(service.nearby(45, -73, 90000));
  assert.equal(calls, 1);
});

test('Overpass overload falls back to sourced local data without retrying or fabricating points', async () => {
  let calls = 0;
  const service = new LandmarkService({ catalog, fetcher: async () => { calls++; return new Response('busy', { status: 429 }); } });
  const first = await service.nearby(45.505, -73.57, 1500);
  const second = await service.nearby(45.505, -73.57, 1500);
  assert.match(first.warning, /unavailable/); assert.ok(first.landmarks.length);
  assert.ok(first.landmarks.every((poi) => poi.id.startsWith('montreal_art_')));
  assert.equal(calls, 1); assert.deepEqual(second, first);
});

test('bundled-only discovery and mock stories make zero external calls', async () => {
  const never = () => { throw new Error('No network allowed'); };
  const service = new LandmarkService({ catalog, fetcher: never });
  assert.ok((await service.nearby(45.505, -73.57, 1500, false)).landmarks.length);
  const stories = new DetourStories({ catalog, generate: never });
  const result = await stories.story({ landmarkId: catalog.landmarks[0].id, language: 'fr' }, { mode: 'mock' });
  assert.equal(result.generated, false); assert.equal(result.story, catalog.landmarks[0].description_fr);
});

test('AI stories use server-owned evidence only, cache successes and cannot fetch arbitrary links', async () => {
  let calls = 0;
  const poi = catalog.landmarks[0];
  const stories = new DetourStories({ catalog, generate: async (body) => {
    calls++; const context = JSON.parse(body.contents[0].parts[0].text);
    assert.equal(context.name, poi.name); assert.deepEqual(context.verifiedFacts, poi.verified_facts);
    assert.doesNotMatch(JSON.stringify(body), /invented-fact/);
    assert.equal(body.tools, undefined);
    return { candidates: [{ content: { parts: [{ text: '{"story":"A brief source-based story."}' }] } }] };
  } });
  const input = { landmarkId: poi.id, language: 'en', verifiedFacts: ['invented-fact'] };
  const config = { mode: 'gemini', model: 'test' };
  const first = await stories.story(input, config); await stories.story(input, config);
  assert.equal(calls, 1); assert.equal(first.generated, true); assert.deepEqual(first.sourceUrls, poi.source_urls);
  await assert.rejects(stories.story({ landmarkId: 'https://internal.local', language: 'en' }, config));
  await assert.rejects(stories.story({ landmarkId: poi.id, language: 'xx' }, config));
  assert.equal(calls, 1);
});

test('Detour HTTP endpoints authenticate and preserve the existing health/scanner API', async (t) => {
  let liveCalls = 0;
  const landmarks = new LandmarkService({ catalog, fetcher: () => { liveCalls++; throw new Error('Mock mode cannot discover online'); } });
  const settings = { ...loadConfig({}), appToken: 'a-private-proxy-token' };
  const server = createApp(settings, { landmarks }); server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(() => new Promise((resolve) => { server.close(resolve); server.closeAllConnections(); }));
  const base = `http://127.0.0.1:${server.address().port}`;
  assert.equal((await fetch(base + '/health')).status, 200);
  assert.equal((await fetch(base + '/detour/landmarks?lat=45.505&lon=-73.57')).status, 401);
  const headers = { authorization: 'Bearer a-private-proxy-token', 'content-type': 'application/json' };
  const response = await fetch(base + '/detour/landmarks?lat=45.505&lon=-73.57&radius=1500&discover=1', { headers });
  assert.equal(response.status, 200); assert.ok((await response.json()).landmarks.length); assert.equal(liveCalls, 0);
  assert.equal((await fetch(base + '/detour/landmarks?lat=bad&lon=0', { headers })).status, 400);
  const story = await fetch(base + '/detour/story', { method: 'POST', headers, body: JSON.stringify({ landmarkId: catalog.landmarks[0].id, language: 'en' }) });
  assert.equal(story.status, 200); assert.equal((await story.json()).generated, false);
});

test('Wikipedia enrichment batches only supplied article references and retains source attribution', async () => {
  const { enrichWikipedia } = await import('../src/landmark-enrichment.mjs');
  const poi = normalizeOSM(mapped);
  let calls = 0;
  const result = await enrichWikipedia([poi], async (url) => {
    calls++; const parsed = new URL(url); assert.equal(parsed.hostname, 'en.wikipedia.org');
    assert.equal(parsed.searchParams.get('titles'), 'Public sculpture'); assert.equal(parsed.searchParams.get('explaintext'), '1');
    return new Response(JSON.stringify({ query: { pages: { 12: { title: 'Public sculpture', extract: 'A source-provided description.' } } } }));
  });
  assert.equal(calls, 1); assert.equal(result[0].description, 'A source-provided description.');
  assert.match(result[0].source_name, /Wikipedia/); assert.deepEqual(result[0].source_urls, poi.source_urls);
  const unchanged = await enrichWikipedia([poi], async () => { throw new Error('offline'); });
  assert.equal(unchanged[0].description, poi.description);
  assert.equal((await enrichWikipedia(catalog.landmarks, () => { throw new Error('Should not fetch unlinked sites'); })).length, catalog.landmarks.length);
});

const verificationInput = (poi, now = Date.now()) => ({
  landmarkId: poi.id, language: 'en',
  frame: { frameId: 'verify-frame', capturedAt: new Date(now).toISOString(),
    image: { mimeType: 'image/jpeg', width: 640, height: 480, base64: '/9j/2Q==' } },
  location: { latitude: poi.latitude, longitude: poi.longitude, accuracy: 12, timestamp: new Date(now).toISOString() },
});
const visualResult = (overrides = {}) => ({ candidates: [{ content: { parts: [{ text: JSON.stringify({
  match: true, confidence: 'high', evidence: 'visible_name', reason: 'The identifying plaque is clearly visible.',
  needsClearerView: false, box: [100, 100, 800, 800], ...overrides,
}) }] } }] });

test('landmark verification requires visual evidence and uses only server-owned records', async () => {
  const { DetourVerifier } = await import('../src/detour-verify.mjs');
  const landmarks = new LandmarkService({ catalog }); const poi = catalog.landmarks[0];
  let calls = 0;
  const verifier = new DetourVerifier({ landmarks, generate: async (body, config) => {
    calls++; assert.equal(config.operation, 'landmark_verification');
    const record = JSON.parse(body.contents[0].parts[0].text);
    assert.equal(record.name, poi.name); assert.deepEqual(record.verifiedFacts, poi.verified_facts);
    assert.equal(body.contents[0].parts[1].inlineData.data, '/9j/2Q==');
    assert.doesNotMatch(JSON.stringify(body), /made-up-proof/); assert.equal(body.tools, undefined);
    return visualResult();
  } });
  const result = await verifier.verify({ ...verificationInput(poi), verifiedFacts: ['made-up-proof'], match: true }, { mode: 'gemini' });
  assert.equal(result.found, true); assert.equal(result.frameId, 'verify-frame');
  assert.equal(result.landmarkId, poi.id); assert.equal(result.target.label, poi.name); assert.equal(calls, 1);
});

test('proximity, model uncertainty, and unclear views never award a find', async () => {
  const { DetourVerifier } = await import('../src/detour-verify.mjs');
  const landmarks = new LandmarkService({ catalog }); const input = verificationInput(catalog.landmarks[0]);
  for (const overrides of [{ confidence: 'medium' }, { evidence: 'insufficient' }, { needsClearerView: true }, { match: false }]) {
    const verifier = new DetourVerifier({ landmarks, generate: async () => visualResult(overrides) });
    const result = await verifier.verify(input, { mode: 'gemini' });
    assert.equal(result.found, false); assert.equal(result.target, null);
  }
  let calls = 0;
  const demo = new DetourVerifier({ landmarks, generate: () => { calls++; throw new Error('No paid calls'); } });
  assert.equal((await demo.verify(input, { mode: 'mock' })).found, false); assert.equal(calls, 0);
});

test('verification rejects unknown targets, distant or stale GPS, old frames and invalid images before calling AI', async () => {
  const { DetourVerifier } = await import('../src/detour-verify.mjs');
  const now = Date.now(), poi = catalog.landmarks[0], input = verificationInput(poi, now);
  let calls = 0;
  const verifier = new DetourVerifier({ landmarks: new LandmarkService({ catalog }), now: () => now,
    generate: () => { calls++; return visualResult(); } });
  const badInputs = [
    { ...input, landmarkId: 'client-invented' },
    { ...input, language: 'bad' },
    { ...input, location: { ...input.location, latitude: 0 } },
    { ...input, location: { ...input.location, accuracy: 100 } },
    { ...input, location: { ...input.location, timestamp: new Date(now - 60_000).toISOString() } },
    { ...input, frame: { ...input.frame, capturedAt: new Date(now - 60_000).toISOString() } },
    { ...input, frame: { ...input.frame, image: { ...input.frame.image, base64: 'invalid' } } },
  ];
  for (const bad of badInputs) await assert.rejects(verifier.verify(bad, { mode: 'gemini' }));
  assert.equal(calls, 0);
});

test('verification rejects malformed output and does not retry provider failures', async () => {
  const { DetourVerifier } = await import('../src/detour-verify.mjs');
  const landmarks = new LandmarkService({ catalog }), input = verificationInput(catalog.landmarks[0]);
  for (const overrides of [{ box: [900, 100, 200, 300] }, { confidence: 'certain' }, { reason: '' }]) {
    const verifier = new DetourVerifier({ landmarks, generate: async () => visualResult(overrides) });
    await assert.rejects(verifier.verify(input, { mode: 'gemini' }), (error) => error.code === 'invalid_model_output');
  }
  let calls = 0;
  const failed = new DetourVerifier({ landmarks, generate: async () => { calls++; throw new Error('Provider busy'); } });
  await assert.rejects(failed.verify(input, { mode: 'gemini' })); assert.equal(calls, 1);
});

test('live OSM targets remain verifiable from server cache without client-provided facts', async () => {
  const { DetourVerifier } = await import('../src/detour-verify.mjs');
  let fetches = 0;
  const landmarks = new LandmarkService({ catalog, fetcher: async () => { fetches++; return new Response(JSON.stringify({ elements: [mapped] })); } });
  await landmarks.nearby(45.505, -73.57, 1000);
  const verifier = new DetourVerifier({ landmarks, generate: async () => visualResult() });
  const result = await verifier.verify(verificationInput(normalizeOSM(mapped)), { mode: 'gemini' });
  assert.equal(result.found, true); assert.equal(fetches, 1);
});

test('verification HTTP endpoint authenticates, validates input and keeps mock finds unconfirmed', async (t) => {
  const server = createApp({ ...loadConfig({}), appToken: 'private-detour-token' });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(() => new Promise((resolve) => { server.close(resolve); server.closeAllConnections(); }));
  const endpoint = `http://127.0.0.1:${server.address().port}/detour/verify`;
  const input = verificationInput(catalog.landmarks[0]);
  const headers = { authorization: 'Bearer private-detour-token', 'content-type': 'application/json' };
  assert.equal((await fetch(endpoint, { method: 'POST', body: JSON.stringify(input) })).status, 401);
  const response = await fetch(endpoint, { method: 'POST', headers, body: JSON.stringify(input) });
  assert.equal(response.status, 200); assert.equal((await response.json()).found, false);
  assert.equal((await fetch(endpoint, { method: 'POST', headers, body: '{}' })).status, 400);
});

test('a cancelled verification cannot return a late successful find', async () => {
  const { DetourVerifier } = await import('../src/detour-verify.mjs');
  const controller = new AbortController();
  const verifier = new DetourVerifier({ landmarks: new LandmarkService({ catalog }), generate: async () => {
    controller.abort(); return visualResult();
  } });
  await assert.rejects(verifier.verify(verificationInput(catalog.landmarks[0]), { mode: 'gemini', signal: controller.signal }),
    (error) => error.name === 'AbortError');
});
