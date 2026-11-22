# Audio lifecycle fixes

The warning log showed repeated AVAudioSession/SessionCore main-thread hang-risk
diagnostics, zero-length buffers, audio underflows and an audio-service IPC
failure. The previous main-actor speech service called synchronous session and
engine APIs during each listen/speak transition. Its TTS entry point also called
stopSpeaking, which could schedule a microphone restart before playback began.

The UI-facing SpeechService remains on the main actor. SpeechAudioWorker owns
session configuration/activation, engine creation/start/stop, input taps and the
recognition task on one serial DispatchQueue. Blocking APIs stay off the UI
thread and remain compatible with the project's iOS 17 minimum. The synthesizer
explicitly uses the application-managed session. Voice choice and captions keep
their existing behavior.

The session is configured once and stays active across foreground question,
analysis and reply transitions. Stopping recognition removes only the microphone
tap/task; it does not repeatedly reconfigure/deactivate the shared session while
TTS is playing. App suspension stops recording and speech, then deactivates the
session on the worker. Interruption recovery asks the user to Unmute. Microphone
route changes stop/restart recognition against the new input format. A media
services reset discards audio objects and session configuration; recording and
speech wait for user recovery (Unmute, a new question or voice preview) rather than automatically resuming old audio.

Startup has cancellation gates checked on the worker before hardware side
effects and after activation. Late queued recording/playback operations cannot
undo a mute, cancellation or background transition. UI generation IDs also
reject late recognition callbacks and superseded playback preparation. Playback
is marked pending before asynchronous preparation, so recording cannot restart
in that gap. The 400 ms post-speech restart delay is retained.

Input taps discard empty/invalid PCM buffers. A short lock-protected gate closes
before endAudio/cancel; the realtime callback uses try-lock, and never waits for
teardown. The session is reused across replies instead of enumerating/configuring
audio on every speech turn.

## Validation

Native XCTest additions in GeometryTests.swift use an injected fake session to
check worker thread affinity, session reuse, suspend/resume ordering, cancelled
startup, cancellation during activation, explicit recovery after an activation
failure, media-services reset, and empty-buffer filtering. The fake-session tests
do not open a real microphone. Xcode compilation, those native tests and actual
iPhone playback are unavailable in the authoring environment and remain required.

These changes address application-side lifecycle problems; they do not guarantee
that every internal iOS audio diagnostic disappears. Framework-generated
unsafeForcedSync/IPC/underflow messages need device reproduction and a stack
trace if they persist. The unrelated dSYM, PointerUI and network timing messages
were not suppressed or used as evidence of an audio fix.
