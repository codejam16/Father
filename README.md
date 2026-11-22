> **Apple foreground-mask experiment** (`experiment/apple-foreground-masks`): selected objects use fresh on-device Vision silhouettes instead of rectangular highlights. This branch supersedes the appearance-recovery behavior described below. See the experimental device checks at the end of `docs/DEVICE_CHECKS.md`.

# TaskLens

A starter for a moving-camera task assistant on iPhone. Keep the camera open, ask a question, hear the reply, and optionally point something out in either direction.

**This is a development base, not a validated repair assistant.** Camera capture, optional Vision tracking, speech, the conversation UI, and a Gemini proxy are implemented. The native app must still be compiled and exercised in Xcode on a real iPhone; it has not been device-tested in the environment that created this repository. Provider accuracy and latency have not been measured.

## What is included

- Native SwiftUI app, targeting iPhone/iOS 17+, with a checked-in Xcode project and shared scheme.
- Uninterrupted rear-camera preview. No permanently selected object.
- Continuous speech recognition with pause-to-send, a mute button, and native spoken replies.
- Optional transparent grey live captions over the camera: your speech on the right, assistant replies on the left. Drag the top handle to resize their height. The side bubble button toggles captions; the history button opens the session conversation.
- Web lookup for every new live question when search is connected. Show or hide the transparent result box independently; a mint dot marks hidden results. Expand it for previews or drag upward to fill the screen. Web search uses a separate backend-only Serper key; Gemini handles camera understanding and answers.
- Tap or drag a region to attach it to your next question. A tap creates a region; it does not automatically segment an object.
- Optional AI-requested target, drawn over the live preview. Normal replies return no target.
- Experimental Apple Vision tracking without a fixed pointer expiry, including retained-frame replay and on-device appearance-based recovery. Lost pointers are hidden while searching rather than drawn at stale coordinates.
- Conversation context, task notes, cancellation, and pause-on-background behavior.
- Clearly labelled, **zero-provider-call demo mode**, enabled by default. Demo replies do not identify objects.
- Dependency-free Node.js proxy with structured-output validation, authentication for live calls, bounded input and timeout handling; Google enforces API usage quotas.

## Start with the iPhone app

1. On a Mac with Xcode 16 or later, open `ios/TaskLens.xcodeproj`.
2. Select the **TaskLens** scheme and your connected iPhone running iOS 17 or later.
3. Configure your personal signing values once using [Personal signing setup](docs/SIGNING.md). The shared project reads `ios/Config/Signing.local.xcconfig`, which Git ignores. Then select your connected iPhone and Run.
4. Enable Developer Mode on the iPhone if Xcode requests it. Build and run.
5. Grant camera permission. Grant microphone and Speech permissions when trying voice.
6. Leave **Demo responses** on in app settings initially. The camera, selection, conversation, and speech UI can be exercised without an API key or backend.

A free Apple Account can install a development app on a personal device with provisioning limits. This repository does not require App Store or TestFlight distribution. The simulator can exercise UI and geometry tests, but the real camera/tracker requires a device.

**Voice controls:** the microphone starts automatically while the app is active, after microphone and Speech permissions are granted. Speak a question, then pause for about 1.2 seconds to send it automatically with a camera image. The microphone button mutes/unmutes. Listening pauses during analysis and spoken replies to avoid transcribing the assistant, then resumes automatically. Opening settings/conversation or leaving the app pauses listening. Returning resumes it unless muted. This is turn-taking voice, without barge-in or continuous cloud audio/video streaming. Each automatically sent question uses the same backend quota as a typed question; demo responses make no Gemini calls.

**Camera overlays:** tap the circular text bubble on the upper right for captions. The captions use transparent grey bubbles, with your words on the right and replies on the left. Drag the small top handle upward/downward to make the captions taller/shorter; height is saved and constrained to fit the screen. VoiceOver can adjust the handle too. Captions start off and do not change microphone or spoken-reply settings. The history button opens the session conversation. Errors and microphone status remain visible with captions off.

**Show web info** controls visibility only and remembers your choice. The info circle shows a mint dot when hidden results are available; tapping it reveals the same results without searching again. Source cards contain actual provider links; uncited links are labelled Related search results rather than presented as support for the spoken answer. Tap the chevron for images and longer details inside the camera view. Drag the top handle upward to fill the screen, downward to shrink it, or the corner to adjust width and height. An expand/restore button provides the same full-screen choice. × hides the box while keeping its results available. New replies start compact; saved dimensions apply on expansion. Captions retain their separate height handle.

