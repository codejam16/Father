# TaskLens API contract

Development server: `http://localhost:8787`. All responses use JSON and `Cache-Control: no-store`. There is no image storage or application-level request-content logging.

## GET /health

Returns `{ "status": "ok", "mode": "mock" }` or mode `gemini`. Does not expose credentials or quota state.

## POST /analyze

Use `Content-Type: application/json`. Supply `Authorization: Bearer <APP_TOKEN>` when a token is configured (required in live mode).

```json
{
  "frameId": "a-client-generated-frame-identifier",
  "capturedAt": "2026-11-21T16:00:00Z",
  "question": "What is this connector for?",
  "task": "Identify the connectors on this disconnected demo device.",
  "image": {
    "mimeType": "image/jpeg",
    "base64": "<upright JPEG encoded as base64>",
    "width": 480,
    "height": 640
  },
  "history": [
    { "role": "user", "content": "Help me identify these connectors." },
    { "role": "assistant", "content": "Show me the connectors and identify the device." }
  ],
  "selection": [100, 200, 400, 600],
  "includeWebInfo": false
}
```

`selection` is optional/null. It refers to the supplied image, not a future camera frame. Only the current image is sent; historical messages contain text, not historical images. Keep any required visual comparison explicit in future contract changes.

`includeWebInfo` is an optional boolean, default `false` for older clients. For legacy clients without `sessionId`, explicit `true` enables `tools: [{ googleSearch: {} }]` in the single Gemini analysis request and adds a nullable `webSummary` to its response schema. Task-aware clients reuse the bounded research workflow to populate optional cards; they never add a second implicit search to a camera-decision call. Captions are entirely local and are not part of this flag. With the flag off, legacy clients do not request Google Search. Task-aware research is controlled by `researchEnabled`; mock mode never searches.

Limits: 1,500-character question, 4,000-character task notes, eight history messages of up to 2,000 characters each, JPEG up to 1.5 MB, declared dimensions up to 2048 per side, total HTTP body up to 2.2 MB. The proxy checks encoding and JPEG envelope, not a full image decode. Invalid images may still be rejected by the provider.

```json
{
  "frameId": "a-client-generated-frame-identifier",
  "mode": "gemini",
  "answer": "The selected region appears to contain a USB connector.",
  "target": null,
  "needsClearerView": false,
  "webInfo": null,
  "usage": { "inputTokens": 400, "outputTokens": 120 }
}
```

The usage values above are illustrative. Backend-reported output includes provider reasoning tokens when returned.

When Google returns usable grounding metadata for a Web info request, `webInfo` may instead be:

```json
{
  "summary": "A similar bottle is listed for CAD 25 at the linked retailer. This is not a confirmed exact match.",
  "sources": [{ "title": "Bottle listing", "url": "https://example.com/bottle" }],
  "searchSuggestionHTML": null
}
```

These are illustrative values, not an actual price. The entire `webInfo` value is null unless a nonempty summary and a grounding support referencing a valid source are both present; incidental tool results do not create an automatic strip. The summary may contain price/currency/retailer text; no price is inferred from preview imagery. Sources are deduplicated public HTTPS links from actual `groundingChunks[].web` metadata, capped at six, never generated JSON links. Non-web grounding chunks, executable/local URLs, credential-bearing URLs, and non-default ports are ignored. The backend does not fetch source pages. The phone's Link Presentation loads online previews only while strip details are expanded, with a link fallback if metadata is unavailable. `searchSuggestionHTML` is Google's bounded `searchEntryPoint.renderedContent`, rendered in a nonpersistent, JavaScript-disabled webview; user link taps open HTTPS destinations externally. Without sources, `webInfo` is null. Search support is not proof that every claim or product match is correct. Updated iOS clients accept older responses without `webInfo`.

If highlighting is useful, `target` is `{ "label": "USB connector", "box": [100, 200, 400, 600] }`.

- Every box is `[ymin, xmin, ymax, xmax]`, normalized 0–1000, top-left origin, full upright image.
- The iPhone flips the vertical origin for Apple Vision. It then converts results back to the canonical top-left coordinates for drawing in the aspect-fit preview.
- Always echo the exact `frameId`. The app rejects mismatches and does not apply stale coordinates to an unrelated frame.
- `needsClearerView: true` suppresses highlighting even if a model returned a box.
- Valid JSON/coordinates do not establish correct identification. No model-generated numeric confidence is treated as calibrated certainty.
- Identifying a specific visible object should return a target when it can be located. General or ambiguous answers should not invent a target.

## Guided steps

