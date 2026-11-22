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

/// A close-up of part of a frame, and where it sits in that frame.
struct CapturedDetail {
    let jpeg: Data
    let width: Int
    let height: Int
    let box: NormalizedBox
}

struct DetailImagePayload: Encodable {
    let base64: String
    let mimeType = "image/jpeg"
    let width: Int
    let height: Int
    let box: NormalizedBox
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
    /// Optional fingertip close-up of the same frame.
    let detailImage: DetailImagePayload?
    let searchEveryQuestion: Bool
    let guided: Bool
    /// Spots the user's fingertip rested on while asking, in order, as [y, x] (0–1000).
    let pointedAt: [[Double]]?

    init(frame: CapturedFrame, question: String, task: String, history: [ChatMessage], selection: NormalizedBox?,
         sessionId: String? = nil, continuationId: String? = nil,
         researchEnabled: Bool = true, confirmedStepIds: [String] = [], includeWebInfo: Bool = false,
         searchEveryQuestion: Bool = false, guided: Bool = false, detail: CapturedDetail? = nil,
         pointedAt: [CGPoint] = []) {
        self.guided = guided
        self.pointedAt = pointedAt.isEmpty ? nil : pointedAt.prefix(4).map { point -> [Double] in
            let x = Double(point.x)
            let y = Double(point.y)
            return [(min(max(y, 0), 1) * 1000).rounded(),
                    (min(max(x, 0), 1) * 1000).rounded()]
        }
        self.detailImage = detail.map {
            DetailImagePayload(base64: $0.jpeg.base64EncodedString(), width: $0.width, height: $0.height, box: $0.box)
        }
        self.frameId = frame.id
        self.capturedAt = ISO8601DateFormatter().string(from: frame.capturedAt)
        self.question = question
        self.task = String(task.prefix(4000))
        self.image = ImagePayload(base64: frame.jpeg.base64EncodedString(), width: frame.width, height: frame.height)
        self.history = history.suffix(8).map { HistoryMessage(role: $0.role, content: String($0.content.prefix(2000))) }
        self.selection = selection
        self.sessionId = sessionId
        self.continuationId = continuationId
        self.researchEnabled = researchEnabled && includeWebInfo
        self.confirmedStepIds = confirmedStepIds
        self.includeWebInfo = includeWebInfo
        self.searchEveryQuestion = false
    }
}

/// Guided mode: "is the current step done?", with a few recent frames, oldest first.
struct StepCheckFrame: Encodable {
    let frameId: String
    let capturedAt: String
    let image: ImagePayload

    init(_ frame: CapturedFrame) {
        frameId = frame.id
        capturedAt = ISO8601DateFormatter().string(from: frame.capturedAt)
        image = ImagePayload(base64: frame.jpeg.base64EncodedString(), width: frame.width, height: frame.height)
    }
}

struct StepCheckRequest: Encodable {
    let stepId: String
    let step: String
    let goal: String
    let task: String
    /// The step after this one, so a "done" check can highlight where to act next.
    let nextStep: String
    let frames: [StepCheckFrame]
    let userSaysDone: Bool

    init(step: TaskStep, next: TaskStep?, goal: String, task: String, frames: [CapturedFrame], userSaysDone: Bool) {
        stepId = step.id
        nextStep = String((next?.text ?? "").prefix(400))
        self.step = String(step.text.prefix(400))
        self.goal = String(goal.prefix(600))
        self.task = String(task.prefix(4000))
        self.frames = frames.suffix(3).map { StepCheckFrame($0) }
        self.userSaysDone = userSaysDone
    }
}

/// status is "done", "in_progress", "problem" or "unclear".
struct StepCheckResponse: Decodable {
    let stepId: String
    let mode: String
    let status: String
    let feedback: String
    var target: Target? = nil
}

/// Natural speech made by Gemini on the backend: 16-bit mono PCM.
struct SpeechAudio {
    let pcm: Data
    let sampleRate: Double
}

struct SpeakRequest: Encodable {
    let text: String
    let voice: String
}

struct SpeakResponse: Decodable {
    let mode: String
    let audio: String?
    var sampleRate: Double? = nil
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
    /// "What you'll need" when guided steps start.
    var toolsNeeded: [ToolItem]? = nil
    /// Step-by-step drawings explaining a diagram (empty for ordinary answers).
    var annotations: [Annotation]? = nil
    /// "What does it look like?": a short phrase to show a reference photo of.
    var pictureOf: String? = nil
}

/// A reference photo of something the user may not recognize (a tool, a part).
struct ReferencePicture: Decodable, Equatable {
    let imageUrl: URL
    let title: String
    let source: String
    var link: URL? = nil
}

struct PictureRequest: Encodable {
    let query: String
    let context: String
}

struct PictureResponse: Decodable {
    let picture: ReferencePicture?
}

/// One beat of a visual walkthrough: a caption plus a box around a part or a path traced along the drawing.
struct Annotation: Codable, Equatable {
    let caption: String
    /// What is spoken while this beat is on screen.
    var say: String? = nil
    var box: NormalizedBox? = nil
    var path: [[Double]]? = nil
    /// Short tag drawn next to the part, e.g. "R1 · 220 Ω".
    var label: String? = nil
    /// A second part: a curved arrow is drawn from `box` to it (connections, cause and effect).
    var to: NormalizedBox? = nil
    /// Show a magnified bubble of the part in `box`.
    var zoom: Bool? = nil
    /// An outlined area to shade, as [y, x] points.
    var region: [[Double]]? = nil

    /// Path points as unit (x, y), top-left origin.
    var unitPath: [CGPoint] { Self.unitPoints(path) }
    var unitRegion: [CGPoint] { Self.unitPoints(region) }

    private static func unitPoints(_ points: [[Double]]?) -> [CGPoint] {
        (points ?? []).compactMap { $0.count == 2 ? CGPoint(x: $0[1] / 1000, y: $0[0] / 1000) : nil }
    }
}

/// A tool or part for the job; `visible` means seen on camera (or ticked by the user).
struct ToolItem: Codable, Identifiable, Equatable {
    let name: String
    var visible: Bool
    var id: String { name }
}

struct TraceRequest: Encodable {
    let image: ImagePayload
    let rough: [[Double]]
    let what: String
    let question: String
}

struct TraceResponse: Decodable {
    let path: [[Double]]?
}

struct ToolsRequest: Encodable {
    let items: [String]
    let goal: String
    let image: ImagePayload
}

struct ToolsResponse: Decodable {
    let mode: String
    let items: [ToolItem]
    let note: String?
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
