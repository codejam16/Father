import { APIError } from './contract.mjs';
import { logGoogleError } from './diagnostics.mjs';

// Original Google diagnostics stay on the backend; the phone gets a concise explanation.
export async function geminiHTTPError(response, config = {}, context = {}) {
  let payload = null;
  let rawText = null;
  try {
    if (typeof response.text === 'function') {
      rawText = (await response.text()).slice(0, 65_536);
      try { payload = JSON.parse(rawText); } catch { /* Preserve non-JSON error text below. */ }
    } else { payload = await response.json(); }
  } catch { /* Status and headers still help if the body cannot be read. */ }
  const detail = JSON.stringify(payload?.error ?? {}).toLowerCase();
  logGoogleError({
    timestamp: new Date().toISOString(), ...context,
    model: config.model ?? null, httpStatus: response.status,
    retryAfter: response.headers?.get?.('retry-after') ?? null,
    googleRequestId: response.headers?.get?.('x-request-id') ?? response.headers?.get?.('x-goog-request-id') ?? null,
    googleResponse: payload ?? rawText ?? '[Response body unavailable]',
  }, config);
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
  } else if (status === 400 && /google.?search|url_context|grounding|tool.*support|search.*support/.test(detail)) {
    message = 'Google rejected the research tool. Turn off Web info for legacy clients, or disable online research in app settings. Check model and project tool support.';
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
  const error = new APIError(status === 429 ? 429 : 502, 'provider_error', `Gemini HTTP ${status}: ${message} No automatic retry was made.`);
  if (status === 429) {
    error.userMessage = 'The AI service is limiting requests right now. Please try again later.';
  } else if (status >= 500) {
    error.userMessage = 'The AI service is busy right now. Please try again in a moment.';
  } else if (status === 400 && /image|jpeg|inline.?data/.test(detail)) {
    error.userMessage = "I couldn't read that camera view. Please show it again.";
  } else if ([401, 402, 403, 404].includes(status) || /api_key_invalid|api_key_expired/.test(detail)) {
    error.userMessage = "I can't connect to the AI service right now. Please check the connection settings.";
  } else {
    error.userMessage = "I couldn't get an answer this time. Please try again.";
  }
  return error;
}
