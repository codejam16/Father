# TaskLens

A starter for a moving-camera task assistant on iPhone. Keep the camera open, ask a question, hear the reply, and optionally point something out in either direction.

**This is a development base, not a validated repair assistant.** Camera capture, optional Vision tracking, speech, the conversation UI, and a Gemini proxy are implemented. The native app must still be compiled and exercised in Xcode on a real iPhone; it has not been device-tested in the environment that created this repository. Provider accuracy and latency have not been measured.

## What is included

- Native SwiftUI app, targeting iPhone/iOS 17+, with a checked-in Xcode project and shared scheme.
- Uninterrupted rear-camera preview. No permanently selected object.
- Typed questions, continuous speech recognition with pause-to-send and a mute button, and native spoken replies.
- Tap or drag a region to attach it to your next question. A tap creates a region; it does not automatically segment an object.
- Optional AI-requested target, drawn over the live preview. Normal replies return no target.
- Experimental Apple Vision tracking for short-lived pointers, including replay of retained frames to compensate for delayed model responses. Lost/expired pointers are hidden, not drawn at stale coordinates.
- Conversation context, task notes, cancellation, and pause-on-background behavior.
- Clearly labelled, **zero-provider-call demo mode**, enabled by default. Demo replies do not identify objects.
- Dependency-free Node.js proxy with structured-output validation, authentication for live calls, bounded input and timeout handling; Google enforces API usage quotas.

## Start with the iPhone app

1. On a Mac with Xcode 16 or later, open `ios/TaskLens.xcodeproj`.
2. Select the **TaskLens** scheme and your connected iPhone running iOS 17 or later.
3. Under the app target's **Signing & Capabilities**, choose your Personal Team. Change the bundle identifier if Xcode requires a unique one. Choose the same team for the test target when running tests.
4. Enable Developer Mode on the iPhone if Xcode requests it. Build and run.
5. Grant camera permission. Grant microphone and Speech permissions when trying voice.
6. Leave **Demo responses** on in app settings initially. The camera, selection, conversation, and speech UI can be exercised without an API key or backend.

A free Apple Account can install a development app on a personal device with provisioning limits. This repository does not require App Store or TestFlight distribution. The simulator can exercise UI and geometry tests, but the real camera/tracker requires a device.

**Voice controls:** the microphone starts automatically while the app is active, after microphone and Speech permissions are granted. Speak a question, then pause for about 1.2 seconds to send it automatically with a camera image. The microphone button mutes/unmutes; typed questions still have a send button. Listening pauses during analysis and spoken replies to avoid transcribing the assistant, then resumes automatically. Opening settings/conversation or leaving the app pauses listening. Returning resumes it unless muted. This is turn-taking voice, without barge-in or continuous cloud audio/video streaming. Each automatically sent question uses the same backend quota as a typed question; demo responses make no Gemini calls.

## Start the backend

Node.js **22.9+**, with no npm dependencies:

```sh
cd server
cp .env.example .env
npm start
```

Check `http://localhost:8787/health`. It should report `mode: "mock"`. To exercise the phone-to-backend connection, turn off the app's Demo responses switch while leaving the backend in mock mode. Replies will still be clearly labelled as demos and will not call Gemini.

For a physical phone, enter **`http://YOUR_MAC_LAN_IP:8787`** as the backend URL in the app. `localhost` on the phone means the phone. Put both devices on the same reachable network; campus/guest Wi-Fi can isolate clients. Accept the iPhone's Local Network permission. Use the Mac's Wi-Fi settings to find its IP. If using the simulator on the same Mac, `http://localhost:8787` is appropriate.

The checked-in Info.plist permits HTTP **for local development only**. Use an HTTPS endpoint and remove `NSAllowsArbitraryLoads` before distribution. Do not expose a development server to the internet without reviewing deployment/authentication settings.

## Research and task memory

In live mode, the assistant chooses one validated action per decision: `respond`, `ask_clarification`, `request_view`, `search_online`, or `read_source`. Ordinary identification uses one model call. It asks for missing product/version details when needed, rather than assuming every task is about a vehicle or a particular product type.

Research uses Gemini's built-in Google Search and URL Context tools in separate calls, without mixing tools with the structured camera response. Search returns source metadata; reading is limited to source IDs already returned by Google. A failed/paywalled retrieval is not treated as a read document. Relevant PDF diagrams can inform research notes, but this is not guaranteed pixel matching between a manual illustration and the camera view.

