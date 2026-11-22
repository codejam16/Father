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
    var trackedObjects: [TrackedObjectContext] = []
}

struct SelectedFrame {
    let frame: CapturedFrame
    let box: NormalizedBox
    var targetID: String? = nil
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
    let searchEveryQuestion: Bool
    let knownTargets: [TrackedObjectContext]
    let selections: [Target]

    init(frame: CapturedFrame, question: String, task: String, history: [ChatMessage], selection: NormalizedBox?,
         sessionId: String? = nil, continuationId: String? = nil,
         researchEnabled: Bool = true, confirmedStepIds: [String] = [], includeWebInfo: Bool = false,
         searchEveryQuestion: Bool = false, selections: [Target] = []) {
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
        self.searchEveryQuestion = searchEveryQuestion
        self.knownTargets = frame.trackedObjects
        self.selections = selections
    }
}

struct Target: Codable {
    let label: String
    let box: NormalizedBox
    var id: String? = nil
    var parentId: String? = nil
}

struct TrackedObjectContext: Codable, Identifiable {
    let id: String
    let label: String
    let parentId: String?
    let source: String
    let state: String
    let box: NormalizedBox?
    let isFocused: Bool
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
    var targets: [Target]? = nil
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

struct Highlight: Identifiable {
    enum Source: String { case user, assistant }
    let id: String
    let label: String
    let source: Source
    let pose: RotatedBox
    let isFocused: Bool
}

/// Sizes are normalized to the upright image; rotation is applied in pixel space,
/// never in a square normalized space (which would distort portrait images).
struct RotatedBox: Equatable {
    var center: CGPoint
    var size: CGSize
    var angle: Double

    init(box: NormalizedBox, angle: Double = 0) {
        let rect = box.unitRect
        center = CGPoint(x: rect.midX, y: rect.midY)
        size = rect.size
        self.angle = angle
    }

    func corners(aspect: CGFloat) -> [CGPoint] {
        let c = CGFloat(cos(angle)), s = CGFloat(sin(angle))
        return [CGPoint(x: -0.5, y: -0.5), CGPoint(x: 0.5, y: -0.5),
                CGPoint(x: 0.5, y: 0.5), CGPoint(x: -0.5, y: 0.5)].map { point in
            let x = point.x * size.width * aspect, y = point.y * size.height
            return CGPoint(x: center.x + (c * x - s * y) / aspect, y: center.y + s * x + c * y)
        }
    }

    func boundingBox(aspect: CGFloat) -> NormalizedBox? {
        let points = corners(aspect: aspect)
        let x1 = max(0, points.map(\.x).min() ?? 0), x2 = min(1, points.map(\.x).max() ?? 1)
        let y1 = max(0, points.map(\.y).min() ?? 0), y2 = min(1, points.map(\.y).max() ?? 1)
        return NormalizedBox([Double(y1 * 1000), Double(x1 * 1000), Double(y2 * 1000), Double(x2 * 1000)])
    }
}

enum TrackingRecoveryPolicy {
    static func interval(after elapsed: TimeInterval) -> TimeInterval? {
        guard elapsed < 60 else { return nil }
        return 1
    }
}

/// Debounce weak evidence. Rotation matching is advisory for a healthy Vision track.
struct TrackingStability {
    private(set) var weakVisionFrames = 0
    private(set) var appearanceMismatches = 0

    mutating func recordVision(_ confidence: Float) -> Bool {
        weakVisionFrames = confidence >= 0.4 ? 0 : weakVisionFrames + 1
        return weakVisionFrames >= 3
    }

    mutating func recordAppearance(_ score: Float?, visionConfidence: Float) -> Bool {
        guard let score else { return false }
        appearanceMismatches = score >= 0.6 ? 0 : appearanceMismatches + 1
        // Mild appearance changes never overrule a confident positional tracker.
        return appearanceMismatches >= 4 && (visionConfidence < 0.65 || score < 0.1)
    }
}

enum TaskLensError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let value): return value }
    }
}

/// Small upright luminance image used only for on-device target recovery.
struct TrackingImage {
    let width: Int
    let height: Int
    let values: [Float]
    var aspect: CGFloat { CGFloat(width) / CGFloat(height) }

    init?(width: Int, height: Int, values: [Float]) {
        guard width > 0, height > 0, values.count == width * height,
              values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        self.width = width; self.height = height; self.values = values
    }

