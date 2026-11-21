import { APIError } from './contract.mjs';

// Classify Google's response locally. Never forward arbitrary upstream text,
// project identifiers, URLs, or credential values to the app or terminal.
export async function geminiHTTPError(response) {
  let detail = '';
  try {
    const payload = await response.json();
    detail = JSON.stringify(payload.error ?? {}).toLowerCase();
  } catch { /* A proxy may return HTML or an empty body. Status still helps. */ }
  const status = response.status;
  let message;
  if (status === 401 || /api_key_invalid|api_key_expired|api key not valid|api key expired/.test(detail)) {
    message = 'Google rejected GEMINI_API_KEY. Check the key in server/.env and restart the backend.';
  } else if (status === 403) {
    message = 'Google denied access. Check the key restrictions and the project access status in Google AI Studio.';
  } else if (status === 402) {
    message = 'Google requires available billing credits for this project. Check its plan and quota in Google AI Studio.';
  } else if (status === 404) {
    message = 'Google could not find or access GEMINI_MODEL for generateContent. Check the model in server/.env and restart the backend.';
  } else if (status === 429) {
    message = 'Google quota or rate limit reached. Check the project quota in Google AI Studio; waiting may not resolve a zero allowance.';
  } else if (status === 400 && /failed_precondition|free tier|billing|country|region/.test(detail)) {
    message = 'Google rejected the project setup. Check project eligibility, region and plan in Google AI Studio.';
  } else if (status === 400 && /google_search|url_context|grounding|tool.*support/.test(detail)) {
    message = 'Google rejected the research tool. Check tool availability for this model/project, or turn off online research in app settings.';
  } else if (status === 400 && /thinking/.test(detail)) {
    message = 'Google rejected the thinking settings for this model. Check the backend generationConfig and selected model.';
  } else if (status === 400 && /schema|responsemimetype|response_mime_type/.test(detail)) {
    message = 'Google rejected the structured response settings. Check model support and the backend response schema.';
  } else if (status === 400 && /image|jpeg|inline.?data/.test(detail)) {
    message = 'Google rejected the camera image. Capture a new frame and verify that the selected model accepts images.';
  } else if (status === 400) {
    message = 'Google rejected the request format or model settings. Check the backend generationConfig and selected model.';
  } else if (status >= 500) {
    message = 'Google is temporarily unable to serve this request. Try again later.';
  } else {
    message = 'Google rejected the AI request. Check the project and model configuration in Google AI Studio.';
  }
  return new APIError(status === 429 ? 429 : 502, 'provider_error', `Gemini HTTP ${status}: ${message} No automatic retry was made.`);
}
