import AVFoundation
import Combine
import Speech

/// Lets the microphone tap (a real-time audio thread) feed whichever recognition request is current.
private final class RecognitionFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ value: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        request = value
        lock.unlock()
    }

    private var buffers = 0
    private var peak: Float = 0
    private var loudBuffers = 0

    func append(_ buffer: AVAudioPCMBuffer) {
        let level = Self.level(of: buffer)
        lock.lock()
        let current = request
        buffers += 1
        peak = max(peak, level)
        if level > 0.02 { loudBuffers += 1 }
        lock.unlock()
        current?.append(buffer)
    }

    func resetStats() {
        lock.lock()
        buffers = 0
        peak = 0
        loudBuffers = 0
        lock.unlock()
    }

    /// Buffers received, loudest level, and how many buffers sounded like someone talking.
    func stats() -> (buffers: Int, peak: Float, loudBuffers: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (buffers, peak, loudBuffers)
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        let count = Int(buffer.frameLength)
        for index in 0..<count { sum += channel[index] * channel[index] }
        return (sum / Float(count)).squareRoot()
    }
}

/// Counts the audio frames scheduled for one reply, so playback position can be turned into progress.
private final class PlaybackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: AVAudioFramePosition = 0
    private var finished = false

    func add(_ count: AVAudioFrameCount) {
        lock.lock()
        frames += AVAudioFramePosition(count)
        lock.unlock()
    }

    func finish() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    /// Total length once all of the reply has been scheduled.
    var total: AVAudioFramePosition? {
        lock.lock()
        defer { lock.unlock() }
        return finished ? frames : nil
    }
}

/// Converts one reply's audio chunks with a single, continuous converter. A fresh converter per chunk
/// restarted at every chunk boundary, which was audible as tiny pauses between syllables.
private final class StreamConverter {
    private let output: AVAudioFormat
    private var converter: AVAudioConverter?

    init(output: AVAudioFormat) { self.output = output }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter == nil && buffer.format == output { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: output)
        }
        guard let converter else { return nil }
        return run(converter, input: buffer, endOfStream: false)
    }

    /// Releases the last few samples the converter holds back.
    func flush() -> AVAudioPCMBuffer? {
        guard let converter else { return nil }
        return run(converter, input: nil, endOfStream: true)
    }

    private func run(_ converter: AVAudioConverter, input: AVAudioPCMBuffer?, endOfStream: Bool) -> AVAudioPCMBuffer? {
        let ratio = output.sampleRate / converter.inputFormat.sampleRate
        let expected = Double(input?.frameLength ?? 0) * ratio
        guard let result = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(expected) + 2048) else { return nil }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: result, error: &conversionError) { _, inputStatus in
            if !supplied, let input {
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            // Keep the converter's state between chunks; only the final call ends the stream.
            inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
            return nil
        }
        return status == .error || result.frameLength == 0 ? nil : result
    }
}