When online research is enabled, Gemini decides whether external information would help. The backend sends one Google-search query per search action to **Serper**, then returns actual links and snippets to Gemini. It does not use Gemini's built-in Google Search tool. Greetings, ordinary conversation and simple visual identification should not need a search. Ask, for example, “How much does a bottle like this cost?” Search-based price details should include currency and retailer when found; similar products must not be presented as exact matches. The existing image previews use the source page's online metadata after you expand them; the backend does not make extra image-search or shopping requests.

Each new live question requests an initial search even while web info is hidden. The display controls do not change research or repeat requests. Existing API clients without the per-question flag retain optional research. Demo mode never calls Gemini or Serper, and ENABLE_WEB_RESEARCH=false disables server research globally. A missing Serper key leaves camera answers available. Search authentication, credit/rate-limit, network and empty-result failures finish the turn with an honest web-search message, without retrying, fabricating a price, or disabling later camera questions. Gemini model quotas still apply.

## Connect Serper search

1. Create an account at [Serper](https://serper.dev/) and copy its API key from your dashboard. Check the current starter-credit allowance and expiry there; it is not an unlimited monthly plan.
2. Add these lines to your existing `server/.env` (keep the Gemini key and connection token):

```dotenv
ENABLE_WEB_RESEARCH=true
SERPER_API_KEY=YOUR_PRIVATE_SERPER_KEY
SERPER_COUNTRY=ca
SERPER_LANGUAGE=en
```

3. Restart the backend with `npm start`. It should print **Web search: Serper**. Rebuild the updated iPhone app once. Each new live question requests a lookup when search is connected; **Show web info** only controls visibility.

Only search text, result count and locale go to Serper; camera images, conversation history, task memory and the Gemini key do not. Serper returns search snippets, not full documents. The existing explicit `read_source` action still uses Gemini URL Context to read a known source and is subject to that feature's project support and quotas. There is no fallback to Google's built-in search or automatic purchase of credits. `npm run doctor` checks Gemini metadata and whether a Serper key is configured; it does not spend a search query or validate Serper credits. Tests use mocked responses; live Serper credentials and end-to-end device latency were not available in the authoring environment.

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

In live mode, the assistant chooses one validated action per decision: `respond`, `ask_clarification`, `request_view`, `search_online`, or `read_source`. The updated iPhone app requests an initial search for every new question, including ordinary identification, when Serper is connected and server research is enabled. Older clients retain the optional research policy. It asks for missing product/version details when needed, rather than assuming every task is about a vehicle or a particular product type.

Research uses Serper for Google search results and Gemini URL Context for explicit document reads. Gemini decision calls never include a Google Search tool. Search returns source metadata; reading is limited to source IDs already returned by the search provider. A failed/paywalled retrieval is not treated as a read document. Relevant PDF diagrams can inform research notes, but this is not guaranteed pixel matching between a manual illustration and the camera view.

After a successful research operation, the backend returns a short-lived continuation. The iPhone takes a fresh camera image, clears the old manual selection, and continues the same question before deciding what to highlight. At most two research operations and five total external calls are allowed per question, with no automatic provider retries. A simple researched question uses two Gemini calls and one Serper query; a search/read/fresh-frame sequence uses four Gemini calls and one Serper query. The backend imposes no total or per-minute usage limit. Each search action sends exactly one Serper request for up to five usable results; provider credits and model tokens have separate quotas. Research availability and charges depend on the model/project; no billing settings are changed by this app.

The camera screen keeps the colored assistant status at the top center, camera controls, caption toggle and optional web-info box. The viewfinder button toggles manual region selection, off by default; turning it off clears the selected frame. Automatic assistant highlighting still works. Research results **do not automatically open a sheet** or suspend listening. Drag the transparent box upward to fill the screen, downward to shrink it, or drag its corner to adjust width. The expand/restore button provides the same full-screen choice. Details expand and scroll inside the box; opening settings or conversation history is a separate user action. Full research evidence and task memory remain available from settings when explicitly requested. Serper results do not fabricate a Google Search suggestions widget. Errors are spoken when spoken replies are enabled and are available as **Last issue** in settings.

Task context is held in bounded backend memory (100 sessions, 30-minute inactivity expiry); images are not stored there. It includes a goal, relevant facts, open questions, and proposed plan steps. Only **Mark completed** in settings confirms a step; model suggestions cannot mark work completed. Confirmations sync with the next question. **Start a new task** or changing the task notes starts a fresh context; backend restarts discard memory. Treat remembered facts as assistant-maintained notes, not verified ground truth.

Research settings (add the Serper key to an existing `.env` to enable search):

```dotenv
ENABLE_WEB_RESEARCH=true
SERPER_API_KEY=YOUR_PRIVATE_SERPER_KEY
MAX_RESEARCH_STEPS=2
```

The app always requests research; **Show web info** only hides or shows the cached result cards. A mint dot on the info button means hidden links are available. Toggling visibility does not make a new request. Set `ENABLE_WEB_RESEARCH=false` on the server to disable research globally. Demo mode never runs any provider calls or search tools. Tool availability, localization accuracy, and latency still need verification on the intended account/device.

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

Each Google call logs the actual model, action, call number, HTTP status, elapsed time, and token usage when available. Calls for the same `/analyze` request share a request ID, so you can see whether one spoken question triggered a camera decision or document-reading call. Serper searches are logged separately, with no query text or key. Each completed HTTP request logs `googleCalls` and `serperSearches`.

On a Google failure, Terminal prints **GOOGLE ERROR — original response** followed by Google's response JSON or error text, not a replacement explanation. Quota violation details (`quotaId`, `quotaMetric`, `quotaValue`, dimensions), retry information, and `Retry-After` are preserved when Google supplies them. API keys, the configured app token, and recognized credential fields are redacted. Successful image/question bodies and authentication headers are not logged.

The same error record is saved to `server/.data/provider-errors.jsonl` with owner-only permissions, bounded to a 1 MB file plus one rotated backup. `.data` is excluded from Git. Errors may include Google project identifiers; review diagnostics before sharing them publicly. The app still receives a concise error, while the original provider details stay on your Mac.

After restarting the server and reproducing the problem, inspect the newest saved error:

```sh
cd ~/Desktop/Father/server
node --input-type=module -e 'import {readFileSync} from "node:fs"; const lines=readFileSync(".data/provider-errors.jsonl","utf8").trim().split("\n"); console.log(JSON.stringify(JSON.parse(lines.at(-1)), null, 2));'
```

## API usage and quotas

- Google enforces model quotas and rate limits; Serper separately enforces search credits and throughput. The backend has no daily/total request allowance and no requests-per-minute cap. Old `MAX_LIVE_REQUESTS`, `REQUESTS_PER_MINUTE`, `BUDGET_FILE`, and historical allowance files are ignored.
- Demo mode makes no provider calls, even when a Gemini key exists.
- A spoken or typed question may trigger several model calls, including research and fresh-frame analysis. Google accounts for model calls according to the project/model limits; Serper accounts separately for successful search queries against its credit allowance.
- Each question has a bounded research workflow (at most two research operations and five external calls) to stop recursive tool loops. This is not a usage quota across questions.
- Images, input context and output size remain bounded. The backend makes no automatic provider retries. A Google 429 is returned as `provider_error` with Google's status, without imposing a local cooldown or preventing the next user request.

## How pointing works

1. Ask a normal question: the model can answer with `target: null`.
2. Ask to find something, or let the assistant refer to a useful visible component: the model can return one normalized box.
3. The image sent to Gemini is an upright JPEG. Boxes use **`[ymin, xmin, ymax, xmax]`, top-left origin, 0–1000**.
4. The phone retains a bounded ring of copied frames, approximately six seconds at its throttled processing rate. It seeds a tracker on the exact source frame, replays retained frames, then tracks subsequent frames locally.
5. There is no fixed expiry while tracking remains valid. A lost object is hidden while local appearance matching searches roughly once per second for one minute. After that, it stays remembered but dormant; a new question restarts local recovery. A distinct match must survive several tracked frames before its box reappears. Recovery makes no Gemini calls. Full-image recovery runs on a single lower-priority background worker, and JPEG encoding uses a separate snapshot queue, so neither waits inline on the camera queue. Worker results are validated against the same target instance/loss revision and replayed from their source frame before display. Clearing/forgetting a target, switching cameras, or backgrounding cancels its recovery. An expired source frame still requires a new question rather than applying old coordinates to the current image.
6. A user-selected frame remains the attachment for the next question even if the view moves afterward. The request includes that frame's timestamp. Clear the attachment if you want to ask about the latest view instead.

**Multiple objects:** up to six targets are retained on the phone. Gemini can return up to four newly identified/referenced objects per answer, with stable IDs and optional parent IDs. A bottle and its release button can therefore remain highlighted together; the focused object is brighter. Requests include the current object inventory, focus, and parent relationships so follow-up questions can refer to existing objects. Hidden/lost objects have no current coordinates. Manual selections accumulate; the next question uses one fresh image instead of mixing boxes from older frames. Use Settings → Remembered objects to forget one object or clear all. A new task clears the inventory.

**Snapshot memory:** confident tracked views are sampled about once per second as small grayscale images plus object poses/descriptors. The original and newest are retained; older intermediate views are progressively thinned (approximately 0/5/10 seconds after ten seconds, then 0/10/20 after twenty, and wider spacing later). History is bounded to at most twelve small views per object. For the first five seconds after a loss, recovery only checks the last-known area at the existing object size. Wider searches start afterward. Each candidate carries its exact source snapshot through confirmation; a match found with an older view is never verified against an unrelated newer template. These snapshots stay in RAM, are cleared with the target, and are not extra images uploaded to Gemini. This improves local responsiveness and gives recovery more viewpoints; it does not guarantee re-identification after major appearance changes, and external search/model latency is separate.

**Rotating boxes:** appearance descriptors sample oriented regions in actual image pixel geometry. Rotation checks are advisory for confident Vision tracks, tolerate brief mismatches, and never overwrite Vision’s positional observation. Vision supplies position and scale; local appearance matching only adjusts rotation so it cannot gradually shrink the object box; recovery searches rotated candidates as well. The preview rotates each outline and mirrors its position/angle correctly for the front camera. This handles in-plane phone/object roll; it is not a 3D world anchor or a segmented contour.

**Limitations:** Tracking can drift, including to a similar object without low confidence. Appearance recovery is best-effort: similar-looking objects, textureless regions, large viewpoint/scale changes, or poor lighting can prevent recovery or cause a false match. It rejects ambiguous competing locations but does not prove object identity. Replaying frames can add delay. The portrait rear-camera coordinate pipeline and performance need validation on actual devices. No ARKit/LiDAR/world anchors, reliable occlusion recovery, precise screw identification, or automatic assembly verification are claimed. Use a simple, low-risk task with visually distinct parts for the first demo.

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

Regeneration rebuilds the project definition with variable-based signing and leaves your ignored local signing file intact. Review unrelated custom project settings after regeneration. Source files are unchanged.

## Next milestone

Complete `docs/DEVICE_CHECKS.md` before promising live tracking. Tune coordinate alignment and replay performance on the actual phone, then improve continuous conversation if time remains. Avoid expanding into manual ingestion, additional platforms, or 3D anchors before the camera/pointing interaction is reliable.

References: [Apple Vision tracking](https://developer.apple.com/documentation/vision/tracking-multiple-objects-or-rectangles-in-video), [Apple Speech](https://developer.apple.com/documentation/speech/sfspeechrecognizer), [Gemini image understanding](https://ai.google.dev/gemini-api/docs/image-understanding), [Gemini pricing](https://ai.google.dev/gemini-api/docs/pricing).


### Apple foreground-mask experiment

Uses iOS 17's `VNGenerateForegroundInstanceMaskRequest`, without Gemini calls or model downloads. A single background worker processes the latest available camera view at most every 0.4 seconds; slow work is never queued. Box tracking bridges requests internally. Displayed masks expire after 0.8 seconds and are regenerated from fresh frames rather than stretching the initial Gemini region forever. Front-camera masks use the same preview mirroring.

Each frame's foreground instances are associated with remembered target regions using overlap, size and ambiguity gates; instance numbers are never reused as identities. Lost targets are checked approximately once per second for up to one minute, near their last tracked region. This experiment disables the previous template/rotation-search worker. It does not provide global identity recovery: substantial movement while hidden can require another question/selection. If Apple merges a lid into its bottle, the app rejects the oversized mask rather than claiming to segment the lid. Transparent objects, merged objects and weak foreground separation can yield no highlight. No rectangle is substituted for a missing mask; manual drag previews remain rectangular.

Baseline checkpoint: `296de7e` on `starter/visual-assistant`. Switch back with `git switch starter/visual-assistant` after saving any subsequent experimental edits. Nothing is pushed automatically.
