# Real-device checks required before the demo

These are acceptance checks, not completed test results. Native compilation and hardware behavior were unavailable in the Linux authoring environment.

## First: build and camera

- Open the checked-in Xcode project, configure signing, and run on the actual demo iPhone.
- Camera denial shows a useful message; settings remain accessible.
- Portrait rear-camera preview is upright and unmirrored. Confirm right/left with a printed asymmetric card.
- Preview stays live while a question is processing. Switch apps and return; capture resumes and old highlights do not reappear.

## Pointing, before provider access

- Keep Demo responses enabled and turn on the viewfinder button. Drag a region near each of the four corners and center. Check that the yellow box follows the finger and accounts for black letterboxing.
- Tap instead of dragging; a small region should be selected. It must not claim to have detected an object.
- Move the phone slowly while the selected region remains visible. Evaluate the Vision tracker; record failures, including drift to similar items.
- Keep a well-tracked object visible for at least a minute: it must not disappear after five seconds. Occlude it or move it out of view: the box must hide rather than freeze. Bring it back at another location and verify local recovery without another question or provider call. A high tracker confidence is not proof that it still follows the intended item.
- Test two identical objects, a uniform/textureless target, lighting and distance changes, and rapid viewpoint changes. Ambiguous or unsupported recovery should leave the box hidden. Check front/rear cameras, clear/new selections, camera switching, and backgrounding: recovery of an old target must stop. Measure preview smoothness and battery/CPU use while searching for a missing target.
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
- Show web info defaults on. Hide it and verify new live questions still search via Serper and receive source cards. A mint dot appears on the info button when hidden links are available. Tap it to show those same results without another request; relaunch and confirm visibility persists. Ask about a visible, clearly labelled product's price; confirm price text identifies currency/retailer, the sources open real pages, and the returned preview image comes from the online page. An unbranded object should yield similar-product wording or a clarification, not a confident exact match. Page images are best effort; blocked/missing metadata must leave a usable link.
- Ask for further reading on a non-shopping topic. Confirm cited results create a small strip; empty results and thinking states reserve no space. Every new live question requests an initial lookup when connected. Links must work with captions off. Expand/collapse details, then send a new question and confirm the new strip starts collapsed. Hide a strip with × and confirm its links remain available via the dotted info button. Check the Serper source links; no Google Search suggestions widget should be fabricated. Rehearse using the actual project/key: supported models and search eligibility are provider-dependent; no live search was executed in the automated checks.
- Hide Web info while a request or preview is loading. Cards disappear, preview fetching is cancelled, future questions still request research, and an old response must not appear as sources for a newer question. Turning it back on must not automatically send another paid request. New conversation clears source cards. Demo mode must not show live-looking prices or perform searches/previews.
- Confirm small-screen/landscape controls, caption scrolling, source-card scrolling, webpage opening and returning, privacy/network failures, and Gemini timeouts (40 seconds per model call), cancellation, and the 95-second backend/105-second phone deadlines on a physical iPhone. Existing native decoding tests cover old responses and new source payloads but still require Xcode execution.

## Honest demo scope

Use one clear, low-risk task and distinctive objects. Confirm that identifying a visible object produces an assistant pointer, while general or ambiguous answers do not invent one. Show both user pointing (tap/drag) and automatic assistant pointing. Briefly move the phone after acquisition only if tracking has passed rehearsal. Do not claim reliable tiny-part tracking, occlusion recovery, automated repair safety, or full-duplex continuous voice.


## Research and memory

