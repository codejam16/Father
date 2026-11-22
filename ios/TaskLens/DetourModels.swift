import Foundation
import CoreLocation
import MapKit

struct DetourPoint: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
    init(_ coordinate: CLLocationCoordinate2D) { latitude = coordinate.latitude; longitude = coordinate.longitude }
    init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }
    func distance(to other: DetourPoint) -> Double { location.distance(from: other.location) }
    static let montreal = DetourPoint(latitude: 45.503724, longitude: -73.568507)
}

enum DetourInterest: String, CaseIterable, Codable, Identifiable {
    case history, architecture, streetArt, nature, hiddenGems, surprise
    var id: String { rawValue }
    var title: String {
        switch self {
        case .history: "History"
        case .architecture: "Architecture"
        case .streetArt: "Street Art"
        case .nature: "Nature"
        case .hiddenGems: "Hidden Gems"
        case .surprise: "Surprise Me"
        }
    }
    var symbol: String {
        switch self {
        case .history: "clock.arrow.circlepath"
        case .architecture: "building.columns"
        case .streetArt: "paintpalette"
        case .nature: "leaf"
        case .hiddenGems: "sparkles"
        case .surprise: "shuffle"
        }
    }
}

enum DetourPace: String, CaseIterable, Codable { case slow, normal, fast
    var multiplier: Double { switch self { case .slow: 1.25; case .normal: 1; case .fast: 0.85 } }
}
enum DetourFrequency: String, CaseIterable, Codable { case low, normal, high
    var stopLimit: Int { switch self { case .low: 2; case .normal: 3; case .high: 5 } }
    var dwell: Double { switch self { case .low: 30; case .normal: 50; case .high: 65 } }
}
struct DetourPreferences: Codable {
    var minutes = 30
    var interests: Set<DetourInterest> = [.history, .architecture]
    var returnToStart = true
    var preferNew = true
    var frequency = DetourFrequency.normal
    var pace = DetourPace.normal
    var language = "en"
    var automaticStories = false
    var aiStories = false
    var simulation = false
}
struct DetourPOI: Codable, Identifiable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let categories: [String]
    let description: String
    let descriptionFr: String?
    let verifiedFacts: [String]
    let sourceUrls: [String]
    let sourceName: String
    let license: String
    let coordinateKind: String
    let routable: Bool
    var point: DetourPoint { DetourPoint(latitude: latitude, longitude: longitude) }
    func summary(language: String) -> String { language == "fr" ? descriptionFr ?? description : description }
    var scannerContext: String {
        "Discovery context: the user may be near \(name). This is a candidate, not a confirmed visual identification. Ask for a better angle if the camera does not match. Source-grounded record: \(description) \(verifiedFacts.joined(separator: " ")). References: \(sourceUrls.joined(separator: " ")). Never invent historical details."
    }
}
struct DetourCatalog: Decodable {
    let landmarks: [DetourPOI]
}
struct DetourLandmarkResponse: Decodable {
    let landmarks: [DetourPOI]
    let warning: String?
}
struct DetourStory: Decodable { let story: String; let generated: Bool; let sourceUrls: [String] }
struct DetourStep: Identifiable {
    let id = UUID()
    let instruction: String
    let startDistance: Double
}
struct DetourLeg: Identifiable {
    let id = UUID()
    let start: DetourPoint
    let end: DetourPoint
    let landmark: DetourPOI?
    let points: [DetourPoint]
    let distance: Double
    let seconds: Double
    let steps: [DetourStep]
    var polyline: MKPolyline { MKPolyline(coordinates: points.map(\.coordinate), count: points.count) }
}
struct DetourPlan: Identifiable {
    let id = UUID()
    let start: DetourPoint
    let stops: [DetourPOI]
    let legs: [DetourLeg]
    let estimatedSeconds: Double
    let simulated: Bool
    let notes: [String]
    var distance: Double { legs.reduce(0) { $0 + $1.distance } }
    var points: [DetourPoint] { legs.enumerated().flatMap { $0.offset == 0 ? $0.element.points : Array($0.element.points.dropFirst()) } }
}
struct DetourWalkSummary: Codable, Identifiable {
    let id: UUID
    let date: Date
    let seconds: Double
    let metres: Double
    let discoveries: [String]
    let discoveryIds: [String]
    let simulated: Bool
    let completed: Bool
}

// Geometry is used to measure progress along a provider-supplied path, never to
// substitute straight lines for real pedestrian routing.
enum DetourGeometry {
    static func projection(_ location: DetourPoint, path: [DetourPoint], after minimumProgress: Double = 0,
                           through maximumProgress: Double = .greatestFiniteMagnitude) -> (progress: Double, separation: Double) {
        guard path.count > 1 else { return (0, .greatestFiniteMagnitude) }
        var travelled = 0.0, bestDistance = Double.greatestFiniteMagnitude, bestProgress = minimumProgress
        let scale = cos(location.latitude * .pi / 180)
        for i in 1..<path.count {
            let a = path[i - 1], b = path[i], length = a.distance(to: b)
            defer { travelled += length }
            guard travelled + length >= minimumProgress, travelled <= maximumProgress else { continue }
            let ax = (a.longitude - location.longitude) * scale * 111_195, ay = (a.latitude - location.latitude) * 111_195
            let bx = (b.longitude - location.longitude) * scale * 111_195, by = (b.latitude - location.latitude) * 111_195
            let dx = bx - ax, dy = by - ay, denominator = dx * dx + dy * dy
            let t = denominator > 0 ? min(1, max(0, -(ax * dx + ay * dy) / denominator)) : 0
            let projected = travelled + t * length
            guard projected >= minimumProgress, projected <= maximumProgress else { continue }
            let distance = hypot(ax + t * dx, ay + t * dy)
            if distance < bestDistance { bestDistance = distance; bestProgress = projected }
        }
        return (bestProgress, bestDistance)
    }
}
