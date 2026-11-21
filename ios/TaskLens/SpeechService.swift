import AVFoundation
import Combine
import Speech

@MainActor
final class SpeechService: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPreparing = false
    @Published private(set) var transcript = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasTap = false
    private var recordingID: UUID?
    private var finishContinuation: CheckedContinuation<String, Never>?
    private var operationID = UUID()

    func startRecording() async throws {
        guard !isRecording, !isPreparing else { return }
        cancelRecording()
        let operation = UUID()
        operationID = operation
        isPreparing = true
        defer { isPreparing = false }
        stopSpeaking()
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard authorization == .authorized, await AVCaptureDevice.requestAccess(for: .audio) else {
            throw TaskLensError.message("Allow microphone and speech recognition in iPhone Settings, or type your question.")
        }
        guard operationID == operation else { throw CancellationError() }
        guard let recognizer, recognizer.isAvailable else {
            throw TaskLensError.message("Speech recognition is unavailable. You can still type a question.")
        }
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try audioSession.setActive(true)
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
            throw TaskLensError.message("No microphone input is available.")
        }
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        hasTap = true
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.recordingID == id else { return }
                if let result { self.transcript = result.bestTranscription.formattedString }
                if result?.isFinal == true || error != nil { self.finishNow() }
            }
        }
        engine.prepare()
        do {
            try engine.start()
            isRecording = true
        } catch {
            cancelRecording()
            throw TaskLensError.message("Could not start the microphone. Try typing your question.")
        }
    }

    func finishRecording() async -> String {
        guard recordingID != nil else { return transcript }
        isPreparing = true
        defer { isPreparing = false }
        engine.stop()
        removeTap()
        request?.endAudio()
        isRecording = false
        return await withCheckedContinuation { continuation in
            finishContinuation = continuation
            let id = recordingID
            // Some recognizers never deliver a final result after endAudio.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                guard let self, self.recordingID == id else { return }
                self.finishNow()
            }
        }
    }

    func cancelRecording() {
        operationID = UUID()
        finishNow()
    }

    private func finishNow() {
        recordingID = nil
        engine.stop()
        removeTap()
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        isRecording = false
        let continuation = finishContinuation
        finishContinuation = nil
        continuation?.resume(returning: transcript)
    }

    private func removeTap() {
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
    }

    func speak(_ text: String) {
        guard !isRecording else { return }
        stopSpeaking()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stopSpeaking() { synthesizer.stopSpeaking(at: .immediate) }
}
