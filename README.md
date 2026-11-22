> **Apple foreground-mask experiment** (`experiment/apple-foreground-masks`): selected objects use fresh on-device Vision silhouettes instead of rectangular highlights. This branch supersedes the appearance-recovery behavior described below. See the experimental device checks at the end of `docs/DEVICE_CHECKS.md`.

# TaskLens

A starter for a moving-camera task assistant on iPhone. Keep the camera open, ask a question, hear the reply, and optionally point something out in either direction.

**This is a development base, not a validated repair assistant.** Camera capture, optional Vision tracking, speech, the conversation UI, and a Gemini proxy are implemented. The native app must still be compiled and exercised in Xcode on a real iPhone; it has not been device-tested in the environment that created this repository. Provider accuracy and latency have not been measured.

## What is included

- Native SwiftUI app, targeting iPhone/iOS 17+, with a checked-in Xcode project and shared scheme.
- Uninterrupted rear-camera preview. No permanently selected object.
- Continuous speech recognition with pause-to-send, a mute button, and native spoken replies.
- Optional transparent grey live captions over the camera: your speech on the right, assistant replies on the left. Drag the top handle to resize their height. The side bubble button toggles captions; the history button opens the session conversation.
- Optional web lookup only while the info toggle is on and the question needs outside information. The same toggle controls the transparent result box; a mint dot marks hidden results. Expand it for previews or drag upward to fill the screen. Web search uses a separate backend-only Serper key; Gemini handles camera understanding and answers.
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

**Audio handling:** blocking session and microphone operations run on a serial audio worker. Listening and replies share one foreground session; backgrounding deactivates it. Pending startup is cancellable, empty input buffers are dropped, and interruption/media-reset recovery waits for a new user action. See [audio lifecycle fixes and device checks](docs/AUDIO.md).

**Camera overlays:** tap the circular text bubble on the upper right for captions. The captions use transparent grey bubbles, with your words on the right and replies on the left. Drag the small top handle upward/downward to make the captions taller/shorter; height is saved and constrained to fit the screen. VoiceOver can adjust the handle too. Captions start off and do not change microphone or spoken-reply settings. The history button opens the session conversation. Errors and microphone status remain visible with captions off.

**Web info & search** controls search permission and result visibility, and remembers your choice. With it off, questions use the camera without web research. With it on, the assistant searches only when the question needs outside information, such as current prices, specifications or a manufacturer manual. The info circle shows a mint dot when hidden results are available; tapping it reveals the same results without searching again. Source cards contain actual provider links; uncited links are labelled Related search results rather than presented as support for the spoken answer. Tap the chevron for images and longer details inside the camera view. Drag the top handle upward to fill the screen, downward to shrink it, or the corner to adjust width and height. An expand/restore button provides the same full-screen choice. × turns off web search and hides the box while retaining already-fetched results. New replies start compact; saved dimensions apply on expansion. Captions retain their separate height handle.

When online research is enabled, Gemini decides whether external information would help. The backend sends one Google-search query per search action to **Serper**, then returns actual links and snippets to Gemini. It does not use Gemini's built-in Google Search tool. Greetings, ordinary conversation and simple visual identification should not need a search. Ask, for example, “How much does a bottle like this cost?” Search-based price details should include currency and retailer when found; similar products must not be presented as exact matches. The existing image previews use the source page's online metadata after you expand them; the backend does not make extra image-search or shopping requests.

Web research requires the info toggle to be on AND an actual need for outside information. Object location/counting, colors, clearly visible controls and ordinary chat do not require a lookup. Turning info on does not send a request by itself. Turning it off cancels a pending research-enabled question and prevents additional research steps; already-started provider requests cannot be undone. You can resend the preserved question without searching. The old `searchEveryQuestion` field is accepted for compatibility but ignored. Demo mode never calls Gemini or Serper; `ENABLE_WEB_RESEARCH=false` disables research globally. A missing Serper key leaves camera answers available. Search failures do not fabricate links or disable later camera questions.

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

