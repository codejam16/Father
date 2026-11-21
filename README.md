# TaskLens

A starter for a moving-camera task assistant on iPhone. Keep the camera open, ask a question, hear the reply, and optionally point something out in either direction.

**This is a development base, not a validated repair assistant.** Camera capture, optional Vision tracking, speech, the conversation UI, and a Gemini proxy are implemented. The native app must still be compiled and exercised in Xcode on a real iPhone; it has not been device-tested in the environment that created this repository. Provider accuracy and latency have not been measured.

## What is included

- Native SwiftUI app, targeting iPhone/iOS 17+, with a checked-in Xcode project and shared scheme.
- Uninterrupted rear-camera preview. No permanently selected object.
- Typed questions, push-to-talk speech recognition, and native spoken replies.
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

**Voice controls:** tap the microphone to start, tap stop to finish, review the recognized text, then tap send. The camera stays live. This base is not an always-listening/full-duplex call.

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
