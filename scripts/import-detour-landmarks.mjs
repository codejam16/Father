// Import a downloaded municipal JSON snapshot. No AI-generated coordinates/facts.
import { readFileSync, writeFileSync } from 'node:fs';
import { normalizeMunicipal, distance, CITY_URL } from '../server/src/landmarks.mjs';
const input = process.argv[2];
if (!input) throw new Error('Usage: node scripts/import-detour-landmarks.mjs path/to/oeuvresdonneesouvertes.json');
const rows = JSON.parse(readFileSync(input, 'utf8'));
if (!Array.isArray(rows)) throw new Error('Expected the municipal JSON array.');
const centre = { latitude: 45.505, longitude: -73.57 };
const landmarks = rows.map(normalizeMunicipal).filter(Boolean)
  .filter((p) => distance(centre, p) < 3500)
  .sort((a, b) => distance(centre, a) - distance(centre, b)).slice(0, 35);
if (landmarks.length < 20) throw new Error('Not enough valid records for the curated Montréal catalog.');
const output = JSON.stringify({ version: 1,
  attribution: 'Ville de Montréal · CC BY 4.0 · names, locations and factual metadata normalized for Detour',
  source_url: CITY_URL, coordinate_system: 'WGS84 latitude/longitude in decimal degrees',
  snapshot_note: 'Municipal snapshot mirrored at 5nguy/opendata, commit ec8c7325d9e0df7f00bbba09471cc0a999e96705. Not a live inventory; inspect access and entrances on site.',
  landmarks }, null, 2) + '\n';
for (const path of ['../server/data/montreal-landmarks.json', '../ios/TaskLens/montreal-landmarks.json']) writeFileSync(new URL(path, import.meta.url), output);
console.log(`Imported ${landmarks.length} municipal landmarks.`);
