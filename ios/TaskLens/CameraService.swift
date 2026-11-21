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

    private struct BufferedFrame {
        let id: String
        let date: Date
        let time: Double
        let pixels: CVPixelBuffer
    }

    private let queue = DispatchQueue(label: "tasklens.camera", qos: .userInitiated)
    private let context = CIContext()
    private var configured = false
    private var frames: [BufferedFrame] = []
    private var lastFrameTime = -Double.infinity
    private var tracker: VNTrackObjectRequest?
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
            self.lastFrameTime = -Double.infinity
            self.resetTracking()
            DispatchQueue.main.async { self.isRunning = false; self.status = "Camera paused" }
        }
    }

    private func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .vga640x480
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw TaskLensError.message("A rear camera is required. Use a physical iPhone.")
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw TaskLensError.message("Could not open the camera.") }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw TaskLensError.message("Could not receive camera frames.") }
        session.addOutput(output)
        // Physically rotate buffers upright; use the same rotation on the preview.
        guard let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) else {
            throw TaskLensError.message("This camera cannot provide the required portrait frames.")
        }
        connection.videoRotationAngle = 90
        if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
        configured = true
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
        if tracker != nil {
            if Date() >= trackingUntil { resetTracking() }
            else { advanceTracker(on: pixels) }
        }
    }

    func snapshot() async throws -> CapturedFrame {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self, let frame = self.frames.last, self.session.isRunning,
                      Date().timeIntervalSince(frame.date) < 1 else {
                    continuation.resume(throwing: TaskLensError.message("Wait for a fresh camera view, then try again."))
                    return
                }
                let image = CIImage(cvPixelBuffer: frame.pixels)
                guard let cgImage = self.context.createCGImage(image, from: image.extent),
                      let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.75) else {
                    continuation.resume(throwing: TaskLensError.message("Could not capture the camera view."))
                    return
                }
                continuation.resume(returning: CapturedFrame(id: frame.id, capturedAt: frame.date, jpeg: jpeg,
                                                            width: cgImage.width, height: cgImage.height))
            }
        }
    }

    /// Seeds the original image and replays retained frames before going live.
    /// An expired source frame is never interpreted as a current-frame location.
    func point(at box: NormalizedBox, frameID: String, label: String, source: Highlight.Source) {
        queue.async { [weak self] in
            guard let self else { return }
            self.resetTracking()
            guard let index = self.frames.firstIndex(where: { $0.id == frameID }), self.session.isRunning else {
                self.publishStatus("The view changed. Ask again to locate the item.")
                return
            }
            let id = UUID()
            self.trackingID = id
            self.trackingLabel = label
            self.trackingSource = source
            self.trackingUntil = Date().addingTimeInterval(5)
            let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: box.visionRect))
            request.trackingLevel = .accurate
            self.tracker = request
            self.sequence = VNSequenceRequestHandler()
            for frame in self.frames[index...] {
                guard self.tracker != nil else { break }
                self.advanceTracker(on: frame.pixels, publish: false)
            }
            if self.tracker != nil, let result = self.tracker?.results?.first,
               let trackedBox = NormalizedBox.fromVision(result.boundingBox) {
                self.publishHighlight(trackedBox)
            }
            self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.trackingID == id else { return }
                self.resetTracking()
            }
        }
    }

    private func advanceTracker(on pixels: CVPixelBuffer, publish: Bool = true) {
        guard let tracker, let sequence else { return }
        do {
            try sequence.perform([tracker], on: pixels, orientation: .up)
            guard let result = tracker.results?.first, result.confidence >= 0.5,
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
