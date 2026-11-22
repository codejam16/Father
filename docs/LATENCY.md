# Measuring response time

The camera's Thinking phase follows `AssistantViewModel.isBusy`, not the model's
internal reasoning state. It starts before frame preparation and ends after answer
presentation. With natural cloud voice disabled, synchronous iPhone speech setup
can still run before this phase clears. Cloud voice generation, when enabled, is
a separate asynchronous request. The label alone cannot identify the bottleneck.

## Simple locating requests

New self-contained questions such as “Find the girl” and “Where is my bottle?”
use a smaller camera-only request with either Info setting. Enabling Info permits
research for eligible questions; it does not require a lookup for locating a visible
object. An established shopping/research context keeps its full assistant flow.
The smaller request asks for
only a short answer, label, box, and clearer-view flag; no diagrams, tools, plan
generation, or research. It keeps the configured model, coordinate
validation and existing busy-error retry policy. It retains only the latest two
conversation messages as brief context and preserves established task memory.

Selections and ordered pointing spots are preserved in simple locating requests.
`QUICK_LOCATE_MODE=fast` is the default: one primary image is sent with
`MEDIA_RESOLUTION_MEDIUM`; an incidental fingertip close-up is omitted from the
Google request. The original primary JPEG and its coordinate system are unchanged.
This reduces visual input at the cost of fine detail; evaluate localization on the
target device. It does not promise a particular response time.

Use `QUICK_LOCATE_MODE=detailed` to restore the configured `IMAGE_DETAIL` level
and any close-up for locating requests. Tiny manual selections (under 2% of the
full image) automatically retain detailed processing in either mode. There is no
automatic second generation at higher detail after an uncertain result.

Shopping/research questions and their follow-ups, research continuations, active unfinished guided plans,
contextual pronouns, multi-part questions and requests
for fine controls stay on the full assistant path. This intentionally conservative
English routing rule is not a general-purpose intent classifier. It never sends
raw user text to a search provider or adds a classification model call.

This reduces request complexity; it does not guarantee a particular latency or
constant provider response times. No live Gemini/device benchmark was available.
Fine controls, text, diagrams and other full-assistant tasks retain the configured
image detail. A saved unfinished plan does not force the full path or higher
reasoning while `guided=false`; its memory is preserved for resuming later.

## Reasoning policy

`GEMINI_THINKING_LEVEL=auto` is the default, including existing installations with
no new `.env` entry. Basic Flash-Lite (`gemini-3.5-flash-lite`) questions use
`MINIMAL`, rather than forcing `LOW` on every request. Explanations, repairs,
fine controls, explicit step confirmations and active guided plans retain `LOW`.
Direct document/step-check operations without question classification also retain
their existing setting. This applies to the full assistant as well as the locator.

An explicit `low`, `medium` or `high` overrides the automatic policy. An explicit
`minimal` falls back to `LOW` on the supported stronger model, which does not
support `MINIMAL`. Model selection, image detail, coordinate validation, web
permissions, output limits and busy-retry policy remain separate controls.

Google documents `MINIMAL` as the near-off, lowest-latency thinking level for
Flash-Lite; see [Gemini thinking](https://ai.google.dev/gemini-api/docs/generate-content/thinking).
Reducing reasoning can affect answer quality. The automatic policy keeps more
reasoning for detailed work, but real-device accuracy and latency still require
evaluation. Backend tests verify the outgoing settings, not live response speed.

## Logs

Backend output identifies `Camera path=quick_locate` or `full_assistant`, with a
non-sensitive routing reason and counts for received images/pointing data. A
separate Locate line reports the effective quality mode, number of images actually
sent to Google and media-resolution setting. It does not log
the question or image. The
Google START includes the actual `thinking` level, and DONE includes separate
`answerTokens` and `thoughtTokens` counts without logging reasoning content. The
Google DONE line also includes `totalMs`, covering response-body reading as well as
headers and any busy retries. Completed requests already log total elapsed time.
`Server-Timing: app;dur=...` exposes total backend elapsed time in milliseconds.

Xcode's console logs these stages without question text, images, or credentials:

| Log | Includes |
| --- | --- |
| `camera preparation totalMs` | Snapshot, JPEG preparation and pointing lookup |
| `/analyze: totalMs ... serverTiming=app;dur=...` | Request encoding, transfer and full HTTP response; backend time is separate |
| `answer presentation totalMs` | State changes, saved walkthrough preparation and synchronous speech startup |
| `question totalMs` | Total app-side duration before clearing the busy state |

Compare one fast and one slow request under the same settings. Large Google
totalMs points to the upstream generation/retry stage. A fast backend with a slow
HTTP round trip points to client preparation/transfer; a slow presentation stage
points to local answer/audio setup. These measurements locate a boundary, rather
than proving the exact cause of a slow network or hardware operation.

Backend tests cover routing exclusions, one-call localization, unchanged image
detail, source/card isolation, task-memory preservation, uncertainty, malformed
coordinates and the timing header. Native compilation and device timings still
require Xcode and an iPhone.
