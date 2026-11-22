import { pathToFileURL } from 'node:url';
import { loadConfig } from './server.mjs';
import { geminiHTTPError } from './provider-error.mjs';

export async function checkGemini(config, fetcher = fetch) {
  if (!config.apiKey) throw new Error('Set GEMINI_API_KEY in server/.env first.');
  let response;
  try {
    response = await fetcher(`https://generativelanguage.googleapis.com/v1beta/models/${config.model}`, {
      method: 'GET', headers: { 'x-goog-api-key': config.apiKey }, signal: AbortSignal.timeout(15_000),
    });
  } catch {
    throw new Error('Could not reach Google. Check the Mac internet connection and try again.');
  }
  if (!response.ok) throw await geminiHTTPError(response, config, { operation: 'model_metadata' });
  let model;
  try { model = await response.json(); } catch { throw new Error('Google returned unreadable model metadata.'); }
  if (!model.supportedGenerationMethods?.includes('generateContent')) {
    throw new Error('This model does not advertise generateContent support. Check GEMINI_MODEL in server/.env.');
  }
  return 'Model metadata is reachable and advertises generateContent support. This does not verify generation permission, free-tier eligibility, image support, or quota. Try one question in the app for the specific generation result.';
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    console.log('Checking Google model metadata only. No answer generation.');
    console.log(await checkGemini(loadConfig()));
    const config = loadConfig();
    console.log(config.webResearchEnabled && config.serperApiKey
      ? 'Serper key is configured. No search was sent; this does not verify its validity or remaining credits.'
      : 'Serper search is off or not configured. Set SERPER_API_KEY in server/.env to enable it.');
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
