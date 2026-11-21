# TaskLens

A starter for a moving-camera task assistant on iPhone. Keep the camera open, ask a question, hear the reply, and optionally point something out in either direction.

**This is a development base, not a validated repair assistant.** Camera capture, optional Vision tracking, speech, the conversation UI, and a Gemini proxy are implemented. The native app must still be compiled and exercised in Xcode on a real iPhone; it has not been device-tested in the environment that created this repository. Provider accuracy and latency have not been measured.

## What is included

- Native SwiftUI app, targeting iPhone/iOS 17+, with a checked-in Xcode project and shared scheme.
- Uninterrupted rear-camera preview. No permanently selected object.
- Continuous speech recognition with pause-to-send, a mute button, and native spoken replies.
- Optional translucent live captions over the camera: your speech on the right, assistant replies on the left. The side bubble button toggles captions; the history button opens the saved conversation for this session.
- Separate Web info toggle: optional Google Search grounding, source links, shopping/price summaries when found, and native online page previews. No extra API key is required beyond the backend's Gemini key.
- Tap or drag a region to attach it to your next question. A tap creates a region; it does not automatically segment an object.
- Optional AI-requested target, drawn over the live preview. Normal replies return no target.
- Experimental Apple Vision tracking for short-lived pointers, including replay of retained frames to compensate for delayed model responses. Lost/expired pointers are hidden, not drawn at stale coordinates.
- Conversation context, task notes, cancellation, and pause-on-background behavior.
- Clearly labelled, **zero-provider-call demo mode**, enabled by default. Demo replies do not identify objects.
- Dependency-free Node.js proxy with structured-output validation, authentication for live calls, bounded input, timeout, rate limit, and persistent request allowance.

## Start with the iPhone app

1. On a Mac with Xcode 16 or later, open `ios/TaskLens.xcodeproj`.
2. Select the **TaskLens** scheme and your connected iPhone running iOS 17 or later.
3. Under the app target's **Signing & Capabilities**, choose your Personal Team. Change the bundle identifier if Xcode requires a unique one. Choose the same team for the test target when running tests.
4. Enable Developer Mode on the iPhone if Xcode requests it. Build and run.
5. Grant camera permission. Grant microphone and Speech permissions when trying voice.
6. Leave **Demo responses** on in app settings initially. The camera, selection, conversation, and speech UI can be exercised without an API key or backend.

A free Apple Account can install a development app on a personal device with provisioning limits. This repository does not require App Store or TestFlight distribution. The simulator can exercise UI and geometry tests, but the real camera/tracker requires a device.

**Voice controls:** the microphone starts automatically while the app is active, after microphone and Speech permissions are granted. Speak a question, then pause for about 1.2 seconds to send it automatically with a camera image. The microphone button mutes/unmutes. Listening pauses during analysis and spoken replies to avoid transcribing the assistant, then resumes automatically. Opening settings/conversation or leaving the app pauses listening. Returning resumes it unless muted. This is turn-taking voice, without barge-in or continuous cloud audio/video streaming. Each automatically sent question uses the same backend quota as a typed question; demo responses make no Gemini calls.

**Camera overlays:** tap the circular text bubble on the upper right for captions, and the info circle beneath it for Web info. Both start off, persist across launches, and can also be changed in Settings. Captions show partial recognized speech while you talk, the submitted question while waiting, and completed replies. They don't change microphone or spoken-reply settings. The captions history button opens the session conversation. Errors and microphone status remain visible even with captions off.

When Web info is enabled **before sending a question**, Gemini may use Google Search in the same analysis call. Ask, for example, “How much does a bottle like this cost?” or “Where can I learn more about this?” Current search-based price details appear above the source cards, with currency/retailer when found. Result URLs come from Google's grounding metadata rather than generated links. Online previews use Apple's Link Presentation on the phone; product/page imagery depends on the source providing usable metadata, and a failed preview leaves the source link available. An image or general visual similarity does not prove an exact product match. No purchase is made by the app. Google search suggestions are rendered when supplied.

Turning Web info off hides its panel, cancels visible preview loads, and omits the search tool from **future** requests. It cannot undo a request already sent. Enabling it doesn't automatically repeat an old question. Demo mode returns no web cards and makes no search/preview requests. An older backend can still answer the updated app but won't return web cards; update and restart the backend too. Search requires model/project support for Google Search plus structured output (the configured Gemini 3 Flash models), and can add latency and provider charges, including per-query search usage. The request allowance counts analysis requests, not individual searches within them. Web-enabled analysis allows up to 40 seconds for the provider and does not retry automatically. No live provider/search call has been used to validate this integration in the build environment; check it on the demo account and device.

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

## Enable real AI

In `server/.env`:

```dotenv
AI_MODE=gemini
GEMINI_API_KEY=YOUR_PROVIDER_KEY
GEMINI_MODEL=gemini-3.8-flash
APP_TOKEN=YOUR_RANDOM_PRIVATE_TOKEN_AT_LEAST_16_CHARACTERS
MAX_LIVE_REQUESTS=50
```

Generate a proxy token locally if needed:

```sh
node -e "console.log(require('node:crypto').randomBytes(24).toString('hex'))"
```

Restart the backend. In app settings, turn off **Demo responses**, enter the backend URL and the matching **connection token**, and add a specific task/short instructions. Never put the Gemini API key in the iPhone app. Its proxy token is stored in the iOS Keychain.

The default model is `gemini-3.8-flash`; `gemini-3.5-flash-lite` is also allowed by the proxy. Verify access in your own Google project. `gemini-2.5-flash` is not the starter's default because it is deprecated/restricted for new users as of November 2026. Localization quality still needs evaluation for each model and task.

If an AI request fails, the app and backend terminal now show Google's HTTP status and a specific, credential-free explanation. From `server`, run `npm run doctor` to check model metadata without generating an answer or consuming the app's request allowance. A successful metadata check does **not** establish generation permission, image support, quota, or free-tier eligibility. Send one question from the app to see the generation result. For 401/403, review the key and project access in [Google AI Studio](https://aistudio.google.com/apikey); for 404, verify the selected model; for 400, the message identifies recognized image/schema/thinking or project setup problems. After changing `.env`, stop and restart the backend. Keep keys, tokens and `.env` private when sharing diagnostics.

## Keep within the $5 budget

- Demo mode makes **no provider calls**, even if a Gemini key happens to exist in the environment.
- Real image analysis happens only when the user sends a question. Camera preview/tracking remain on the phone. There is no continuous cloud video/audio stream.
- `MAX_LIVE_REQUESTS` is a persistent total allowance stored in `server/.data/allowance.json`; restarts do not reset it. Failed/aborted attempts also consume a slot. Do not delete that file to bypass the limit unintentionally.
- Limit image size, conversation length, output tokens, and rate. The backend makes no automatic provider retries.
- This allowance is **not a guaranteed monetary cap**. Prices, image tokens, reasoning tokens, quota eligibility, and other project usage affect spending. Verify current provider pricing/billing, monitor usage, and leave headroom. An alerts-only cloud budget is not a hard spending limit.
- For a strictly free run, keep billing disabled and use an eligible free-tier model after confirming your project's quotas. Avoid enabling paid services merely to make a demo work.
- One backend process owns the allowance file. This is not a multi-instance production ledger.

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
| `server/src/` | Validation, Gemini adapter, proxy, allowance |
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
