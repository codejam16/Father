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
    @Published private(set) var highlight: Highlight?
    @Published private(set) var aspectRatio: CGFloat = 0.75
    /// Which camera is live. Frames are never mirrored; the front preview is mirrored on screen only.
    @Published private(set) var position: AVCaptureDevice.Position = .back

    private struct BufferedFrame {
        let id: String
        let date: Date
        let time: Double
        let pixels: CVPixelBuffer
    }

    /// The newest frame at full resolution, for questions and step checks. Only this one camera
    /// buffer is retained; the ring below holds small copies for tracking and change detection.
    private var latestFull: (id: String, date: Date, pixels: CVPixelBuffer)?
    private var lastAspect: CGFloat = 0
    /// Frames that were sent to the AI, kept even after they leave the ring, so a slow answer's box still has its frame.
    private var sentFrames: [BufferedFrame] = []

    private func rememberSent(_ frame: BufferedFrame) {
        guard !sentFrames.contains(where: { $0.id == frame.id }) else { return }
        sentFrames.append(frame)
        if sentFrames.count > 6 { sentFrames.removeFirst(sentFrames.count - 6) }
    }

    private let queue = DispatchQueue(label: "tasklens.camera", qos: .userInitiated)
    private let context = CIContext()
    private var configured = false
    private var input: AVCaptureDeviceInput?
    private var output: AVCaptureVideoDataOutput?
    private var desiredPosition: AVCaptureDevice.Position = .back
    private var frames: [BufferedFrame] = []
    private var lastFrameTime = -Double.infinity
    private var tracker: VNTrackObjectRequest?

    // MARK: Pointing while talking ("how do I get from this… to this?")
    /// Fingertip positions seen while the user is talking (unit, top-left origin), newest last.
    private var pointerLog: [(date: Date, point: CGPoint)] = []
    private var pointerEnabled = false
    private var lastPointerTime = -Double.infinity
    private var sequence: VNSequenceRequestHandler?
    private var trackingID: UUID?
    private var trackingLabel = ""
    private var trackingSource: Highlight.Source = .assistant
    private var trackingUntil = Date.distantPast

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
            self.sentFrames.removeAll()
            self.latestFull = nil
            self.lastFrameTime = -Double.infinity
            self.lastSignature = nil
            self.resetTracking()
            DispatchQueue.main.async { self.isRunning = false; self.status = "Camera paused" }
        }
    }

    private func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: desiredPosition) else {
            throw TaskLensError.message("This camera is unavailable. Use a physical iPhone.")
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw TaskLensError.message("Could not open the camera.") }
        session.addInput(input)
        self.input = input
        // 720p: a much sharper preview and clearer images for the AI. Older/limited cameras fall back to VGA.
        // 1080p keeps small details (keys, labels) readable in close-ups; older cameras fall back.
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else {
            session.sessionPreset = .vga640x480
        }
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
            // Frames from the previous camera must not be used for questions, tracking or watching.
            self.lastSignature = nil
            self.watchReference = nil
            self.latestFull = nil
            self.sentFrames.removeAll()
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
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard width > 0, height > 0 else { return }
        let aspect = CGFloat(width) / CGFloat(height)
        if abs(aspect - lastAspect) > 0.001 {
            lastAspect = aspect
            DispatchQueue.main.async { self.aspectRatio = aspect }
        }
        // Copy out of AVFoundation's pool (retaining a ring of capture buffers can starve it),
        // scaled down to at most 640 px: plenty for tracking and change detection, and light on memory.
        let scale = min(1, 640 / CGFloat(max(width, height)))
        let smallWidth = max(1, Int((CGFloat(width) * scale).rounded()))
        let smallHeight = max(1, Int((CGFloat(height) * scale).rounded()))
        var owned: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, smallWidth, smallHeight,
                                  kCVPixelFormatType_32BGRA, attributes, &owned) == kCVReturnSuccess,
              let pixels = owned else { return }
        var image = CIImage(cvPixelBuffer: source)
        if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        context.render(image, to: pixels)
        let frame = BufferedFrame(id: UUID().uuidString, date: Date(), time: time, pixels: pixels)
        latestFull = (frame.id, frame.date, source)
        frames.append(frame)
        // About 10 seconds of small frames, so slow answers can still be matched to the view they describe.
        if frames.count > 60 { frames.removeFirst(frames.count - 60) }
        observeActivity(pixels, time: time)
        // About 4 times a second while listening: where is the fingertip?
        if pointerEnabled, time - lastPointerTime >= 0.25 {
            lastPointerTime = time
            if let tip = Self.fingertip(in: pixels) { pointerLog.append((Date(), tip)) }
            let cutoff = Date().addingTimeInterval(-30)
            pointerLog.removeAll { $0.date < cutoff }
        }
        if tracker != nil {
            if Date() >= trackingUntil { resetTracking() }
            else { advanceTracker(on: pixels) }
        }
    }

    // MARK: Guided-mode watching (on the phone, no network)

    /// Called on the main thread when the view settles after the user was working in it.
    var onSettled: (() -> Void)?
    private var watching = false
    private var lastSignature: [Float]?
    private var watchReference: [Float]?
    private var stillSince: Double?
    private var changedSince: Double?
    // Tuning values (0–255 brightness units); validate on a real device.
    /// Frame-to-frame difference above this counts as movement (tolerates hand-held jitter).
    private static let motionThreshold: Float = 9
    /// Difference from the step's reference view that counts as "something changed" (a click, a part removed).
    private static let changeThreshold: Float = 3
    private static let settleSeconds = 1.0
    /// A change that persists this long triggers a check even if the view never stops moving.
    private static let changeHoldSeconds = 4.0

    /// Starts or stops watching. `resetReference` marks the current view as the step's starting point.
    func setWatching(_ enabled: Bool, resetReference: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            let changed = enabled != self.watching
            if resetReference || (enabled && changed) { self.watchReference = self.lastSignature }
            if resetReference || changed {
                self.stillSince = nil
                self.changedSince = nil
            }
            self.watching = enabled
        }
    }

    /// A check is worth making when the view differs from the step's starting view and has either
    /// settled (the user stopped moving, e.g. after a click or removing a part) or stayed different for a
    /// few seconds. Small screen changes count too, not only big hand movements.
    private func observeActivity(_ pixels: CVPixelBuffer, time: Double) {
        guard let signature = Self.signature(of: pixels) else { return }
        let previous = lastSignature
        lastSignature = signature
        guard watching, let previous else { return }
        guard let reference = watchReference else {
            watchReference = signature
            return
        }
        if Self.difference(signature, previous) > Self.motionThreshold {
            stillSince = nil
        } else if stillSince == nil {
            stillSince = time
        }
        guard Self.difference(signature, reference) > Self.changeThreshold else {
            changedSince = nil
            return
        }
        if changedSince == nil { changedSince = time }
        let settled = stillSince.map { time - $0 >= Self.settleSeconds } ?? false
        let persistent = changedSince.map { time - $0 >= Self.changeHoldSeconds } ?? false
        guard settled || persistent else { return }
        watchReference = signature
        changedSince = nil
        DispatchQueue.main.async { self.onSettled?() }
    }

    /// A 16×12 grid of local brightness averages, with the overall brightness removed so
    /// auto-exposure changes are not mistaken for activity.
    private static func signature(of buffer: CVPixelBuffer) -> [Float]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 8, height > 8 else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var values: [Float] = []
        values.reserveCapacity(192)
        for gridY in 0..<12 {
            for gridX in 0..<16 {
                let centerX = (2 * gridX + 1) * width / 32
                let centerY = (2 * gridY + 1) * height / 24
                var sum = 0
                for offsetY in -1...1 {
                    for offsetX in -1...1 {
                        let x = min(max(centerX + offsetX * 2, 0), width - 1)
                        let y = min(max(centerY + offsetY * 2, 0), height - 1)
                        let pixel = bytes + y * rowBytes + x * 4
                        sum += Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])
                    }
                }
                values.append(Float(sum) / 27)
            }
        }
        let mean: Float = values.reduce(0, +) / Float(values.count)
        return values.map { $0 - mean }
    }

    private static func difference(_ first: [Float], _ second: [Float]) -> Float {
        guard first.count == second.count, !first.isEmpty else { return Float.greatestFiniteMagnitude }
        var total: Float = 0
        for index in first.indices { total += abs(first[index] - second[index]) }
        return total / Float(first.count)
    }

    /// Up to `count` recent frames about `spacing` seconds apart, oldest first, for a step check.
    func recentFrames(count: Int, spacing: TimeInterval) async throws -> [CapturedFrame] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self, let latest = self.frames.last, self.session.isRunning,
                      Date().timeIntervalSince(latest.date) < 1 else {
                    continuation.resume(throwing: TaskLensError.message("Wait for a fresh camera view, then try again."))
                    return
                }
                var picked: [BufferedFrame] = []
                for index in stride(from: count - 1, through: 0, by: -1) {
                    let target = latest.date.addingTimeInterval(-spacing * Double(index))
                    let nearest = self.frames.min(by: {
                        abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target))
                    })
                    if let nearest, !picked.contains(where: { $0.id == nearest.id }) { picked.append(nearest) }
                }
                if let newest = picked.last { self.rememberSent(newest) }
                let encoded: [CapturedFrame] = picked.compactMap { self.encode($0, quality: 0.75) }
                if encoded.isEmpty {
                    continuation.resume(throwing: TaskLensError.message("Could not capture the camera view."))
                } else {
                    continuation.resume(returning: encoded)
                }
            }
        }
    }

    /// JPEG for the AI. The newest frame is encoded at full resolution; older ones from the small copies.
    /// Boxes are normalized (0–1000), so both map onto the same tracked frame.
    private func encode(_ frame: BufferedFrame, quality: CGFloat) -> CapturedFrame? {
        let pixels = latestFull?.id == frame.id ? latestFull!.pixels : frame.pixels
        var image = CIImage(cvPixelBuffer: pixels)
        // The whole view never needs more than 1280 px; fine detail goes in the separate close-up.
        let longSide = max(image.extent.width, image.extent.height)
        if longSide > 1280 {
            let scale = 1280 / longSide
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let cgImage = context.createCGImage(image, from: image.extent),
              let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: quality) else { return nil }
        return CapturedFrame(id: frame.id, capturedAt: frame.date, jpeg: jpeg, width: cgImage.width, height: cgImage.height)
    }

    /// The newest frame, plus (when a fingertip is visible) a sharp close-up around it cut from the
    /// full-resolution frame, so the AI can read small things like individual keys.
    func snapshotWithDetail() async throws -> (CapturedFrame, CapturedDetail?) {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self, let frame = self.frames.last, self.session.isRunning,
                      Date().timeIntervalSince(frame.date) < 1 else {
                    continuation.resume(throwing: TaskLensError.message("Wait for a fresh camera view, then try again."))
                    return
                }
                self.rememberSent(frame)
                guard let captured = self.encode(frame, quality: 0.75) else {
                    continuation.resume(throwing: TaskLensError.message("Could not capture the camera view."))
                    return
                }
                var detail: CapturedDetail?
                if let full = self.latestFull, full.id == frame.id, let spot = Self.fingertip(in: frame.pixels) {
                    detail = self.closeUp(of: full.pixels, around: spot)
                }
                continuation.resume(returning: (captured, detail))
            }
        }
    }

    /// Watch for a pointing finger while the microphone is listening (cheap: a few hand-pose passes a second).
    func setPointerTracking(_ on: Bool) {
        queue.async { [weak self] in
            guard let self, self.pointerEnabled != on else { return }
            self.pointerEnabled = on
            if !on { self.pointerLog.removeAll() }
        }
    }

    /// The distinct spots the fingertip rested on since `start`, in the order they were pointed at
    /// (at most 4), as unit points. "From this to this" gives [first spot, second spot].
    func pointedSpots(since start: Date) async -> [CGPoint] {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                let samples = self?.pointerLog.filter { $0.date >= start }.map(\.point) ?? []
                continuation.resume(returning: Self.restingSpots(in: samples))
            }
        }
    }

    /// Groups fingertip samples into places the finger stayed (at least two samples ≈ half a second).
    static func restingSpots(in samples: [CGPoint]) -> [CGPoint] {
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        var groups: [[CGPoint]] = []
        var current: [CGPoint] = []
        func mean(_ points: [CGPoint]) -> CGPoint {
            CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                    y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
        }
        for sample in samples {
            if current.isEmpty || distance(sample, mean(current)) < 0.05 { current.append(sample) }
            else { groups.append(current); current = [sample] }
        }
        if !current.isEmpty { groups.append(current) }
        var spots: [(point: CGPoint, weight: Int)] = []
        for group in groups where group.count >= 2 {
            let center = mean(group)
            // Came back to (nearly) the same place: still the same spot.
            if let last = spots.last, distance(last.point, center) < 0.07 {
                spots[spots.count - 1].weight += group.count
            } else {
                spots.append((center, group.count))
            }
        }
        if spots.isEmpty, let last = samples.last { return [last] }
        if spots.count > 4 {
            // Keep the first and last, plus the two places the finger stayed longest, in order.
            let middle = spots[1..<(spots.count - 1)].enumerated().sorted { $0.element.weight > $1.element.weight }
                .prefix(2).map(\.offset).sorted().map { spots[$0 + 1] }
            spots = [spots[0]] + middle + [spots[spots.count - 1]]
        }
        return spots.map(\.point)
    }

    /// Where an index fingertip points (a little beyond the tip, along the finger), in unit
    /// top-left coordinates. One hand-pose pass on a small frame; nothing is shown on screen.
    private static func fingertip(in pixels: CVPixelBuffer) -> CGPoint? {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up)
        guard (try? handler.perform([request])) != nil, let hand = request.results?.first,
              let points = try? hand.recognizedPoints(.all),
              let tip = points[.indexTip], tip.confidence > 0.3 else { return nil }
        let tipPoint = CGPoint(x: tip.location.x, y: 1 - tip.location.y)
        guard let pip = points[.indexPIP], pip.confidence > 0.3 else { return tipPoint }
        let pipPoint = CGPoint(x: pip.location.x, y: 1 - pip.location.y)
        return CGPoint(x: min(max(tipPoint.x + (tipPoint.x - pipPoint.x) * 0.4, 0), 1),
                       y: min(max(tipPoint.y + (tipPoint.y - pipPoint.y) * 0.4, 0), 1))
    }

    /// A square close-up (about 40% of the frame's short side) around `point`, at full resolution.
    private func closeUp(of pixels: CVPixelBuffer, around point: CGPoint) -> CapturedDetail? {
        let width = CGFloat(CVPixelBufferGetWidth(pixels))
        let height = CGFloat(CVPixelBufferGetHeight(pixels))
        let side = (min(width, height) * 0.42).rounded()
        guard side >= 64 else { return nil }
        let originX = min(max(point.x * width - side / 2, 0), width - side).rounded()
        let originY = min(max(point.y * height - side / 2, 0), height - side).rounded()
        // Core Image measures from the bottom-left corner.
        let rect = CGRect(x: originX, y: height - originY - side, width: side, height: side)
        let image = CIImage(cvPixelBuffer: pixels)
        func unit(_ value: CGFloat) -> Double { Double(min(max(value, 0), 1000)) }
        guard let cgImage = context.createCGImage(image, from: rect),
              let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85),
              let box = NormalizedBox([unit(originY / height * 1000), unit(originX / width * 1000),
                                       unit((originY + side) / height * 1000), unit((originX + side) / width * 1000)]) else { return nil }
        return CapturedDetail(jpeg: jpeg, width: cgImage.width, height: cgImage.height, box: box)
    }

    func snapshot() async throws -> CapturedFrame {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self, let frame = self.frames.last, self.session.isRunning,
                      Date().timeIntervalSince(frame.date) < 1 else {
                    continuation.resume(throwing: TaskLensError.message("Wait for a fresh camera view, then try again."))
                    return
                }
                self.rememberSent(frame)
                guard let captured = self.encode(frame, quality: 0.75) else {
                    continuation.resume(throwing: TaskLensError.message("Could not capture the camera view."))
                    return
                }
                continuation.resume(returning: captured)
            }
        }
    }

    /// Seeds the original image and replays retained frames before going live.
    /// An expired source frame is never interpreted as a current-frame location.
    /// `duration`: how long the highlight follows the object before it fades (longer during guided steps).
    func point(at box: NormalizedBox, frameID: String, label: String, source: Highlight.Source, duration: TimeInterval = 5) {
        queue.async { [weak self] in
            guard let self else { return }
            self.resetTracking()
            guard self.session.isRunning, let latest = self.frames.last else { return }
            // The frame the box was drawn on: still in the ring, or kept because it was sent to the AI.
            let sourceFrame: BufferedFrame
            let replay: [BufferedFrame]
            if let index = self.frames.firstIndex(where: { $0.id == frameID }) {
                sourceFrame = self.frames[index]
                replay = Array(self.frames[(index + 1)...])
            } else if let kept = self.sentFrames.first(where: { $0.id == frameID }) {
                sourceFrame = kept
                replay = self.frames
            } else {
                self.publishStatus("The view changed. Ask again to locate the item.")
                return
            }
            let id = UUID()
            self.trackingID = id
            self.trackingLabel = label
            self.trackingSource = source
            self.trackingUntil = Date().addingTimeInterval(duration)

            // Follow the object from the answer's frame to now.
            let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: box.visionRect))
            request.trackingLevel = .accurate
            self.tracker = request
            self.sequence = VNSequenceRequestHandler()
            self.advanceTracker(on: sourceFrame.pixels, publish: false)
            for frame in replay {
                guard self.tracker != nil else { break }
                self.advanceTracker(on: frame.pixels, publish: false)
            }
            var tracked: NormalizedBox?
            if self.tracker != nil, let result = self.tracker?.results?.first as? VNDetectedObjectObservation {
                tracked = NormalizedBox.fromVision(result.boundingBox)
            }

            // If the camera has barely moved since the answer's frame, the AI's own box is still right.
            // Use it when following failed, and when "following" wandered off while the view stayed put
            // (drifting onto a similar-looking thing, common on screens).
            let viewUnchanged: Bool = {
                guard let before = Self.signature(of: sourceFrame.pixels), let now = Self.signature(of: latest.pixels) else { return false }
                return Self.difference(before, now) < 5
            }()
            let shown: NormalizedBox
            if let tracked, !(viewUnchanged && Self.centerDistance(tracked, box) > 0.12) {
                shown = tracked
            } else if viewUnchanged {
                shown = box
                self.restartTracking(at: box, on: latest)
            } else {
                self.resetTracking()
                self.publishStatus("The view changed. Ask again to locate the item.")
                return
            }
            // A failed replay may have cleared these; the highlight still needs its expiry.
            self.trackingID = id
            self.trackingLabel = label
            self.trackingSource = source
            self.publishHighlight(shown)
            self.queue.asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let self, self.trackingID == id else { return }
                self.resetTracking()
            }
        }
    }

    /// Starts following `box` from the latest frame. If that fails, the box stays where it is until it expires.
    private func restartTracking(at box: NormalizedBox, on frame: BufferedFrame) {
        let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: box.visionRect))
        request.trackingLevel = .accurate
        let handler = VNSequenceRequestHandler()
        do {
            try handler.perform([request], on: frame.pixels, orientation: .up)
            if let result = request.results?.first as? VNDetectedObjectObservation { request.inputObservation = result }
            tracker = request
            sequence = handler
        } catch {
            tracker = nil
            sequence = nil
        }
    }

    private static func centerDistance(_ first: NormalizedBox, _ second: NormalizedBox) -> CGFloat {
        let a = first.unitRect
        let b = second.unitRect
        return hypot(a.midX - b.midX, a.midY - b.midY)
    }

    private func advanceTracker(on pixels: CVPixelBuffer, publish: Bool = true) {
        guard let tracker, let sequence else { return }
        do {
            try sequence.perform([tracker], on: pixels, orientation: .up)
            guard let result = tracker.results?.first as? VNDetectedObjectObservation,
                  // Replaying the seconds the AI was thinking is bumpier (blur, motion), so it gets a
                  // more forgiving threshold; live tracking stays moderately strict to limit drift.
                  result.confidence >= (publish ? 0.5 : 0.3),
                  let box = NormalizedBox.fromVision(result.boundingBox) else {
                resetTracking()
                publishStatus("Lost the pointer. Ask again or point to the item.")
                return
            }
            tracker.inputObservation = result
            if publish { publishHighlight(box) }
        } catch {
            resetTracking()
            publishStatus("Could not follow that item. Ask again to locate it.")
        }
    }

    func clearHighlight() { queue.async { [weak self] in self?.resetTracking() } }

    private func resetTracking() {
        tracker = nil
        sequence = nil
        trackingID = nil
        DispatchQueue.main.async { self.highlight = nil }
    }

    private func publishHighlight(_ box: NormalizedBox) {
        let item = Highlight(box: box, label: trackingLabel, source: trackingSource)
        DispatchQueue.main.async { self.highlight = item; self.status = "Camera live" }
    }

    private func publishStatus(_ value: String) { DispatchQueue.main.async { self.status = value } }
}
