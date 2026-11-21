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

`includeWebInfo` is an optional boolean, default `false` for older clients. For task-aware clients it controls optional source cards; `researchEnabled` independently controls research. Task-aware `search_online` actions use Serper, then return a continuation for a fresh frame. Legacy clients without `sessionId` may request a search only when `includeWebInfo` is true: a first Gemini call may return one `searchQuery`, Serper supplies results, and a final Gemini call uses those snippets to answer. No built-in Gemini Google Search tool is sent in either path. Global `ENABLE_WEB_RESEARCH=false` disables both paths. Without `SERPER_API_KEY`, camera questions remain available and research is not offered. Mock mode never searches. Captions remain local.

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

When the assistant cites actual search sources for a Web info request, `webInfo` may instead be:

```json
{
  "summary": "A similar bottle is listed for CAD 25 at the linked retailer. This is not a confirmed exact match.",
  "sources": [{ "title": "Bottle listing", "url": "https://example.com/bottle" }],
  "searchSuggestionHTML": null
}
```

These are illustrative values, not an actual price. Sources are public HTTPS URLs returned by Serper, with stable server-assigned IDs; model-generated IDs must resolve to existing provider sources. Serper's `organic` entries supply titles, links and snippets, capped at five usable results per query, deduplicated against the session's sources. Knowledge-graph website/description fields may supply an additional candidate within the same cap. Local/IP/credential-bearing/non-HTTPS URLs are rejected. Search snippets are labelled as snippets, never read-document evidence. New generated URLs are not accepted as citations. `searchSuggestionHTML`/`searchSuggestionsHTML` are null for Serper results, so the app displays no invented Google widget. The existing native Link Presentation preview fetches page metadata when expanded, independently of Serper. Exact prices and product matches still need source checking. Legacy clients receive cards only after citing supplied source IDs with a nonempty summary. Updated iOS clients accept older responses without `webInfo`. For per-question-search sessions, uncited results from the current completed research turn can appear as Related search results with real provider links; they are not added to the spoken answer’s `sourceIds` and old results are not revived as a fresh search.

If highlighting is useful, `target` is `{ "label": "USB connector", "box": [100, 200, 400, 600] }`.

- Every box is `[ymin, xmin, ymax, xmax]`, normalized 0–1000, top-left origin, full upright image.
- The iPhone flips the vertical origin for Apple Vision. It then converts results back to the canonical top-left coordinates for drawing in the aspect-fit preview.
- Always echo the exact `frameId`. The app rejects mismatches and does not apply stale coordinates to an unrelated frame.
- `needsClearerView: true` suppresses highlighting even if a model returned a box.
- Valid JSON/coordinates do not establish correct identification. No model-generated numeric confidence is treated as calibrated certainty.
- Identifying a specific visible object should return a target when it can be located. General or ambiguous answers should not invent a target.

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
| 504 | Provider or whole-request timeout |

No automatic retries. Cancellation on the phone does not guarantee cancellation of work already accepted by Google or reverse its usage accounting.


## Task-aware requests

The updated iPhone app adds these optional fields to `POST /analyze`:

```json
{
  "sessionId": "c1d43987-6b55-4258-9742-a4bfccdb50ed",
  "continuationId": null,
  "researchEnabled": true,
  "searchEveryQuestion": true,
  "includeWebInfo": true,
  "confirmedStepIds": []
}
```

`searchEveryQuestion` is an optional boolean, default `false` for older clients. With a task session, `true` requires the first decision of each new question to be `search_online` when research is available. Continuations do not repeat that requirement. Existing session evidence does not replace the next question’s initial lookup. Missing search credentials and the global research switch still permit camera-only answers. The updated iPhone always sends this flag, `researchEnabled: true`, and `includeWebInfo: true`; its display toggle is entirely local and never triggers a new request.

`sessionId` enables the bounded action workflow in live mode. Legacy clients without it retain single-call camera analysis unless an explicit Web info request produces a Serper lookup and a second model call. Demo mode remains provider-free. Confirmations must reference an existing plan step; new/edited model-proposed steps are never completed automatically.

Additional response fields are `action`, `continuationId`, `taskMemory`, `sources`, `sourceIds`, and `researchReports`. `action` is one of `respond`, `ask_clarification`, `request_view`, or `refresh_camera`. Internal `search_online` and `read_source` actions are validated and executed by the backend, never arbitrary code. Model-generated citations must reference provider-supplied source IDs.

`taskMemory` contains `goal`, `facts`, `openQuestions`, and `plan` (`id`, `text`, `completed`). Sources have `id`, `title`, and an HTTPS `url`. Research reports contain `kind`, `text`, source-linked `supports`, optional `provider` and optional `searchSuggestionsHTML`. Serper reports use `provider: "serper"` and no HTML widget. Render Google's Search suggestions unmodified and show source links/evidence with grounded answers. Do not execute model-provided HTML; only the provider metadata supplies this widget.

For `refresh_camera`, no target is returned. Capture a new frame and repeat the same question, task, and session with the returned `continuationId`. Clear any previous selection. A continuation lasts two minutes, cannot reuse the preceding frame ID, is consumed on success, and cannot be shared across sessions/questions. The client follows at most two refreshes. Do not add intermediate research progress messages to chat history as completed answers.

Each task-aware HTTP request permits a decision and at most one research operation, with a 95-second backend deadline and a 105-second phone timeout. Each Gemini call allows up to 40 seconds, including reading the response body; the request budget also covers legacy requests with two Gemini calls and a 10-second Serper query. Across a question and its continuations there are at most five external calls; Serper searches replace the previous grounded-model search calls. One search action sends exactly one authenticated POST to `https://google.serper.dev/search`, with `q`, `num: 5`, `gl` and `hl`. The Serper key is sent only as `X-API-KEY` to that fixed host; redirects are rejected. Serper requests have a 10-second timeout and share the client-disconnect cancellation signal. There are no automatic retries or fallback to Google's built-in search. Model calls and Serper searches have separate counters and quotas. No camera images, conversation or task memory are sent to Serper. Legacy web requests use at most two model calls and one Serper query.

A missing Serper key leaves camera-only mode available. A Serper 401/403, 402/429, timeout, network failure, or empty/unusable results ends a research turn with an honest answer and no fabricated citations/target/continuation. No further model call is made for that failure; subsequent camera questions are still allowed. These fallback replies use HTTP 200 as a completed conversational turn. Google model 429s remain provider errors.

Sessions are process-local, capped at 100, and expire after 30 minutes of inactivity. They contain bounded task notes, sources and research excerpts, not images or API keys. Use an unguessable, per-task UUID. One active operation per session prevents out-of-order state updates. Changing task notes resets state; new tasks should use new UUIDs. A backend restart loses memory and invalidates continuations. Expired or overlapping tasks return 409. No client-supplied research text is accepted as verified evidence.
