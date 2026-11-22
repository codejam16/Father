# Voice behavior after scanner integration

The integrated scanner uses the visual-assistant branch’s speech engine, cloud
voice playback, spoken interruptions, progress reporting, and unfinished-sentence
handling. Recognition rejects empty/invalid buffers and synchronizes appending
with recognition-request replacement, retaining the defensive input handling
from the Apple branch.

The prior Apple-only SpeechAudioWorker lifecycle implementation is not used by
this combined speech engine. In particular, engine/session setup in the incoming
voice implementation still needs checking for main-thread responsiveness warnings
on a physical iPhone. Do not treat backend tests or static review as audio or
native-build verification.
