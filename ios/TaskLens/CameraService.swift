import AVFoundation
import Combine
import CoreImage
import UIKit
import Vision

/// Session, frame buffer, and trackers are confined to this service's serial queue.
/// UI state is published on the main queue. The preview never waits for network IO.
final class CameraService: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Starting camera…"
    @Published private(set) var highlights: [Highlight] = []
    @Published private(set) var trackedObjects: [TrackedObjectContext] = []
    @Published private(set) var aspectRatio: CGFloat = 0.75
    /// Which camera is live. Frames are never mirrored; the front preview is mirrored on screen only.
    @Published private(set) var position: AVCaptureDevice.Position = .back

    // Camera-owned pixel copies are immutable once published to either worker queue.
    private struct BufferedFrame: @unchecked Sendable {
        let id: String
        let date: Date
        let time: Double
        let pixels: CVPixelBuffer
    }

    private let queue = DispatchQueue(label: "tasklens.camera", qos: .userInitiated)
    private let context = CIContext()
    private let snapshotQueue = DispatchQueue(label: "tasklens.snapshot", qos: .userInitiated)
    private let snapshotContext = CIContext()
    private let recoveryQueue = DispatchQueue(label: "tasklens.recovery", qos: .utility)
    private var recoveryWorkID: UUID?
    private let segmentationQueue = DispatchQueue(label: "tasklens.segmentation", qos: .utility)
    private let segmentationContext = CIContext()
    private var segmentationBusy = false
    private var segmentationGeneration = UUID()
    private var lastSegmentationTime = -Double.infinity
    private var lastSegmentationError: String?

    private struct SegmentationInput {
        let id: UUID
        let box: NormalizedBox
        let isPart: Bool
    }
    private struct SegmentedTarget {
        let id: UUID
        let box: NormalizedBox
        let mask: CGImage
        let reanchorObject: Bool
    }
    private var configured = false
    private var input: AVCaptureDeviceInput?
    private var output: AVCaptureVideoDataOutput?
    private var desiredPosition: AVCaptureDevice.Position = .back
    private var frames: [BufferedFrame] = []
    private var lastFrameTime = -Double.infinity
    private final class TrackedTarget {
        let id: String
        var label: String
        var parentID: String?
        var source: Highlight.Source
        var kind: TargetKind?
        var pose: RotatedBox
        var tracker: VNTrackObjectRequest?
        var sequence: VNSequenceRequestHandler?
        let instanceID = UUID()
        var lossRevision = UUID()
        var history = ObjectSnapshotHistory()
        var activeAppearance: ObjectAppearance?
        var lastBox: NormalizedBox
        var lastVisionBox: NormalizedBox
        var lastFrameID: String?
        var stability = TrackingStability()
        var lastRotationCheck = -Double.infinity
        var lastAppearanceUpdate = -Double.infinity
        var lostAt: Double?
        var nextRecoveryTime = -Double.infinity
        var recoveryFramesRemaining = 0
        var recoveryAppearanceIndex = 0
        var foregroundMaskBox: NormalizedBox?
        var foregroundMask: CGImage?
        var foregroundMaskTime = -Double.infinity

        init(id: String, label: String, parentID: String?, source: Highlight.Source, box: NormalizedBox) {
            self.id = id; self.label = label; self.parentID = parentID; self.source = source
            pose = RotatedBox(box: box); lastBox = box; lastVisionBox = box
        }
    }
    private var targets: [TrackedTarget] = []
    private var activeHighlightIDs = Set<String>()
    private var focusedID: String?
    private var manualSelectionCount = 0

    func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            publishStatus("Allow camera access in iPhone Settings to start.")
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            do {
                if !self.configured { try self.configure() }
                if !self.session.isRunning { self.session.startRunning() }
                DispatchQueue.main.async { self.isRunning = true; self.status = "Camera live" }
            } catch { self.publishStatus(error.localizedDescription) }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.session.stopRunning()
            self.frames.removeAll()
            self.lastFrameTime = -Double.infinity
            self.resetTracking()
            DispatchQueue.main.async { self.isRunning = false; self.status = "Camera paused" }
        }
    }

    private func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .vga640x480
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: desiredPosition) else {
            throw TaskLensError.message("This camera is unavailable. Use a physical iPhone.")
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw TaskLensError.message("Could not open the camera.") }
        session.addInput(input)
        self.input = input
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw TaskLensError.message("Could not receive camera frames.") }
        session.addOutput(output)
        self.output = output
        guard orientOutput() else {
            throw TaskLensError.message("This camera cannot provide the required portrait frames.")
        }
        configured = true
    }

    /// Physically rotate buffers upright; the preview uses the same rotation. Buffers are never
    /// mirrored (even for the front camera) so text stays readable for the AI and every box
    /// coordinate refers to the same unmirrored image.
    private func orientOutput() -> Bool {
        guard let connection = output?.connection(with: .video), connection.isVideoRotationAngleSupported(90) else {
            return false
        }
        connection.videoRotationAngle = 90
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        return true
    }

    /// Switches between the rear and front cameras without stopping the session.
    func flipCamera() {
        queue.async { [weak self] in
            guard let self else { return }
            let next: AVCaptureDevice.Position = self.desiredPosition == .back ? .front : .back
            guard self.configured, let current = self.input else {
                // Not started yet: the next start() opens the chosen camera.
                self.desiredPosition = next
                DispatchQueue.main.async { self.position = next }
                return
            }
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: next),
                  let replacement = try? AVCaptureDeviceInput(device: device) else {
                self.publishStatus(next == .front ? "No front camera is available." : "No rear camera is available.")
                return
            }
            self.session.beginConfiguration()
            self.session.removeInput(current)
            guard self.session.canAddInput(replacement) else {
                self.session.addInput(current)
                self.session.commitConfiguration()
                self.publishStatus("Could not switch cameras.")
                return
            }
            self.session.addInput(replacement)
            self.input = replacement
            let oriented = self.orientOutput()
            self.session.commitConfiguration()
            self.desiredPosition = next
            // Frames from the previous camera must not be used for questions or tracking.
            self.frames.removeAll()
            self.lastFrameTime = -Double.infinity
            self.resetTracking()
            DispatchQueue.main.async {
                self.position = next
                self.status = oriented ? "Camera live" : "This camera cannot provide portrait frames."
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard time - lastFrameTime >= 0.16, let source = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrameTime = time
        // Copy out of AVFoundation's pool: retaining a ring of capture buffers can starve it.
        var owned: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source),
                                  kCVPixelFormatType_32BGRA, attributes, &owned) == kCVReturnSuccess,
              let pixels = owned else { return }
        context.render(CIImage(cvPixelBuffer: source), to: pixels)
        let frame = BufferedFrame(id: UUID().uuidString, date: Date(), time: time, pixels: pixels)
        frames.append(frame)
        if frames.count > 36 { frames.removeFirst(frames.count - 36) }
        // Vision's lightweight box tracker interpolates motion between fresh segmentations.
        // The experimental path does not run template/rotation scans alongside segmentation.
        for target in targets where target.tracker != nil {
            advanceTracker(target, on: frame, allowAppearanceCheck: false)
        }
        segmentForeground(on: frame)
        publishTargets(at: frame.time)

    }

    func snapshot(restartRecovery: Bool = false) async throws -> CapturedFrame {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self, let frame = self.frames.last, self.session.isRunning,
                      Date().timeIntervalSince(frame.date) < 1 else {
                    continuation.resume(throwing: TaskLensError.message("Wait for a fresh camera view, then try again."))
                    return
                }
                if restartRecovery {
                    for target in self.targets where target.tracker == nil {
                        target.lostAt = frame.time
                        target.nextRecoveryTime = frame.time
                        target.recoveryAppearanceIndex = 0
                        target.lossRevision = UUID()
                    }
                }
                let objects = self.objectContext(at: frame.time)
                // Do not make the next capture/tracking update wait for JPEG encoding.
                self.snapshotQueue.async {
                    autoreleasepool {
                        let image = CIImage(cvPixelBuffer: frame.pixels)
                        guard let cgImage = self.snapshotContext.createCGImage(image, from: image.extent),
                              let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.75) else {
                            continuation.resume(throwing: TaskLensError.message("Could not capture the camera view."))
                            return
                        }
                        continuation.resume(returning: CapturedFrame(id: frame.id, capturedAt: frame.date, jpeg: jpeg,
                            width: cgImage.width, height: cgImage.height, trackedObjects: objects))
                    }
                }
            }
        }
    }

    /// Adds or updates a stable target without replacing other tracked objects.
    func point(at box: NormalizedBox, frameID: String, label: String, source: Highlight.Source,
               id: String? = nil, parentID: String? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            if let id = self.seedTarget(at: box, frameID: frameID, label: label, source: source, id: id, parentID: parentID) {
                self.activeHighlightIDs.insert(id)
            }
            self.publishTargets(at: self.frames.last?.time ?? 0)
        }
    }

    /// Clear the previous answer's paint while preserving identity/focus for "it".
    func hideAnswerHighlights() {
        queue.async { [weak self] in
            guard let self else { return }
            self.activeHighlightIDs.removeAll()
            self.publishTargets(at: self.frames.last?.time ?? 0)
        }
    }

    /// Apply an answer atomically: retain identity memory, replace the visible scope,
    /// and seed every coordinate from the exact image the model actually saw.
    func showAnswerTargets(_ incoming: [Target], frameID: String) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: false); return }
                self.activeHighlightIDs.removeAll()
                self.focusedID = nil
                guard !incoming.isEmpty else {
                    self.publishTargets(at: self.frames.last?.time ?? 0)
                    continuation.resume(returning: true); return
                }
                guard incoming.count <= 6, self.session.isRunning,
                      self.frames.contains(where: { $0.id == frameID }) else {
                    self.publishTargets(at: self.frames.last?.time ?? 0)
                    self.publishStatus("The view changed. Hold the camera steady and ask again.")
                    continuation.resume(returning: false); return
                }
                let primary = HighlightPresentation.primary(incoming)
                var protected = Set(incoming.compactMap(\.id))
                // A known parent stays in memory even when only its button is lit.
                for item in incoming {
                    var parent = item.parentId
                    var seen = Set<String>()
                    while let id = parent, seen.insert(id).inserted {
                        protected.insert(id)
                        parent = self.targets.first(where: { $0.id == id })?.parentID
                    }
                }
                let newCount = incoming.filter { item in !self.targets.contains(where: { $0.id == item.id }) }.count
                while self.targets.count + newCount > 6,
                      let index = self.targets.firstIndex(where: { !protected.contains($0.id) }) {
                    let removed = self.targets.remove(at: index).id
                    for child in self.targets where child.parentID == removed { child.parentID = nil }
                }
                var shown = Set<String>()
                for item in incoming {
                    if let id = self.seedTarget(at: item.box, frameID: frameID, label: item.label,
                        source: .assistant, id: item.id, parentID: item.parentId, kind: item.resolvedKind),
                       primary.contains(where: { $0.id == item.id && $0.label == item.label }),
                       self.targets.contains(where: { $0.id == id && $0.tracker != nil && $0.recoveryFramesRemaining == 0 }) {
                        shown.insert(id)
                    }
                }
                self.activeHighlightIDs = shown
                self.focusedID = HighlightPresentation.focusedID(shown)
                self.publishTargets(at: self.frames.last?.time ?? 0)
                continuation.resume(returning: shown.count == primary.count)
            }
        }
    }

    func addSelection(at box: NormalizedBox, frameID: String) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: nil); return }
                self.manualSelectionCount += 1
                let existing = self.targets.first { $0.tracker != nil && self.overlap($0.lastBox, box) > 0.65 }
                let id = self.seedTarget(at: box, frameID: frameID,
                                         label: existing?.label ?? "Selection \(self.manualSelectionCount)",
                                         source: existing?.source ?? .user, id: existing?.id, parentID: existing?.parentID)
                if let id { self.activeHighlightIDs.insert(id) }
                self.publishTargets(at: self.frames.last?.time ?? 0)
                continuation.resume(returning: id)
            }
        }
    }

    private func seedTarget(at box: NormalizedBox, frameID: String, label: String, source: Highlight.Source,
                            id: String?, parentID: String?, kind: TargetKind? = nil) -> String? {
        guard let index = frames.firstIndex(where: { $0.id == frameID }), session.isRunning else {
            publishStatus("The view changed. Ask again to locate the item.")
            return nil
        }
        // Older backends have no IDs; reuse a matching label/region rather than duplicating it.
        let legacy = id == nil && source == .assistant ? targets.first(where: {
            $0.label.caseInsensitiveCompare(label) == .orderedSame || ($0.tracker != nil && overlap($0.lastBox, box) > 0.7)
        })?.id : nil
        let targetID = id ?? legacy ?? UUID().uuidString.lowercased()
        // A new visual answer is stronger evidence than the old tracker. Never
        // ignore corrected coordinates merely because an ID already exists.
        let previous = targets.first(where: { $0.id == targetID })
        let target = TrackedTarget(id: targetID, label: label, parentID: parentID, source: previous?.source ?? source, box: box)
        target.kind = kind ?? previous?.kind
        if let previous, previous.kind == target.kind { target.history = previous.history }
        if let existingIndex = targets.firstIndex(where: { $0.id == targetID }) { targets.remove(at: existingIndex) }
        if targets.count >= 6 {
            let parents = Set(targets.compactMap(\.parentID) + [parentID].compactMap { $0 })
            let evicted = targets.firstIndex { $0.tracker == nil && !parents.contains($0.id) }
                ?? targets.firstIndex { $0.id != focusedID && !parents.contains($0.id) }
            guard let evicted else { return nil }
            targets.remove(at: evicted)
        }
        targets.append(target)
        focusedID = target.id
        if let image = trackingImage(from: frames[index].pixels) {
            target.history.record(image: image, pose: target.pose, time: frames[index].time)
            target.lastAppearanceUpdate = frames[index].time
            target.activeAppearance = target.history.snapshots.last?.appearance
        }
        seedVision(target, box: box)
        for frame in frames[index...] {
            guard target.tracker != nil else { break }
            advanceTracker(target, on: frame, allowAppearanceCheck: false)
        }
        return target.id
    }

    private func seedVision(_ target: TrackedTarget, box: NormalizedBox) {
        let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: box.visionRect))
        request.trackingLevel = .accurate
        target.tracker = request
        target.sequence = VNSequenceRequestHandler()
    }

    private func advanceTracker(_ target: TrackedTarget, on frame: BufferedFrame, allowAppearanceCheck: Bool = true) {
        guard let tracker = target.tracker, let sequence = target.sequence else { return }
        do {
            try sequence.perform([tracker], on: frame.pixels, orientation: .up)
            let result = tracker.results?.first as? VNDetectedObjectObservation
            let confidence = result?.confidence ?? 0
            guard let result, let box = NormalizedBox.fromVision(result.boundingBox),
                  confidence >= (target.recoveryFramesRemaining > 0 ? 0.5 : 0.4) else {
                if target.recoveryFramesRemaining > 0 || target.stability.recordVision(min(confidence, 0.39)) {
                    loseTracking(target, at: frame.time)
                }
                return
            }
            if target.kind == .part {
                // Small controls must not drift onto their enclosing object.
                guard confidence >= 0.65 else { loseTracking(target, at: frame.time); return }
                if let parentID = target.parentID,
                   let parent = targets.first(where: { $0.id == parentID && $0.tracker != nil && $0.lastFrameID == frame.id }) {
                    let region = parent.lastBox.unitRect.insetBy(dx: -0.03, dy: -0.03)
                    let part = box.unitRect
                    guard region.contains(CGPoint(x: part.midX, y: part.midY)),
                          part.width * part.height < parent.lastBox.unitRect.width * parent.lastBox.unitRect.height * 0.85 else {
                        loseTracking(target, at: frame.time); return
                    }
                }
            }
            _ = target.stability.recordVision(confidence)
            let oldArea = target.lastVisionBox.unitRect.width * target.lastVisionBox.unitRect.height
            let newArea = box.unitRect.width * box.unitRect.height
            let scale = min(1.06, max(0.94, sqrt(newArea / max(oldArea, 0.00001))))
            var predicted = target.pose
            predicted.center = CGPoint(x: box.unitRect.midX, y: box.unitRect.midY)
            predicted.size = CGSize(width: predicted.size.width * scale, height: predicted.size.height * scale)
            let confirming = target.recoveryFramesRemaining > 0
            let checkInterval = target.id == focusedID ? 0.25 : 0.5
            let checkAppearance = allowAppearanceCheck && (confirming || frame.time - target.lastRotationCheck >= checkInterval)
            // Vision owns translation and scale. Appearance matching may update
            // orientation, but must not slowly crop/shrink the displayed object.
            target.pose = predicted
            if checkAppearance, let primary = target.activeAppearance ?? target.history.snapshots.last?.appearance,
               let image = trackingImage(from: frame.pixels) {
                func match(_ appearance: ObjectAppearance) -> (pose: RotatedBox, score: Float)? {
                    if let score = appearance.similarity(in: image, pose: predicted), score >= 0.9 { return (predicted, score) }
                    return appearance.follow(in: image, near: predicted, allowScale: false)
                }
                var reference = primary
                var matched = match(primary)
                // During confirmation, never switch away from the snapshot that
                // actually found this object. That used to reject valid recoveries.
                if !confirming, (matched?.score ?? -1) < 0.8 {
                    let remembered = target.history.snapshots.compactMap { snapshot -> (ObjectAppearance, Float)? in
                        guard let score = snapshot.appearance.similarity(in: image, pose: predicted) else { return nil }
                        return (snapshot.appearance, score)
                    }.max { $0.1 < $1.1 }
                    if let remembered, let candidate = match(remembered.0), candidate.score > (matched?.score ?? -1) {
                        matched = candidate; reference = remembered.0
                    }
                }
                target.lastRotationCheck = frame.time
                if confirming && (matched?.score ?? -1) < 0.78 {
                    loseTracking(target, at: frame.time); return
                }
                if target.stability.recordAppearance(matched?.score, visionConfidence: confidence) {
                    loseTracking(target, at: frame.time); return
                }
                if let matched, matched.score >= 0.7 {
                    target.pose.angle = matched.pose.angle
                    target.activeAppearance = reference
                    if !confirming, (matched.score >= 0.8 && confidence >= 0.75 || matched.score >= 0.7 && confidence >= 0.9),
                       frame.time - target.lastAppearanceUpdate >= 1 {
                        target.history.record(image: image, pose: target.pose, time: frame.time)
                        target.lastAppearanceUpdate = frame.time
                        target.activeAppearance = target.history.snapshots.last?.appearance ?? reference
                    }
                }
            } else if allowAppearanceCheck, target.history.snapshots.isEmpty, confidence >= 0.8,
                      frame.time - target.lastAppearanceUpdate >= 1, let image = trackingImage(from: frame.pixels) {
                target.history.record(image: image, pose: target.pose, time: frame.time)
                target.lastAppearanceUpdate = frame.time
                target.activeAppearance = target.history.snapshots.last?.appearance
            }
            target.lastVisionBox = box
            target.lastFrameID = frame.id
            target.lastBox = target.pose.boundingBox(aspect: CGFloat(CVPixelBufferGetWidth(frame.pixels)) / CGFloat(CVPixelBufferGetHeight(frame.pixels))) ?? box
            // Preserve Vision's own observation. Rotated overlay estimates must not
            // repeatedly overwrite its internal positional tracking region.
            tracker.inputObservation = result
            if target.recoveryFramesRemaining > 0 { target.recoveryFramesRemaining -= 1 }
            if target.recoveryFramesRemaining == 0 { target.lostAt = nil }
        } catch {
            if target.recoveryFramesRemaining > 0 || target.stability.recordVision(0) {
                loseTracking(target, at: frame.time)
            }
        }
    }

    private func loseTracking(_ target: TrackedTarget, at time: Double) {
        target.tracker = nil; target.sequence = nil; target.recoveryFramesRemaining = 0
        if target.lostAt == nil {
            target.lostAt = time; target.nextRecoveryTime = time; target.recoveryAppearanceIndex = 0
            target.lossRevision = UUID()
        }
    }

    private func attemptRecovery(_ target: TrackedTarget, on frame: BufferedFrame) {
        guard recoveryWorkID == nil, let lostAt = target.lostAt,
              let interval = TrackingRecoveryPolicy.interval(after: frame.time - lostAt) else { return }
        target.nextRecoveryTime = frame.time + interval
        guard !target.history.snapshots.isEmpty, let image = trackingImage(from: frame.pixels) else { return }
        let history = target.history
        let allowGlobalSearch = frame.time - lostAt >= 5
        let attempt = target.recoveryAppearanceIndex
        target.recoveryAppearanceIndex += 1
        let previousPose = target.pose
        let sourceFrameID = frame.id
        let instanceID = target.instanceID, lossRevision = target.lossRevision, targetID = target.id
        let workID = UUID()
        recoveryWorkID = workID
        // This scan must never run on the capture/snapshot queue. The worker receives
        // only immutable low-resolution values, not live tracker/session objects.
        recoveryQueue.async { [weak self] in
            let recovered = autoreleasepool {
                history.recoverMatch(in: image, near: previousPose, attempt: attempt, allowGlobalSearch: allowGlobalSearch)
            }
            guard let self else { return }
            self.queue.async {
                if self.recoveryWorkID == workID { self.recoveryWorkID = nil }
                guard let recovered, self.session.isRunning,
                      let current = self.targets.first(where: { $0.id == targetID && $0.instanceID == instanceID }),
                      current.lossRevision == lossRevision, current.tracker == nil,
                      let currentTime = self.frames.last?.time, let lostAt = current.lostAt,
                      TrackingRecoveryPolicy.interval(after: currentTime - lostAt) != nil,
                      let index = self.frames.firstIndex(where: { $0.id == sourceFrameID }),
                      let box = recovered.pose.boundingBox(aspect: image.aspect) else { return }
                current.activeAppearance = recovered.snapshot.appearance
                current.pose = recovered.pose; current.lastBox = box; current.lastVisionBox = box
                current.stability = TrackingStability()
                self.seedVision(current, box: box)
                current.recoveryFramesRemaining = 3
                // Advance from the worker's actual source frame, never install its old
                // coordinates directly on the newest frame.
                for replay in self.frames[index...] {
                    guard current.tracker != nil else { break }
                    self.advanceTracker(current, on: replay, allowAppearanceCheck: current.recoveryFramesRemaining > 0)
                }
                self.publishTargets(at: currentTime)
            }
        }
    }

    /// Bounded worker: no queued frames, no network calls, no work on the capture queue.
    private func segmentForeground(on frame: BufferedFrame) {
        guard !segmentationBusy, frame.time - lastSegmentationTime >= 0.4 else { return }
        let inputs = targets.filter {
            // Geometry alone cannot prove that a lost bottle is the same bottle.
            // Re-identify it on the next camera question instead of mask-only recovery.
            activeHighlightIDs.contains($0.id) && $0.tracker != nil && $0.recoveryFramesRemaining == 0
        }.sorted {
            $0.lastBox.unitRect.width * $0.lastBox.unitRect.height < $1.lastBox.unitRect.width * $1.lastBox.unitRect.height
        }.map { SegmentationInput(id: $0.instanceID, box: $0.lastBox, isPart: $0.kind == .part) }
        guard !inputs.isEmpty else { return }
        let inputIDs = Set(inputs.map(\.id))
        for target in targets where target.tracker == nil && inputIDs.contains(target.instanceID) {
            target.nextRecoveryTime = frame.time + 1
        }
        segmentationBusy = true
        lastSegmentationTime = frame.time
        let generation = segmentationGeneration
        segmentationQueue.async { [weak self] in
            guard let self else { return }
            let result: Result<[SegmentedTarget], Error> = Result {
                try autoreleasepool { try self.foregroundMasks(on: frame, inputs: inputs) }
            }
            self.queue.async {
                self.segmentationBusy = false
                guard self.segmentationGeneration == generation,
                      let newest = self.frames.last, self.session.isRunning else { return }
                switch result {
                case .failure(let error):
                    // Developers retain the diagnostic; speech never receives Vision internals.
                    let message = error.localizedDescription
                    if self.lastSegmentationError != message {
                        NSLog("TaskLens foreground segmentation failed: %@", message)
                        self.lastSegmentationError = message
                    }
                case .success(let masks):
                    self.lastSegmentationError = nil
                    // Never display masks inferred from a camera view that is already stale.
                    guard newest.time - frame.time < 0.8,
                          let sourceIndex = self.frames.firstIndex(where: { $0.id == frame.id }) else { return }
                    for match in masks {
                        guard let target = self.targets.first(where: { $0.instanceID == match.id }) else { continue }
                        guard target.tracker != nil else { continue }
                        if match.reanchorObject {
                            // Fresh whole-object silhouettes correct positional drift.
                            // Parts never get expanded to an enclosing object's bounds.
                            target.pose = RotatedBox(box: match.box)
                            target.lastBox = match.box; target.lastVisionBox = match.box
                            target.stability = TrackingStability()
                            self.seedVision(target, box: match.box)
                            for replay in self.frames[sourceIndex...] {
                                guard target.tracker != nil else { break }
                                self.advanceTracker(target, on: replay, allowAppearanceCheck: false)
                            }
                        }
                        target.foregroundMaskBox = match.box
                        target.foregroundMask = match.mask
                        target.foregroundMaskTime = frame.time
                    }
                    self.publishTargets(at: newest.time)
                }
            }
        }
    }

    private func foregroundMasks(on frame: BufferedFrame, inputs: [SegmentationInput]) throws -> [SegmentedTarget] {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.pixels, orientation: .up)
        try handler.perform([request])
        guard let observation = request.results?.first else { return [] }
        var instances: [(index: Int, box: NormalizedBox)] = []
        // Use Vision's per-instance masks, not the instance-label buffer.
        for index in observation.allInstances {
            let mask = try observation.generateMask(forInstances: IndexSet(integer: index))
            if let box = Self.foregroundBounds(mask) { instances.append((index, box)) }
        }
        var claimed = Set<Int>()
        var results: [SegmentedTarget] = []
        for input in inputs {
            let available = instances.filter { !claimed.contains($0.index) }
            guard let selected = ForegroundAssociation.match(target: input.box.unitRect,
                                                             candidates: available.map { $0.box.unitRect }, isPart: input.isPart) else { continue }
            let instance = available[selected]
            let mask = try observation.generateScaledMaskForImage(forInstances: IndexSet(integer: instance.index), from: handler)
            let image = CIImage(cvPixelBuffer: mask)
            guard let cgImage = segmentationContext.createCGImage(image, from: image.extent,
                format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()) else { continue }
            results.append(SegmentedTarget(id: input.id, box: input.isPart ? input.box : instance.box, mask: cgImage, reanchorObject: !input.isPart))
            claimed.insert(instance.index)
        }
        return results
    }

    /// Mask rows, like our upright camera buffers and API coordinates, start at the top.
    static func foregroundBounds(_ mask: CVPixelBuffer) -> NormalizedBox? {
        let format = CVPixelBufferGetPixelFormatType(mask)
        guard [kCVPixelFormatType_OneComponent32Float, kCVPixelFormatType_OneComponent8].contains(format),
              CVPixelBufferLockBaseAddress(mask, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let width = CVPixelBufferGetWidth(mask), height = CVPixelBufferGetHeight(mask)
        let stride = CVPixelBufferGetBytesPerRow(mask)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = base.advanced(by: y * stride)
            for x in 0..<width {
                let foreground = format == kCVPixelFormatType_OneComponent32Float
                    ? row.assumingMemoryBound(to: Float.self)[x] >= 0.5
                    : row.assumingMemoryBound(to: UInt8.self)[x] >= 128
                guard foreground else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return NormalizedBox([Double(minY) / Double(height) * 1000, Double(minX) / Double(width) * 1000,
            Double(maxY + 1) / Double(height) * 1000, Double(maxX + 1) / Double(width) * 1000])
    }

    private func overlap(_ a: NormalizedBox, _ b: NormalizedBox) -> CGFloat {
        let intersection = a.unitRect.intersection(b.unitRect)
        let area = intersection.isNull ? 0 : intersection.width * intersection.height
        let union = a.unitRect.width * a.unitRect.height + b.unitRect.width * b.unitRect.height - area
        return union > 0 ? area / union : 0
    }

    private func objectContext(at time: Double) -> [TrackedObjectContext] {
        targets.map { target in
            let visible = target.tracker != nil && target.recoveryFramesRemaining == 0
            let recovering = target.lostAt.map { TrackingRecoveryPolicy.interval(after: time - $0) != nil } ?? false
            return TrackedObjectContext(id: target.id, label: target.label, parentId: target.parentID,
                source: target.source.rawValue, state: visible ? "visible" : recovering ? "searching" : "dormant",
                box: visible ? target.lastBox : nil, isFocused: target.id == focusedID, kind: target.kind)
        }
    }

    private func publishTargets(at time: Double) {
        let visible = targets.filter {
            activeHighlightIDs.contains($0.id) && $0.tracker != nil && $0.recoveryFramesRemaining == 0
        }.map {
            Highlight(id: $0.id, label: $0.label, source: $0.source, pose: $0.pose,
                      isFocused: $0.id == focusedID, kind: $0.kind ?? .object,
                      mask: time - $0.foregroundMaskTime < 0.8 ? $0.foregroundMask : nil,
                      maskBox: time - $0.foregroundMaskTime < 0.8 ? $0.foregroundMaskBox : nil)
        }
        let objects = objectContext(at: time)
        DispatchQueue.main.async { self.highlights = visible; self.trackedObjects = objects }
    }

    func forgetTarget(_ id: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.targets.removeAll { $0.id == id }
            self.activeHighlightIDs.remove(id)
            for child in self.targets where child.parentID == id { child.parentID = nil }
            if self.focusedID == id { self.focusedID = self.targets.last?.id }
            self.publishTargets(at: self.frames.last?.time ?? 0)
        }
    }

    private func trackingImage(from pixels: CVPixelBuffer) -> TrackingImage? {
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
        let sourceWidth = CVPixelBufferGetWidth(pixels), sourceHeight = CVPixelBufferGetHeight(pixels)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        let width = min(96, sourceWidth)
        let height = min(192, max(1, sourceHeight * width / sourceWidth))
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let sourceY = min(sourceHeight - 1, (2 * y + 1) * sourceHeight / (2 * height))
            for x in 0..<width {
                let sourceX = min(sourceWidth - 1, (2 * x + 1) * sourceWidth / (2 * width))
                let offset = sourceY * rowBytes + sourceX * 4
                values[y * width + x] = (0.2126 * Float(bytes[offset + 2]) + 0.7152 * Float(bytes[offset + 1])
                                         + 0.0722 * Float(bytes[offset])) / 255
            }
        }
        return TrackingImage(width: width, height: height, values: values)
    }

    func clearHighlight() { queue.async { [weak self] in self?.resetTracking() } }

    private func resetTracking() {
        segmentationGeneration = UUID()
        lastSegmentationTime = -Double.infinity
        targets.removeAll(); activeHighlightIDs.removeAll(); focusedID = nil
        DispatchQueue.main.async { self.highlights = []; self.trackedObjects = [] }
    }

    private func publishStatus(_ value: String) { DispatchQueue.main.async { self.status = value } }
}