- Keep the camera screen free of transcripts. Ask for ordinary object identification: verify the initial lookup runs for each new live question.
- Ask a task that needs exact product documentation. Confirm uncertain searches use qualified categories and the assistant asks for missing model/version details instead of claiming an exact match and retains your answer after earlier messages fall out of chat history.
- Inspect Terminal for `Agent action: search_online` / `read_source`. Receiving a researched answer must not automatically open Sources and research, cover the camera, stop playback, or pause/resume the microphone. Useful links appear only in the transparent camera-local info box when its display toggle is enabled. Full evidence is available from Settings only on explicit navigation.
- Compare an accessible manual with a paywalled/unreachable document. The latter must not be claimed as read. Uncertain diagram-to-camera matches must ask for a clearer view instead of producing a speculative box.
- Move the camera during research. Confirm a fresh frame is sent after research and old selected-image coordinates are never drawn on the new view. Keep in mind the existing frame-ring tracking lifetime.
- Check a task plan in settings. It must not mark suggested steps complete automatically. Mark one completed, ask another question and confirm its state persists. Start a new task/change notes and confirm old context/sources clear.
- Set ENABLE_WEB_RESEARCH=false on the server. Camera answers and memory should still work without search calls. Demo mode must always make zero provider calls.
- Test bad source metadata, Google quota errors, expired continuations/backend restart, cancellation, network loss, and backgrounding during research. Do not automatically retry failed provider calls. Errors should be spoken (if enabled) and visible under Last issue.
- Measure the calls and latency for direct identification vs search plus document reading. Budget per model call, not per spoken question. Do not promise free research without verifying the account's tool quota/pricing.

## Serper search integration

- Set a real `SERPER_API_KEY` locally and restart the backend; confirm startup says `Web search: Serper`. Keep Gemini configured as before. No native code changes are required.
- With research enabled, ask for a product price or manufacturer manual. Confirm one `Serper search` request per search action, source links/snippets returned, a fresh-frame continuation, and a cited final answer. No Google `search_online` model calls or Google Search widgets should appear. Normal identification from the updated app also starts with one Serper lookup; older clients without searchEveryQuestion retain the optional search policy.
- Test missing/invalid key, empty search results, exhausted credits, slow network, and cancellation. The assistant must not fabricate a live price or claim to have read a full page from a snippet. Search failures should finish cleanly and allow the next camera question.
- Hide results in Settings and verify lookups continue. Then set `ENABLE_WEB_RESEARCH=false` globally and verify no Serper queries are sent. Mock mode must remain entirely offline. Test old clients without task sessions as well as the task-aware client.
- Serper credits are finite and separate from Gemini quotas. Verify actual result quality, product match, images and latency using the team's account; the automated checks use mocked responses and spend no search credits.

## Resizable inline info box

- With real search results visible, drag the info box's top handle vertically and its corner horizontally/vertically. Height and width change without selecting camera objects, sending another question, opening a modal or interrupting speech. Drag upward until the box fills the screen, including when captions are also tall. Drag down to shrink it. Confirm the centered status remains visible, the close/restore controls work, and voice listening continues.
- Collapse/expand using the chevron: details, images and scrolling remain inside the box. New replies start compact, saved dimensions apply on expansion, and × hides the box and its saved results can be reopened with the dotted info button. Test size persistence after relaunch and orientation changes, smaller phones and larger text.
- The centered colored status badge stays in place, with no old top-left status text. Captions keep their independent height adjustment. Test both resize handles with VoiceOver. Only explicit Settings/history navigation or tapping a website link should open another screen. Native layout and gestures require real-device verification.

- Region selection starts off. Camera touches must not select or freeze a frame until the viewfinder button is enabled. Disable it with an active selection and verify the focus chip and selection clear; the next question uses a fresh frame. Automatic assistant boxes still work with manual selection off. Verify the lighter pointer, small focus chip, VoiceOver labels, and drag cancellation during a request.

## Caption and info bubble spacing

- Start with captions on and make them tall. Expand the info bubble slowly, resize its width, and test long source titles and larger text. Captions stay above the measured bubble with a gap and shrink to the available space; they must not overlap.
- Enlarge info past roughly two thirds of the camera area: captions temporarily disappear without changing their saved toggle or height. Shrink/collapse/hide info and verify captions return. Repeat with captions off beforehand: they must stay off. Repeat while new messages arrive, after rotating, and on a small phone.
- At maximum size, info retains continuous rounded corners, horizontal and bottom camera margins, and a translucent grey fill. The centered status stays clear and restore/close/drag controls remain usable. There is no modal presentation or listening interruption.
- Check captions against bright and moving backgrounds: the slightly stronger grey bubble fill should improve readability while leaving the camera visible. Native geometry and gestures require Xcode/device verification.

## Assistant voice

