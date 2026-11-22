import XCTest
@testable import TaskLens

final class GeometryTests: XCTestCase {
    func testOlderBackendResponseWithoutWebInfoStillDecodes() throws {
        let json = #"{"frameId":"test","mode":"gemini","answer":"A bottle.","target":null,"needsClearerView":false}"#
        let response = try JSONDecoder().decode(AnalysisResponse.self, from: Data(json.utf8))
        XCTAssertNil(response.webInfo)
        XCTAssertEqual(response.answer, "A bottle.")
    }

    func testGroundedWebSourcesDecodeAlongsideCameraAnswer() throws {
        let json = #"{"frameId":"test","mode":"gemini","answer":"A bottle.","target":null,"needsClearerView":false,"webInfo":{"summary":"Similar bottle: CAD 25.","sources":[{"title":"Bottle listing","url":"https://example.com/bottle"}],"searchSuggestionHTML":null}}"#
        let response = try JSONDecoder().decode(AnalysisResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.webInfo?.sources.first?.url.host, "example.com")
        XCTAssertEqual(response.webInfo?.summary, "Similar bottle: CAD 25.")
    }

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

final class TrackingRecoveryTests: XCTestCase {
    private let width = 96
    private let height = 128

    private func box(_ rect: CGRect) -> NormalizedBox {
        NormalizedBox([Double(rect.minY / CGFloat(height) * 1000), Double(rect.minX / CGFloat(width) * 1000),
                       Double(rect.maxY / CGFloat(height) * 1000), Double(rect.maxX / CGFloat(width) * 1000)])!
    }

    private func image(objects: [CGRect], brightness: Float = 0) -> TrackingImage {
        var values = [Float](repeating: 0.12 + brightness, count: width * height)
        for rect in objects {
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    let u = Float(CGFloat(x) - rect.minX) / Float(rect.width)
                    let v = Float(CGFloat(y) - rect.minY) / Float(rect.height)
                    let pattern = 0.48 + 0.16 * sin(u * 9) + 0.12 * cos(v * 11) + 0.08 * sin(u * 5 + v * 7)
                    values[y * width + x] = min(1, max(0, pattern + brightness))
                }
            }
        }
        return TrackingImage(width: width, height: height, values: values)!
    }

    func testRecoversTranslatedObjectAcrossTheFrame() throws {
        let start = CGRect(x: 12, y: 16, width: 24, height: 32)
        let end = CGRect(x: 48, y: 64, width: 24, height: 32)
        let appearance = try XCTUnwrap(ObjectAppearance(image: image(objects: [start]), box: box(start)))
        let recovered = try XCTUnwrap(appearance.locate(in: image(objects: [end]), near: box(start)))
        XCTAssertEqual(recovered.unitRect.midX, box(end).unitRect.midX, accuracy: 0.03)
        XCTAssertEqual(recovered.unitRect.midY, box(end).unitRect.midY, accuracy: 0.03)
    }

    func testAbsentObjectDoesNotLeaveOrInventABox() throws {
        let start = CGRect(x: 12, y: 16, width: 24, height: 32)
        let appearance = try XCTUnwrap(ObjectAppearance(image: image(objects: [start]), box: box(start)))
        XCTAssertNil(appearance.locate(in: image(objects: []), near: box(start)))
    }

    func testAmbiguousIdenticalObjectsAreNotAutomaticallySelected() throws {
        let start = CGRect(x: 12, y: 16, width: 24, height: 32)
        let duplicate = CGRect(x: 60, y: 80, width: 24, height: 32)
        let appearance = try XCTUnwrap(ObjectAppearance(image: image(objects: [start]), box: box(start)))
        XCTAssertNil(appearance.locate(in: image(objects: [start, duplicate]), near: box(start)))
    }

    func testModerateScaleAndLightingChangeCanBeRecovered() throws {
        let start = CGRect(x: 12, y: 16, width: 24, height: 32)
        let end = CGRect(x: 48, y: 64, width: 30, height: 40)
        let appearance = try XCTUnwrap(ObjectAppearance(image: image(objects: [start]), box: box(start)))
        let recovered = try XCTUnwrap(appearance.locate(in: image(objects: [end], brightness: 0.08), near: box(start)))
        XCTAssertEqual(recovered.unitRect.midX, box(end).unitRect.midX, accuracy: 0.04)
        XCTAssertEqual(recovered.unitRect.midY, box(end).unitRect.midY, accuracy: 0.04)
    }

    func testUniformTargetsAreNotUsedAsIdentityTemplates() {
        let start = CGRect(x: 12, y: 16, width: 24, height: 32)
        XCTAssertNil(ObjectAppearance(image: image(objects: []), box: box(start)))
    }

    func testBriefLossDoesNotJumpAcrossTheFrameToFindAnotherPatch() throws {
        let start = CGRect(x: 12, y: 16, width: 24, height: 32)
        let far = CGRect(x: 48, y: 64, width: 24, height: 32)
        var history = ObjectSnapshotHistory()
        let pose = RotatedBox(box: box(start))
        history.record(image: image(objects: [start]), pose: pose, time: 0)
        XCTAssertNil(history.recoverMatch(in: image(objects: [far]), near: pose, attempt: 0, allowGlobalSearch: false))
        XCTAssertNotNil(history.recoverMatch(in: image(objects: [far]), near: pose, attempt: 0, allowGlobalSearch: true))
    }

    func testNearbyRecoveryPreservesTheLastObjectSize() throws {
        let start = CGRect(x: 12, y: 16, width: 24, height: 32)
        let end = CGRect(x: 16, y: 20, width: 24, height: 32)
        let pose = RotatedBox(box: box(start))
        var history = ObjectSnapshotHistory()
        history.record(image: image(objects: [start]), pose: pose, time: 0)
        let recovered = try XCTUnwrap(history.recoverMatch(in: image(objects: [end]), near: pose, attempt: 0, allowGlobalSearch: false))
        XCTAssertEqual(recovered.pose.size.width, pose.size.width, accuracy: 0.0001)
        XCTAssertEqual(recovered.pose.size.height, pose.size.height, accuracy: 0.0001)
    }
}

