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

## Tools checklist

In guided mode, the agent response includes `toolsNeeded: [{ "name": "Phillips screwdriver", "visible": false }]` when steps start (at most 8 items, otherwise an empty list). The phone shows them as "You'll need" with ticks; the user can tick items themselves.

### POST /tools

"Check my tools": one camera image and the current item names.

```json
{ "items": ["Phillips screwdriver", "Plastic pry tool"], "goal": "Replace the laptop fan", "image": { "mimeType": "image/jpeg", "base64": "…", "width": 720, "height": 1280 } }
```

Response: `{ "mode": "gemini", "items": [{ "name": "Phillips screwdriver", "visible": true }, { "name": "Plastic pry tool", "visible": false }], "note": "The pry tool is missing." }`. The backend keeps the phone's list and names; the model only decides visibility. Mock mode marks everything visible. One AI request per scan.

## Image detail and fingertip close-ups

`/analyze` asks Gemini for high image detail (`generationConfig.mediaResolution = MEDIA_RESOLUTION_HIGH`, about 1120 tokens per image on Gemini 3). Set `IMAGE_DETAIL=medium|low|default` in `server/.env` to trade detail for speed.

The camera captures at 1080p (falling back to 720p/VGA). The whole view is sent at up to 1280 px. When a question is asked and an index fingertip is visible (one Apple Vision hand-pose pass on the phone, nothing shown on screen), the request also carries an optional close-up:

```json
"detailImage": { "mimeType": "image/jpeg", "base64": "…", "width": 454, "height": 454, "box": [520, 310, 755, 690] }
```

`box` is where the close-up sits in the first image (0–1000, top-left origin). The model is told to read small labels from it and to return boxes in the first image's coordinates. Only the first look of a question carries it (not research refreshes or step checks).

## Reference pictures (`POST /picture`)

"What does a spudger look like?": answers carry `pictureOf`, a short search phrase (or null), when the user asks what something looks like, says they don't know it, or asks to see it. The app then shows a photo card (top of the screen, closed with X). Each item in the "You'll need" list also has a photo button.

```json
{ "query": "Phillips #1 screwdriver", "context": "replace a laptop battery" }
→ { "mode": "gemini", "picture": { "imageUrl": "https://…", "thumbnailUrl": "https://…", "title": "Screwdriver", "source": "Wikipedia", "link": "https://…" } }
```

Sources, in order: Google Images via Serper (when `SERPER_API_KEY` is set), the Wikipedia article with exactly that name (following redirects), Wikimedia Commons photos, a Wikipedia search, then the article for the main word ("Phillips #1 screwdriver" → "Screwdriver"). Every result's title must name the item's main word, so an unrelated photo is never shown; `picture: null` when nothing matches. HTTPS JPEG/PNG/WebP only, no SVGs. The app shows the card under the tools and step cards. No Gemini call, so it also works in mock mode.

## Tracing routes (`POST /trace`)

The first answer places route points roughly. Before showing an explanation, the app crops the photo around each route (up to 3, with the parts at its ends, squared and at least a third of the photo) and asks for the existing drawn line on that zoomed view:

```json
{ "image": { "mimeType": "image/jpeg", "base64": "…", "width": 640, "height": 640 },
  "rough": [[750, 200], [650, 600], [300, 700]], "what": "Follow the dashed path", "question": "How do I go from A to B?" }
```

`rough` is the first route in the crop's coordinates (`[y, x]`, 0–1000). The reply is `{ "mode": "gemini", "path": [[750, 200], [760, 640], …] }`: the drawn line from start to end with a point at every turn, or `path: null` if no line connects them (the app then keeps the rough route). Uses `EXPLAIN_MODEL` with the regular model as a fallback; mock mode returns the rough route. The app waits at most 20 s per route.

## Pointing while asking ("from this to this")

While the microphone listens, the phone runs a hand-pose pass about 4 times a second. When a spoken question is sent, the places the fingertip rested on (about half a second or more) since the user started talking are sent in order:

```json
"pointedAt": [[120, 300], [800, 640]]
```

Up to four `[y, x]` points (0–1000, top-left origin) in the sent image. The model is told that each "this/that/here/there" maps to these spots in order, and that for "from this to this" the start is spot 1 and the end is the last spot (any drawn path must run between them). Typed questions and picked photos send none. A spoken sentence that is clearly unfinished ("…from this", "…to") waits 2.2 s of silence instead of 0.8 s before it is sent, so the user has time to move their finger to the second spot.

## Visual walkthroughs (explaining diagrams)

When the user asks to explain a diagram, circuit, chart or how something flows, the answer includes `annotations`: 2–6 ordered beats, each `{ "caption": "Current flows through R1 to B", "box": null, "path": [[150, 200], [150, 600], [500, 600]] }` with either a `box` or a `path` of `[y, x]` points (0–1000, top-left origin) traced along the drawn lines in the direction of flow. Otherwise `annotations` is an empty list. Malformed beats are dropped; `needsClearerView` clears them.

