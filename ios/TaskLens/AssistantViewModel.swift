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
    /// Guided steps: the camera is being watched for the current step / a step check is in flight.
    @Published private(set) var isWatching = false
    @Published private(set) var isChecking = false
    /// Latest correction or hint for the current step, shown on the step card.
    @Published private(set) var guidedNotice: String?
    private var checkTask: Task<Void, Never>?
    private var checkID: UUID?
    private var watchedStepID: String?
    private var lastCheckAt = Date.distantPast
    private var checksThisStep = 0
    private var unclearCount = 0
    /// The step whose part is currently highlighted (or was located for it).
    private var highlightedStepID: String?
    private var autoCheckRetry: Task<Void, Never>?
    private var isActive = false
    private var voiceSuspended = false
    private let client = AnalysisClient()
    private var work: Task<Void, Never>?
    private var workID: UUID?
    private var selectionID = UUID()

    init() {
        speech.onUtterance = { [weak self] text in
            guard let self, self.isActive, !self.isMuted, !self.voiceSuspended, !self.isBusy else { return }
            if self.speech.lastUtteranceInterrupted, Self.isOnlyInterruption(text) { return }
            if self.handleStepCommand(text) { return }
            self.question = text
            self.send()
        }
        camera.onSettled = { [weak self] in
            Task { @MainActor in self?.autoCheck() }
        }
        speech.onFailure = { [weak self] message in
            self?.isMuted = true
            self?.errorMessage = message
        }
    }

    func resume() async {
        isActive = true
        speech.refreshVoices()
        await camera.start()
        updateListening()
        updateWatching()
    }

    func setVoiceSuspended(_ suspended: Bool, stopPlayback: Bool = true) {
        voiceSuspended = suspended
        updateListening()
        if suspended && stopPlayback { speech.stopSpeaking() }
    }

    private func updateListening() {
        // Muted means the microphone stays off, including while replies play.
        speech.allowsInterruption = settings.interruptionsEnabled && isActive && !isMuted && !voiceSuspended
        speech.setListening(isActive && !isMuted && !voiceSuspended && !isBusy)
    }

    /// "Stop" / "wait" said over a reply only meant "be quiet": don't send it as a question.
    private static func isOnlyInterruption(_ text: String) -> Bool {
        let phrase = text.lowercased()
            .filter { $0.isLetter || $0 == " " }
            .split(separator: " ")
            .joined(separator: " ")
        let phrases: Set<String> = ["stop", "wait", "hold on", "pause", "quiet", "shush", "shut up", "stop talking",
                                    "ok stop", "okay stop", "enough", "ok", "okay", "got it", "thanks", "thank you",
                                    "ok thanks", "okay thanks", "wait wait", "stop stop", "hang on", "one sec", "one second"]
        return phrases.contains(phrase)
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
        cancelCheck()
        updateWatching()
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
        let guided = settings.guidedMode
        let hasPlan = !taskMemory.plan.isEmpty
        work = Task {
            defer {
                if workID == id {
                    isBusy = false
                    workID = nil
                    pendingQuestion = nil
                    updateListening()
                    updateWatching()
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
                                                  searchEveryQuestion: true, guided: guided)
                    if demoMode { response = try await client.demo(request, hasPlan: hasPlan) }
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
                    // During guided steps the highlight marks where to act, so keep it up longer.
                    let guiding = settings.guidedMode && response.taskMemory?.plan.contains(where: { !$0.completed }) == true
                    camera.point(at: target.box, frameID: frame.id, label: target.label, source: .assistant,
                                 duration: guiding ? 8 : 5)
                    if guiding { highlightedStepID = currentStep?.id }
                }
                if settings.spokenReplies { speech.speak(response.answer, voiceIdentifier: settings.voiceIdentifier) }
                if !demoMode && (usedResearch || !citedSourceIds.isEmpty) { researchReviewID = UUID() }
            } catch is CancellationError {
                // Explicit cancellation/backgrounding should not surface as a failed task.
            } catch {
                guard workID == id else { return }
                // Unexpected decoding/system errors must not become a spoken stack of technical details.
                let message = (error as? TaskLensError)?.localizedDescription
                    ?? "I couldn't finish that request. Please try again."
                errorMessage = message
                if settings.spokenReplies { speech.speak(message, voiceIdentifier: settings.voiceIdentifier) }
            }
        }
    }

    func cancel() {
        workID = nil
        work?.cancel()
        work = nil
        isBusy = false
        pendingQuestion = nil
        cancelCheck()
        speech.setListening(false)
        speech.stopSpeaking()
        updateListening()
        updateWatching()
    }

    func pause() {
        isActive = false
        cancel()
        updateWatching()
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
        updateWatching()
    }

    // MARK: Guided steps

    /// The first unfinished step while guided mode is on.
    var currentStep: TaskStep? {
        guard settings.guidedMode else { return nil }
        return taskMemory.plan.first(where: { !$0.completed })
    }

    /// 1-based position of the current step in the plan.
    var stepNumber: Int? {
        guard let step = currentStep, let index = taskMemory.plan.firstIndex(where: { $0.id == step.id }) else { return nil }
        return index + 1
    }

    /// Keeps the on-phone watcher in sync with the current step. Safe to call often.
    func updateWatching() {
        let step = currentStep
        let active = isActive && !isBusy && step != nil
        if step?.id != watchedStepID {
            watchedStepID = step?.id
            checksThisStep = 0
            unclearCount = 0
            guidedNotice = nil
            camera.setWatching(active, resetReference: true)
            if active, let step, highlightedStepID != step.id { scheduleLocate(step.id) }
        } else if active != isWatching {
            camera.setWatching(active, resetReference: false)
        }
        isWatching = active
        if step == nil { cancelCheck() }
    }

    func markCurrentStepDone() { runCheck(userSaysDone: true) }

    func skipCurrentStep() {
        guard let step = currentStep, !isBusy else { return }
        cancelCheck()
        advance(past: step, lead: "Okay, skipping that one.")
    }

    /// Stop following the current plan; the assistant goes back to open conversation.
    func endSteps() {
        cancelCheck()
        let remaining = taskMemory.plan.filter { !$0.completed }.map(\.id)
        guard !remaining.isEmpty else { return }
        for id in remaining { confirmStep(id) }
        say("Okay, I've stopped the steps. Ask me anything.")
    }

    /// Highlight where the current step happens (button or "show me").
    func showCurrentStepPart() {
        guard currentStep != nil, !isBusy else { return }
        runCheck(userSaysDone: false)
    }

    private func nextStepID(after step: TaskStep) -> String? {
        taskMemory.plan.drop(while: { $0.id != step.id }).dropFirst().first(where: { !$0.completed })?.id
    }

    /// A fresh step has no highlight yet: look for its part shortly after it is announced.
    private func scheduleLocate(_ stepID: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, self.currentStep?.id == stepID, self.highlightedStepID != stepID,
                  self.isWatching, !self.isChecking, !self.isBusy else { return }
            self.runCheck(userSaysDone: false)
        }
    }

    func repeatCurrentStep() {
        guard let step = currentStep, let number = stepNumber else { return }
        say("Step \(number): \(step.text)")
    }

    /// Short spoken commands while a step is active. Anything else is a normal question.
    private func handleStepCommand(_ text: String) -> Bool {
        guard currentStep != nil else { return false }
        let phrase = text.lowercased()
            .filter { $0.isLetter || $0 == " " }
            .split(separator: " ")
            .joined(separator: " ")
        let done: Set<String> = ["done", "im done", "i am done", "its done", "it is done", "finished", "im finished",
                                 "i did it", "next", "next step", "ok done", "okay done", "all done", "done now", "ok next", "okay next",
                                 "ok", "okay", "alright", "all right", "yes", "yep", "yeah", "got it", "did it", "done that",
                                 "i did that", "ok i did it", "okay i did it", "whats next", "what next", "next one", "and now",
                                 "then what", "ok whats next", "okay whats next", "ok what now", "okay what now"]
        let skip: Set<String> = ["skip", "skip it", "skip this", "skip that", "skip step", "skip this step"]
        let stop: Set<String> = ["stop", "stop steps", "stop the steps", "stop guiding", "end steps", "cancel steps",
                                 "stop guidance", "end guidance", "cancel", "never mind", "nevermind"]
        if stop.contains(phrase) { endSteps(); return true }
        let again: Set<String> = ["repeat", "repeat that", "repeat the step", "say again", "say that again", "again",
                                  "what was the step", "whats the step", "what step", "what do i do", "what now"]
        if done.contains(phrase) { markCurrentStepDone(); return true }
        if skip.contains(phrase) { skipCurrentStep(); return true }
        if again.contains(phrase) { repeatCurrentStep(); return true }
        let where_: Set<String> = ["where", "where is it", "where is that", "show me", "show me where", "which one",
                                   "which one is it", "highlight it", "point to it", "where do i do that"]
        if where_.contains(phrase) { showCurrentStepPart(); return true }
        return false
    }

    private func cancelCheck() {
        checkID = nil
        checkTask?.cancel()
        checkTask = nil
        isChecking = false
    }

    /// The camera saw the user work and then pause: check the step, at most every 8 seconds.
    private func autoCheck() {
        guard isWatching, checksThisStep < 15 else { return }
        if canAutoCheckNow {
            runCheck(userSaysDone: false)
            return
        }
        // A change seen while speaking or just after a check is retried shortly, not dropped.
        guard autoCheckRetry == nil else { return }
        autoCheckRetry = Task { [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.isWatching else { break }
                if self.canAutoCheckNow {
                    self.autoCheckRetry = nil
                    self.runCheck(userSaysDone: false)
                    return
                }
            }
            self?.autoCheckRetry = nil
        }
    }

    private var canAutoCheckNow: Bool {
        !isChecking && !isBusy && !speech.isSpeaking && Date().timeIntervalSince(lastCheckAt) >= 6
    }

    private func runCheck(userSaysDone: Bool) {
        guard let step = currentStep, isActive, !isBusy else { return }
        if isChecking && !userSaysDone { return }
        cancelCheck()
        isChecking = true
        lastCheckAt = Date()
        checksThisStep += 1
        let id = UUID()
        checkID = id
        let attempt = checksThisStep
        let demoMode = settings.demoMode
        let endpoint = settings.serverURL
        let token = settings.token
        let task = settings.task
        let goal = taskMemory.goal
        let next = taskMemory.plan.drop(while: { $0.id != step.id }).dropFirst().first(where: { !$0.completed })
        checkTask = Task {
            defer {
                if checkID == id {
                    isChecking = false
                    checkID = nil
                }
            }
            do {
                let frames = try await camera.recentFrames(count: 3, spacing: 1.5)
                let request = StepCheckRequest(step: step, next: next, goal: goal, task: task, frames: frames, userSaysDone: userSaysDone)
                let result: StepCheckResponse
                if demoMode {
                    result = try await client.demoCheck(request, attempt: attempt)
                } else {
                    result = try await client.check(request, endpoint: endpoint, token: token)
                }
                try Task.checkCancellation()
                guard checkID == id, currentStep?.id == step.id, let lastFrame = frames.last else { return }
                handleCheck(result, step: step, frameID: lastFrame.id, userSaysDone: userSaysDone)
            } catch is CancellationError {
                // A question or pause replaced this check.
            } catch {
                // Background checks fail quietly; only a requested check reports a problem.
                guard checkID == id, userSaysDone else { return }
                let message = (error as? TaskLensError)?.localizedDescription ?? "I couldn't check that step. Please try again."
                errorMessage = message
                say(message)
            }
        }
    }

    private func handleCheck(_ result: StepCheckResponse, step: TaskStep, frameID: String, userSaysDone: Bool) {
        if let target = result.target {
            camera.point(at: target.box, frameID: frameID, label: target.label, source: .assistant, duration: 8)
            // A "done" check boxes the NEXT step's part; any other result boxes this step's part.
            highlightedStepID = result.status == "done" ? nextStepID(after: step) : step.id
        }
        switch result.status {
        case "done":
            advance(past: step, lead: result.feedback)
        case "problem":
            unclearCount = 0
            guidedNotice = result.feedback
            say(result.feedback)
        case "unclear":
            unclearCount += 1
            if userSaysDone {
                advance(past: step, lead: "I couldn't see it clearly, so I'll go with what you said.")
            } else if unclearCount == 2 {
                guidedNotice = result.feedback
                say(result.feedback)
            }
        default:
            if userSaysDone {
                let text = result.feedback.isEmpty
                    ? "It doesn't look finished yet. Keep going, or say skip to move on."
                    : result.feedback
                guidedNotice = text
                say(text)
            }
        }
    }

    private func advance(past step: TaskStep, lead: String) {
        confirmStep(step.id)
        let trimmed = lead.trimmingCharacters(in: .whitespacesAndNewlines)
        let opening = trimmed.isEmpty ? "Done." : trimmed
        if let next = currentStep, let number = stepNumber {
            say("\(opening) Step \(number): \(next.text)")
        } else {
            say("\(opening) That was the last step. Nice work!")
        }
    }

    private func say(_ text: String) {
        showAnswered()
        if settings.spokenReplies { speech.speak(text, voiceIdentifier: settings.voiceIdentifier) }
    }

    private func clearTaskContext() {
        sessionID = UUID().uuidString.lowercased()
        messages.removeAll()
        pendingQuestion = nil
        webInfo = nil
        taskMemory = .empty
        highlightedStepID = nil
        sources = []
        researchReports = []
        citedSourceIds = []
        researchReviewID = nil
        confirmedStepIDs.removeAll()
        updateWatching()
    }
}