    fileprivate func descriptor(in pose: RotatedBox, grid: Int = 12) -> [Float]? {
        guard pose.size.width * CGFloat(width) >= 4, pose.size.height * CGFloat(height) >= 4,
              pose.corners(aspect: aspect).allSatisfy({ $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 }) else { return nil }
        var samples: [Float] = []
        samples.reserveCapacity(grid * grid)
        let c = CGFloat(cos(pose.angle)), s = CGFloat(sin(pose.angle))
        for row in 0..<grid {
            for column in 0..<grid {
                let offsetX = ((CGFloat(column) + 0.5) / CGFloat(grid) - 0.5) * pose.size.width * CGFloat(width)
                let offsetY = ((CGFloat(row) + 0.5) / CGFloat(grid) - 0.5) * pose.size.height * CGFloat(height)
                let px = pose.center.x * CGFloat(width) + c * offsetX - s * offsetY - 0.5
                let py = pose.center.y * CGFloat(height) + s * offsetX + c * offsetY - 0.5
                let x = min(Float(width - 1), max(0, Float(px))), y = min(Float(height - 1), max(0, Float(py)))
                let x0 = Int(x), y0 = Int(y), x1 = min(Int(x) + 1, width - 1), y1 = min(Int(y) + 1, height - 1)
                let dx = x - Float(x0), dy = y - Float(y0)
                let top = values[y0 * width + x0] * (1 - dx) + values[y0 * width + x1] * dx
                let bottom = values[y1 * width + x0] * (1 - dx) + values[y1 * width + x1] * dx
                samples.append(top * (1 - dy) + bottom * dy)
            }
        }
        let mean = samples.reduce(0, +) / Float(samples.count)
        let centered = samples.map { $0 - mean }
        let energy = centered.reduce(Float(0)) { $0 + $1 * $1 }
        guard energy / Float(samples.count) >= 0.0012 else { return nil }
        let norm = sqrt(energy)
        return centered.map { $0 / norm }
    }
}

struct ObjectAppearance {
    private let descriptor: [Float]

    init?(image: TrackingImage, box: NormalizedBox) { self.init(image: image, pose: RotatedBox(box: box)) }
    init?(image: TrackingImage, pose: RotatedBox) {
        guard let descriptor = image.descriptor(in: pose) else { return nil }
        self.descriptor = descriptor
    }

    func similarity(in image: TrackingImage, box: NormalizedBox) -> Float? { similarity(in: image, pose: RotatedBox(box: box)) }
    func similarity(in image: TrackingImage, pose: RotatedBox) -> Float? {
        guard let candidate = image.descriptor(in: pose) else { return nil }
        return zip(descriptor, candidate).reduce(Float(0)) { $0 + $1.0 * $1.1 }
    }

    /// Correct rotation, scale and small translations while the Vision tracker supplies position.
    func follow(in image: TrackingImage, near predicted: RotatedBox, maximumRotationStep: Double = .pi / 12,
                translationRadius: Int = 2, allowScale: Bool = true) -> (pose: RotatedBox, score: Float)? {
        var best: (pose: RotatedBox, score: Float)?
        for scale: CGFloat in allowScale ? [0.94, 1, 1.06] : [1] {
            for turn in [-maximumRotationStep, -maximumRotationStep / 2, 0, maximumRotationStep / 2, maximumRotationStep] {
                let radius = max(0, translationRadius)
                let offsets = radius == 0 ? [0] : radius <= 2 ? [-radius, 0, radius]
                    : Array(stride(from: -radius, through: radius, by: max(1, radius / 2)))
                for dy in offsets {
                    for dx in offsets {
                        var pose = predicted
                        pose.size = CGSize(width: predicted.size.width * scale, height: predicted.size.height * scale)
                        pose.angle += turn
                        pose.center.x += CGFloat(dx) / CGFloat(image.width)
                        pose.center.y += CGFloat(dy) / CGFloat(image.height)
                        if let score = similarity(in: image, pose: pose), score > (best?.score ?? -1) { best = (pose, score) }
                    }
                }
            }
        }
        return best
    }

    func locate(in image: TrackingImage, near previous: NormalizedBox) -> NormalizedBox? {
        locatePose(in: image, near: RotatedBox(box: previous), angles: [0])?.boundingBox(aspect: image.aspect)
    }

    func locatePose(in image: TrackingImage, near previous: RotatedBox, angles: [Double]? = nil) -> RotatedBox? {
        struct Candidate { let pose: RotatedBox; let bounds: CGRect; let score: Float }
        var candidates: [Candidate] = []
        func evaluate(_ pose: RotatedBox) {
            guard let score = similarity(in: image, pose: pose), let box = pose.boundingBox(aspect: image.aspect) else { return }
            candidates.append(Candidate(pose: pose, bounds: box.unitRect, score: score))
        }
        let rotations = angles ?? stride(from: -180.0, to: 180.0, by: 30).map { $0 * .pi / 180 }
        for scale: CGFloat in [0.8, 1, 1.25] {
            let width = previous.size.width * scale, height = previous.size.height * scale
            guard width * CGFloat(image.width) >= 4, height * CGFloat(image.height) >= 4 else { continue }
            let step = max(3, Int(sqrt(Double(image.width * image.height) / 240)))
            for angle in rotations {
                for y in stride(from: 0, to: image.height, by: step) {
                    for x in stride(from: 0, to: image.width, by: step) {
                        var pose = previous
                        pose.size = CGSize(width: width, height: height)
                        pose.center = CGPoint(x: CGFloat(x) / CGFloat(image.width), y: CGFloat(y) / CGFloat(image.height))
                        pose.angle = angle
                        evaluate(pose)
                    }
                }
            }
        }
        let seeds = candidates.sorted { $0.score > $1.score }.prefix(4)
        for seed in seeds {
            for scale: CGFloat in [0.9, 1, 1.1] {
                for turn in angles == nil ? [-Double.pi / 12, -Double.pi / 24, 0, Double.pi / 24, Double.pi / 12] : [0] {
                    for dy in -5...5 {
                        for dx in -5...5 {
                            var pose = seed.pose
                            pose.size = CGSize(width: pose.size.width * scale, height: pose.size.height * scale)
                            pose.center.x += CGFloat(dx) / CGFloat(image.width)
                            pose.center.y += CGFloat(dy) / CGFloat(image.height)
                            pose.angle += turn
                            evaluate(pose)
                        }
                    }
                }
            }
        }
        guard let best = candidates.max(by: { $0.score < $1.score }), best.score >= 0.86 else { return nil }
        let runnerUp = candidates.filter { candidate in
            let intersection = best.bounds.intersection(candidate.bounds)
            let overlap = intersection.isNull ? 0 : intersection.width * intersection.height
            let union = best.bounds.width * best.bounds.height + candidate.bounds.width * candidate.bounds.height - overlap
            return union > 0 && overlap / union < 0.25
        }.map(\.score).max() ?? -1
        guard best.score - runnerUp >= 0.07 else { return nil }
        return best.pose
    }
}