final class PersistentTargetTests: XCTestCase {
    func testRecoveryScheduleStopsAfterOneMinute() {
        XCTAssertEqual(TrackingRecoveryPolicy.interval(after: 0), 1)
        XCTAssertEqual(TrackingRecoveryPolicy.interval(after: 14.99), 1)
        XCTAssertEqual(TrackingRecoveryPolicy.interval(after: 15), 1)
        XCTAssertEqual(TrackingRecoveryPolicy.interval(after: 59.99), 1)
        XCTAssertNil(TrackingRecoveryPolicy.interval(after: 60))
        XCTAssertNil(TrackingRecoveryPolicy.interval(after: 600))
    }

    func testRotatingBoxesRespectPortraitPixelAspect() throws {
        let box = try XCTUnwrap(NormalizedBox([250, 250, 500, 500]))
        var pose = RotatedBox(box: box)
        pose.angle = .pi / 2
        let bounds = try XCTUnwrap(pose.boundingBox(aspect: 0.75)).unitRect
        XCTAssertEqual(bounds.width, 0.25 / 0.75, accuracy: 0.0001)
        XCTAssertEqual(bounds.height, 0.25 * 0.75, accuracy: 0.0001)
        XCTAssertEqual(bounds.midX, box.unitRect.midX, accuracy: 0.0001)
        XCTAssertEqual(bounds.midY, box.unitRect.midY, accuracy: 0.0001)
    }

