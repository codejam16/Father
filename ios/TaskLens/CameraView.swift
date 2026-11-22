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
                ForEach(camera.highlights) { highlight in
                    let color: Color = highlight.source == .user ? .yellow : .mint
                    if let mask = highlight.mask, let box = highlight.maskBox {
                        foreground(mask, from: box, to: highlight.pose, color: color,
                                   focused: highlight.isFocused, in: geometry.size)
                    } else {
                        // Keep the requested filled-area presentation while a fresh
                        // silhouette is unavailable; never substitute corner boxes.
                        targetArea(highlight, color: color, in: geometry.size)
                    }
                    targetLabel(highlight, color: color, in: geometry.size)
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
                }, including: enabled ? .all : .none)
            .onChange(of: enabled) { _, active in
                if !active { dragStart = nil; dragEnd = nil }
            }
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
        .accessibilityLabel(enabled ? "Live camera. Tap or drag to select a region for your next question." : "Live camera. Region selection is off.")
    }

    private func targetArea(_ highlight: Highlight, color: Color, in size: CGSize) -> some View {
        let image = FrameGeometry.fittedRect(in: size, aspect: camera.aspectRatio)
        let pose = highlight.pose
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: highlight.kind == .part ? 5 : 14)
                .fill(color.opacity(highlight.isFocused ? 0.30 : 0.23))
                .blur(radius: highlight.kind == .part ? 1 : 3)
                .frame(width: max(8, pose.size.width * image.width), height: max(8, pose.size.height * image.height))
                .rotationEffect(.radians(mirrored ? -pose.angle : pose.angle))
                .position(x: (mirrored ? 1 - pose.center.x : pose.center.x) * image.width,
                          y: pose.center.y * image.height)
        }
        .frame(width: image.width, height: image.height).clipped()
        .position(x: image.midX, y: image.midY)
        .allowsHitTesting(false).accessibilityLabel("Highlighted area: " + highlight.label)
    }

    private func targetLabel(_ highlight: Highlight, color: Color, in size: CGSize) -> some View {
        let image = FrameGeometry.fittedRect(in: size, aspect: camera.aspectRatio)
        let pose = highlight.pose
        let x = image.minX + (mirrored ? 1 - pose.center.x : pose.center.x) * image.width
        let y = image.minY + max(0, pose.center.y - pose.size.height / 2) * image.height
        return Text(highlight.label).font(.system(size: 10, weight: .semibold)).lineLimit(1)
            .foregroundStyle(color).padding(.horizontal, 7).padding(.vertical, 4)
            .background(.black.opacity(0.6), in: Capsule()).frame(maxWidth: 140)
            .position(x: min(max(x, image.minX + 70), image.maxX - 70), y: max(image.minY + 14, y - 12))
            .allowsHitTesting(false)
    }

    private func foreground(_ mask: CGImage, from box: NormalizedBox, to pose: RotatedBox, color: Color, focused: Bool, in size: CGSize) -> some View {
        let image = FrameGeometry.fittedRect(in: size, aspect: camera.aspectRatio)
        let source = box.unitRect
        let sx = pose.size.width / max(0.00001, source.width)
        let sy = pose.size.height / max(0.00001, source.height)
        let dx = (pose.center.x - source.midX * sx) * image.width
        let dy = (pose.center.y - source.midY * sy) * image.height
        // Track translation/scale between mask refreshes; fresh segmentation supplies
        // the changing silhouette, rather than permanently warping an initial cutout.
        // Vision returns a grayscale image, not an alpha mask. Convert luminance to
        // alpha explicitly, otherwise the black background would tint the whole frame.
        return color.opacity(focused ? 0.32 : 0.18)
            .frame(width: image.width, height: image.height)
            .mask(alignment: .topLeading) {
                Image(decorative: mask, scale: 1).resizable()
                    .frame(width: image.width, height: image.height)
                    .luminanceToAlpha()
                    .scaleEffect(x: sx, y: sy, anchor: .topLeading)
                    .offset(x: dx, y: dy)
            }
            .scaleEffect(x: mirrored ? -1 : 1, y: 1)
            .position(x: image.midX, y: image.midY)
            .allowsHitTesting(false)
    }

    private func pointer(_ box: NormalizedBox, label: String, color: Color, in size: CGSize) -> some View {
        pointer(RotatedBox(box: box), label: label, color: color, focused: true, in: size)
    }

    private func pointer(_ pose: RotatedBox, label: String, color: Color, focused: Bool, in size: CGSize) -> some View {
        let image = FrameGeometry.fittedRect(in: size, aspect: camera.aspectRatio)
        let width = pose.size.width * image.width
        let height = pose.size.height * image.height
        let midX = mirrored ? 1 - pose.center.x : pose.center.x
        return RoundedRectangle(cornerRadius: 10)
            .fill(color.opacity(0.035))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(focused ? 0.95 : 0.65), lineWidth: focused ? 2 : 1))
            .overlay(alignment: .topLeading) {
                Text(label).font(.system(size: 10, weight: .semibold))
                    .lineLimit(2).padding(.horizontal, 7).padding(.vertical, 4)
                    .foregroundStyle(.white.opacity(0.9))
                    .background(.black.opacity(0.35), in: Capsule())
                    .padding(6)
            }
            .frame(width: width, height: height)
            .rotationEffect(.radians(mirrored ? -pose.angle : pose.angle))
            .opacity(focused ? 1 : 0.55)
            .position(x: image.minX + midX * image.width, y: image.minY + pose.center.y * image.height)
            .allowsHitTesting(false)
    }
}
