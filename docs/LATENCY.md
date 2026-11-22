# Measuring response time

The camera's Thinking phase follows `AssistantViewModel.isBusy`, not the model's
internal reasoning state. It starts before frame preparation and ends after answer
presentation. With natural cloud voice disabled, synchronous iPhone speech setup
can still run before this phase clears. Cloud voice generation, when enabled, is
a separate asynchronous request. The label alone cannot identify the bottleneck.

## Simple locating requests

New self-contained questions such as “Find the girl” and “Where is my bottle?”
use a smaller camera-only request when both research flags are off. It requests
only a short answer, label, box, and clearer-view flag; no diagrams, tools, plan
generation, or research. It keeps the configured model, image detail, coordinate
validation and existing busy-error retry policy. It retains only the latest two
conversation messages as brief context and preserves established task memory.

Selections, ordered pointing spots, and optional close-up images are preserved
in simple locating requests rather than forcing the full assistant solely because
that camera context exists. The first image remains the coordinate reference.

Info-on questions, research continuations, unfinished guided plans,
contextual pronouns, multi-part questions and requests
for fine controls stay on the full assistant path. This intentionally conservative
English routing rule is not a general-purpose intent classifier. It never sends
raw user text to a search provider or adds a classification model call.

This reduces request complexity; it does not guarantee a particular latency or
constant provider response times. No live Gemini/device benchmark was available.
Image resolution has not been lowered as a speed shortcut.

## Logs

Backend output identifies `Camera path=quick_locate` or `full_assistant`, with a
non-sensitive routing reason and counts for images/pointing data. It does not log
the question or image. The
Google DONE line includes `totalMs`, covering response-body reading as well as
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