    private func rotatedImage(_ pose: RotatedBox) -> TrackingImage {
        let width = 96, height = 128
        var values = [Float](repeating: 0.12, count: width * height)
        let c = cos(pose.angle), s = sin(pose.angle)
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x) + 0.5 - Double(pose.center.x) * Double(width)
                let dy = Double(y) + 0.5 - Double(pose.center.y) * Double(height)
                let u = (c * dx + s * dy) / (Double(pose.size.width) * Double(width)) + 0.5
                let v = (-s * dx + c * dy) / (Double(pose.size.height) * Double(height)) + 0.5
                if (0..<1).contains(u), (0..<1).contains(v) {
                    values[y * width + x] = Float(0.48 + 0.16 * sin(u * 9) + 0.12 * cos(v * 11) + 0.08 * sin(u * 5 + v * 7))
                }
            }
        }
        return TrackingImage(width: width, height: height, values: values)!
    }

    func testSmallSuccessivePhoneRollsKeepAMatchingRotatedBox() throws {
        let box = try XCTUnwrap(NormalizedBox([250, 250, 500, 500]))
        let original = RotatedBox(box: box)
        let appearance = try XCTUnwrap(ObjectAppearance(image: rotatedImage(original), pose: original))
        var predicted = original
        for degrees in [7.0, 14, 21, 28] {
            var actual = original
            actual.angle = degrees * .pi / 180
            let match = try XCTUnwrap(appearance.follow(in: rotatedImage(actual), near: predicted))
            XCTAssertGreaterThan(match.score, 0.8)
            XCTAssertEqual(match.pose.angle, actual.angle, accuracy: 8 * .pi / 180)
            predicted = match.pose
        }
    }

    func testLostRotatedObjectCanBeFoundAtAnotherPosition() throws {
        let box = try XCTUnwrap(NormalizedBox([200, 200, 450, 450]))
        let original = RotatedBox(box: box)
        let appearance = try XCTUnwrap(ObjectAppearance(image: rotatedImage(original), pose: original))
        var actual = original
        actual.center = CGPoint(x: 0.65, y: 0.65)
        actual.angle = .pi / 3
        let recovered = try XCTUnwrap(appearance.locatePose(in: rotatedImage(actual), near: original))
        XCTAssertEqual(recovered.center.x, actual.center.x, accuracy: 0.04)
        XCTAssertEqual(recovered.center.y, actual.center.y, accuracy: 0.04)
        XCTAssertEqual(recovered.angle, actual.angle, accuracy: 15 * .pi / 180)
    }

    func testMultipleRelatedTargetsDecodeWithoutDroppingTheParent() throws {
        let json = #"{"frameId":"test","mode":"gemini","answer":"Press the button.","target":null,"needsClearerView":false,"targets":[{"id":"bottle","parentId":null,"label":"Bottle","box":[100,100,900,900]},{"id":"button","parentId":"bottle","label":"Button","box":[200,300,300,400]}]}"#
        let response = try JSONDecoder().decode(AnalysisResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.targets?.count, 2)
        XCTAssertEqual(response.targets?.last?.parentId, response.targets?.first?.id)
    }
}


final class TrackingStabilityTests: XCTestCase {
    func testOneWeakFrameDoesNotLoseAnOtherwiseHealthyTrack() {
        var stability = TrackingStability()
        XCTAssertFalse(stability.recordVision(0.2))
        XCTAssertFalse(stability.recordVision(0.8))
        XCTAssertEqual(stability.weakVisionFrames, 0)
    }

    func testSustainedWeakVisionStillLosesTheTrack() {
        var stability = TrackingStability()
        XCTAssertFalse(stability.recordVision(0.2))
        XCTAssertFalse(stability.recordVision(0.1))
        XCTAssertTrue(stability.recordVision(0))
    }

    func testRotationMismatchDoesNotVetoConfidentVision() {
        var stability = TrackingStability()
        for _ in 0..<8 { XCTAssertFalse(stability.recordAppearance(0.45, visionConfidence: 0.9)) }
        XCTAssertFalse(stability.recordAppearance(nil, visionConfidence: 0.9))
    }

    func testSustainedStrongContradictionStillRejectsDrift() {
        var stability = TrackingStability()
        for _ in 0..<3 { XCTAssertFalse(stability.recordAppearance(0.05, visionConfidence: 0.9)) }
        XCTAssertTrue(stability.recordAppearance(0.05, visionConfidence: 0.9))
    }

    func testGoodAppearanceResetsMismatchHistory() {
        var stability = TrackingStability()
        for _ in 0..<3 { _ = stability.recordAppearance(0.3, visionConfidence: 0.9) }
        XCTAssertFalse(stability.recordAppearance(0.9, visionConfidence: 0.9))
        XCTAssertEqual(stability.appearanceMismatches, 0)
    }
}

final class SnapshotHistoryTests: XCTestCase {
    private func sample(inverted: Bool = false) -> TrackingImage {
        let values: [Float] = (0..<144).map { index in
            let value = Float(0.5 + 0.2 * sin(Double(index % 12) * 0.6) + 0.15 * cos(Double(index / 12) * 0.7))
            return inverted ? 1 - value : value
        }
        return TrackingImage(width: 12, height: 12, values: values)!
    }
    private var pose: RotatedBox { RotatedBox(box: NormalizedBox([0, 0, 1000, 1000])!) }

