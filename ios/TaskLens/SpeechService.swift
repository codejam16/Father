import AVFoundation
import Combine
import Speech

// Hardware/session work is confined to this serial queue, never the main actor.
// Keep playAndRecord active across turns instead of renegotiating it per reply.
protocol SpeechSessionControlling: AnyObject {
    func configure() throws
    func setActive(_ active: Bool) throws
}

private final class SystemSpeechSession: SpeechSessionControlling {
    func configure() throws {
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
    }
    func setActive(_ active: Bool) throws {
        try AVAudioSession.sharedInstance().setActive(active, options: active ? [] : [.notifyOthersOnDeactivation])
    }
}

enum SpeechBufferPolicy {
    static func canAppend(frames: UInt32, sampleRate: Double, channels: UInt32, bytes: UInt32, hasData: Bool) -> Bool {
        frames > 0 && sampleRate.isFinite && sampleRate > 0 && channels > 0 && bytes > 0 && hasData
    }
}

// Cancellation must be visible before a delayed async call reaches the queue.
// Otherwise an old start could run after the user already muted/stopped it.
final class SpeechAudioOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func checkCancellation() throws { if isCancelled { throw CancellationError() } }
}

private final class RecognitionInputGate {
    private let lock = NSLock()
    private var open = true
    let request: SFSpeechAudioBufferRecognitionRequest
    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    func append(_ buffer: AVAudioPCMBuffer) {
        let list = buffer.audioBufferList.pointee
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard list.mNumberBuffers > 0, buffers.allSatisfy({ $0.mData != nil && $0.mDataByteSize > 0 }),
              SpeechBufferPolicy.canAppend(frames: buffer.frameLength, sampleRate: buffer.format.sampleRate,
                channels: buffer.format.channelCount, bytes: list.mBuffers.mDataByteSize,
                hasData: list.mBuffers.mData != nil), lock.try() else { return }
        defer { lock.unlock() }
        if open { request.append(buffer) }
    }
    func close() {
        lock.lock(); open = false; lock.unlock()
    }
}

final class SpeechAudioWorker {
    typealias Update = @Sendable (String?, Bool, Bool) -> Void
    private let queue = DispatchQueue(label: "tasklens.audio", qos: .userInitiated)
    private let session: SpeechSessionControlling
    private var configured = false
    private var active = false
    private var engine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var input: RecognitionInputGate?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasTap = false

    init(session: SpeechSessionControlling? = nil) { self.session = session ?? SystemSpeechSession() }

    private func ensureActive() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        if !configured { try session.configure(); configured = true }
        if !active { try session.setActive(true); active = true }
    }

    func startRecording(operation: SpeechAudioOperation, update: @escaping Update) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard !operation.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                do {
                    stopRecordingOnQueue()
                    try ensureActive()
                    try operation.checkCancellation()
                    if recognizer == nil { recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) }
                    guard let recognizer, recognizer.isAvailable else {
                        throw TaskLensError.message("Speech recognition is unavailable. Tap Unmute to retry, or type a question.")
                    }
                    if engine == nil { engine = AVAudioEngine() }
                    guard let engine else { throw TaskLensError.message("The microphone could not start.") }
                    let node = engine.inputNode
                    let format = node.outputFormat(forBus: 0)
                    guard format.sampleRate > 0, format.channelCount > 0 else {
                        throw TaskLensError.message("No microphone input is available. You can still type a question.")
                    }
                    let request = SFSpeechAudioBufferRecognitionRequest()
                    request.shouldReportPartialResults = true
                    if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
                    let gate = RecognitionInputGate(request)
                    input = gate
                    node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in gate.append(buffer) }
                    hasTap = true
                    recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                        update(result?.bestTranscription.formattedString, result?.isFinal == true, error != nil)
                    }
                    try operation.checkCancellation()
                    engine.prepare()
                    try engine.start()
                    try operation.checkCancellation()
                    continuation.resume()
                } catch {
                    stopRecordingOnQueue()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stopRecording() { queue.async { [self] in stopRecordingOnQueue() } }

    private func stopRecordingOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        input?.close() // No tap may append after endAudio/cancel.
        if let engine {
            if engine.isRunning { engine.stop() }
            if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        }
        input?.request.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil; input = nil
    }

    func preparePlayback(operation: SpeechAudioOperation = SpeechAudioOperation()) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try operation.checkCancellation()
                    stopRecordingOnQueue()
                    try ensureActive()
                    try operation.checkCancellation()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func mediaServicesReset() {
        queue.async { [self] in
            stopRecordingOnQueue()
            engine = nil; recognizer = nil
            configured = false; active = false
        }
    }

    func suspend() {
        queue.async { [self] in
            stopRecordingOnQueue()
            if active {
                do { try session.setActive(false) }
                catch { NSLog("TaskLens audio deactivation: %@", error.localizedDescription) }
                active = false
            }
        }
    }
}

