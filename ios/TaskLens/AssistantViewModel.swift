import Combine
import Foundation
import CoreGraphics

@MainActor
final class AssistantViewModel: ObservableObject {
    let camera = CameraService()
    let speech = SpeechService()
    let settings = ConnectionSettings()
    @Published var question = ""
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isBusy = false
    @Published private(set) var selectedFrame: SelectedFrame?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastReplyWasDemo = true
    @Published private(set) var isMuted = false
    @Published private(set) var pendingQuestion: String?
    @Published private(set) var webInfo: WebInfo?
    private var isActive = false
    private var voiceSuspended = false
    private let client = AnalysisClient()
    private var work: Task<Void, Never>?
    private var workID: UUID?
    private var selectionID = UUID()

    init() {
        speech.onUtterance = { [weak self] text in
            guard let self, self.isActive, !self.isMuted, !self.voiceSuspended, !self.isBusy else { return }
            self.question = text
            self.send()
        }
        speech.onFailure = { [weak self] message in
            self?.isMuted = true
            self?.errorMessage = message
        }
    }

    func resume() async {
        isActive = true
        await camera.start()
        updateListening()
    }

    func setVoiceSuspended(_ suspended: Bool) {
        voiceSuspended = suspended
        updateListening()
        if suspended { speech.stopSpeaking() }
    }

    private func updateListening() {
        speech.setListening(isActive && !isMuted && !voiceSuspended && !isBusy)
    }

    var lastAnswer: String {
        messages.last(where: { $0.role == .assistant })?.content
            ?? "Show me what you’re working on. Ask a question, or point to something in the camera."
    }

    func select(_ box: NormalizedBox) {
        guard !isBusy else { return }
        let id = UUID()
        selectionID = id
        Task {
            do {
                let frame = try await camera.snapshot()
                guard selectionID == id else { return }
                selectedFrame = SelectedFrame(frame: frame, box: box)
                camera.point(at: box, frameID: frame.id, label: "Your selection", source: .user)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func clearSelection() {
        selectionID = UUID()
        selectedFrame = nil
        camera.clearHighlight()
    }

    func toggleMicrophone() {
        isMuted.toggle()
        errorMessage = nil
        updateListening()
    }

    func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, !text.isEmpty else { return }
        guard text.count <= 1500 else { errorMessage = "Please shorten your question to 1,500 characters."; return }
        isBusy = true
        pendingQuestion = text
        webInfo = nil
        updateListening()
        speech.stopSpeaking()
        errorMessage = nil
        let id = UUID()
        workID = id
        let attachment = selectedFrame
        let history = messages
        let demoMode = settings.demoMode
        let endpoint = settings.serverURL
        let token = settings.token
        let task = settings.task
        let includeWebInfo = settings.webInfoEnabled
        work = Task {
            defer {
                if workID == id {
                    isBusy = false
                    workID = nil
                    pendingQuestion = nil
                    updateListening()
                }
            }
            do {
                let frame: CapturedFrame
                if let attachment { frame = attachment.frame }
                else { frame = try await camera.snapshot() }
                try Task.checkCancellation()
                let request = AnalysisRequest(frame: frame, question: text, task: task,
                                              history: history, selection: attachment?.box, includeWebInfo: includeWebInfo)
                let response: AnalysisResponse
                if demoMode { response = try await client.demo(request) }
                else { response = try await client.analyze(request, endpoint: endpoint, token: token) }
                try Task.checkCancellation()
                guard workID == id else { return }
                messages.append(ChatMessage(role: .user, content: text))
                messages.append(ChatMessage(role: .assistant, content: response.answer))
                pendingQuestion = nil
                webInfo = response.webInfo
                if messages.count > 40 { messages.removeFirst(messages.count - 40) }
                question = ""
                clearSelection()
                lastReplyWasDemo = response.mode == "mock"
                if let target = response.target, !response.needsClearerView {
                    camera.point(at: target.box, frameID: frame.id, label: target.label, source: .assistant)
                }
                if settings.spokenReplies { speech.speak(response.answer) }
            } catch is CancellationError {
                // Explicit cancellation/backgrounding should not surface as a failed task.
            } catch {
                guard workID == id else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancel() {
        workID = nil
        work?.cancel()
        work = nil
        isBusy = false
        pendingQuestion = nil
        speech.setListening(false)
        speech.stopSpeaking()
        updateListening()
    }

    func pause() {
        isActive = false
        cancel()
        clearSelection()
        camera.stop()
    }

    func resetConversation() {
        cancel()
        clearSelection()
        question = ""
        messages.removeAll()
        webInfo = nil
        errorMessage = nil
    }
}