    func testDenseInitialSnapshotsThinToFiveSecondLandmarks() {
        var history = ObjectSnapshotHistory()
        for second in 0..<10 { history.record(image: sample(), pose: pose, time: Double(second)) }
        XCTAssertEqual(history.snapshots.map(\.time), (0..<10).map(Double.init))
        history.record(image: sample(), pose: pose, time: 10)
        XCTAssertEqual(history.snapshots.map(\.time), [0, 5, 10])
        for second in 11...20 { history.record(image: sample(), pose: pose, time: Double(second)) }
        XCTAssertEqual(history.snapshots.map(\.time), [0, 10, 20])
    }

    func testHourOfTrackingKeepsMemoryBoundedAndFirstAndNewestViews() {
        var history = ObjectSnapshotHistory()
        let image = sample()
        for second in 0...3600 {
            history.record(image: image, pose: pose, time: Double(second))
            XCTAssertLessThanOrEqual(history.snapshots.count, 12)
        }
        XCTAssertEqual(history.snapshots.first?.time, 0)
        XCTAssertEqual(history.snapshots.last?.time, 3600)
    }

    func testSamplingNeverStoresMoreThanOncePerSecond() {
        var history = ObjectSnapshotHistory()
        XCTAssertTrue(history.record(image: sample(), pose: pose, time: 0))
        XCTAssertFalse(history.record(image: sample(), pose: pose, time: 0.1))
        XCTAssertFalse(history.record(image: sample(), pose: pose, time: 0.9))
        XCTAssertTrue(history.record(image: sample(), pose: pose, time: 1))
        XCTAssertEqual(history.snapshots.count, 2)
    }

    func testTexturelessViewsAreNotAddedToRecoveryHistory() {
        let image = TrackingImage(width: 12, height: 12, values: [Float](repeating: 0.5, count: 144))!
        var history = ObjectSnapshotHistory()
        XCTAssertFalse(history.record(image: image, pose: pose, time: 0))
        XCTAssertTrue(history.snapshots.isEmpty)
    }

    func testRecoveryCanUseAnOlderViewInsteadOfTheNewestTemplate() throws {
        var history = ObjectSnapshotHistory()
        history.record(image: sample(), pose: pose, time: 0)
        for second in 1...20 { history.record(image: sample(inverted: true), pose: pose, time: Double(second)) }
        let recovered = try XCTUnwrap(history.recover(in: sample(), near: pose, attempt: 0))
        XCTAssertEqual(recovered.center.x, pose.center.x, accuracy: 0.01)
        XCTAssertEqual(recovered.center.y, pose.center.y, accuracy: 0.01)
    }

    func testRecoveryCarriesTheMatchingMiddleSnapshotForConfirmation() throws {
        var history = ObjectSnapshotHistory()
        let first = sample()
        let middle = sample(inverted: true)
        let last = TrackingImage(width: 12, height: 12, values: (0..<144).map { Float(0.5 + 0.3 * sin(Double($0) * 1.3)) })!
        history.record(image: first, pose: pose, time: 0)
        history.record(image: middle, pose: pose, time: 5)
        history.record(image: last, pose: pose, time: 10)
        let recovered = try XCTUnwrap(history.recoverMatch(in: middle, near: pose, attempt: 0, allowGlobalSearch: false))
        XCTAssertEqual(recovered.snapshot.time, 5)
        let confirmation = try XCTUnwrap(recovered.snapshot.appearance.similarity(in: middle, pose: recovered.pose))
        XCTAssertGreaterThan(confirmation, 0.99)
        XCTAssertLessThan(try XCTUnwrap(history.snapshots.last?.appearance.similarity(in: middle, pose: pose)), 0.8)
    }

    func testOriginalUsefulViewSurvivesEvenWhenRecentAppearanceChanges() throws {
        var history = ObjectSnapshotHistory()
        history.record(image: sample(), pose: pose, time: 0)
        for second in 1...60 { history.record(image: sample(inverted: true), pose: pose, time: Double(second)) }
        let original = try XCTUnwrap(history.snapshots.first?.appearance.similarity(in: sample(), pose: pose))
        let recent = try XCTUnwrap(history.snapshots.last?.appearance.similarity(in: sample(), pose: pose))
        XCTAssertGreaterThan(original, 0.99)
        XCTAssertLessThan(recent, 0)
    }
}