@MainActor
final class SpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var transcript = ""
    @Published private(set) var availableVoices: [AVSpeechSynthesisVoice] = []
    var onUtterance: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    private let audio = SpeechAudioWorker()
    private var synthesizer = AVSpeechSynthesizer()
    private var silenceTask: Task<Void, Never>?
    private var sessionLimitTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var interruptionObserver: AnyCancellable?
    private var routeObserver: AnyCancellable?
    private var mediaServicesObserver: AnyCancellable?
    private var recordingID: UUID?
    private var recordingOperation: SpeechAudioOperation?
    private var playbackOperation: SpeechAudioOperation?
    private var operationID = UUID()
    private var playbackID = UUID()
    private var wantsListening = false
    private var needsUserAudioRecovery = false
    private var consecutiveFailures = 0
    private var activeUtterance: AVSpeechUtterance?

    override init() {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
        refreshVoices()
        interruptionObserver = NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.wantsListening || self.isRecording || self.isSpeaking else { return }
                    self.suspend()
                    self.needsUserAudioRecovery = true
                    self.onFailure?("Audio was interrupted. Tap Unmute when you're ready to continue.")
                }
            }
        routeObserver = NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] notification in
                let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue ||
                      reason == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.wantsListening, !self.isSpeaking else { return }
                    self.cancelPreparation(); self.finishSession(); self.scheduleRestart()
                }
            }
        mediaServicesObserver = NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.suspend()
                    self.needsUserAudioRecovery = true
                    self.audio.mediaServicesReset()
                    self.synthesizer = AVSpeechSynthesizer()
                    self.synthesizer.delegate = self
                    self.synthesizer.usesApplicationAudioSession = true
                    self.onFailure?("Audio services restarted. Tap Unmute to reconnect, or type your question.")
                }
            }

    }

    func setListening(_ enabled: Bool) {
        let changed = wantsListening != enabled
        wantsListening = enabled
        if enabled {
            needsUserAudioRecovery = false
            if !isRecording, !isPreparing, !isSpeaking, restartTask == nil { prepareListening() }
        } else if changed || isRecording || isPreparing {
            cancelPreparation()
            restartTask?.cancel(); restartTask = nil
            finishSession(); transcript = ""; consecutiveFailures = 0
        }
    }

    private func cancelPreparation() {
        recordingOperation?.cancel(); recordingOperation = nil
        operationID = UUID()
        preparationTask?.cancel(); preparationTask = nil; isPreparing = false
    }

    private func prepareListening() {
        guard wantsListening, !isSpeaking, !isRecording, !isPreparing else { return }
        let operation = UUID(); operationID = operation; isPreparing = true
        let audioOperation = SpeechAudioOperation(); recordingOperation = audioOperation
        preparationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.operationID == operation {
                    self.isPreparing = false; self.preparationTask = nil
                    if !self.isRecording { self.scheduleRestart() }
                }
            }
            do {
                var authorization = SFSpeechRecognizer.authorizationStatus()
                if authorization == .notDetermined {
                    authorization = await withCheckedContinuation { continuation in
                        SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
                    }
                }
                guard self.operationID == operation, self.wantsListening, !Task.isCancelled else { return }
                guard authorization == .authorized else {
                    throw TaskLensError.message("Allow speech recognition in iPhone Settings, or type your question.")
                }
                let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
                guard self.operationID == operation, self.wantsListening, !self.isSpeaking, !Task.isCancelled else { return }
                guard microphoneAllowed else {
                    throw TaskLensError.message("Allow microphone access in iPhone Settings, or type your question.")
                }
                let id = UUID(); self.recordingID = id; self.transcript = ""
                try await self.audio.startRecording(operation: audioOperation) { [weak self] text, final, failed in
                    Task { @MainActor [weak self] in self?.receive(text, final: final, failed: failed, for: id) }
                }
                guard self.operationID == operation, self.recordingID == id, self.wantsListening,
                      !self.isSpeaking, !Task.isCancelled else { return }
                self.isRecording = true
                self.sessionLimitTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(50)) } catch { return }
                    guard let self, self.recordingID == id else { return }
                    self.completeUtterance()
                }
            } catch is CancellationError {
                // A final/failed callback or a user action may cancel startup.
                // The deferred restart only runs if listening is still wanted.
            } catch {
                guard self.operationID == operation, !Task.isCancelled else { return }
                self.setListening(false)
                self.onFailure?((error as? TaskLensError)?.localizedDescription ?? "Could not start audio. Tap Unmute to retry, or type a question.")
            }
        }
    }

    private func receive(_ text: String?, final: Bool, failed: Bool, for id: UUID) {
        guard recordingID == id, wantsListening, !isSpeaking else { return }
        if let text, text != transcript {
            transcript = text; consecutiveFailures = 0; scheduleSilence(for: id)
        }
        if final { completeUtterance() }
        else if failed {
            finishSession(); consecutiveFailures += 1
            if consecutiveFailures >= 3 {
                setListening(false)
                onFailure?("Speech recognition stopped. Tap Unmute to retry, or type your question.")
            } else { scheduleRestart() }
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
        finishSession(); transcript = ""
        if wantsListening, !text.isEmpty { onUtterance?(text) }
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard wantsListening, !isSpeaking, !isRecording, !isPreparing, restartTask == nil else { return }
        restartTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self else { return }
            self.restartTask = nil
            if self.wantsListening { self.prepareListening() }
        }
    }

    private func finishSession() {
        recordingOperation?.cancel(); recordingOperation = nil
        recordingID = nil
        silenceTask?.cancel(); silenceTask = nil
        sessionLimitTask?.cancel(); sessionLimitTask = nil
        isRecording = false
        audio.stopRecording()
    }

    func suspend() {
        setListening(false)
        cancelPreparation()
        restartTask?.cancel(); restartTask = nil
        finishSession()
        cancelPlayback(restartListening: false)
        audio.suspend()
    }

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

    /// A fresh question/preview can reconnect audio; delayed old replies cannot.
    func noteUserAction() { needsUserAudioRecovery = false }

    func speak(_ text: String, voiceIdentifier: String = "") {
        guard !needsUserAudioRecovery, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        cancelPlayback(restartListening: false)
        cancelPreparation()
        restartTask?.cancel(); restartTask = nil
        finishSession(); transcript = ""
        let id = UUID(); playbackID = id
        let audioOperation = SpeechAudioOperation(); playbackOperation = audioOperation
        isSpeaking = true // Block mic restart while audio preparation is pending.
        let utterance = AVSpeechUtterance(string: text)
        if availableVoices.isEmpty { refreshVoices() }
        utterance.voice = voice(for: voiceIdentifier)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.96
        playbackTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.playbackID == id { self.playbackTask = nil } }
            do {
                try await self.audio.preparePlayback(operation: audioOperation)
                guard self.playbackID == id, self.isSpeaking, !Task.isCancelled else { return }
                self.activeUtterance = utterance
                self.synthesizer.speak(utterance)
            } catch {
                guard self.playbackID == id, !Task.isCancelled else { return }
                self.activeUtterance = nil; self.isSpeaking = false
                self.setListening(false)
                self.onFailure?("Audio playback could not start. Your answer is still available in captions.")
            }
        }
    }

    func stopSpeaking() { cancelPlayback(restartListening: true) }

    private func cancelPlayback(restartListening: Bool) {
        playbackOperation?.cancel(); playbackOperation = nil
        playbackID = UUID()
        playbackTask?.cancel(); playbackTask = nil
        let wasSpeaking = activeUtterance != nil
        activeUtterance = nil; isSpeaking = false
        if wasSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        if restartListening { scheduleRestart() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finishedSpeaking(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finishedSpeaking(utterance) }
    }

    private func finishedSpeaking(_ utterance: AVSpeechUtterance) {
        guard activeUtterance === utterance else { return }
        activeUtterance = nil; isSpeaking = false
        scheduleRestart()
    }
}