The phone freezes the exact photo that was analysed and plays the beats over it, roughly in step with the spoken answer: boxes light up with a number, paths draw themselves and then show moving dots in the direction of flow, earlier beats stay faded, and the caption shows below. Previous / Next / Replay and **Back to camera** are available; asking a new question closes it. Optional visuals per beat: `label` (a short tag drawn next to the part), `to` (a second box: a curved arrow is drawn from `box` to it, for connections), `zoom` (true: a magnified bubble of the part in `box`) and `region` (`[y, x]` points outlining an area to shade). A beat needs a `box`, `path` or `region`; `to` and `zoom` need a `box`. The model sends paths and regions as flat number lists (the schema stays flat, without nested size limits, which Gemini can reject as too complex); the backend returns `[y, x]` pairs. Paths and connections are drawn as arrows: an arrowhead traces the route, chevrons flow along it, and the end gets a solid arrowhead. Each beat also has `say`, the line spoken while it is shown; the phone speaks the `say` lines in order and moves to each beat when its line starts (word position for the iPhone voice, playback position for the Gemini voice). The caption bar shows the caption and the full line, and **All steps** lists every step to read or jump to. Every walkthrough is saved on the phone when it appears (photo + steps, newest 50, in Application Support/Walkthroughs); **Save** keeps it and returns to the camera, while the top-right **X** closes it and removes it again (for a reopened saved one, X only closes); the bottom-right thumbnail opens the saved list, where an explanation can be reopened (paused; Replay speaks it) or deleted. Demo mode shows a sample walkthrough for "explain…", "diagram", "circuit" or "how does…" questions (it does not read the image).

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

Google quota/auth failures are not retried. Transient 5xx responses can receive bounded retries; explanation-model and structured-schema fallbacks may add a model call. Cancellation on the phone does not guarantee cancellation of work already accepted by Google or reverse its usage accounting.


## Task-aware requests

The updated iPhone app adds these optional fields to `POST /analyze`:

```json
{
  "sessionId": "c1d43987-6b55-4258-9742-a4bfccdb50ed",
  "continuationId": null,
  "researchEnabled": true,
  "searchEveryQuestion": false,
  "includeWebInfo": true,
  "confirmedStepIds": []
}
```

`searchEveryQuestion` is deprecated: it remains type-checked for old clients but is always normalized to false and cannot force a lookup. Web search/read actions require BOTH `includeWebInfo: true` (the info toggle) and `researchEnabled: true`, plus server permission, credentials and remaining research steps. Enabling info permits research; it does not require one. The model should answer visual questions directly and select research only when outside information is needed. The native client sends both permission fields from its saved info toggle, never forces searches, and cancels in-flight research-enabled work when the toggle is turned off. Provider requests already dispatched cannot be undone; subsequent steps are cancelled. Previously fetched links may remain cached locally.

`sessionId` enables the bounded action workflow in live mode. Legacy clients without it retain single-call camera analysis unless an explicit Web info request produces a Serper lookup and a second model call. Demo mode remains provider-free. Confirmations must reference an existing plan step; new/edited model-proposed steps are never completed automatically.

Additional response fields are `action`, `continuationId`, `taskMemory`, `sources`, `sourceIds`, and `researchReports`. `action` is one of `respond`, `ask_clarification`, `request_view`, or `refresh_camera`. Internal `search_online` and `read_source` actions are validated and executed by the backend, never arbitrary code. Model-generated citations must reference provider-supplied source IDs. Citation schemas enumerate the available IDs; final answers ignore unused tool arguments because they do not execute tools. Invalid actions, missing queries and unsupported source references still fail without automatically retrying. Rejection logs include the request ID and a redacted validation reason, while the phone receives a concise friendly message.

`taskMemory` contains `goal`, `facts`, `openQuestions`, and `plan` (`id`, `text`, `completed`). Sources have `id`, `title`, and an HTTPS `url`. Research reports contain `kind`, `text`, source-linked `supports`, optional `provider` and optional `searchSuggestionsHTML`. Serper reports use `provider: "serper"` and no HTML widget. Render Google's Search suggestions unmodified and show source links/evidence with grounded answers. Do not execute model-provided HTML; only the provider metadata supplies this widget.

For `refresh_camera`, no target is returned. Capture a new frame and repeat the same question, task, and session with the returned `continuationId`. Clear any previous selection. A continuation lasts two minutes, cannot reuse the preceding frame ID, is consumed on success, and cannot be shared across sessions/questions. The client follows at most two refreshes. Do not add intermediate research progress messages to chat history as completed answers.

Each task-aware HTTP request permits a decision and at most one research operation (bounded busy/schema/model fallbacks can add model attempts), with a 95-second backend deadline and a 105-second phone timeout. Each Gemini call allows up to 40 seconds, including reading the response body; the request budget also covers legacy requests with two Gemini calls and a 10-second Serper query. Across a question and its continuations there are at most five external calls; Serper searches replace the previous grounded-model search calls. One search action sends exactly one authenticated POST to `https://google.serper.dev/search`, with `q`, `num: 5`, `gl` and `hl`. The Serper key is sent only as `X-API-KEY` to that fixed host; redirects are rejected. Serper requests have a 10-second timeout and share the client-disconnect cancellation signal. There are no automatic retries or fallback to Google's built-in search. Model calls and Serper searches have separate counters and quotas. No camera images, conversation or task memory are sent to Serper. Legacy web requests use at most two model calls and one Serper query.

A missing Serper key leaves camera-only mode available. A Serper 401/403, 402/429, timeout, network failure, or empty/unusable results ends a research turn with an honest answer and no fabricated citations/target/continuation. No further model call is made for that failure; subsequent camera questions are still allowed. These fallback replies use HTTP 200 as a completed conversational turn. Google model 429s remain provider errors.

Sessions are process-local, capped at 100, and expire after 30 minutes of inactivity. They contain bounded task notes, sources and research excerpts, not images or API keys. Use an unguessable, per-task UUID. One active operation per session prevents out-of-order state updates. Changing task notes resets state; new tasks should use new UUIDs. A backend restart loses memory and invalidates continuations. Expired or overlapping tasks return 409. No client-supplied research text is accepted as verified evidence.
