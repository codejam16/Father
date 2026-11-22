import Combine
import Foundation
import CoreGraphics
import UIKit

/// A frozen photo with step-by-step drawings that explain it (diagrams, circuits, charts).
struct Walkthrough: Identifiable {
    let id = UUID()
    let image: UIImage
    /// The exact JPEG the AI looked at, saved as-is so a reopened explanation uses the very same pixels.
    let photo: Data?
    let beats: [Annotation]
    let answer: String
    /// The spoken explanation: each beat's line, in order.
    let narration: String
    /// Where each beat's line starts in `narration`, as a fraction (0…1).
    let beatStarts: [Double]
    /// Opened again from the saved list (not just answered): browse it, don't auto-play.
    let reopened: Bool

    init(image: UIImage, photo: Data? = nil, beats: [Annotation], answer: String, reopened: Bool = false) {
        self.reopened = reopened
        self.image = image
        self.photo = photo
        self.beats = beats
        self.answer = answer
        let lines = beats.map { beat -> String in
            let line = beat.say?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return line.isEmpty ? beat.caption : line
        }
        let text = lines.joined(separator: " ")
        narration = text
        var starts: [Double] = []
        var offset = 0
        for line in lines {
            starts.append(text.isEmpty ? 0 : Double(offset) / Double(text.count))
            offset += line.count + 1
        }
        beatStarts = starts
    }

    /// The beat being spoken at `progress` through the narration.
    func beat(at progress: Double) -> Int {
        beatStarts.lastIndex(where: { $0 <= progress + 0.001 }) ?? 0
    }
}

/// A walkthrough kept on the phone: the photo plus every step, to open again later.
struct SavedWalkthrough: Codable, Identifiable {
    let id: UUID
    let date: Date
    let title: String
    let answer: String
    let beats: [Annotation]
}

/// Saved walkthroughs in Application Support/Walkthroughs: an index file plus one JPEG each (newest 50).
@MainActor
final class WalkthroughLibrary: ObservableObject {
    @Published private(set) var items: [SavedWalkthrough] = []
    private let folder: URL
    private let limit = 50
    private var thumbnails: [UUID: UIImage] = [:]

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        folder = base.appendingPathComponent("Walkthroughs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([SavedWalkthrough].self, from: data) {
            items = saved
        }
    }

    private var indexURL: URL { folder.appendingPathComponent("index.json") }
    private func imageURL(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).jpg") }

    func save(_ walkthrough: Walkthrough) {
        guard let jpeg = walkthrough.photo ?? walkthrough.image.jpegData(compressionQuality: 0.9) else { return }
        let item = SavedWalkthrough(id: walkthrough.id, date: Date(), title: Self.title(for: walkthrough),
                                    answer: walkthrough.answer, beats: walkthrough.beats)
        do { try jpeg.write(to: imageURL(item.id), options: .atomic) } catch { return }
        items.insert(item, at: 0)
        while items.count > limit {
            let oldest = items.removeLast()
            try? FileManager.default.removeItem(at: imageURL(oldest.id))
        }
        persist()
    }

    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        thumbnails[id] = nil
        try? FileManager.default.removeItem(at: imageURL(id))
        persist()
    }

    func image(for id: UUID) -> UIImage? { UIImage(contentsOfFile: imageURL(id).path) }

    func thumbnail(for id: UUID) -> UIImage? {
        if let cached = thumbnails[id] { return cached }
        guard let image = image(for: id) else { return nil }
        let height = 160 * image.size.height / max(image.size.width, 1)
        let small = image.preparingThumbnail(of: CGSize(width: 160, height: height)) ?? image
        thumbnails[id] = small
        return small
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private static func title(for walkthrough: Walkthrough) -> String {
        let firstSentence = walkthrough.answer.split(whereSeparator: { ".!?".contains($0) }).first.map(String.init)
        let title = firstSentence ?? walkthrough.beats.first?.caption ?? "Explanation"
        return String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
    }
}

@MainActor
final class AssistantViewModel: ObservableObject {
    let camera = CameraService()
    /// Every walkthrough is saved here, to be opened again from the camera screen.
    let library = WalkthroughLibrary()
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
    private var voiceFetch: Task<Void, Never>?
    /// Shown over the camera while a diagram is being explained.
    @Published private(set) var walkthrough: Walkthrough? {
        didSet { if oldValue?.reopened != walkthrough?.reopened { updateListening() } }
    }
    /// A saved explanation is open: it stays until the user taps X, so nothing heard closes it.
    private var isViewingSaved: Bool { walkthrough?.reopened == true }
    /// "What you'll need" for the current guided task.
    @Published private(set) var tools: [ToolItem] = []
    @Published private(set) var isScanningTools = false
    @Published var toolsExpanded = true
    private var isActive = false
    private var voiceSuspended = false
    private let client = AnalysisClient()
    private var work: Task<Void, Never>?
    private var workID: UUID?
    private var selectionID = UUID()
    private var webPreferenceObserver: AnyCancellable?
    private var workMayResearch = false

