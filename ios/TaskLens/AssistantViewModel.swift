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
    private let client = AnalysisClient()
    private var work: Task<Void, Never>?
    private var workID: UUID?
    private var selectionID = UUID()

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

    func toggleMicrophone() async {
        errorMessage = nil
        if speech.isRecording {
            let text = await speech.finishRecording()
            if !text.isEmpty { question = text }
        } else {
            do { try await speech.startRecording() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, !speech.isRecording, !text.isEmpty else { return }
        guard text.count <= 1500 else { errorMessage = "Please shorten your question to 1,500 characters."; return }
        speech.stopSpeaking()
        errorMessage = nil
        isBusy = true
        let id = UUID()
        workID = id
        let attachment = selectedFrame
        let history = messages
        let demoMode = settings.demoMode
        let endpoint = settings.serverURL
        let token = settings.token
        let task = settings.task
        work = Task {
            defer { if workID == id { isBusy = false; workID = nil } }
            do {
                let frame: CapturedFrame
                if let attachment { frame = attachment.frame }
                else { frame = try await camera.snapshot() }
                try Task.checkCancellation()
                let request = AnalysisRequest(frame: frame, question: text, task: task,
                                              history: history, selection: attachment?.box)
                let response: AnalysisResponse
                if demoMode { response = try await client.demo(request) }
                else { response = try await client.analyze(request, endpoint: endpoint, token: token) }
                try Task.checkCancellation()
                guard workID == id else { return }
                messages.append(ChatMessage(role: .user, content: text))
                messages.append(ChatMessage(role: .assistant, content: response.answer))
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
        speech.cancelRecording()
        speech.stopSpeaking()
    }

    func pause() {
        cancel()
        clearSelection()
        camera.stop()
    }

    func resetConversation() {
        cancel()
        clearSelection()
        question = ""
        messages.removeAll()
        errorMessage = nil
    }
}