- In Settings → Assistant voice, preview Automatic and an installed English voice. Automatic prefers Premium, then Enhanced; explicit choices persist after relaunch and apply to replies and spoken errors. Previews must not send camera questions, search, or change conversation/task history.
- Download an Enhanced/Premium English voice in iPhone accessibility settings and return. The picker refreshes on foregrounding. Delete a selected download and verify the app falls back to Automatic without a broken Picker selection or failed reply. With no higher-quality voice installed, a basic English voice still works; do not claim that code alone upgrades a missing voice download.
- Stop a preview, switch voices during playback, dismiss settings during a preview, interrupt audio, and mute/unmute. Speech playback must stop as appropriate and listening must resume only when the camera screen is active, unmuted and not busy. Confirm captions and the colored speaking/listening badge still follow playback. Preview and voice quality require a physical iPhone and were not executable in the Linux authoring environment.

- While previewing a voice, scroll the voice rows and download instructions out of view: playback must continue. Closing Settings or changing the voice stops it. With only standard voices installed, Automatic should still prefer the phone’s English dialect where available.


## Multiple targets, recovery schedule and rotation

- Identify a bottle, then ask how to open it. The bottle should retain its ID and highlight while a new lid/button target is added with the bottle as its parent. Repeat across several follow-ups; unrelated objects must not inherit each other's IDs. Retain at most six objects.
- Make two manual selections before asking a question. Confirm both are associated with one fresh camera frame, and old objects persist after the answer. In Settings → Remembered objects, forget one target and clear all; forgotten targets must not reappear from recovery callbacks.
- Occlude a target: hide its box and search approximately once a second for the full minute. After one minute, it must remain hidden/dormant with no more recovery scans. A new question restarts local recovery. Other visible targets must continue tracking throughout.
- Roll the phone slowly through positive and negative angles while pointing at a textured object: outlines should rotate with it without arbitrary expiry. Repeat with the mirrored front camera and verify the angle/position reflect together. Move/rotate the object itself, change distance, occlude/reintroduce it rotated, and test distinct competing lookalikes.
- Measure preview smoothness with several live trackers and several missing targets. Recovery searches are scheduled for at most one lost object per captured frame. Confirm no extra Gemini/Serper calls occur for rotation or recovery.
- Test camera flip, a new task, backgrounding and clearing/forgetting targets while a reply is in flight. No old-camera or old-task boxes should be reintroduced. Large out-of-plane rotations, uniform surfaces and occlusion remain best-effort cases and must not show frozen positions.


## Snapshot-history and recovery responsiveness

- Track a textured object for 10, 20 and 60 seconds while changing its view gradually. Inspect that source/newest views remain while intermediate history is thinned; memory must not grow indefinitely. Return to an earlier view and check recovery against that older snapshot.
- Lose one or several targets, then immediately ask a question. Camera capture and JPEG encoding must not wait for the full-image search to finish. Compare local capture-to-send delay separately from Serper/Gemini response latency.
- While a background search is running, clear/forget the object, switch cameras, start a new task, or background the app. A result from the old target instance or loss revision must never reappear. A recovery result is replayed from its own source frame before drawing, not applied directly to the latest image.
- Check CPU/thermal behavior on the actual phone with several missing objects: only one full-image background scan can be in flight, and pending target deadlines are served fairly. Once a lost target reaches one minute, it must stop scheduling work until a new question restarts recovery.
- Verify uniform views are not used as identity templates; appearance changes and lookalikes remain best-effort cases. No history/recovery operation should generate extra provider calls or write camera images to disk.


## Apple foreground-mask experimental branch

These replace the rectangle/appearance-recovery checks on this branch. Rebuild and run on a physical iPhone:

- Ask to identify a distinct foreground object. Confirm the tint follows its silhouette, including gaps around it, rather than tinting a full rectangular region or the entire camera.
- Move around the object and rotate the phone slightly. The silhouette must update to the current viewpoint. Try the front camera too: the tint must mirror with the preview.
- Cover the object briefly, then uncover it near its last location. A stale tint must disappear within 0.8 seconds, with fresh segmentation attempting recovery approximately once per second for one minute. Major movement while hidden may require a new selection.
- Identify two separate objects. Confirm each gets its own tint. Ask about a small lid/button: if Apple only returns the whole object, there should be no misleading whole-object highlight for that part.
- Clear/forget selections, switch cameras and background the app during segmentation. Old results must never appear afterward.
- Speak while objects are lost. Check camera smoothness, response latency, device warmth and mask refresh rate. Actual Vision inference speed depends on the phone; a worker result older than 0.8 seconds is discarded.
