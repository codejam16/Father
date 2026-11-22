import XCTest
@testable import TaskLens

final class DetourTests: XCTestCase {
    private func poi(_ id: String, latitude: Double = 45.501, categories: [String] = ["history"]) -> DetourPOI {
        DetourPOI(id: id, name: id, latitude: latitude, longitude: -73.57, categories: categories,
                  description: "A sourced record.", descriptionFr: nil, verifiedFacts: [], sourceUrls: ["https://example.com"],
                  sourceName: "Fixture", license: "Test", coordinateKind: "point", routable: true)
    }
    func testProjectionDoesNotJumpAheadAroundALoop() {
        let start = DetourPoint(latitude: 45.5, longitude: -73.57)
        let east = DetourPoint(latitude: 45.5, longitude: -73.56)
        let north = DetourPoint(latitude: 45.51, longitude: -73.56)
        let path = [start, east, north, start]
        let result = DetourGeometry.projection(start, path: path, after: 0, through: 100)
        XCTAssertEqual(result.progress, 0, accuracy: 0.1)
        XCTAssertEqual(result.separation, 0, accuracy: 0.1)
        let away = DetourGeometry.projection(DetourPoint(latitude: 45.6, longitude: -73.4), path: path, through: 100)
        XCTAssertGreaterThan(away.separation, 100)
    }
    @MainActor func testRealRouteTimeBudgetRejectsGeographicallyCloseButLongWalkingDetour() async throws {
        let planner = DetourRoutePlanner { from, to, landmark in
            DetourLeg(start: from, end: to, landmark: landmark, points: [from, to], distance: 4000, seconds: 1000, steps: [])
        }
        var preferences = DetourPreferences(); preferences.minutes = 15
        do {
            _ = try await planner.generate(start: DetourPoint(latitude: 45.5, longitude: -73.57), landmarks: [poi("near")], preferences: preferences, visited: [], status: { _ in })
            XCTFail("The round trip cannot fit 15 minutes even if its endpoints are close.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("time budget")) }
    }
    @MainActor func testInterestsAndNoveltyAffectSelectedStopsAndReturnLeg() async throws {
        let planner = DetourRoutePlanner { from, to, landmark in
            DetourLeg(start: from, end: to, landmark: landmark, points: [from, to], distance: 200, seconds: 100, steps: [])
        }
        let start = DetourPoint(latitude: 45.5, longitude: -73.57)
        let history = poi("history", categories: ["history"]), nature = poi("nature", latitude: 45.502, categories: ["nature"])
        var preferences = DetourPreferences(); preferences.frequency = .low; preferences.minutes = 15
        preferences.interests = [.nature]
        let plan = try await planner.generate(start: start, landmarks: [history, nature], preferences: preferences, visited: [], status: { _ in })
        XCTAssertEqual(plan.stops.first?.id, "nature")
        XCTAssertEqual(plan.legs.last?.end, start)
        XCTAssertLessThanOrEqual(plan.estimatedSeconds, 900)
        preferences.interests = [.surprise]; preferences.preferNew = true
        let new = try await planner.generate(start: start, landmarks: [history, nature], preferences: preferences, visited: ["history"], status: { _ in })
        XCTAssertEqual(new.stops.first?.id, "nature")
    }
    @MainActor func testSimulationCannotInvokeRealDirections() async throws {
        let planner = DetourRoutePlanner { _, _, _ in XCTFail("Simulation must not query MapKit"); throw CancellationError() }
        var preferences = DetourPreferences(); preferences.simulation = true
        let plan = try await planner.generate(start: .montreal, landmarks: [poi("a"), poi("b", latitude: 45.502)], preferences: preferences, visited: [], status: { _ in })
        XCTAssertTrue(plan.simulated)
        XCTAssertTrue(plan.notes.joined().contains("not pedestrian routes"))
    }
    @MainActor func testDestinationOverridesReturnAndIncludesFinalWalkingLeg() async throws {
        let planner = DetourRoutePlanner { from, to, landmark in
            DetourLeg(start: from, end: to, landmark: landmark, points: [from, to], distance: 200, seconds: 120, steps: [])
        }
        let start = DetourPoint(latitude: 45.5, longitude: -73.57)
        let end = DetourPoint(latitude: 45.51, longitude: -73.57)
        var prefs = DetourPreferences(); prefs.minutes = 15; prefs.returnToStart = true
        let plan = try await planner.generate(start: start, landmarks: [poi("art")], preferences: prefs, visited: [],
            destination: end, destinationName: "Finish", status: { _ in })
        XCTAssertEqual(plan.legs.last?.end, end)
        XCTAssertEqual(plan.destination, end)
        XCTAssertEqual(plan.estimatedSeconds, 240 + prefs.frequency.dwell, accuracy: 0.1)
    }
    @MainActor func testDestinationTooFarIsRejectedEvenWithNoLandmarks() async throws {
        let planner = DetourRoutePlanner { from, to, landmark in
            DetourLeg(start: from, end: to, landmark: landmark, points: [from, to], distance: 5000, seconds: 1500, steps: [])
        }
        var prefs = DetourPreferences(); prefs.minutes = 15
        do {
            _ = try await planner.generate(start: .montreal, landmarks: [], preferences: prefs, visited: [],
                destination: DetourPoint(latitude: 45.52, longitude: -73.57), status: { _ in })
            XCTFail("Must include the actual walking time to the destination")
        } catch { XCTAssertTrue(error.localizedDescription.contains("destination")) }
    }
    @MainActor func testNoExtraStopsFitButDirectDestinationStillWorks() async throws {
        let end = DetourPoint(latitude: 45.51, longitude: -73.57)
        let planner = DetourRoutePlanner { from, to, landmark in
            DetourLeg(start: from, end: to, landmark: landmark, points: [from, to], distance: 500, seconds: landmark == nil ? 700 : 400, steps: [])
        }
        var prefs = DetourPreferences(); prefs.minutes = 15
        let plan = try await planner.generate(start: .montreal, landmarks: [poi("art")], preferences: prefs, visited: [], destination: end, status: { _ in })
        XCTAssertTrue(plan.stops.isEmpty)
        XCTAssertEqual(plan.legs.last?.end, end)
        XCTAssertEqual(plan.estimatedSeconds, 700)
    }
    func testLegacyWalkSummariesDoNotAcquireUnverifiedFinds() throws {
        let old = DetourWalkSummary(id: UUID(), date: Date(), seconds: 100, metres: 200, discoveries: ["Passed by"],
            discoveryIds: ["old"], simulated: false, completed: true)
        let value = try JSONDecoder().decode(DetourWalkSummary.self, from: JSONEncoder().encode(old))
        XCTAssertNil(value.foundNames)
        XCTAssertNil(value.foundIds)
    }

}
