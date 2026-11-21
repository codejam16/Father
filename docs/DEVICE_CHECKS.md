# Real-device checks required before the demo

These are acceptance checks, not completed test results. Native compilation and hardware behavior were unavailable in the Linux authoring environment.

## First: build and camera

- Open the checked-in Xcode project, configure signing, and run on the actual demo iPhone.
- Camera denial shows a useful message; typed input remains visible.
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
