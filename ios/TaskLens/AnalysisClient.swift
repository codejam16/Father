import Foundation

/// Backend error body. Declared at file scope: Swift does not allow types inside generic functions.
private struct ErrorEnvelope: Decodable {
    struct Detail: Decodable { let userMessage: String? }
    let error: Detail
}

struct AnalysisClient {
    func analyze(_ input: AnalysisRequest, endpoint: String, token: String) async throws -> AnalysisResponse {
        let data = try await post(input, path: "analyze", endpoint: endpoint, token: token)
        let result = try JSONDecoder().decode(AnalysisResponse.self, from: data)
        guard result.frameId == input.frameId, !result.answer.isEmpty,
              ["mock", "gemini"].contains(result.mode) else {
            throw TaskLensError.message("The response did not match the requested camera view.")
        }
        return result
    }

    func check(_ input: StepCheckRequest, endpoint: String, token: String) async throws -> StepCheckResponse {
        let data = try await post(input, path: "check", endpoint: endpoint, token: token)
        let result = try JSONDecoder().decode(StepCheckResponse.self, from: data)
        guard result.stepId == input.stepId, ["mock", "gemini"].contains(result.mode) else {
            throw TaskLensError.message("The step check did not match the current step.")
        }
        return result
    }

    private func post<Body: Encodable>(_ body: Body, path: String, endpoint: String, token: String) async throws -> Data {
        guard let base = URL(string: endpoint), ["http", "https"].contains(base.scheme ?? ""), base.host != nil,
              base.user == nil, base.password == nil else {
            throw TaskLensError.message("Enter a valid backend URL in Connection settings.")
        }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        // Backend allows 95s for a decision, research and a final answer.
        request.timeoutInterval = 105
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(body)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw TaskLensError.message("That took too long. Please try again.") }
            throw TaskLensError.message("I can't reach the server. Please check your connection and try again.")
        }
        guard let response = response as? HTTPURLResponse else { throw TaskLensError.message("The backend did not respond.") }
        guard response.statusCode == 200 else {
            // Older servers may return technical text in `message`; never read it aloud.
            let friendly = try? JSONDecoder().decode(ErrorEnvelope.self, from: data).error.userMessage
            let fallback: String
            switch response.statusCode {
            case 401, 403: fallback = "I couldn't connect. Please check the app's connection settings."
            case 429: fallback = "The AI service is limiting requests right now. Please try again later."
            case 504: fallback = "That took too long. Please try again."
            default: fallback = "I couldn't get an answer this time. Please try again."
            }
            let message = friendly ?? fallback
            throw TaskLensError.message(message)
        }
        return data
    }

    func demo(_ input: AnalysisRequest, hasPlan: Bool = false) async throws -> AnalysisResponse {
        try await Task.sleep(for: .milliseconds(450))
        if input.guided && !hasPlan && Self.isHowTo(input.question) {
            // Practice steps so guided mode can be tried without AI requests. Identifies nothing.
            let plan: [TaskStep] = [
                TaskStep(id: "demo-1", text: "Show me the object you want to fix.", completed: false),
                TaskStep(id: "demo-2", text: "Turn the screw counterclockwise to loosen it.", completed: false),
                TaskStep(id: "demo-3", text: "Lift the cover off and set it aside.", completed: false),
            ]
            var response = AnalysisResponse(
                frameId: input.frameId, mode: "mock",
                answer: "Demo guided steps: I’ll take you through three practice steps and watch as you go. Step 1: show me the object you want to fix.",
                target: nil, needsClearerView: false)
            response.taskMemory = TaskMemory(goal: "Demo repair", facts: [], openQuestions: [], plan: plan)
            return response
        }
        return AnalysisResponse(
            frameId: input.frameId, mode: "mock",
            answer: input.selection == nil
                ? "Demo response: show me what you’re working on. Select an area to try pointing, or connect Gemini in Settings for real visual help."
                : "Demo response: I’ve marked the region you selected. Connect Gemini to identify it and answer your question.",
            target: input.selection.map { Target(label: "Your selection — demo", box: $0) },
            needsClearerView: false
        )
    }

    /// Demo only: a rough "how do I…" detector. The real assistant decides this itself.
    static func isHowTo(_ question: String) -> Bool {
        let text = question.lowercased()
        if text.contains("step by step") || text.contains("walk me through") { return true }
        let words = Set(text.split(whereSeparator: { !$0.isLetter }).map(String.init))
        let actions: Set<String> = ["fix", "repair", "install", "replace", "assemble", "change", "open", "remove",
                                    "clean", "build", "set", "setup", "connect", "unscrew", "tighten", "do"]
        return words.contains("how") && !words.isDisjoint(with: actions)
    }

    /// Demo step checks: the second automatic check of a step, or saying "done", counts as done.
    func demoCheck(_ input: StepCheckRequest, attempt: Int) async throws -> StepCheckResponse {
        try await Task.sleep(for: .milliseconds(400))
        let done = input.userSaysDone || attempt >= 2
        return StepCheckResponse(stepId: input.stepId, mode: "mock", status: done ? "done" : "in_progress",
                                 feedback: done ? "Demo: that counts as done." : "")
    }
}
