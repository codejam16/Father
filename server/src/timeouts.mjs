// One legacy web answer can make two Gemini calls and one Serper search.
// Keep the whole-request deadline above that budget; iOS allows another 10s.
export const GEMINI_TIMEOUT_MS = 40_000;
export const SEARCH_TIMEOUT_MS = 10_000;
export const ANALYSIS_TIMEOUT_MS = 2 * GEMINI_TIMEOUT_MS + SEARCH_TIMEOUT_MS + 5_000;