final class ForegroundAssociationTests: XCTestCase {
    func testSelectsOverlappingInstanceInsteadOfUnrelatedForeground() {
        let target = CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.5)
        XCTAssertEqual(ForegroundAssociation.match(target: target, candidates: [
            CGRect(x: 0.7, y: 0.2, width: 0.2, height: 0.5),
            CGRect(x: 0.21, y: 0.22, width: 0.28, height: 0.48)
        ]), 1)
    }

    func testDoesNotSubstituteWholeBottleForLid() {
        XCTAssertNil(ForegroundAssociation.match(
            target: CGRect(x: 0.3, y: 0.2, width: 0.15, height: 0.06),
            candidates: [CGRect(x: 0.25, y: 0.18, width: 0.25, height: 0.65)]))
    }

    func testAmbiguousInstancesAreNotSelected() {
        let target = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.5)
        XCTAssertNil(ForegroundAssociation.match(target: target, candidates: [
            CGRect(x: 0.18, y: 0.2, width: 0.4, height: 0.5),
            CGRect(x: 0.22, y: 0.2, width: 0.4, height: 0.5)
        ]))
    }
}

final class HighlightIntentTests: XCTestCase {
    private func target(_ id: String, parent: String? = nil, emphasis: TargetEmphasis? = nil) throws -> Target {
        Target(label: id, box: try XCTUnwrap(NormalizedBox([200, 200, 300, 300])), id: id,
               parentId: parent, kind: parent == nil ? .object : .part, emphasis: emphasis)
    }
    func testOpeningKeepsBottleInContextAndOnlyLightsButton() throws {
        let bottle = try target("bottle", emphasis: .context)
        let button = try target("button", parent: "bottle", emphasis: .primary)
        XCTAssertEqual(HighlightPresentation.primary([bottle, button]).compactMap(\.id), ["button"])
        XCTAssertEqual(button.resolvedKind, .part)
    }
    func testAllSixObjectsRemainPrimaryWithoutAnArbitraryPronounFocus() throws {
        let objects = try (0..<6).map { try target("bottle\($0)", emphasis: .primary) }
        let primary = HighlightPresentation.primary(objects)
        XCTAssertEqual(primary.count, 6)
        XCTAssertNil(HighlightPresentation.focusedID(Set(primary.compactMap(\.id))))
        XCTAssertEqual(HighlightPresentation.focusedID(["one"]), "one")
    }
    func testLegacyParentChildAnswersPreferTheSpecificPart() throws {
        let parent = try target("bottle"), child = try target("latch", parent: "bottle")
        XCTAssertEqual(HighlightPresentation.primary([parent, child]).compactMap(\.id), ["latch"])
    }
    func testExplicitEmptyArrayClearsTheLegacyTarget() throws {
        let json = #"{"frameId":"test","mode":"gemini","answer":"Which one?","target":{"label":"Old bottle","box":[100,100,900,900]},"needsClearerView":false,"targets":[]}"#
        let response = try JSONDecoder().decode(AnalysisResponse.self, from: Data(json.utf8))
        XCTAssertTrue(response.highlightTargets.isEmpty)
    }
    func testUnclearViewsNeverDisplayEvenALegacyTarget() throws {
        let json = #"{"frameId":"test","mode":"gemini","answer":"Move closer.","target":{"label":"Bottle","box":[100,100,900,900]},"needsClearerView":true}"#
        let response = try JSONDecoder().decode(AnalysisResponse.self, from: Data(json.utf8))
        XCTAssertTrue(response.highlightTargets.isEmpty)
    }
    func testLegacySingleTargetStillWorks() throws {
        let json = #"{"frameId":"test","mode":"gemini","answer":"There.","target":{"label":"Bottle","box":[100,100,900,900]},"needsClearerView":false}"#
        let response = try JSONDecoder().decode(AnalysisResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.highlightTargets.first?.label, "Bottle")
    }
    func testPartMaskCannotGrowIntoALargerEnclosingComponent() {
        let button = CGRect(x: 0.3, y: 0.3, width: 0.1, height: 0.1)
        let lid = CGRect(x: 0.29, y: 0.29, width: 0.12, height: 0.12)
        XCTAssertNil(ForegroundAssociation.match(target: button, candidates: [lid], isPart: true))
        XCTAssertEqual(ForegroundAssociation.match(target: button, candidates: [button], isPart: true), 0)
    }
}
