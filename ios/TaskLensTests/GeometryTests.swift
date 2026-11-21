import XCTest
@testable import TaskLens

final class GeometryTests: XCTestCase {
    func testVisionConversionFlipsOriginAndRoundTrips() throws {
        let original = try XCTUnwrap(NormalizedBox([100, 200, 400, 600]))
        XCTAssertEqual(original.visionRect.minX, 0.2, accuracy: 0.0001)
        XCTAssertEqual(original.visionRect.minY, 0.6, accuracy: 0.0001)
        let roundTrip = try XCTUnwrap(NormalizedBox.fromVision(original.visionRect))
        for (a, b) in zip(original.values, roundTrip.values) { XCTAssertEqual(a, b, accuracy: 0.0001) }
    }

    func testInvalidNetworkCoordinatesAreRejected() {
        for json in ["[0,0,0,100]", "[-1,0,50,50]", "[0,0,1001,100]", "[1,2,3]"] {
            XCTAssertThrowsError(try JSONDecoder().decode(NormalizedBox.self, from: Data(json.utf8)))
        }
    }

    func testLetterboxingDoesNotBecomePartOfImageCoordinates() throws {
        let viewport = CGSize(width: 400, height: 400)
        let rect = FrameGeometry.fittedRect(in: viewport, aspect: 0.75)
        XCTAssertEqual(rect.minX, 50, accuracy: 0.001)
        XCTAssertNil(FrameGeometry.selection(start: CGPoint(x: 10, y: 100), end: CGPoint(x: 20, y: 150), viewport: viewport, aspect: 0.75))
        let full = try XCTUnwrap(FrameGeometry.selection(start: CGPoint(x: 50, y: 0), end: CGPoint(x: 350, y: 400), viewport: viewport, aspect: 0.75))
        XCTAssertEqual(full.values, [0, 0, 1000, 1000])
    }

    func testTapCreatesClampedNonemptySelection() throws {
        let box = try XCTUnwrap(FrameGeometry.selection(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 0), viewport: CGSize(width: 300, height: 400), aspect: 0.75))
        XCTAssertEqual(box.values[0], 0)
        XCTAssertEqual(box.values[1], 0)
        XCTAssertGreaterThan(box.values[2], 0)
        XCTAssertGreaterThan(box.values[3], 0)
    }
}
