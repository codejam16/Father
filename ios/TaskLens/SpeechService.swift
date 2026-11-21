import AVFoundation
import Combine
import Speech

@MainActor
final class SpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var transcript = ""
    @Published private(set) var availableVoices: [AVSpeechSynthesisVoice] = []
    var onUtterance: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
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
    private var activeUtterance: AVSpeechUtterance?

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

    func setListening(_ enabled: Bool) {
        wantsListening = enabled
        if enabled {
            if !isRecording, !isPreparing, !isSpeaking, restartTask == nil { prepareListening() }
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
        guard wantsListening, !isSpeaking, !isRecording, !isPreparing else { return }
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
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        transcript = ""
        let id = UUID()
        recordingID = id
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw TaskLensError.message("No microphone input is available. You can still type a question.")
        }
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        hasTap = true
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.recordingID == id else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if text != self.transcript {
                        self.transcript = text
                        self.consecutiveFailures = 0
                        self.scheduleSilence(for: id)
                    }
                }
                if result?.isFinal == true {
                    self.completeUtterance()
                } else if error != nil {
                    self.finishSession()
                    self.consecutiveFailures += 1
                    if self.consecutiveFailures >= 3 {
                        self.setListening(false)
                        self.onFailure?("Speech recognition stopped. Tap Unmute to retry, or type your question.")
                    } else {
                        self.scheduleRestart()
                    }
                }
            }
        }
        engine.prepare()
        do { try engine.start() }
        catch {
            finishSession()
            throw TaskLensError.message("Could not start the microphone. Tap Unmute to retry, or type a question.")
        }
        isRecording = true
        // Rotate before Apple's recognition session duration limit.
        sessionLimitTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(50)) } catch { return }
            guard let self, self.recordingID == id else { return }
            self.completeUtterance()
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
        finishSession()
        transcript = ""
        if wantsListening, !text.isEmpty { onUtterance?(text) }
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard wantsListening, !isSpeaking, restartTask == nil else { return }
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
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        isRecording = false
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

    func speak(_ text: String, voiceIdentifier: String = "") {
        stopSpeaking()
        finishSession()
        transcript = ""
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch { scheduleRestart(); return }
        let utterance = AVSpeechUtterance(string: text)
        refreshVoices()
        utterance.voice = voice(for: voiceIdentifier)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.96
        activeUtterance = utterance
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        activeUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        scheduleRestart()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finishedSpeaking(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finishedSpeaking(utterance) }
    }

    private func finishedSpeaking(_ utterance: AVSpeechUtterance) {
        guard activeUtterance === utterance else { return }
        activeUtterance = nil
        isSpeaking = false
        // Let the speaker's last sound fade before opening the microphone.
        scheduleRestart()
    }
}
