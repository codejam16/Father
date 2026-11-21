import Foundation

struct AnalysisClient {
    func analyze(_ input: AnalysisRequest, endpoint: String, token: String) async throws -> AnalysisResponse {
        guard let base = URL(string: endpoint), ["http", "https"].contains(base.scheme ?? ""), base.host != nil,
              base.user == nil, base.password == nil else {
            throw TaskLensError.message("Enter a valid backend URL in Connection settings.")
        }
        var request = URLRequest(url: base.appendingPathComponent("analyze"))
        request.httpMethod = "POST"
        request.timeoutInterval = input.includeWebInfo ? 45 : 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(input)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw TaskLensError.message("The backend did not respond.") }
        guard response.statusCode == 200 else {
            struct ErrorEnvelope: Decodable {
                struct Detail: Decodable { let message: String }
                let error: Detail
            }
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data).error.message)
                ?? "Backend error (\(response.statusCode)). Check Connection settings."
            throw TaskLensError.message(message)
        }
        let result = try JSONDecoder().decode(AnalysisResponse.self, from: data)
        guard result.frameId == input.frameId, !result.answer.isEmpty,
              ["mock", "gemini"].contains(result.mode) else {
            throw TaskLensError.message("The response did not match the requested camera view.")
        }
        return result
    }

    func demo(_ input: AnalysisRequest) async throws -> AnalysisResponse {
        try await Task.sleep(for: .milliseconds(450))
        return AnalysisResponse(
            frameId: input.frameId, mode: "mock",
            answer: input.selection == nil
                ? "Demo response: show me what you’re working on. Select an area to try pointing, or connect Gemini in Settings for real visual help."
                : "Demo response: I’ve marked the region you selected. Connect Gemini to identify it and answer your question.",
            target: input.selection.map { Target(label: "Your selection — demo", box: $0) },
            needsClearerView: false
        )
    }
}
