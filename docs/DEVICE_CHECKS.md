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
- Verify that historical allowance files and legacy local quota settings do not block requests. Google quota errors must remain distinguishable from validation or connectivity failures.
- Check provider usage before/after rehearsal; Google enforces the project/model quotas.

## Captions and web info

- Drag the captions handle upward/downward: height changes without selecting a camera object or scrolling the transcript. Release, relaunch and confirm the height persists. Test minimum/maximum height, rotation, small screens and VoiceOver adjustment. Check the grey bubbles stay transparent and readable over bright/dark scenes.
- With captions off, confirm the camera, pointer, listening and spoken replies still work. Turn on the side text-bubble button: user words should appear on the right while speaking, remain once submitted, and be followed by the assistant on the left. New messages scroll into view; older messages can be scrolled/read. Check long answers and larger accessibility text.
- Turn captions off/on during listening, processing and playback. No request should be repeated or voice turn cancelled by changing the overlay. Check persistence after relaunch. Open the full conversation from the captions header; listening pauses while it is open and resumes on dismissal unless muted. Errors should remain visible with both overlays off.
- Automatic web info starts on after installing this version, including existing installs. Disable it and verify future questions omit Google Search; relaunch and confirm the explicit opt-out persists. Re-enable it and ask about a visible, clearly labelled product's price; confirm price text identifies currency/retailer, the sources open real pages, and the returned preview image comes from the online page. An unbranded object should yield similar-product wording or a clarification, not a confident exact match. Page images are best effort; blocked/missing metadata must leave a usable link.
- Ask for further reading on a non-shopping topic. Confirm only useful grounded results create a small strip; greetings, purely visual answers, empty results and thinking states reserve no space. Links must work with captions off. Expand/collapse details, then send a new question and confirm the new strip starts collapsed. Dismiss a strip with × and confirm the next relevant reply can still show its own sources. Check the Serper source links; no Google Search suggestions widget should be fabricated. Rehearse using the actual project/key: supported models and search eligibility are provider-dependent; no live search was executed in the automated checks.
- Hide Web info while a request or preview is loading. Cards disappear, preview fetching is cancelled, future questions omit the search tool, and an old response must not appear as sources for a newer question. Turning it back on must not automatically send another paid request. New conversation clears source cards. Demo mode must not show live-looking prices or perform searches/previews.
- Confirm small-screen/landscape controls, caption scrolling, source-card scrolling, webpage opening and returning, privacy/network failures, and the 40-second search timeout on a physical iPhone. Existing native decoding tests cover old responses and new source payloads but still require Xcode execution.

## Honest demo scope

Use one clear, low-risk task and distinctive objects. Confirm that identifying a visible object produces an assistant pointer, while general or ambiguous answers do not invent one. Show both user pointing (tap/drag) and automatic assistant pointing. Briefly move the phone after acquisition only if tracking has passed rehearsal. Do not claim reliable tiny-part tracking, occlusion recovery, automated repair safety, or full-duplex continuous voice.


## Research and memory

- Keep the camera screen free of transcripts. Ask for ordinary object identification: no research should be performed unnecessarily.
- Ask a task that needs exact product documentation. Confirm the assistant asks for missing model/version details before researching and retains your answer after earlier messages fall out of chat history.
- With an eligible Gemini project, inspect Terminal for `Agent action: search_online` / `read_source`. Verify source links, manufacturer relevance, grounded excerpts, and Google's supplied Search suggestions appear in the secondary sheet. Dismissing it resumes listening; playback must not be transcribed.
- Compare an accessible manual with a paywalled/unreachable document. The latter must not be claimed as read. Uncertain diagram-to-camera matches must ask for a clearer view instead of producing a speculative box.
- Move the camera during research. Confirm a fresh frame is sent after research and old selected-image coordinates are never drawn on the new view. Keep in mind the existing frame-ring tracking lifetime.
- Check a task plan in settings. It must not mark suggested steps complete automatically. Mark one completed, ask another question and confirm its state persists. Start a new task/change notes and confirm old context/sources clear.
- Turn online research off. Camera answers and memory should still work without search calls. Demo mode must make zero provider calls regardless of this toggle.
- Test bad source metadata, Google quota errors, expired continuations/backend restart, cancellation, network loss, and backgrounding during research. Do not automatically retry failed provider calls. Errors should be spoken (if enabled) and visible under Last issue.
- Measure the calls and latency for direct identification vs search plus document reading. Budget per model call, not per spoken question. Do not promise free research without verifying the account's tool quota/pricing.

## Serper search integration

- Set a real `SERPER_API_KEY` locally and restart the backend; confirm startup says `Web search: Serper`. Keep Gemini configured as before. No native code changes are required.
- With research enabled, ask for a product price or manufacturer manual. Confirm one `Serper search` request per search action, source links/snippets returned, a fresh-frame continuation, and a cited final answer. No Google `search_online` model calls or Google Search widgets should appear. Normal identification should remain one Gemini call and zero Serper searches.
- Test missing/invalid key, empty search results, exhausted credits, slow network, and cancellation. The assistant must not fabricate a live price or claim to have read a full page from a snippet. Search failures should finish cleanly and allow the next camera question.
- Disable research in Settings and then globally with `ENABLE_WEB_RESEARCH=false`: neither path may send Serper queries. Mock mode must remain entirely offline. Test old clients without task sessions as well as the task-aware client.
- Serper credits are finite and separate from Gemini quotas. Verify actual result quality, product match, images and latency using the team's account; the automated checks use mocked responses and spend no search credits.
