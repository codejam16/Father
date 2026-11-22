import Foundation
import MapKit

@MainActor
final class DetourRoutePlanner {
    private var cache: [String: DetourLeg] = [:]
    private let routeProvider: ((DetourPoint, DetourPoint, DetourPOI?) async throws -> DetourLeg)?
    init(routeProvider: ((DetourPoint, DetourPoint, DetourPOI?) async throws -> DetourLeg)? = nil) { self.routeProvider = routeProvider }

    func generate(start: DetourPoint, landmarks: [DetourPOI], preferences: DetourPreferences,
                  visited: Set<String>, destination: DetourPoint? = nil, destinationName: String? = nil, status: (String) -> Void) async throws -> DetourPlan {
        cache.removeAll()
        if preferences.simulation { return try simulation(landmarks: landmarks, preferences: preferences, visited: visited, destination: destination, destinationName: destinationName) }
        let endpoint = destination ?? (preferences.returnToStart ? start : nil)
        let budget = Double(preferences.minutes * 60)
        var direct: DetourLeg?
        if let endpoint, start.distance(to: endpoint) >= 20 {
            status("Checking the walk to your destination…")
            direct = try await leg(from: start, to: endpoint, landmark: nil)
            guard (direct?.seconds ?? 0) * preferences.pace.multiplier <= budget else {
                throw TaskLensError.message("Your destination does not fit this time budget on foot. Choose a closer destination or allow more time.")
            }
        }
        let wanted = Set(preferences.interests.map(\.rawValue))
        let surprise = preferences.interests.contains(.surprise)
        let candidates = landmarks.filter { $0.routable && start.distance(to: $0.point) >= 50 }
            .sorted { a, b in
                score(a, wanted: wanted, surprise: surprise, visited: visited, preferences: preferences, start: start)
                > score(b, wanted: wanted, surprise: surprise, visited: visited, preferences: preferences, start: start)
            }
        var stops: [DetourPOI] = [], legs: [DetourLeg] = [], elapsed = 0.0, previous = start
        var finalReturn: DetourLeg?
        var checked = 0
        for candidate in candidates.prefix(10) {
            try Task.checkCancellation()
            if stops.count >= preferences.frequency.stopLimit { break }
            if stops.contains(where: { $0.point.distance(to: candidate.point) < 75 }) { continue }
            checked += 1
            status("Checking pedestrian route \(checked)…")
            do {
                let outbound = try await leg(from: previous, to: candidate.point, landmark: candidate)
                let back: DetourLeg?
                if let endpoint, candidate.point.distance(to: endpoint) >= 20 {
                    back = try await leg(from: candidate.point, to: endpoint, landmark: nil)
                } else { back = nil }
                let walking = elapsed + outbound.seconds * preferences.pace.multiplier
                let estimate = walking + (back?.seconds ?? 0) * preferences.pace.multiplier + Double(stops.count + 1) * preferences.frequency.dwell
                guard estimate <= budget else { continue }
                stops.append(candidate); legs.append(outbound); previous = candidate.point
                elapsed = walking; finalReturn = back
            } catch is CancellationError { throw CancellationError() }
            catch let error as MKError where error.code == .loadingThrottled {
                throw TaskLensError.message("Maps is limiting route requests. Please wait a moment and generate again.")
            } catch {
                // An unroutable candidate is skipped; never replace it with a straight line.
                continue
            }
        }
        if stops.isEmpty, destination != nil, let direct {
            return DetourPlan(start: start, stops: [], legs: [direct], estimatedSeconds: direct.seconds * preferences.pace.multiplier,
                simulated: false, notes: ["Your destination fits, but no extra landmark stop fits this time budget."],
                destination: destination, destinationName: destinationName)
        }
        guard !stops.isEmpty else {
            throw TaskLensError.message("No pedestrian route fits this time budget here. Try a longer walk, another start, or the clearly labelled indoor simulation.")
        }
        if let finalReturn { legs.append(finalReturn); elapsed += finalReturn.seconds * preferences.pace.multiplier }
        var notes = ["Walking estimates include your pace preference and brief optional stops. Access and opening hours are not guaranteed."]
        if !surprise && !stops.contains(where: { !wanted.isDisjoint(with: $0.categories) }) {
            notes.append("No matching interests were available nearby; this route uses other sourced discoveries.")
        }
        return DetourPlan(start: start, stops: stops, legs: legs,
                          estimatedSeconds: elapsed + Double(stops.count) * preferences.frequency.dwell,
                          simulated: false, notes: notes, destination: destination, destinationName: destinationName)
    }

