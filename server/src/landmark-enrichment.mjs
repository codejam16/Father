// Only explicit OSM Wikipedia references are eligible. No arbitrary URL fetches,
// speculative name matching, LLM facts, or per-GPS lookups.
export async function enrichWikipedia(pois, fetcher = fetch) {
  const eligible = pois.flatMap((poi) => {
    const url = poi.source_urls.find((value) => /^https:\/\/(en|fr)\.wikipedia\.org\/wiki\//.test(value));
    if (!url) return [];
    const parsed = new URL(url);
    return [{ poi, host: parsed.hostname, title: decodeURIComponent(parsed.pathname.slice(6)).replaceAll('_', ' ') }];
  }).slice(0, 4);
  const descriptions = new Map();
  for (const host of [...new Set(eligible.map((item) => item.host))]) {
    const items = eligible.filter((item) => item.host === host);
    const url = new URL(`https://${host}/w/api.php`);
    url.search = new URLSearchParams({ action: 'query', prop: 'extracts', exintro: '1', explaintext: '1',
      exchars: '850', redirects: '1', titles: items.map((item) => item.title).join('|'), format: 'json' }).toString();
    try {
      const response = await fetcher(url.href, { headers: { 'User-Agent': 'Detour/0.1 (walking discovery prototype)' }, signal: AbortSignal.timeout(5000), redirect: 'error' });
      if (!response.ok) continue;
      const text = await response.text(); if (text.length > 100_000) continue;
      const data = JSON.parse(text);
      const aliases = [...(data.query?.normalized ?? []), ...(data.query?.redirects ?? [])];
      for (const item of items) {
        let title = item.title;
        for (const alias of aliases) if (alias.from === title) title = alias.to;
        const page = Object.values(data.query?.pages ?? {}).find((page) => page.title === title && !Object.hasOwn(page, 'missing'));
        if (typeof page?.extract === 'string' && page.extract.trim()) descriptions.set(item.poi.id, { text: page.extract.trim().slice(0, 900), french: host.startsWith('fr.') });
      }
    } catch { /* A source outage leaves the mapped facts intact. No retries. */ }
  }
  return pois.map((poi) => {
    const entry = descriptions.get(poi.id); if (!entry) return poi;
    return { ...poi, ...(entry.french ? { description_fr: entry.text } : { description: entry.text }),
      source_name: `${poi.source_name}; Wikipedia article`, license: `${poi.license}; Wikipedia text: see linked article licence/history` };
  });
}