/// Continuous listening with pause-to-send, spoken replies, and interruption ("barge-in").
///
/// Replies normally play through the same AVAudioEngine as the microphone with Apple's voice
/// processing enabled, so the phone cancels its own voice from the microphone signal. Anything
/// still heard that matches the reply's words is treated as echo; new words ("wait", "stop", or a
/// real question) stop the reply and become the user's next utterance. If echo cancellation is
/// unavailable, interruptions are off, or the user is muted, replies use the original turn-taking
/// path: the microphone is off while the assistant speaks.
@MainActor
final class SpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var transcript = ""
    @Published private(set) var availableVoices: [AVSpeechSynthesisVoice] = []
    var onUtterance: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    /// Set by the owner: whether talking over a reply may interrupt it.
    var allowsInterruption = true
    /// The last reply was cut off by the user talking (so the rest of it should not play).
    private(set) var lastPlaybackInterrupted = false
    /// True while `onUtterance` runs if that utterance interrupted a spoken reply.
    private(set) var lastUtteranceInterrupted = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    // 48 kHz so higher-quality voices are not squeezed down; the mixer feeds the speaker from here.
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    private let synthesizer = AVSpeechSynthesizer()
    private let feed = RecognitionFeed()
    private var engineConfigured = false
    private var echoCancellation = false
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceTask: Task<Void, Never>?
    private var sessionLimitTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var interruptionObserver: AnyCancellable?
    private var hasTap = false
    private var recordingID: UUID?
    private var operationID = UUID()
    private var wantsListening = false
    private var consecutiveFailures = 0
    /// Fallback (turn-taking) playback.
    private var activeUtterance: AVSpeechUtterance?
    /// Engine playback that can be interrupted.
    private var playbackID: UUID?
    private var spokenWords = Set<String>()
    private var echoText = ""
    private var interruptedThisUtterance = false
    /// Gemini voice played without interruption support (mic off).
    private var filePlayer: AVAudioPlayer?
    /// How the current reply's progress can be measured.
    private enum ProgressSource {
        case none
        case utterance(length: Int)
        case engine(PlaybackCounter)
        case file
    }
    private var progressSource = ProgressSource.none
    private var spokenLocation = 0
    /// Set when echo cancellation delivered unusable audio on this phone; not retried this run.
    private var voiceProcessingFailed = false
    private var receivedResult = false
    private var audioCheckTask: Task<Void, Never>?

    private var interruptible: Bool { echoCancellation && playbackID != nil }
    /// The microphone may run now: either nothing is playing, or the reply can be interrupted.
    private var canListenNow: Bool { !isSpeaking || interruptible }

    override init() {
        super.init()
        synthesizer.delegate = self
        refreshVoices()
        interruptionObserver = NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.wantsListening || self.isRecording || self.isSpeaking else { return }
                    self.setListening(false)
                    self.stopSpeaking()
                    self.onFailure?("Audio was interrupted. Tap Unmute when you're ready to continue.")
                }
            }
    }

    // MARK: Listening

    func setListening(_ enabled: Bool) {
        wantsListening = enabled
        if enabled {
            if !isRecording, !isPreparing, canListenNow, restartTask == nil { prepareListening() }
        } else {
            operationID = UUID()
            preparationTask?.cancel()
            preparationTask = nil
            isPreparing = false
            restartTask?.cancel()
            restartTask = nil
            finishSession()
            transcript = ""
            consecutiveFailures = 0
        }
    }

    private func prepareListening() {
        guard wantsListening, canListenNow, !isRecording, !isPreparing else { return }
        let operation = UUID()
        operationID = operation
        isPreparing = true
        preparationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.operationID == operation {
                    self.isPreparing = false
                    self.preparationTask = nil
                }
            }
            do {
                let authorization = await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
                }
                guard self.operationID == operation, self.wantsListening, !Task.isCancelled else { return }
                guard authorization == .authorized else {
                    throw TaskLensError.message("Allow speech recognition in iPhone Settings, or type your question.")
                }
                let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
                guard self.operationID == operation, self.wantsListening, !Task.isCancelled else { return }
                guard microphoneAllowed else {
                    throw TaskLensError.message("Allow microphone access in iPhone Settings, or type your question.")
                }
                guard self.canListenNow else { return }
                try self.startSession()
            } catch {
                guard self.operationID == operation else { return }
                self.setListening(false)
                self.onFailure?(error.localizedDescription)
            }
        }
    }

    private func startSession() throws {
        guard let recognizer, recognizer.isAvailable else {
            throw TaskLensError.message("Speech recognition is unavailable. Tap Unmute to retry, or type a question.")
        }
        try startEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        feed.set(request)
        transcript = ""
        echoText = ""
        interruptedThisUtterance = false
        let id = UUID()
        recordingID = id
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in self?.handle(result: result, error: error, id: id) }
        }
        isRecording = true
        receivedResult = false
        feed.resetStats()
        if echoCancellation { startAudioCheck(for: id) }
        // Rotate before Apple's recognition session duration limit.
        sessionLimitTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(50)) } catch { return }
            guard let self, self.recordingID == id else { return }
            self.completeUtterance()
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, id: UUID) {
        guard recordingID == id else { return }
        if result != nil { receivedResult = true }
        if let result {
            let heard = result.bestTranscription.formattedString
            if isSpeaking {
                if interruptible, shouldInterrupt(heard) {
                    interruptPlayback()
                } else {
                    // Still the assistant's own voice (or nothing new): remember it as echo.
                    echoText = heard
                    if result.isFinal {
                        finishSession()
                        scheduleRestart()
                    }
                    return
                }
            }
            let spoken = removingEcho(heard)
            if spoken != transcript {
                transcript = spoken
                consecutiveFailures = 0
                scheduleSilence(for: id)
            }
        }
        if result?.isFinal == true {
            completeUtterance()
        } else if error != nil {
            finishSession()
            if isSpeaking { scheduleRestart(); return }
            consecutiveFailures += 1
            if consecutiveFailures >= 3 {
                setListening(false)
                onFailure?("Speech recognition stopped. Tap Unmute to retry, or type your question.")
            } else {
                scheduleRestart()
            }
        }
    }

    private func scheduleSilence(for id: UUID) {
        silenceTask?.cancel()
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        silenceTask = Task { [weak self] in
            // How long a pause ends a question: short enough to feel responsive, long enough for a breath.
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            guard let self, self.recordingID == id, self.wantsListening else { return }
            self.completeUtterance()
        }
    }

    private func completeUtterance() {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let interrupted = interruptedThisUtterance
        finishSession()
        transcript = ""
        if wantsListening, !text.isEmpty {
            lastUtteranceInterrupted = interrupted
            onUtterance?(text)
            lastUtteranceInterrupted = false
        }
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard wantsListening, canListenNow, restartTask == nil else { return }
        restartTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self else { return }
            self.restartTask = nil
            if self.wantsListening { self.prepareListening() }
        }
    }

    private func finishSession() {
        // Invalidate callbacks before cancelling, so late results cannot send twice.
        recordingID = nil
        silenceTask?.cancel()
        silenceTask = nil
        sessionLimitTask?.cancel()
        sessionLimitTask = nil
        audioCheckTask?.cancel()
        audioCheckTask = nil
        feed.set(nil)
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        isRecording = false
        echoText = ""
        stopEngineIfIdle()
    }

    // MARK: Interruption

    /// New words that are not part of the reply mean the user is talking.
    private func shouldInterrupt(_ heard: String) -> Bool {
        let fresh = Self.words(removingEcho(heard))
        let novel = fresh.filter { !spokenWords.contains($0) }
        let cues: Set<String> = ["stop", "wait", "hold", "pause", "sorry", "hey", "no", "quiet", "shush", "enough", "excuse"]
        return novel.count >= 2 || novel.contains(where: { cues.contains($0) })
    }

    private func removingEcho(_ heard: String) -> String {
        guard !echoText.isEmpty, heard.hasPrefix(echoText) else { return heard }
        return String(heard.dropFirst(echoText.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func interruptPlayback() {
        lastPlaybackInterrupted = true
        playbackID = nil
        activeUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        if engineConfigured { player.stop() }
        isSpeaking = false
        spokenWords = []
        interruptedThisUtterance = true
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map { String($0).replacingOccurrences(of: "'", with: "") }
            .filter { !$0.isEmpty }
    }

    // MARK: Speaking

    func speak(_ text: String, voiceIdentifier: String = "", audio: SpeechAudio? = nil) {
        stopSpeaking(restartListening: false)
        lastPlaybackInterrupted = false
        // Gemini's natural voice: interruptible through the echo-cancelled engine when possible.
        if let audio, let buffer = Self.pcmBuffer(audio) {
            if allowsInterruption, (try? startEngine()) != nil, echoCancellation {
                playThroughEngine(buffer, text: text)
                return
            }
            if playWithAudioPlayer(audio) { return }
        }
        let utterance = AVSpeechUtterance(string: Self.speakable(text))
        refreshVoices()
        utterance.voice = voice(for: voiceIdentifier)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.96
        utterance.pitchMultiplier = 1.0
        // Use the voice chosen here, not the system's accessibility speech settings.
        utterance.prefersAssistiveTechnologySettings = false
        if allowsInterruption {
            do {
                try startEngine()
                if echoCancellation {
                    speakThroughEngine(utterance, text: text)
                    return
                }
            } catch {
                // Fall back to turn-taking playback below.
            }
        }
        finishSession()
        stopEngine()
        transcript = ""
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch { scheduleRestart(); return }
        activeUtterance = utterance
        progressSource = .utterance(length: utterance.speechString.count)
        spokenLocation = 0
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    private func speakThroughEngine(_ utterance: AVSpeechUtterance, text: String) {
        let id = UUID()
        playbackID = id
        // Restart recognition so echo and the user's words start from a clean transcript.
        finishSession()
        transcript = ""
        spokenWords = Set(Self.words(text))
        isSpeaking = true
        let counter = PlaybackCounter()
        progressSource = .engine(counter)
        Self.render(utterance, synthesizer: synthesizer, player: player, format: playbackFormat, counter: counter) { [weak self] in
            Task { @MainActor [weak self] in self?.finishedPlayback(id) }
        }
        if wantsListening { prepareListening() }
    }

    /// Synthesizes into buffers and schedules them on the player. Runs off the main actor.
    nonisolated private static func render(_ utterance: AVSpeechUtterance, synthesizer: AVSpeechSynthesizer,
                                           player: AVAudioPlayerNode, format: AVAudioFormat,
                                           counter: PlaybackCounter, onFinished: @escaping () -> Void) {
        var ended = false
        var started = false
        var scheduledFrames: AVAudioFrameCount = 0
        // Build up a short cushion before playing, so slower voices never run dry mid-word.
        let cushion = AVAudioFrameCount(format.sampleRate * 0.3)
        let stream = StreamConverter(output: format)
        func schedule(_ buffer: AVAudioPCMBuffer) {
            player.scheduleBuffer(buffer, completionHandler: nil)
            scheduledFrames += buffer.frameLength
            counter.add(buffer.frameLength)
            if !started && scheduledFrames >= cushion {
                started = true
                player.play()
            }
        }
        synthesizer.write(utterance) { buffer in
            guard !ended, let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                ended = true
                if let tail = stream.flush() { schedule(tail) }
                counter.finish()
                if !started {
                    started = true
                    player.play()
                }
                // A one-frame silent buffer marks the end of the reply.
                guard let marker = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else { onFinished(); return }
                marker.frameLength = 1
                player.scheduleBuffer(marker, completionCallbackType: .dataPlayedBack) { _ in onFinished() }
                return
            }
            if let converted = stream.convert(pcm) { schedule(converted) }
        }
    }

    private func playThroughEngine(_ buffer: AVAudioPCMBuffer, text: String) {
        let id = UUID()
        playbackID = id
        // Restart recognition so echo and the user's words start from a clean transcript.
        finishSession()
        transcript = ""
        spokenWords = Set(Self.words(text))
        isSpeaking = true
        let counter = PlaybackCounter()
        progressSource = .engine(counter)
        Self.schedule(buffer, on: player, format: playbackFormat, counter: counter) { [weak self] in
            Task { @MainActor [weak self] in self?.finishedPlayback(id) }
        }
        if wantsListening { prepareListening() }
    }

    nonisolated private static func schedule(_ buffer: AVAudioPCMBuffer, on player: AVAudioPlayerNode,
                                             format: AVAudioFormat, counter: PlaybackCounter,
                                             onFinished: @escaping () -> Void) {
        let stream = StreamConverter(output: format)
        if let converted = stream.convert(buffer) {
            player.scheduleBuffer(converted, completionHandler: nil)
            counter.add(converted.frameLength)
        }
        if let tail = stream.flush() {
            player.scheduleBuffer(tail, completionHandler: nil)
            counter.add(tail.frameLength)
        }
        counter.finish()
        guard let marker = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else { onFinished(); return }
        marker.frameLength = 1
        player.scheduleBuffer(marker, completionCallbackType: .dataPlayedBack) { _ in onFinished() }
        player.play()
    }

    /// Plays Gemini audio with the microphone off (interruptions disabled, muted, or no echo cancellation).
    private func playWithAudioPlayer(_ audio: SpeechAudio) -> Bool {
        finishSession()
        stopEngine()
        transcript = ""
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch { return false }
        guard let audioPlayer = try? AVAudioPlayer(data: Self.wav(audio)) else { return false }
        audioPlayer.delegate = self
        filePlayer = audioPlayer
        progressSource = .file
        isSpeaking = true
        if audioPlayer.play() { return true }
        filePlayer = nil
        isSpeaking = false
        return false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.finishedFilePlayback(player) }
    }

    private func finishedFilePlayback(_ audioPlayer: AVAudioPlayer) {
        guard filePlayer === audioPlayer else { return }
        filePlayer = nil
        isSpeaking = false
        scheduleRestart()
    }

    nonisolated private static func pcmBuffer(_ audio: SpeechAudio) -> AVAudioPCMBuffer? {
        let frames = audio.pcm.count / 2
        guard frames > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: audio.sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.int16ChannelData?[0] else { return nil }
        audio.pcm.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(channel, base, frames * 2) // 16-bit little-endian, as iOS uses natively
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }

    nonisolated private static func wav(_ audio: SpeechAudio) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        let rate = UInt32(audio.sampleRate)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + audio.pcm.count)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(rate); append(rate * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(audio.pcm.count))
        data.append(audio.pcm)
        return data
    }

    private func finishedPlayback(_ id: UUID) {
        guard playbackID == id else { return }
        playbackID = nil
        isSpeaking = false
        spokenWords = []
        // Drop what was heard during the reply (echo) unless the user had started talking.
        if transcript.isEmpty {
            finishSession()
            scheduleRestart()
        }
        stopEngineIfIdle()
    }

    /// How much of the current reply has been spoken (0…1), or nil when not speaking or not yet known.
    func currentProgress() -> Double? {
        guard isSpeaking else { return nil }
        switch progressSource {
        case .none:
            return nil
        case .utterance(let length):
            return length > 0 ? min(1, Double(spokenLocation) / Double(length)) : nil
        case .engine(let counter):
            guard let total = counter.total, total > 0, let nodeTime = player.lastRenderTime,
                  let playerTime = player.playerTime(forNodeTime: nodeTime) else { return nil }
            return min(1, max(0, Double(playerTime.sampleTime) / Double(total)))
        case .file:
            guard let filePlayer, filePlayer.duration > 0 else { return nil }
            return min(1, filePlayer.currentTime / filePlayer.duration)
        }
    }

    func stopSpeaking(restartListening: Bool = true) {
        filePlayer?.stop()
        filePlayer = nil
        activeUtterance = nil
        playbackID = nil
        synthesizer.stopSpeaking(at: .immediate)
        if engineConfigured { player.stop() }
        isSpeaking = false
        spokenWords = []
        if restartListening { scheduleRestart() }
        stopEngineIfIdle()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        let location = characterRange.location
        Task { @MainActor [weak self] in
            guard let self, self.activeUtterance === utterance else { return }
            self.spokenLocation = location
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finishedSpeaking(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finishedSpeaking(utterance) }
    }

    /// Fallback path only; engine playback reports through `finishedPlayback`.
    private func finishedSpeaking(_ utterance: AVSpeechUtterance) {
        guard activeUtterance === utterance else { return }
        activeUtterance = nil
        isSpeaking = false
        // Let the speaker's last sound fade before opening the microphone.
        scheduleRestart()
    }

    // MARK: Voices

    func refreshVoices() {
        let preferredLanguage = Locale.preferredLanguages.first(where: { $0.hasPrefix("en") }) ?? "en-US"
        availableVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { left, right in
                // Quality comes first, then the phone's English dialect.
                if left.quality.rawValue != right.quality.rawValue { return left.quality.rawValue > right.quality.rawValue }
                let leftMatches = left.language == preferredLanguage
                let rightMatches = right.language == preferredLanguage
                if leftMatches != rightMatches { return leftMatches }
                if left.language != right.language { return left.language < right.language }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
    }

    func voice(for identifier: String) -> AVSpeechSynthesisVoice? {
        if let saved = availableVoices.first(where: { $0.identifier == identifier }) { return saved }
        // A removed download falls back gracefully instead of breaking replies.
        // The list already ranks quality and the preferred English dialect.
        return availableVoices.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    static func voiceLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        let quality: String
        switch voice.quality {
        case .premium: quality = "Premium"
        case .enhanced: quality = "Enhanced"
        default: quality = "Standard"
        }
        let name = voice.name.localizedCaseInsensitiveContains(quality) ? voice.name : "\(voice.name) · \(quality)"
        return "\(name) · \(voice.language)"
    }

    /// Replies are written text: remove formatting that sounds odd when read aloud.
    nonisolated static func speakable(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: #"https?://\S+"#, with: "the link on screen", options: .regularExpression)
        // List bullets at the start of a line, then leftover formatting characters.
        result = result.replacingOccurrences(of: #"(?m)^\s*(?:[•\-–*]|\d+[.)])\s+"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[*_#`>]+"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Audio engine

    private func startEngine() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        // Echo cancellation is only needed to talk over replies. It can only change while stopped.
        let wantEchoCancellation = allowsInterruption && !voiceProcessingFailed
        if !engineConfigured || wantEchoCancellation != echoCancellation {
            if engineConfigured { stopEngine() }
            do {
                try engine.inputNode.setVoiceProcessingEnabled(wantEchoCancellation)
                echoCancellation = wantEchoCancellation
            } catch {
                try? engine.inputNode.setVoiceProcessingEnabled(false)
                echoCancellation = false
            }
        }
        if !engineConfigured {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
            engineConfigured = true
        }
        if !hasTap {
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw TaskLensError.message("No microphone input is available. You can still type a question.")
            }
            Self.installTap(on: engine.inputNode, format: format, feed: feed)
            hasTap = true
        }
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch {
                throw TaskLensError.message("Could not start the microphone. Tap Unmute to retry, or type a question.")
            }
        }
    }

    /// If echo cancellation gives the recognizer no usable audio on this phone, switch it off
    /// and go back to plain listening (replies then pause the microphone, as before).
    private func startAudioCheck(for id: UUID) {
        audioCheckTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, self.recordingID == id else { return }
            let early = self.feed.stats()
            if early.buffers == 0 || early.peak == 0 {
                self.disableEchoCancellation()
                return
            }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard self.recordingID == id, !self.receivedResult else { return }
            // About a second of speech-level audio, yet not a single word recognized.
            if self.feed.stats().loudBuffers > 40 { self.disableEchoCancellation() }
        }
    }

    private func disableEchoCancellation() {
        guard echoCancellation, playbackID == nil else { return }
        voiceProcessingFailed = true
        finishSession()
        stopEngine()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        echoCancellation = false
        scheduleRestart()
    }

    nonisolated private static func installTap(on node: AVAudioInputNode, format: AVAudioFormat, feed: RecognitionFeed) {
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in feed.append(buffer) }
    }

    private func stopEngineIfIdle() {
        guard !wantsListening, !isRecording, playbackID == nil else { return }
        stopEngine()
    }

    private func stopEngine() {
        if engineConfigured { player.stop() }
        if engine.isRunning { engine.stop() }
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
    }
}
