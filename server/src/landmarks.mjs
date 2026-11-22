import { readFileSync } from 'node:fs';
import { APIError } from './contract.mjs';
import { enrichWikipedia } from './landmark-enrichment.mjs';

export const OSM_ATTRIBUTION = '© OpenStreetMap contributors · ODbL 1.0';
export const CITY_URL = 'https://donnees.montreal.ca/dataset/2980db3a-9eb4-4c0e-b7c6-a6584cb769c9/resource/18705524-c8a6-49a0-bca7-92f493e6d329/download/oeuvresdonneesouvertes.json';
const categories = new Set(['history', 'architecture', 'streetArt', 'nature', 'hiddenGems']);
export function coordinate(lat, lon) {
  return typeof lat === 'number' && Number.isFinite(lat) && lat >= -90 && lat <= 90
    && typeof lon === 'number' && Number.isFinite(lon) && lon >= -180 && lon <= 180;
}
export function distance(a, b) {
  const radians = (n) => n * Math.PI / 180;
  const dlat = radians(b.latitude - a.latitude), dlon = radians(b.longitude - a.longitude);
  const h = Math.sin(dlat / 2) ** 2 + Math.cos(radians(a.latitude)) * Math.cos(radians(b.latitude)) * Math.sin(dlon / 2) ** 2;
  return 6371000 * 2 * Math.asin(Math.min(1, Math.sqrt(h)));
}
function safeURL(value) {
  try { const u = new URL(value); return u.protocol === 'https:' && !u.username && !u.password ? u.href : null; } catch { return null; }
}
export function validatePOI(p) {
  if (!p || typeof p.id !== 'string' || p.id.length > 100 || !p.id || typeof p.name !== 'string' || !p.name.trim()
    || p.name.length > 200 || !coordinate(p.latitude, p.longitude) || !Array.isArray(p.categories)
    || !p.categories.length || p.categories.some((c) => !categories.has(c)) || typeof p.description !== 'string'
    || !Array.isArray(p.verified_facts) || !p.verified_facts.every((f) => typeof f === 'string' && f.length <= 600)
    || !Array.isArray(p.source_urls) || !p.source_urls.length || p.source_urls.some((url) => !safeURL(url))) {
    throw new Error('Invalid landmark record.');
  }
  return p;
}
export function normalizeMunicipal(row) {
  const latitude = Number(row.CoordonneeLatitude), longitude = Number(row.CoordonneeLongitude);
  if (!row.NoInterne || !row.Titre?.trim() || !coordinate(latitude, longitude) || !row.CoordonneeLatitude || !row.CoordonneeLongitude) return null;
  const artist = (row.Artistes ?? []).map((a) => a.NomCollectif || [a.Prenom, a.Nom].filter(Boolean).join(' ')).filter(Boolean).join(', ');
  const rawDate = /\/Date\((-?\d+)/.exec(row.DateFinProduction ?? '');
  const year = rawDate ? new Date(Number(rawDate[1])).getUTCFullYear() : null;
  const facts = [artist && `Artist: ${artist}.`, year && `Production date recorded: ${year}.`, row.MateriauxAng?.trim() && `Materials: ${row.MateriauxAng.trim()}.`, row.Parc && `Location: ${row.Parc}.`].filter(Boolean);
  const frFacts = [artist && `Artiste : ${artist}.`, year && `Date de production au registre : ${year}.`, row.Materiaux && `Matériaux : ${row.Materiaux}.`, row.Parc && `Emplacement : ${row.Parc}.`].filter(Boolean);
  const cats = ['streetArt'];
  if (/monument|commémor|hommage/i.test(row.Titre)) cats.push('history');
  if (row.Parc) cats.push('nature');
  if (/architecture/i.test(row.ModeAcquisition ?? '')) cats.push('architecture');
  if (cats.length === 1) cats.push('hiddenGems');
  return validatePOI({ id: `montreal_art_${row.NoInterne}`, name: row.Titre.trim(), latitude, longitude, categories: cats,
    description: `${row.Titre.trim()} is a work in Montréal's municipal public art collection. ${facts.join(' ')}`,
    description_fr: `${row.Titre.trim()} fait partie de la collection municipale d’art public de Montréal. ${frFacts.join(' ')}`,
    verified_facts: facts, source_urls: [CITY_URL], source_name: 'Ville de Montréal · Collection municipale d’art public',
    license: 'CC BY 4.0', coordinate_kind: row.Batiment ? 'artwork at a building; entrance/access unverified' : 'mapped outdoor artwork point', routable: !row.Batiment });
}
export function normalizeOSM(element) {
  const tags = element.tags ?? {};
  const name = tags['name:en'] || tags.name;
  const point = element.type === 'node' ? element : element.center;
  if (!name?.trim() || !point || !coordinate(point.lat, point.lon) || ['private', 'no'].includes(tags.access)
    || tags.disused === 'yes' || tags.demolished === 'yes' || tags.indoor === 'yes') return null;
  const cats = [];
  if (tags.historic || tags.heritage) cats.push('history');
  if (tags.building === 'yes' && tags.heritage) cats.push('architecture');
  if (tags.tourism === 'artwork') cats.push('streetArt');
  if (tags.leisure === 'park' || ['tree', 'spring'].includes(tags.natural)) cats.push('nature');
  if (tags.tourism === 'museum') cats.push('history');
  if (!cats.length && tags.tourism !== 'attraction') return null;
  if (!cats.length) cats.push('hiddenGems');
  const urls = [`https://www.openstreetmap.org/${element.type}/${element.id}`];
  const wikipedia = /^([a-z]{2,3}):(.+)$/.exec(tags.wikipedia ?? '');
  if (wikipedia) urls.push(`https://${wikipedia[1]}.wikipedia.org/wiki/${encodeURIComponent(wikipedia[2].replaceAll(' ', '_'))}`);
  if (/^Q\d+$/.test(tags.wikidata ?? '')) urls.push(`https://www.wikidata.org/wiki/${tags.wikidata}`);
  const facts = [];
  if (tags.artist_name) facts.push(`Mapped artist: ${tags.artist_name.slice(0, 200)}.`);
  if (tags.start_date && /^[-\d~?; /]+$/.test(tags.start_date)) facts.push(`Mapped start date: ${tags.start_date.slice(0, 60)}.`);
  const description = typeof tags['description:en'] === 'string' ? tags['description:en'].slice(0, 900)
    : typeof tags.description === 'string' ? tags.description.slice(0, 900)
      : `${name} is mapped in OpenStreetMap as ${tags.historic || tags.tourism || tags.leisure || tags.natural || 'a heritage feature'}. Historical details have not been verified.`;
  const p = { id: `osm_${element.type}_${element.id}`, name: name.slice(0, 200), latitude: point.lat, longitude: point.lon,
    categories: [...new Set(cats)], description, description_fr: tags['description:fr']?.slice(0, 900) ?? null,
    verified_facts: facts, source_urls: urls, source_name: 'OpenStreetMap contributors', license: 'ODbL 1.0',
    coordinate_kind: element.type === 'node' ? 'mapped point' : 'representative centre, not an entrance',
    // Polygon centres are useful discovery pins but must not become navigation entrances.
    routable: element.type === 'node' };
  try { return validatePOI(p); } catch { return null; }
}
export function loadCatalog() {
  const data = JSON.parse(readFileSync(new URL('../data/montreal-landmarks.json', import.meta.url), 'utf8'));
  data.landmarks.forEach(validatePOI);
  return data;
}
export function mergePOIs(...lists) {
  const result = [];
  for (const poi of lists.flat()) {
    const duplicate = result.some((old) => old.id === poi.id || (old.name.toLocaleLowerCase() === poi.name.toLocaleLowerCase() && distance(old, poi) < 80));
    if (!duplicate) result.push(poi);
  }
  return result;
}
export class LandmarkService {
  constructor({ catalog = loadCatalog(), fetcher = fetch, now = Date.now } = {}) {
    this.catalog = catalog; this.fetcher = fetcher; this.now = now; this.cache = new Map();
  }
  async find(id) {
    const local = this.catalog.landmarks.find((poi) => poi.id === id);
    if (local) return local;
    // Only previously discovered, server-owned records; no URLs or client facts.
    for (const entry of this.cache.values()) {
      const records = await (entry.enriched ?? entry.promise);
      const poi = records?.find((record) => record.id === id);
      if (poi) return poi;
    }
    return null;
  }
  async nearby(lat, lon, radius, discover = true, signal, enrich = false) {
    signal?.throwIfAborted();
    if (!coordinate(lat, lon) || !Number.isFinite(radius) || radius < 200 || radius > 3000) throw new APIError(400, 'invalid_request', 'Use valid coordinates and a radius from 200 to 3000 metres.');
    const origin = { latitude: lat, longitude: lon };
    const local = this.catalog.landmarks.filter((p) => distance(origin, p) <= radius);
    let live = [], warning = null;
    if (discover) {
      // Cache by coarse area/radius, with one shared public request per area.
      const key = `${lat.toFixed(2)}:${lon.toFixed(2)}:${Math.ceil(radius / 500)}`;
      let entry = this.cache.get(key);
      if (!entry || entry.expires < this.now()) {
        if (this.cache.size >= 32) this.cache.delete(this.cache.keys().next().value);
        const query = `[out:json][timeout:8];(nwr["historic"]["name"](around:${radius},${lat},${lon});nwr["tourism"~"^(artwork|attraction|museum)$"]["name"](around:${radius},${lat},${lon});nwr["leisure"="park"]["name"](around:${radius},${lat},${lon});node["natural"~"^(tree|spring)$"]["name"](around:${radius},${lat},${lon}););out center 200;`;
        entry = { expires: this.now() + 15 * 60_000, promise: this.fetcher('https://overpass-api.de/api/interpreter', {
          method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded', 'User-Agent': 'Detour/0.1 (walking discovery prototype)' },
          body: new URLSearchParams({ data: query }).toString(), signal: AbortSignal.timeout(10_000), redirect: 'error',
        }).then(async (response) => {
          if (!response.ok) throw new Error('Overpass unavailable');
          const text = await response.text(); if (text.length > 2_000_000) throw new Error('Oversized Overpass response');
          const payload = JSON.parse(text); if (payload.remark || !Array.isArray(payload.elements)) throw new Error('Incomplete Overpass result');
          return payload.elements.slice(0, 200).map(normalizeOSM).filter(Boolean);
        }).catch(() => null) };
        this.cache.set(key, entry);
      }
      const records = await entry.promise; signal?.throwIfAborted();
      if (records) {
        if (enrich && !entry.enriched) entry.enriched = enrichWikipedia(records, this.fetcher);
        const enriched = enrich ? await entry.enriched : records;
        signal?.throwIfAborted();
        live = enriched.filter((p) => distance(origin, p) <= radius);
      } else warning = 'Live OpenStreetMap discovery is unavailable. Showing the bundled municipal collection.';
    }
    return { landmarks: mergePOIs(live, local), warning, attribution: [OSM_ATTRIBUTION, 'Ville de Montréal · CC BY 4.0'], source: live.length ? 'OpenStreetMap + municipal catalog' : 'municipal catalog' };
  }
}