After a successful research operation, the backend returns a short-lived continuation. The iPhone takes a fresh camera image, clears the old manual selection, and continues the same question before deciding what to highlight. At most two research operations and five model calls are allowed per question, with no automatic provider retries. A researched question can make several Google API calls. The backend imposes no total or per-minute usage limit. Google may execute multiple search queries inside one grounded call, so this is not a hard search-query or monetary cap. Research availability and charges depend on the model/project; no billing settings are changed by this app.

The camera screen still has only mute and settings. Source-backed answers automatically open a secondary **Sources and research** sheet with source links, evidence excerpts, and Google's supplied Search suggestions. Dismiss it to resume listening. Sources and task memory are also available from settings. Errors are spoken when spoken replies are enabled and are available as **Last issue** in settings.

Task context is held in bounded backend memory (100 sessions, 30-minute inactivity expiry); images are not stored there. It includes a goal, relevant facts, open questions, and proposed plan steps. Only **Mark completed** in settings confirms a step; model suggestions cannot mark work completed. Confirmations sync with the next question. **Start a new task** or changing the task notes starts a fresh context; backend restarts discard memory. Treat remembered facts as assistant-maintained notes, not verified ground truth.

Optional backend settings (defaults work without editing an existing `.env`):

```dotenv
ENABLE_WEB_RESEARCH=true
MAX_RESEARCH_STEPS=2
```

Turn **Search online when needed** off in app settings to keep task memory and camera answers while disabling research. Demo mode never runs any provider calls or search tools. Tool availability, localization accuracy, and latency still need verification on the intended account/device.

## Enable real AI

In `server/.env`:

```dotenv
AI_MODE=gemini
GEMINI_API_KEY=YOUR_PROVIDER_KEY
GEMINI_MODEL=gemini-3.8-flash
APP_TOKEN=YOUR_RANDOM_PRIVATE_TOKEN_AT_LEAST_16_CHARACTERS
```

Generate a proxy token locally if needed:

```sh
node -e "console.log(require('node:crypto').randomBytes(24).toString('hex'))"
```

Restart the backend. In app settings, turn off **Demo responses**, enter the backend URL and the matching **connection token**, and add a specific task/short instructions. Never put the Gemini API key in the iPhone app. Its proxy token is stored in the iOS Keychain.

The default model is `gemini-3.8-flash`; `gemini-3.5-flash-lite` is also allowed by the proxy. Verify access in your own Google project. `gemini-2.5-flash` is not the starter's default because it is deprecated/restricted for new users as of November 2026. Localization quality still needs evaluation for each model and task.

If an AI request fails, the app and backend terminal now show Google's HTTP status and a specific, credential-free explanation. From `server`, run `npm run doctor` to check model metadata without generating an answer. A successful metadata check does **not** establish generation permission, image support, quota, or free-tier eligibility. Send one question from the app to see the generation result. For 401/403, review the key and project access in [Google AI Studio](https://aistudio.google.com/apikey); for 404, verify the selected model; for 400, the message identifies recognized image/schema/thinking or project setup problems. After changing `.env`, stop and restart the backend. Keep keys, tokens and `.env` private when sharing diagnostics.

## Google error diagnostics

Each Google call logs the actual model, action, call number, HTTP status, elapsed time, and token usage when available. Calls for the same `/analyze` request share a request ID, so you can see whether one spoken question triggered a decision, search, or document-reading call.

On a Google failure, Terminal prints **GOOGLE ERROR — original response** followed by Google's response JSON or error text, not a replacement explanation. Quota violation details (`quotaId`, `quotaMetric`, `quotaValue`, dimensions), retry information, and `Retry-After` are preserved when Google supplies them. API keys, the configured app token, and recognized credential fields are redacted. Successful image/question bodies and authentication headers are not logged.

The same error record is saved to `server/.data/provider-errors.jsonl` with owner-only permissions, bounded to a 1 MB file plus one rotated backup. `.data` is excluded from Git. Errors may include Google project identifiers; review diagnostics before sharing them publicly. The app still receives a concise error, while the original provider details stay on your Mac.

After restarting the server and reproducing the problem, inspect the newest saved error:

```sh
cd ~/Desktop/Father/server
node --input-type=module -e 'import {readFileSync} from "node:fs"; const lines=readFileSync(".data/provider-errors.jsonl","utf8").trim().split("\n"); console.log(JSON.stringify(JSON.parse(lines.at(-1)), null, 2));'
```

## API usage and quotas

- Google enforces API quotas and rate limits. The backend has no daily/total request allowance and no requests-per-minute cap. Old `MAX_LIVE_REQUESTS`, `REQUESTS_PER_MINUTE`, `BUDGET_FILE`, and historical allowance files are ignored.
- Demo mode makes no provider calls, even when a Gemini key exists.
- A spoken or typed question may trigger several model calls, including research and fresh-frame analysis. Google accounts for those calls and any search-tool usage according to the project/model's limits and billing configuration.
- Each question has a bounded research workflow (at most two research operations and five model calls) to stop recursive tool loops. This is not a usage quota across questions.
- Images, input context and output size remain bounded. The backend makes no automatic provider retries. A Google 429 is returned as `provider_error` with Google's status, without imposing a local cooldown or preventing the next user request.

## How pointing works

1. Ask a normal question: the model can answer with `target: null`.
2. Ask to find something, or let the assistant refer to a useful visible component: the model can return one normalized box.
3. The image sent to Gemini is an upright JPEG. Boxes use **`[ymin, xmin, ymax, xmax]`, top-left origin, 0–1000**.
4. The phone retains a bounded ring of copied frames, approximately six seconds at its throttled processing rate. It seeds a tracker on the exact source frame, replays retained frames, then tracks subsequent frames locally.
5. If the original frame is no longer available, tracking fails, or the five-second pointer lifetime expires, the box disappears. The camera does not freeze. Ask again to reacquire.
6. A user-selected frame remains the attachment for the next question even if the view moves afterward. The request includes that frame's timestamp. Clear the attachment if you want to ask about the latest view instead.

**Limitations:** Tracking can drift, including to a similar object without low confidence. Replaying frames can add delay. The portrait rear-camera coordinate pipeline and performance need validation on actual devices. No ARKit/LiDAR/world anchors, reliable occlusion recovery, precise screw identification, or automatic assembly verification are claimed. Use a simple, low-risk task with visually distinct parts for the first demo.

## Repository map

| Path | Responsibility |
| --- | --- |
| `ios/TaskLens/CameraService.swift` | Camera, frame ring, experimental pointer tracking |
| `ios/TaskLens/Models.swift` | Frame identity, coordinate transforms, API types |
| `ios/TaskLens/CameraView.swift` | Live preview, selection gesture, overlays |
| `ios/TaskLens/ContentView.swift` | Main UI and conversation |
| `ios/TaskLens/SpeechService.swift` | Push-to-talk and spoken replies |
| `ios/TaskLens/AssistantViewModel.swift` | Context, selection, request lifecycle |
| `ios/TaskLens/AnalysisClient.swift` | Backend client and local demo replies |
| `server/src/` | Validation, Gemini adapter, research workflow and task memory |
| `docs/API.md` | Shared mobile/backend contract |
| `docs/DEVICE_CHECKS.md` | Required real-device acceptance checks |

## Checks

Backend tests are offline and use fake provider responses:

```sh
cd server
npm test
```

On a Mac, select **Product → Test** in Xcode for the included coordinate/selection tests. To build without signing on a Mac:

```sh
xcodebuild -project ios/TaskLens.xcodeproj -scheme TaskLens \
  -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

The Xcode project is committed; no generator is needed to open it. After adding/removing Swift files, add them to the appropriate target in Xcode, or regenerate the project using Python 3:

```sh
python3 scripts/generate-xcode-project.py
```

Regeneration rebuilds the project definition and resets target signing/custom project settings. Source files are unchanged.

## Next milestone

Complete `docs/DEVICE_CHECKS.md` before promising live tracking. Tune coordinate alignment and replay performance on the actual phone, then improve continuous conversation if time remains. Avoid expanding into manual ingestion, additional platforms, or 3D anchors before the camera/pointing interaction is reliable.

References: [Apple Vision tracking](https://developer.apple.com/documentation/vision/tracking-multiple-objects-or-rectangles-in-video), [Apple Speech](https://developer.apple.com/documentation/speech/sfspeechrecognizer), [Gemini image understanding](https://ai.google.dev/gemini-api/docs/image-understanding), [Gemini pricing](https://ai.google.dev/gemini-api/docs/pricing).
