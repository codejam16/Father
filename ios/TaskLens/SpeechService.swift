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

/// Continuous listening with pause-to-send, spoken replies, and interruption ("barge-in").
///
/// Replies normally play through the same AVAudioEngine as the microphone with Apple's voice
/// processing enabled, so the phone cancels its own voice from the microphone signal. Anything
/// still heard that matches the reply's words is treated as echo; new words ("wait", "stop", or a
/// real question) stop the reply and become the user's next utterance. If echo cancellation is
/// unavailable, interruptions are off, or the user is muted, replies use the original turn-taking
/// path: the microphone is off while the assistant speaks.
@MainActor
final class SpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var transcript = ""
    var onUtterance: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    /// Set by the owner: whether talking over a reply may interrupt it.
    var allowsInterruption = true
    /// Chosen voice identifier; empty means the most natural installed English voice.
    var voiceIdentifier = ""
    /// True while `onUtterance` runs if that utterance interrupted a spoken reply.
    private(set) var lastUtteranceInterrupted = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
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
            do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
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

    func speak(_ text: String) {
        stopSpeaking(restartListening: false)
        let utterance = AVSpeechUtterance(string: Self.speakable(text))
        utterance.voice = Self.voice(for: voiceIdentifier)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
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
        player.play()
        Self.render(utterance, synthesizer: synthesizer, player: player, format: playbackFormat) { [weak self] in
            Task { @MainActor [weak self] in self?.finishedPlayback(id) }
        }
        if wantsListening { prepareListening() }
    }

    /// Synthesizes into buffers and schedules them on the player. Runs off the main actor.
    nonisolated private static func render(_ utterance: AVSpeechUtterance, synthesizer: AVSpeechSynthesizer,
                                           player: AVAudioPlayerNode, format: AVAudioFormat,
                                           onFinished: @escaping () -> Void) {
        var ended = false
        synthesizer.write(utterance) { buffer in
            guard !ended, let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                ended = true
                // A one-frame silent buffer marks the end of the reply.
                guard let marker = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else { onFinished(); return }
                marker.frameLength = 1
                player.scheduleBuffer(marker, completionCallbackType: .dataPlayedBack) { _ in onFinished() }
                return
            }
            if let converted = convert(pcm, to: format) {
                player.scheduleBuffer(converted, completionHandler: nil)
            }
        }
    }

    nonisolated private static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error || output.frameLength == 0 ? nil : output
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

    func stopSpeaking(restartListening: Bool = true) {
        activeUtterance = nil
        playbackID = nil
        synthesizer.stopSpeaking(at: .immediate)
        if engineConfigured { player.stop() }
        isSpeaking = false
        spokenWords = []
        if restartListening { scheduleRestart() }
        stopEngineIfIdle()
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

    /// English voices, most natural first: Premium, then Enhanced, then the basic built-in voices.
    /// Novelty voices (robots, whispers, bells) are excluded.
    nonisolated static func availableVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { first, second in
                if first.quality != second.quality { return first.quality.rawValue > second.quality.rawValue }
                // Prefer the phone's own English region, then US English, then by name.
                let preferred = Locale.current.language.region.map { "en-" + $0.identifier } ?? "en-US"
                let firstScore = first.language == preferred ? 0 : first.language == "en-US" ? 1 : 2
                let secondScore = second.language == preferred ? 0 : second.language == "en-US" ? 1 : 2
                if firstScore != secondScore { return firstScore < secondScore }
                return first.name < second.name
            }
    }

    nonisolated static func voice(for identifier: String) -> AVSpeechSynthesisVoice? {
        if !identifier.isEmpty, let chosen = AVSpeechSynthesisVoice(identifier: identifier) { return chosen }
        return availableVoices().first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    nonisolated static func qualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Basic"
        }
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

    /// Speaks a short sample, for choosing a voice.
    func preview(identifier: String) {
        let previous = voiceIdentifier
        voiceIdentifier = identifier
        speak("Hi! I can see what you're working on. What would you like help with?")
        voiceIdentifier = previous
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
