import { APIError } from './contract.mjs';

const invalid = (message) => { throw new APIError(400, 'invalid_request', message); };

/// "What does it look like?": one reference photo for a short phrase such as "Phillips #1 screwdriver".
export function validatePictureRequest(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) invalid('Expected a JSON object.');
  const query = typeof value.query === 'string' ? value.query.trim().replace(/\s+/g, ' ') : '';
  if (!query || query.length > 80) invalid('query must be 1 to 80 characters.');
  const context = typeof value.context === 'string' ? value.context.trim().slice(0, 120) : '';
  return { query, context };
}

const httpsImage = (url) => {
  try {
    const parsed = new URL(url);
    return parsed.protocol === 'https:' && !parsed.username && !parsed.password ? parsed.href : null;
  } catch { return null; }
};

const stopWords = new Set(['a', 'an', 'the', 'of', 'for', 'with', 'and', 'or', 'to', 'small', 'large', 'big', 'tiny', 'new', 'old', 'set', 'kit', 'tool', 'tools', 'pair', 'size', 'type']);
/// The words that name the thing: "a small pair of tweezers" → ["tweezer"]; "Phillips #1 screwdriver" → ["phillips", "screwdriver"].
export function keyWords(query) {
  return query.toLowerCase().split(/[^a-z0-9]+/)
    .filter((word) => word.length > 2 && !stopWords.has(word) && !/^\d+$/.test(word))
    .map((word) => word.replace(/(es|s)$/, ''));
}
/// A picture only counts if its title names the thing asked for (its main word, usually the last).
export function titleMatches(title, query) {
  const words = keyWords(query);
  if (!words.length) return false;
  const text = String(title ?? '').toLowerCase().replace(/[_-]/g, ' ');
  return text.includes(words[words.length - 1]);
}

/// Google Images through Serper (when SERPER_API_KEY is set).
async function serperImage(input, config, fetcher) {
  const response = await fetcher('https://google.serper.dev/images', {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'X-API-KEY': config.serperApiKey },
    body: JSON.stringify({ q: input.query, num: 10, gl: config.serperCountry ?? 'ca', hl: config.serperLanguage ?? 'en' }),
    signal: config.signal,
  });
  if (!response.ok) return null;
  const payload = await response.json();
  for (const row of Array.isArray(payload?.images) ? payload.images : []) {
    const url = httpsImage(row?.imageUrl);
    if (!url || /\.svg(\?|$)/i.test(url) || !titleMatches(row.title, input.query)) continue;
    return {
      imageUrl: url,
      thumbnailUrl: httpsImage(row.thumbnailUrl),
      title: typeof row.title === 'string' ? row.title.slice(0, 120) : input.query,
      source: typeof row.source === 'string' ? row.source.slice(0, 60) : 'Google Images',
      link: httpsImage(row.link),
    };
  }
  return null;
}

const userAgent = { 'user-agent': 'TaskLens/1.0 (hackathon visual assistant)' };
async function mediaWiki(host, params, config, fetcher) {
  const url = new URL(`https://${host}/w/api.php`);
  for (const [key, value] of Object.entries({ action: 'query', format: 'json', formatversion: '2', origin: '*', ...params })) {
    url.searchParams.set(key, value);
  }
  const response = await fetcher(url, { headers: userAgent, signal: config.signal });
  if (!response.ok) return [];
  const payload = await response.json();
  return (payload?.query?.pages ?? []).slice().sort((a, b) => (a.index ?? 0) - (b.index ?? 0));
}

const wikipediaPicture = (page) => {
  const image = httpsImage(page?.thumbnail?.source);
  if (!image || /\.svg/i.test(image)) return null;
  return {
    imageUrl: image, thumbnailUrl: image, title: String(page.title).slice(0, 120), source: 'Wikipedia',
    link: `https://en.wikipedia.org/wiki/${encodeURIComponent(String(page.title).replace(/ /g, '_'))}`,
  };
};

/// The Wikipedia article with exactly this name (following redirects: "tweezer" → "Tweezers").
async function wikipediaTitle(name, config, fetcher) {
  const pages = await mediaWiki('en.wikipedia.org', { titles: name, redirects: '1', prop: 'pageimages', piprop: 'thumbnail', pithumbsize: '800' }, config, fetcher);
  for (const page of pages) if (!page.missing && titleMatches(page.title, name)) return wikipediaPicture(page);
  return null;
}

/// Photos on Wikimedia Commons whose file name names the thing ("File:Tweezers 01.jpg").
async function commonsPhoto(input, config, fetcher) {
  const pages = await mediaWiki('commons.wikimedia.org', {
    generator: 'search', gsrnamespace: '6', gsrsearch: `${input.query} filetype:bitmap`, gsrlimit: '10',
    prop: 'imageinfo', iiprop: 'url|mime', iiurlwidth: '800',
  }, config, fetcher);
  for (const page of pages) {
    const info = page?.imageinfo?.[0];
    const image = httpsImage(info?.thumburl ?? info?.url);
    if (!image || !/^image\/(jpeg|png|webp)$/.test(info?.mime ?? '') || !titleMatches(page.title, input.query)) continue;
    const title = String(page.title).replace(/^File:/, '').replace(/\.[a-z]+$/i, '').replace(/_/g, ' ');
    return { imageUrl: image, thumbnailUrl: image, title: title.slice(0, 120), source: 'Wikimedia Commons', link: httpsImage(info?.descriptionurl) };
  }
  return null;
}

/// Wikipedia search, but only an article whose title names the thing.
async function wikipediaSearch(input, config, fetcher) {
  const pages = await mediaWiki('en.wikipedia.org', {
    generator: 'search', gsrsearch: input.query, gsrlimit: '5', prop: 'pageimages', piprop: 'thumbnail', pithumbsize: '800',
  }, config, fetcher);
  for (const page of pages) {
    if (!titleMatches(page.title, input.query)) continue;
    const picture = wikipediaPicture(page);
    if (picture) return picture;
  }
  return null;
}

/// Tries, in order: Google Images (if configured), the Wikipedia article of that exact name, Commons
/// photos named after it, a Wikipedia search, then the article for its main word ("Phillips #1
/// screwdriver" → "Screwdriver"). Every source must name the thing, so an unrelated photo is never
/// shown. Returns picture null when nothing matches.
export async function findPicture(input, config, fetcher = fetch) {
  const words = keyWords(input.query);
  const mainWord = input.query.split(/\s+/).filter((word) => /[a-z]/i.test(word)).at(-1) ?? input.query;
  const attempts = [];
  if (config.serperApiKey) attempts.push(() => serperImage(input, config, fetcher));
  attempts.push(() => wikipediaTitle(input.query, config, fetcher));
  attempts.push(() => commonsPhoto(input, config, fetcher));
  attempts.push(() => wikipediaSearch(input, config, fetcher));
  if (words.length > 1) attempts.push(() => wikipediaTitle(mainWord, config, fetcher));
  for (const attempt of attempts) {
    try {
      const picture = await attempt();
      if (picture) return { picture };
    } catch (error) {
      if (config.signal?.aborted) throw error;
      console.warn(`Picture lookup failed: ${error.message}`);
    }
  }
  return { picture: null };
}
