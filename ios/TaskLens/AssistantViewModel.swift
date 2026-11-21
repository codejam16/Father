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
    @Published private(set) var taskMemory = TaskMemory.empty
    @Published private(set) var sources: [ResearchSource] = []
    @Published private(set) var researchReports: [ResearchReport] = []
    @Published private(set) var citedSourceIds: [String] = []
    @Published private(set) var researchReviewID: UUID?
    private var sessionID = UUID().uuidString.lowercased()
    private var sessionTask: String?
    private var confirmedStepIDs = Set<String>()
    @Published private(set) var pendingQuestion: String?
    @Published private(set) var webInfo: WebInfo?
    /// Briefly true after a reply arrives, so the status icon can show an answer even when spoken replies are off.
    @Published private(set) var justAnswered = false
    private var answerFlash: Task<Void, Never>?
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

    func setVoiceSuspended(_ suspended: Bool, stopPlayback: Bool = true) {
        voiceSuspended = suspended
        updateListening()
        if suspended && stopPlayback { speech.stopSpeaking() }
    }

    private func updateListening() {
        speech.setListening(isActive && !isMuted && !voiceSuspended && !isBusy)
    }

    var lastAnswer: String {
        messages.last(where: { $0.role == .assistant })?.content
            ?? "Show me what you’re working on. Ask a question, or point to something in the camera."
    }

    func select(_ box: NormalizedBox) {
        guard !isBusy, settings.selectionEnabled else { return }
        let id = UUID()
        selectionID = id
        Task {
            do {
                let frame = try await camera.snapshot()
                guard selectionID == id, settings.selectionEnabled else { return }
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

    func flipCamera() {
        guard !isBusy else { return }
        clearSelection()
        camera.flipCamera()
    }

    private func showAnswered() {
        answerFlash?.cancel()
        justAnswered = true
        answerFlash = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.justAnswered = false
        }
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
        if sessionTask != settings.task {
            clearTaskContext()
            sessionTask = settings.task
        }
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
        let researchEnabled = true
        let sessionID = self.sessionID
        let confirmations = Array(confirmedStepIDs)
        // Visibility is local: always fetch evidence and cards, even while hidden.
        let includeWebInfo = true
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
                var frame: CapturedFrame
                if let attachment { frame = attachment.frame }
                else { frame = try await camera.snapshot() }
                var continuationID: String?
                var currentSelection = attachment?.box
                var response: AnalysisResponse
                var usedResearch = false
                var refreshes = 0
                while true {
                    try Task.checkCancellation()
                    let request = AnalysisRequest(frame: frame, question: text, task: task,
                                                  history: history, selection: currentSelection,
                                                  sessionId: sessionID, continuationId: continuationID,
                                                  researchEnabled: researchEnabled, confirmedStepIds: confirmations, includeWebInfo: includeWebInfo,
                                                  searchEveryQuestion: true)
                    if demoMode { response = try await client.demo(request) }
                    else { response = try await client.analyze(request, endpoint: endpoint, token: token) }
                    try Task.checkCancellation()
                    guard workID == id else { return }
                    if let memory = response.taskMemory { taskMemory = memory }
                    if let responseSources = response.sources { sources = responseSources }
                    if let reports = response.researchReports { researchReports = reports }
                    guard response.action == "refresh_camera" else { break }
                    guard refreshes < 2, let nextID = response.continuationId else {
                        throw TaskLensError.message("Research reached its limit. Please ask a more specific follow-up.")
                    }
                    refreshes += 1
                    usedResearch = true
                    continuationID = nextID
                    // Research may outlive the camera's frame ring. Never draw its old coordinates.
                    frame = try await camera.snapshot()
                    currentSelection = nil
                }
                confirmedStepIDs.subtract(confirmations)
                citedSourceIds = response.sourceIds ?? []
                messages.append(ChatMessage(role: .user, content: text))
                messages.append(ChatMessage(role: .assistant, content: response.answer))
                pendingQuestion = nil
                webInfo = response.webInfo
                if messages.count > 40 { messages.removeFirst(messages.count - 40) }
                question = ""
                clearSelection()
                lastReplyWasDemo = response.mode == "mock"
                showAnswered()
                if let target = response.target, !response.needsClearerView {
                    camera.point(at: target.box, frameID: frame.id, label: target.label, source: .assistant)
                }
                if settings.spokenReplies { speech.speak(response.answer) }
                if !demoMode && (usedResearch || !citedSourceIds.isEmpty) { researchReviewID = UUID() }
            } catch is CancellationError {
                // Explicit cancellation/backgrounding should not surface as a failed task.
            } catch {
                guard workID == id else { return }
                // Unexpected decoding/system errors must not become a spoken stack of technical details.
                let message = (error as? TaskLensError)?.localizedDescription
                    ?? "I couldn't finish that request. Please try again."
                errorMessage = message
                if settings.spokenReplies { speech.speak(message) }
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
        clearTaskContext()
        sessionTask = settings.task
        webInfo = nil
        errorMessage = nil
    }

    func confirmStep(_ id: String) {
        guard let index = taskMemory.plan.firstIndex(where: { $0.id == id }) else { return }
        taskMemory.plan[index].completed = true
        confirmedStepIDs.insert(id)
    }

    private func clearTaskContext() {
        sessionID = UUID().uuidString.lowercased()
        messages.removeAll()
        pendingQuestion = nil
        webInfo = nil
        taskMemory = .empty
        sources = []
        researchReports = []
        citedSourceIds = []
        researchReviewID = nil
        confirmedStepIDs.removeAll()
    }
}