In live mode, the assistant chooses one validated action per decision: `respond`, `ask_clarification`, `request_view`, `search_online`, or `read_source`. The iPhone permits search/read actions only while info is enabled, Serper is connected and server research is enabled. Even then, the assistant should research only questions that need outside information. It asks for missing product/version details when needed, rather than assuming every task is about a vehicle or a particular product type.

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

The **Web info & search** toggle must be enabled before the app permits research. The model then decides whether the question needs external information. A mint dot on the info button means hidden links are available. Enabling the toggle does not make a request by itself. Disabling it blocks subsequent research and can cancel a pending question that allowed research. Set `ENABLE_WEB_RESEARCH=false` on the server to disable research globally. Demo mode never runs any provider calls or search tools. Tool availability, localization accuracy, and latency still need verification on the intended account/device.

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
2. Ask to find something or act on a visible component: the model returns separate regions for the relevant objects or parts, with contextual parents when needed.
3. The image sent to Gemini is an upright JPEG. Boxes use **`[ymin, xmin, ymax, xmax]`, top-left origin, 0–1000**.
4. The phone retains a bounded ring of copied frames, approximately six seconds at its throttled processing rate. It seeds a tracker on the exact source frame, replays retained frames, then tracks subsequent frames locally.
5. Only the current answer’s primary targets are displayed. Valid Vision tracks interpolate position/scale between segmentation updates. Masks older than 0.8 seconds use a soft filled-area fallback while a fresh silhouette is being computed. Once tracking is lost, the target is hidden; it stays remembered so a new question can locate the same ID from fresh visual evidence. This branch does not use geometry-only or template-based identity recovery.
6. Manual selections are resolved against one fresh frame for each question. Old frames/boxes are not mixed into the current request. An answer whose source frame has left the bounded ring cannot place a current highlight; the app asks you to hold steady and ask again.

**Question-aware highlighting:** the current answer chooses what is lit. “Where is the bottle?” targets the bottle; “How do I open it?” targets its visible latch/cap, with the bottle retained as context. The AI must inspect the actual mechanism, not assume every bottle has a button. “Find all bottles” can highlight up to six distinct visible matches per answer (including required parent records within that capacity); larger groups need another view/request. Similar objects use separate IDs and labels. Only this answer’s primary targets are displayed; old objects remain available as context without staying lit. Plural answers do not arbitrarily focus the last object, so “it” can require clarification afterwards.

**Masks and small parts:** whole-object silhouettes still use on-device Apple foreground segmentation. Small buttons are often not separate foreground instances; they get a soft translucent fill over their localized area when no trustworthy part mask is available. Other unsegmented objects use a lighter filled-area fallback labelled “Area”, with no corner frames. Target labels distinguish multiple matches. Masks are clipped to the AI/tracker target region, reject large spillover and remove disconnected speckles. Mask bounds never become the next tracking region, preventing gradual growth onto hands or the background. A new visual answer re-seeds an existing ID from the new camera coordinates; explicit empty/unclear answers clear the old presentation. Lost objects are not silently re-identified using foreground geometry alone; ask a new camera question to re-localize them. No extra model calls or automatic retries were added.

**Tracking helpers:** earlier appearance-history and rotated-box utilities remain in the source and native tests, but this experimental branch does not run the template/rotation-search worker. Foreground segmentation refreshes the changing silhouette. The mask overlay interpolates translation and scale between refreshes; it is not a 3D anchor or guaranteed rotation/perspective compensation.

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

Each frame's foreground instances are associated only with current visible primary tracks, using overlap, size and ambiguity gates. Instance numbers are never used as persistent identities, and segmentation never revives a lost track based on position alone. If Apple merges a button into its bottle, the app keeps a small localized marker rather than painting the bottle as the button. Transparent objects, merged objects and weak foreground separation can prevent a silhouette. Current markers, stale-frame handling and limitations are described in [the highlighting review](docs/HIGHLIGHTING_REVIEW.md).

Baseline checkpoint: `296de7e` on `starter/visual-assistant`. Switch back with `git switch starter/visual-assistant` after saving any subsequent experimental edits. Nothing is pushed automatically.
