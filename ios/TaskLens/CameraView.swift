import AVFoundation
import SwiftUI

private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let mirrored: Bool

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.previewLayer.session = session
        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = mirrored
            }
        }
    }
}

struct CameraStage: View {
    @ObservedObject var camera: CameraService
    let enabled: Bool
    let onSelect: (NormalizedBox) -> Void
    var showsChrome = true
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?

    /// The front camera preview is mirrored like a selfie view. Captured frames are not,
    /// so touches and boxes are converted between the two horizontally.
    private var mirrored: Bool { camera.position == .front }

    private func unmirrored(_ point: CGPoint, in size: CGSize) -> CGPoint {
        mirrored ? CGPoint(x: size.width - point.x, y: point.y) : point
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                CameraPreview(session: camera.session, mirrored: mirrored)
                if !camera.isRunning {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.viewfinder").font(.system(size: 42, weight: .light))
                        Text(camera.status).font(.callout).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white.opacity(0.8)).padding(28)
                }
                if let highlight = camera.highlight {
                    pointer(highlight.box, label: highlight.label,
                            color: highlight.source == .user ? .yellow : .mint, in: geometry.size)
                }
                if let dragStart, let dragEnd,
                   let box = FrameGeometry.selection(start: dragStart, end: dragEnd,
                                                     viewport: geometry.size, aspect: camera.aspectRatio) {
                    pointer(box, label: "Your selection", color: .yellow, in: geometry.size)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard enabled, camera.isRunning else { return }
                    dragStart = unmirrored(value.startLocation, in: geometry.size)
                    dragEnd = unmirrored(value.location, in: geometry.size)
                }
                .onEnded { value in
                    defer { dragStart = nil; dragEnd = nil }
                    guard enabled, camera.isRunning,
                          let box = FrameGeometry.selection(start: unmirrored(value.startLocation, in: geometry.size),
                                                            end: unmirrored(value.location, in: geometry.size),
                                                            viewport: geometry.size, aspect: camera.aspectRatio) else { return }
                    onSelect(box)
                })
            .overlay(alignment: .topLeading) {
                if showsChrome {
                    Label(camera.isRunning ? "LIVE" : "CAMERA", systemImage: "circle.fill")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(camera.isRunning ? .mint : .white)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(.black.opacity(0.65), in: Capsule()).padding(14)
                }
            }
            .overlay(alignment: .bottom) {
                if showsChrome {
                    Text(camera.status == "Camera live" ? "Tap or drag to point something out" : camera.status)
                        .font(.caption).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.black.opacity(0.65), in: Capsule()).padding(12)
                        .allowsHitTesting(false)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: showsChrome ? 24 : 0))
        .overlay(RoundedRectangle(cornerRadius: showsChrome ? 24 : 0).stroke(.white.opacity(showsChrome ? 0.12 : 0), lineWidth: 1))
        .accessibilityLabel("Live camera. Tap or drag to select a region for your next question.")
    }

    private func pointer(_ box: NormalizedBox, label: String, color: Color, in size: CGSize) -> some View {
        let image = FrameGeometry.fittedRect(in: size, aspect: camera.aspectRatio)
        let rect = box.unitRect
        let width = rect.width * image.width
        let height = rect.height * image.height
        let midX = mirrored ? 1 - rect.midX : rect.midX
        return RoundedRectangle(cornerRadius: 10)
            .fill(color.opacity(0.10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color, lineWidth: 3))
            .overlay(alignment: .topLeading) {
                Text(label).font(.system(size: 10, weight: .semibold))
                    .lineLimit(2).padding(5)
                    .foregroundStyle(.black).background(color, in: RoundedRectangle(cornerRadius: 5))
                    .offset(y: -28)
            }
            .frame(width: width, height: height)
            .position(x: image.minX + midX * image.width, y: image.minY + rect.midY * image.height)
            .allowsHitTesting(false)
    }
}