With **Guided steps** on (app setting, default on), `/analyze` requests include `"guided": true`. The assistant stays open-ended: only when the user asks how to do something hands-on does it create `memory.plan` (short single-action steps) and state just the first step; other questions get normal answers and no plan. Saying "stop" or tapping × on the step card ends the steps (the app confirms the remaining step IDs). The phone shows that step and watches the camera **on the device**: a cheap 16×12 brightness grid detects movement followed by about 1.2 s of stillness on a view that differs from the step's starting view. Only then, and at most every 8 s (15 per step), does it call `/check`. Saying "done", "skip" or "repeat", or tapping the step card's buttons, also works. Completion still flows through `confirmedStepIds`; the model never marks steps complete itself.

### POST /check

Same headers and authentication as `/analyze`.

```json
{
  "stepId": "step-2",
  "step": "Unscrew the four screws on the back cover.",
  "goal": "Replace the laptop fan",
  "task": "",
  "userSaysDone": false,
  "frames": [
    { "frameId": "…", "capturedAt": "2026-11-21T17:30:00Z", "image": { "mimeType": "image/jpeg", "base64": "…", "width": 480, "height": 640 } }
  ]
}
```

One to three frames, oldest first, about 1.5 s apart; the last is the current view. Response:

```json
{ "stepId": "step-2", "mode": "gemini", "status": "done", "feedback": "All four screws are out.", "target": null }
```

`status` is `done`, `in_progress` (normal while working; empty feedback), `problem` (feedback says how to fix; may include a `target` box in the **last** frame), or `unclear` (feedback says what to show). The phone advances on `done`; on `userSaysDone` it also advances on `unclear`, but not on `problem` or `in_progress`. Automatic checks that fail are silent. Mock mode identifies nothing and returns `done` only when `userSaysDone` is true; the app's local demo mode also counts a step's second automatic check as done and supplies three practice steps.

Each check is one Gemini request with up to three images. Movement detection thresholds are first guesses and need tuning on a device. A camera check is a visual judgement, not verification: it cannot confirm torque, alignment, seating or electrical state.

## Errors

`{ "error": { "code": "provider_error", "message": "Gemini HTTP 429: Google quota or rate limit reached." } }`

| Status | Typical cause |
| --- | --- |
| 400 | Malformed JSON, image envelope, context or coordinates |
| 401 | Missing/wrong proxy token |
| 413 | HTTP body too large |
| 415 | Content type is not JSON |
| 429 | Google provider quota or rate limit (no local usage quota) |
| 502 | Upstream rejection, malformed/truncated model response |
| 504 | Provider connection failure/timeout |

No automatic retries. Cancellation on the phone does not guarantee cancellation of work already accepted by Google or reverse its usage accounting.


## Task-aware requests

The updated iPhone app adds these optional fields to `POST /analyze`:

```json
{
  "sessionId": "c1d43987-6b55-4258-9742-a4bfccdb50ed",
  "continuationId": null,
  "researchEnabled": true,
  "confirmedStepIds": []
}
```

`sessionId` enables the bounded action workflow in live mode. Legacy clients without it retain single-call camera analysis. Demo mode remains provider-free. Confirmations must reference an existing plan step; new/edited model-proposed steps are never completed automatically.

Additional response fields are `action`, `continuationId`, `taskMemory`, `sources`, `sourceIds`, and `researchReports`. `action` is one of `respond`, `ask_clarification`, `request_view`, or `refresh_camera`. Internal `search_online` and `read_source` actions are validated and executed by the backend, never arbitrary code. Model-generated citations must reference provider-supplied source IDs.

`taskMemory` contains `goal`, `facts`, `openQuestions`, and `plan` (`id`, `text`, `completed`). Sources have `id`, `title`, and an HTTPS `url`. Research reports contain `kind`, `text`, source-linked `supports`, and optional `searchSuggestionsHTML`. Render Google's Search suggestions unmodified and show source links/evidence with grounded answers. Do not execute model-provided HTML; only the provider metadata supplies this widget.

For `refresh_camera`, no target is returned. Capture a new frame and repeat the same question, task, and session with the returned `continuationId`. Clear any previous selection. A continuation lasts two minutes, cannot reuse the preceding frame ID, is consumed on success, and cannot be shared across sessions/questions. The client follows at most two refreshes. Do not add intermediate research progress messages to chat history as completed answers.

Each HTTP request permits at most two model calls (decision plus research), with a 45-second backend deadline and a 55-second phone timeout. Across a question and its continuations, there are at most five calls. There is no backend total request allowance or per-minute usage quota; Google enforces API limits. Search can internally use multiple queries; quotas and charges apply separately according to Google's project/model terms. Cancellation aborts outstanding backend fetches when the phone disconnects, but cannot refund work already accepted by Google.

Sessions are process-local, capped at 100, and expire after 30 minutes of inactivity. They contain bounded task notes, sources and research excerpts, not images or API keys. Use an unguessable, per-task UUID. One active operation per session prevents out-of-order state updates. Changing task notes resets state; new tasks should use new UUIDs. A backend restart loses memory and invalidates continuations. Expired or overlapping tasks return 409. No client-supplied research text is accepted as verified evidence.