    init() {
        speech.onUtterance = { [weak self] text in
            guard let self, self.isActive, !self.isMuted, !self.voiceSuspended, !self.isBusy, !self.isViewingSaved else { return }
            if self.speech.lastUtteranceInterrupted, Self.isOnlyInterruption(text) { return }
            if self.handleStepCommand(text) { return }
            self.question = text
            self.send(pointingSince: self.speech.lastUtteranceStartedAt)
        }
        camera.onSettled = { [weak self] in
            Task { @MainActor in self?.autoCheck() }
        }
        speech.onFailure = { [weak self] message in
            self?.isMuted = true
            self?.errorMessage = message
        }
        webPreferenceObserver = settings.$webInfoEnabled.dropFirst().removeDuplicates().sink { [weak self] enabled in
            guard !enabled else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.settings.webInfoEnabled, self.isBusy, self.workMayResearch else { return }
                self.cancel()
                self.errorMessage = "Web search turned off. Send the question again to continue without searching."
            }
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
        if suspended && stopPlayback { voiceFetch?.cancel(); speech.stopSpeaking() }
    }

    private func updateListening() {
        // Muted means the microphone stays off, including while replies play.
        // While a saved explanation is open the microphone rests, so background talk
        // (or its own replayed voice) can't send a new question and close it.
        speech.allowsInterruption = settings.interruptionsEnabled && isActive && !isMuted && !voiceSuspended && !isViewingSaved
        speech.setListening(isActive && !isMuted && !voiceSuspended && !isBusy && !isViewingSaved)
        // Watch the fingertip only while the user may be talking, so "this… to this" can be matched.
        camera.setPointerTracking(isActive && !isMuted && !voiceSuspended && !isViewingSaved)
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

    /// `pointingSince`: when a spoken question started, so the spots the user pointed at while
    /// saying it ("from this… to this") go with it. Typed questions don't use pointing history.
    func send(pointingSince: Date? = nil) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, !text.isEmpty else { return }
        guard text.count <= 1500 else { errorMessage = "Please shorten your question to 1,500 characters."; return }
        if sessionTask != settings.task {
            clearTaskContext()
            sessionTask = settings.task
        }
        isBusy = true
        walkthrough = nil
        cancelCheck()
        updateWatching()
        pendingQuestion = text
        webInfo = nil
        updateListening()
        voiceFetch?.cancel()
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
        let researchEnabled = settings.webInfoEnabled
        workMayResearch = researchEnabled
        let sessionID = self.sessionID
        let confirmations = Array(confirmedStepIDs)
        // Info enables optional research; visual questions remain camera-only.
        let includeWebInfo = researchEnabled
        let guided = settings.guidedMode
        let hasPlan = !taskMemory.plan.isEmpty
        work = Task {
            defer {
                if workID == id {
                    isBusy = false
                    workID = nil
                    workMayResearch = false
                    pendingQuestion = nil
                    updateListening()
                    updateWatching()
                }
            }
            do {
                var frame: CapturedFrame
                var detail: CapturedDetail?
                if let attachment { frame = attachment.frame }
                else { (frame, detail) = try await camera.snapshotWithDetail() }
                // Only a live view: a picked photo's coordinates wouldn't match the pointing.
                var pointed: [CGPoint] = []
                if attachment == nil, let since = pointingSince { pointed = await camera.pointedSpots(since: since) }
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
                                                  searchEveryQuestion: false, guided: guided, detail: detail,
                                                  pointedAt: continuationID == nil ? pointed : [])
                    detail = nil // Only the first look carries the close-up.
                    if demoMode { response = try await client.demo(request, hasPlan: hasPlan) }
                    else { response = try await client.analyze(request, endpoint: endpoint, token: token) }
                    try Task.checkCancellation()
                    guard workID == id else { return }
                    if let memory = response.taskMemory { taskMemory = memory }
                    if let needed = response.toolsNeeded, !needed.isEmpty {
                        tools = needed
                        toolsExpanded = true
                    }
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
                workMayResearch = false // No more research after the final reply.
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
                if let beats = response.annotations, !beats.isEmpty, let image = UIImage(data: frame.jpeg) {
                    let made = Walkthrough(image: image, photo: frame.jpeg, beats: beats, answer: response.answer)
                    walkthrough = made
                    library.save(made)
                }
                // A walkthrough is narrated beat by beat, so the screen can follow the voice.
                let spokenText = walkthrough?.narration ?? response.answer
                if let target = response.target, !response.needsClearerView {
                    // During guided steps the highlight marks where to act, so keep it up longer.
                    let guiding = settings.guidedMode && response.taskMemory?.plan.contains(where: { !$0.completed }) == true
                    camera.point(at: target.box, frameID: frame.id, label: target.label, source: .assistant,
                                 duration: guiding ? 8 : 5)
                    if guiding { highlightedStepID = currentStep?.id }
                }
                speakReply(spokenText)
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
        workMayResearch = false
        work?.cancel()
        work = nil
        isBusy = false
        pendingQuestion = nil
        cancelCheck()
        speech.setListening(false)
        voiceFetch?.cancel()
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

    func closeWalkthrough() {
        if walkthrough != nil {
            voiceFetch?.cancel()
            speech.stopSpeaking()
        }
        walkthrough = nil
    }

    /// The X: close without keeping it (a reopened saved one is just closed, never deleted).
    func discardWalkthrough() {
        guard let walkthrough else { return }
        if !walkthrough.reopened { library.delete(walkthrough.id) }
        closeWalkthrough()
    }

    /// Open a saved walkthrough again (it starts paused; Replay speaks it).
    func openSaved(_ item: SavedWalkthrough) {
        guard let image = library.image(for: item.id) else { return }
        voiceFetch?.cancel()
        speech.stopSpeaking()
        walkthrough = Walkthrough(image: image, beats: item.beats, answer: item.answer, reopened: true)
    }

    /// Speak the walkthrough again from the start (Replay).
    func replayWalkthrough() {
        guard let walkthrough else { return }
        speakReply(walkthrough.narration)
    }

    /// How far the current spoken reply has got (0…1), for keeping the walkthrough in step.
    var speechProgress: Double? { speech.currentProgress() }

    var voiceDrivesWalkthrough: Bool { settings.spokenReplies }

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
        if step == nil {
            cancelCheck()
            tools = []
        }
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
        let checkTools: Set<String> = ["check my tools", "check tools", "scan my tools", "do i have everything",
                                       "do i have what i need", "have i got everything", "what am i missing"]
        if checkTools.contains(phrase), !tools.isEmpty { scanTools(); return true }
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

    /// The user has an item even if the camera did not see it (or unticks it).
    func toggleTool(_ name: String) {
        guard let index = tools.firstIndex(where: { $0.name == name }) else { return }
        tools[index].visible.toggle()
    }

    /// "Check my tools": one look at the table, ticks what is visible, says what is missing.
    func scanTools() {
        guard !tools.isEmpty, !isScanningTools, !isBusy else { return }
        isScanningTools = true
        let items = tools.map(\.name)
        let goal = taskMemory.goal
        let demoMode = settings.demoMode
        let endpoint = settings.serverURL
        let token = settings.token
        Task {
            defer { isScanningTools = false }
            do {
                let result: ToolsResponse
                if demoMode {
                    result = try await client.demoToolsScan(items)
                } else {
                    let frame = try await camera.snapshot()
                    result = try await client.scanTools(items: items, goal: goal, frame: frame, endpoint: endpoint, token: token)
                }
                // Keep anything the user ticked themselves.
                tools = tools.map { item in
                    let seen = result.items.first(where: { $0.name.caseInsensitiveCompare(item.name) == .orderedSame })?.visible ?? false
                    return ToolItem(name: item.name, visible: item.visible || seen)
                }
                let missing = tools.filter { !$0.visible }.map(\.name)
                say(missing.isEmpty ? "You've got everything. Let's start."
                                    : "Still missing: \(missing.joined(separator: ", ")).")
            } catch {
                let message = (error as? TaskLensError)?.localizedDescription ?? "I couldn't check your tools. Please try again."
                errorMessage = message
            }
        }
    }

    private func advance(past step: TaskStep, lead: String) {
        toolsExpanded = false
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
        speakReply(text)
    }

    /// Speaks with Gemini's natural voice when connected, otherwise (or if it fails or its quota is used up)
    /// with the iPhone voice. One voice request per reply: free-tier voice quotas are very small.
    private func speakReply(_ text: String) {
        guard settings.spokenReplies else { return }
        voiceFetch?.cancel()
        let voiceID = settings.voiceIdentifier
        guard settings.cloudVoiceEnabled, !settings.demoMode else {
            speech.speak(text, voiceIdentifier: voiceID)
            return
        }
        let endpoint = settings.serverURL
        let token = settings.token
        let voice = settings.cloudVoiceName
        let client = self.client
        voiceFetch = Task { [weak self] in
            let audio = (try? await client.speech(text: SpeechService.speakable(text), voice: voice,
                                                  endpoint: endpoint, token: token)) ?? nil
            guard let self, !Task.isCancelled else { return }
            // Don't start talking over the user, or over a new question, while the voice was being made.
            if !self.speech.transcript.isEmpty || self.isBusy { return }
            self.speech.speak(text, voiceIdentifier: voiceID, audio: audio)
        }
    }

    private func clearTaskContext() {
        sessionID = UUID().uuidString.lowercased()
        messages.removeAll()
        pendingQuestion = nil
        webInfo = nil
        taskMemory = .empty
        tools = []
        highlightedStepID = nil
        sources = []
        researchReports = []
        citedSourceIds = []
        researchReviewID = nil
        confirmedStepIDs.removeAll()
        updateWatching()
    }
}
