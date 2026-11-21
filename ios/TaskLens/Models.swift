import Foundation
import CoreGraphics

enum MessageRole: String, Codable { case user, assistant }

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: MessageRole
    let content: String
}

struct HistoryMessage: Codable {
    let role: MessageRole
    let content: String
}

/// Canonical coordinates: [ymin, xmin, ymax, xmax], top-left origin, 0...1000.
/// All images crossing the API boundary are upright JPEGs with this same space.
struct NormalizedBox: Codable, Equatable {
    let values: [Double]

    init?(_ values: [Double]) {
        guard values.count == 4, values.allSatisfy({ $0.isFinite && (0...1000).contains($0) }),
              values[0] < values[2], values[1] < values[3] else { return nil }
        self.values = values
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let values = try container.decode([Double].self)
        guard let box = Self(values) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid target coordinates")
        }
        self = box
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    var unitRect: CGRect {
        CGRect(x: values[1] / 1000, y: values[0] / 1000,
               width: (values[3] - values[1]) / 1000, height: (values[2] - values[0]) / 1000)
    }

    var visionRect: CGRect {
        let rect = unitRect
        return CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }

    static func fromVision(_ rect: CGRect) -> Self? {
        let clamped = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { return nil }
        return Self([(1 - clamped.maxY) * 1000, clamped.minX * 1000,
                     (1 - clamped.minY) * 1000, clamped.maxX * 1000])
    }
}

enum FrameGeometry {
    static func fittedRect(in size: CGSize, aspect: CGFloat) -> CGRect {
        guard size.width > 0, size.height > 0, aspect > 0 else { return .zero }
        let width = min(size.width, size.height * aspect)
        let height = width / aspect
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    static func selection(start: CGPoint, end: CGPoint, viewport: CGSize, aspect: CGFloat) -> NormalizedBox? {
        let image = fittedRect(in: viewport, aspect: aspect)
        guard image.contains(start), image.width > 0 else { return nil }
        let x1 = min(max(start.x, image.minX), image.maxX)
        let y1 = min(max(start.y, image.minY), image.maxY)
        let x2 = min(max(end.x, image.minX), image.maxX)
        let y2 = min(max(end.y, image.minY), image.maxY)
        var rect = CGRect(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
        if rect.width < 12 && rect.height < 12 {
            // A tap selects a region, not a semantically detected object.
            rect = CGRect(x: x1 - image.width * 0.08, y: y1 - image.height * 0.08,
                          width: image.width * 0.16, height: image.height * 0.16)
        }
        rect = rect.intersection(image)
        return NormalizedBox([
            Double((rect.minY - image.minY) / image.height * 1000),
            Double((rect.minX - image.minX) / image.width * 1000),
            Double((rect.maxY - image.minY) / image.height * 1000),
            Double((rect.maxX - image.minX) / image.width * 1000)
        ])
    }
}

struct CapturedFrame {
    let id: String
    let capturedAt: Date
    let jpeg: Data
    let width: Int
    let height: Int
}

struct SelectedFrame {
    let frame: CapturedFrame
    let box: NormalizedBox
}

struct ImagePayload: Encodable {
    let base64: String
    let mimeType = "image/jpeg"
    let width: Int
    let height: Int
}

struct TaskStep: Codable, Identifiable {
    let id: String
    let text: String
    var completed: Bool
}

struct TaskMemory: Codable {
    var goal: String
    var facts: [String]
    var openQuestions: [String]
    var plan: [TaskStep]
    static var empty: Self { Self(goal: "", facts: [], openQuestions: [], plan: []) }
}

struct ResearchSource: Decodable, Identifiable {
    let id: String
    let title: String
    let url: String
}

struct ResearchSupport: Decodable {
    let text: String
    let sourceIds: [String]
}

struct ResearchReport: Decodable {
    let kind: String
    let text: String
    let supports: [ResearchSupport]
    let searchSuggestionsHTML: String?
}

struct AnalysisRequest: Encodable {
    let frameId: String
    let capturedAt: String
    let question: String
    let task: String
    let image: ImagePayload
    let history: [HistoryMessage]
    let selection: NormalizedBox?
    let sessionId: String?
    let continuationId: String?
    let researchEnabled: Bool
    let confirmedStepIds: [String]
    let includeWebInfo: Bool

    init(frame: CapturedFrame, question: String, task: String, history: [ChatMessage], selection: NormalizedBox?,
         sessionId: String? = nil, continuationId: String? = nil,
         researchEnabled: Bool = true, confirmedStepIds: [String] = [], includeWebInfo: Bool = false) {
        self.frameId = frame.id
        self.capturedAt = ISO8601DateFormatter().string(from: frame.capturedAt)
        self.question = question
        self.task = String(task.prefix(4000))
        self.image = ImagePayload(base64: frame.jpeg.base64EncodedString(), width: frame.width, height: frame.height)
        self.history = history.suffix(8).map { HistoryMessage(role: $0.role, content: String($0.content.prefix(2000))) }
        self.selection = selection
        self.sessionId = sessionId
        self.continuationId = continuationId
        self.researchEnabled = researchEnabled
        self.confirmedStepIds = confirmedStepIds
        self.includeWebInfo = includeWebInfo
    }
}

struct Target: Codable {
    let label: String
    let box: NormalizedBox
}

struct AnalysisResponse: Decodable {
    let frameId: String
    let mode: String
    let answer: String
    let target: Target?
    let needsClearerView: Bool
    var action: String? = nil
    var continuationId: String? = nil
    var taskMemory: TaskMemory? = nil
    var sources: [ResearchSource]? = nil
    var researchReports: [ResearchReport]? = nil
    var sourceIds: [String]? = nil
    var webInfo: WebInfo? = nil
}

struct WebSource: Decodable, Identifiable {
    let title: String
    let url: URL
    var id: String { url.absoluteString }
}

struct WebInfo: Decodable {
    let summary: String?
    let sources: [WebSource]
    let searchSuggestionHTML: String?
}

struct Highlight {
    enum Source { case user, assistant }
    let box: NormalizedBox
    let label: String
    let source: Source
}

enum TaskLensError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let value): return value }
    }
}