    private func score(_ poi: DetourPOI, wanted: Set<String>, surprise: Bool, visited: Set<String>,
                       preferences: DetourPreferences, start: DetourPoint) -> Double {
        let matches = wanted.intersection(poi.categories).count
        let interest = surprise ? 3.0 : Double(matches * 4 + 1)
        let novelty = preferences.preferNew && visited.contains(poi.id) ? 0.22 : 1.0
        return interest * novelty / (1 + start.distance(to: poi.point) / 400)
    }

    func leg(from start: DetourPoint, to end: DetourPoint, landmark: DetourPOI?) async throws -> DetourLeg {
        if let routeProvider { return try await routeProvider(start, end, landmark) }
        let key = "\(start.latitude),\(start.longitude):\(end.latitude),\(end.longitude)"
        if let cached = cache[key] {
            return DetourLeg(start: start, end: end, landmark: landmark, points: cached.points,
                             distance: cached.distance, seconds: cached.seconds, steps: cached.steps)
        }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end.coordinate))
        request.transportType = .walking
        let directions = MKDirections(request: request)
        let response = try await withTaskCancellationHandler {
            try await directions.calculate()
        } onCancel: { Task { @MainActor in directions.cancel() } }
        try Task.checkCancellation()
        guard let route = response.routes.first, route.distance > 0, route.expectedTravelTime > 0 else {
            throw TaskLensError.message("No walking route was returned for that stop.")
        }
        let pointer = route.polyline.points()
        let points = (0..<route.polyline.pointCount).map { DetourPoint(pointer[$0].coordinate) }
        guard points.count > 1, let last = points.last, last.distance(to: end) < 120 else {
            throw TaskLensError.message("The mapped walking path does not reach this landmark closely enough.")
        }
        var offset = 0.0
        let steps = route.steps.compactMap { step -> DetourStep? in
            defer { offset += step.distance }
            let text = step.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : DetourStep(instruction: text, startDistance: offset)
        }
        let result = DetourLeg(start: start, end: end, landmark: landmark, points: points,
                               distance: route.distance, seconds: route.expectedTravelTime, steps: steps)
        cache[key] = result
        return result
    }

    // Explicitly schematic: these lines/times are never used by live GPS guidance.
    private func simulation(landmarks: [DetourPOI], preferences: DetourPreferences, visited: Set<String>, destination: DetourPoint?, destinationName: String?) throws -> DetourPlan {
        let wanted = Set(preferences.interests.map(\.rawValue))
        let ranked = landmarks.filter(\.routable).sorted {
            score($0, wanted: wanted, surprise: preferences.interests.contains(.surprise), visited: visited, preferences: preferences, start: .montreal)
            > score($1, wanted: wanted, surprise: preferences.interests.contains(.surprise), visited: visited, preferences: preferences, start: .montreal)
        }
        let stops = Array(ranked.prefix(preferences.frequency.stopLimit))
        guard stops.count >= 2 else { throw TaskLensError.message("The bundled simulation landmarks are missing.") }
        let start = DetourPoint.montreal
        var previous = start
        var legs: [DetourLeg] = []
        for stop in stops {
            legs.append(DetourLeg(start: previous, end: stop.point, landmark: stop, points: [previous, stop.point],
                                  distance: previous.distance(to: stop.point), seconds: 60,
                                  steps: [DetourStep(instruction: "Simulation: advance to \(stop.name).", startDistance: 0)]))
            previous = stop.point
        }
        if let end = destination ?? (preferences.returnToStart ? start : nil) {
            legs.append(DetourLeg(start: previous, end: end, landmark: nil, points: [previous, end],
                                  distance: previous.distance(to: end), seconds: 60,
                                  steps: [DetourStep(instruction: "Simulation: continue to the finish.", startDistance: 0)]))
        }
        return DetourPlan(start: start, stops: stops, legs: legs, estimatedSeconds: Double(legs.count * 60), simulated: true,
                          notes: ["INDOOR SIMULATION. Dashed straight lines are schematic, not pedestrian routes. Timing and positions are simulated. No live GPS or AI calls are required."],
                          destination: destination, destinationName: destinationName)
    }
}
