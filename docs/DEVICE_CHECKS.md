# Real-device checks required before the demo

These are acceptance checks, not completed test results. Native compilation and hardware behavior were unavailable in the Linux authoring environment.

## First: build and camera

- Open the checked-in Xcode project, configure signing, and run on the actual demo iPhone.
- Camera denial shows a useful message; settings remain accessible.
- Portrait rear-camera preview is upright and unmirrored. Confirm right/left with a printed asymmetric card.
- Preview stays live while a question is processing. Switch apps and return; capture resumes and old highlights do not reappear.

## Pointing, before provider access

- Keep Demo responses enabled. Drag a region near each of the four corners and center. Check that the yellow box follows the finger and accounts for black letterboxing.
- Tap instead of dragging; a small region should be selected. It must not claim to have detected an object.
- Move the phone slowly while the selected region remains visible. Evaluate the Vision tracker; record failures, including drift to similar items.
- Occlude the object or move it out of view. Confirm a lost/expired pointer clears. A high tracker confidence is not proof that it still follows the intended item.
- Ask a demo question with and without a selection. Without a selection there must be no invented target. Every demo reply is labelled.
- An attached selected view belongs to the next question even if you move away. Clear it to use a fresh view.

## Voice

- Microphone permission granted/denied, Speech permission granted/denied.
- After permissions, listening starts without tapping. Speak a question, pause about 1.2 seconds, and confirm exactly one request is sent, retaining the final words. Shorter pauses should not split a question; silence alone must not send anything.
- Listening pauses while processing and speaking, then resumes automatically. Confirm the assistant never sends its own reply back as a new question. Stopping playback should resume listening.
- Mute while listening, preparing, processing, and speaking. Confirm no more voice requests are sent, including after a pending callback or reply; unmute resumes without a push-to-talk step. Typed questions remain available when muted.
- Backgrounding and audio interruptions stop recording/playback; no partial question should be sent. Returning to the foreground resumes unless muted. An audio interruption should show a useful message and require unmuting.
- Settings and conversation sheets pause listening; dismissing resumes unless muted. Test microphone/Speech denial, recognition failure, and repeated session restarts. Leave it silent for two minutes and ask another question to check session renewal.
- Repeat on the actual demo Wi-Fi; Apple speech recognition may need network access if on-device recognition is unavailable for the device/language.

## Backend and provider

- First connect to backend mock mode. Check wrong token, unreachable URL, and phone/Mac LAN reachability.
- Before live mode, confirm model access and quota in the team's Google project. The app is not connected to a personal ChatGPT/Gemini subscription.
- Use the same 10–20 actual demo views/questions to assess model localization. Include an absent object and ambiguous instructions; the assistant should ask for clarification rather than invent a box.
- Measure capture-to-response latency. The frame ring is bounded; a response older than the retained frames should show no stale pointer. Confirm the explanation remains available.
- Deliberately move during a model call; inspect whether buffered replay catches up to the current scene correctly. This behavior is experimental until measured on-device.
- Cancel a request and start a new one. A late response must not overwrite the new conversation or pointer.
- Exhaust a small request allowance and restart the backend. Further live calls must remain blocked.
- Check provider usage before/after rehearsal; do not assume the request allowance is a monetary cap.

## Captions and web info

- With captions off, confirm the camera, pointer, listening and spoken replies still work. Turn on the side text-bubble button: user words should appear on the right while speaking, remain once submitted, and be followed by the assistant on the left. New messages scroll into view; older messages can be scrolled/read. Check long answers and larger accessibility text.
- Turn captions off/on during listening, processing and playback. No request should be repeated or voice turn cancelled by changing the overlay. Check persistence after relaunch. Open the full conversation from the captions header; listening pauses while it is open and resumes on dismissal unless muted. Errors should remain visible with both overlays off.
- Web info starts off. Verify a question with it off makes no Google Search tool request. Turn it on and ask about a visible, clearly labelled product's price; confirm price text identifies currency/retailer, the sources open real pages, and the returned preview image comes from the online page. An unbranded object should yield similar-product wording or a clarification, not a confident exact match. Page images are best effort; blocked/missing metadata must leave a usable link.
- Ask for further reading on a non-shopping topic. Confirm the cards work independently of captions. Check Google-provided search suggestions and their links. Rehearse using the actual project/key: supported models and search eligibility are provider-dependent; no live search was executed in the automated checks.
- Hide Web info while a request or preview is loading. Cards disappear, preview fetching is cancelled, future questions omit the search tool, and an old response must not appear as sources for a newer question. Turning it back on must not automatically send another paid request. New conversation clears source cards. Demo mode must not show live-looking prices or perform searches/previews.
- Confirm small-screen/landscape controls, caption scrolling, source-card scrolling, webpage opening and returning, privacy/network failures, and the 40-second search timeout on a physical iPhone. Existing native decoding tests cover old responses and new source payloads but still require Xcode execution.

## Honest demo scope

Use one clear, low-risk task and distinctive objects. Confirm that identifying a visible object produces an assistant pointer, while general or ambiguous answers do not invent one. Show both user pointing (tap/drag) and automatic assistant pointing. Briefly move the phone after acquisition only if tracking has passed rehearsal. Do not claim reliable tiny-part tracking, occlusion recovery, automated repair safety, or full-duplex continuous voice.