/// Temporal snapshot pyramid: dense recent sampling, then progressively wider spacing.
/// Retains small grayscale views and descriptors, not full-resolution camera buffers.
struct ObjectSnapshotHistory {
    struct Snapshot {
        let time: Double
        let image: TrackingImage
        let pose: RotatedBox
        let appearance: ObjectAppearance
    }
    private(set) var snapshots: [Snapshot] = []
    private var lastSampleTime = -Double.infinity

    struct RecoveryMatch {
        let pose: RotatedBox
        let snapshot: Snapshot
    }

    func recover(in image: TrackingImage, near previous: RotatedBox, attempt: Int) -> RotatedBox? {
        recoverMatch(in: image, near: previous, attempt: attempt)?.pose
    }

    /// Preserve the exact matching reference through Vision confirmation. A brief
    /// dropout searches nearby at the existing size, not arbitrary patches of the frame.
    func recoverMatch(in image: TrackingImage, near previous: RotatedBox, attempt: Int,
                      allowGlobalSearch: Bool = true) -> RecoveryMatch? {
        guard !snapshots.isEmpty else { return nil }
        func adjustedPose(_ snapshot: Snapshot) -> RotatedBox {
            var pose = previous
            let scale = sqrt(previous.size.width * previous.size.height /
                             max(0.00001, snapshot.pose.size.width * snapshot.pose.size.height))
            pose.size = CGSize(width: snapshot.pose.size.width * scale, height: snapshot.pose.size.height * scale)
            return pose
        }
        let nearby = snapshots.compactMap { snapshot -> (Snapshot, Float)? in
            guard let score = snapshot.appearance.similarity(in: image, pose: adjustedPose(snapshot)) else { return nil }
            return (snapshot, score)
        }.sorted { $0.1 > $1.1 }
        let probes = nearby.isEmpty ? Array(snapshots.suffix(2)) : nearby.prefix(2).map { $0.0 }
        for snapshot in probes {
            let pose = adjustedPose(snapshot)
            if let score = snapshot.appearance.similarity(in: image, pose: pose), score >= 0.96 {
                return RecoveryMatch(pose: pose, snapshot: snapshot)
            }
            if let match = snapshot.appearance.follow(in: image, near: pose,
                translationRadius: 8, allowScale: false), match.score >= 0.84 {
                return RecoveryMatch(pose: match.pose, snapshot: snapshot)
            }
        }
        guard allowGlobalSearch else { return nil }
        let selected = snapshots[snapshots.count - 1 - attempt % snapshots.count]
        // Ordinary losses should not compete with hundreds of rotated/subregion
        // hypotheses. Preserve the previous orientation before widening the search.
        let pose = selected.appearance.locatePose(in: image, near: adjustedPose(selected), angles: [previous.angle])
            ?? selected.appearance.locatePose(in: image, near: adjustedPose(selected))
        guard let pose else { return nil }
        return RecoveryMatch(pose: pose, snapshot: selected)
    }

    @discardableResult
    mutating func record(image: TrackingImage, pose: RotatedBox, time: Double) -> Bool {
        guard time.isFinite, time - lastSampleTime >= 1,
              let appearance = ObjectAppearance(image: image, pose: pose) else { return false }
        lastSampleTime = time
        snapshots.append(Snapshot(time: time, image: image, pose: pose, appearance: appearance))
        guard let first = snapshots.first, let latest = snapshots.last else { return true }
        let span = latest.time - first.time
        let interval = span < 10 ? 1 : 5 * pow(2, floor(log2(span / 10)))
        var keep = Set([0, snapshots.count - 1])
        for offset in stride(from: 0.0, through: span, by: interval) {
            let desired = first.time + offset
            if let index = snapshots.indices.min(by: { abs(snapshots[$0].time - desired) < abs(snapshots[$1].time - desired) }) {
                keep.insert(index)
            }
        }
        snapshots = snapshots.enumerated().filter { keep.contains($0.offset) }.map(\.element)
        return true
    }
}
