import SwiftUI
import LinkPresentation
import WebKit

@MainActor
struct ContentView: View {
    @ObservedObject var model: AssistantViewModel
    var discoveryContext: String? = nil
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        CameraExperience(model: model, speech: model.speech, settings: model.settings)
            .preferredColorScheme(.dark)
            .statusBarHidden()
            .task { model.setDiscoveryContext(discoveryContext); await model.resume() }
            .onDisappear { model.pause() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.resume() } }
                else { model.pause() }
            }
    }
}

/// Small assistant indicator: listening, hearing you, thinking, answering.
@MainActor
private struct AssistantStatusBadge: View {
    @ObservedObject var model: AssistantViewModel
    @ObservedObject var speech: SpeechService

    private enum Phase: Equatable { case preparing, muted, listening, hearing, thinking, speaking, answered }

    private var phase: Phase {
        if model.isBusy { return .thinking }
        if speech.isSpeaking { return .speaking }
        if model.justAnswered { return .answered }
        if model.isMuted { return .muted }
        if speech.isRecording { return speech.transcript.isEmpty ? .listening : .hearing }
        return .preparing
    }

    private var symbol: String {
        switch phase {
        case .preparing: "ellipsis"
        case .muted: "mic.slash.fill"
        case .listening: "ear"
        case .hearing: "waveform"
        case .thinking: "sparkles"
        case .speaking: "speaker.wave.2.fill"
        case .answered: "checkmark"
        }
    }

    private var title: String {
        switch phase {
        case .preparing: "Getting ready"
        case .muted: "Muted"
        case .listening: "Listening"
        case .hearing: "Hearing you"
        case .thinking: "Thinking"
        case .speaking: "Answering"
        case .answered: "Answered"
        }
    }

    private var tint: Color {
        switch phase {
        case .preparing: .white
        case .muted: .red
        case .listening, .hearing: .mint
        case .thinking: .purple
        case .speaking, .answered: .cyan
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(tint.opacity(0.22))
                if phase == .thinking {
                    TimelineView(.animation) { context in
                        let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
                        Circle()
                            .trim(from: 0, to: 0.3)
                            .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(turn * 360))
                    }
                }
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, options: .repeating, isActive: phase == .listening || phase == .thinking)
                    .symbolEffect(.variableColor.iterative, options: .repeating,
                                  isActive: phase == .hearing || phase == .speaking)
            }
            .frame(width: 30, height: 30)

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.leading, 5)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 1))
        .animation(.easeInOut(duration: 0.25), value: phase)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Assistant status: \(title)")
    }
}

@MainActor
private struct CameraExperience: View {
    private enum CameraSheet: String, Identifiable, Equatable {
        case settings, conversation
        var id: String { rawValue }
    }

    @ObservedObject var model: AssistantViewModel
    @ObservedObject var speech: SpeechService
    @ObservedObject var settings: ConnectionSettings
    @State private var activeSheet: CameraSheet?
    @State private var webPanelHeight: CGFloat = 0
    @AppStorage("captionHeightFraction") private var captionHeightFraction = 0.22
    @AppStorage("webInfoHeightFraction") private var webInfoHeightFraction = 0.25
    @AppStorage("webInfoWidthFraction") private var webInfoWidthFraction = 1.0

    var body: some View {
        GeometryReader { geometry in
            cameraCanvas(availableSize: geometry.size)
        }
        .background(.black)
        .sheet(item: $activeSheet) { sheet in
            presentedSheet(sheet)
        }
        .onChange(of: activeSheet) { _, sheet in
            model.setVoiceSuspended(sheet != nil)
        }
        .onChange(of: settings.selectionEnabled) { _, enabled in
            if !enabled { model.clearSelection() }
        }
    }

    private func cameraCanvas(availableSize: CGSize) -> some View {
        ZStack(alignment: .bottom) {
            ImmersiveCamera(camera: model.camera, enabled: settings.selectionEnabled && !model.isBusy, onSelect: model.select)
                .ignoresSafeArea()
            cameraOverlays(availableSize: availableSize)
        }
        // A camera-local overlay: expanding never presents a sheet or pauses voice.
        .overlay(alignment: .bottom) { webInfoStrip(availableSize: availableSize) }
        .overlay(alignment: .top) { statusBadge }
        .overlay(alignment: .topTrailing) {
            if !infoIsLarge(in: availableSize) { overlayControls }
        }
        .overlay(alignment: .topLeading) {
            if !infoIsLarge(in: availableSize) { selectionIndicator }
        }
    }

    // Includes the panel's bottom clearance, measured after layout rather than
    // estimated from its saved size. Hidden or cleared results reserve no space.
    private var infoOccupiedHeight: CGFloat {
        guard settings.webInfoEnabled && hasWebResults else { return 0 }
        // Reserve room on the first render, before the compact bubble is measured.
        return webPanelHeight > 0 ? webPanelHeight : 224
    }

    private func infoIsLarge(in size: CGSize) -> Bool {
        infoOccupiedHeight >= size.height * 0.65
    }

    private func captionSpace(in size: CGSize) -> CGFloat {
        let issueHeight: CGFloat = model.errorMessage == nil ? 0 : 80
        // Leave the centered badge clear, and keep a gap between both bubbles.
        return max(0, size.height - 76 - max(72, infoOccupiedHeight) - 10 - issueHeight)
    }

    private func cameraOverlays(availableSize: CGSize) -> some View {
        let captionRoom = captionSpace(in: availableSize)
        let showCaptions = settings.captionsEnabled && !infoIsLarge(in: availableSize) && captionRoom >= 112
        return VStack(spacing: 10) {
            VStack(spacing: 10) {
                errorBanner
                if showCaptions {
                    CaptionsOverlay(model: model, speech: speech, heightFraction: $captionHeightFraction,
                                    availableHeight: availableSize.height, maximumHeight: captionRoom,
                                    showHistory: { activeSheet = .conversation })
                }
            }
            // The controls already occupy 72pt below this stack. Reserve only
            // the extra space, placing captions 10pt above the actual info box.
            .padding(.bottom, max(0, infoOccupiedHeight - 72))
            primaryControls
        }
        .padding(.horizontal, 16).padding(.bottom, 16)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error = model.errorMessage {
            ScrollView {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .frame(maxHeight: 70)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    @ViewBuilder
    private var selectionIndicator: some View {
        if model.selectedFrame != nil {
            Button(action: model.clearSelection) {
                HStack(spacing: 5) {
                    Image(systemName: "viewfinder")
                    Text("Focus")
                    Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                }
                .font(.caption2).foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(.black.opacity(0.24), in: Capsule())
            }
            .accessibilityLabel("Clear selected region")
            .padding(.leading, 16).padding(.top, 62)
        }
    }

    private var hasWebResults: Bool { model.webInfo?.sources.isEmpty == false }

    @ViewBuilder
    private func webInfoStrip(availableSize: CGSize) -> some View {
        if settings.webInfoEnabled, let info = model.webInfo, !info.sources.isEmpty,
           let replyID = model.messages.last?.id {
            WebInfoStrip(info: info, heightFraction: $webInfoHeightFraction, widthFraction: $webInfoWidthFraction,
                         availableSize: availableSize, reportHeight: { webPanelHeight = $0 }) {
                withAnimation(.easeInOut(duration: 0.2)) { settings.webInfoEnabled = false }
            }
            .frame(maxWidth: .infinity)
            .id(replyID)
            .transition(.opacity)
            .onDisappear { webPanelHeight = 0 }
        }
    }

    private var primaryControls: some View {
        HStack(spacing: 24) {
            Button { model.toggleMicrophone() } label: {
                Image(systemName: model.isMuted ? "mic.slash.fill" : "mic.fill")
                    .foregroundStyle(model.isMuted ? Color.red : Color.white)
            }
            .accessibilityLabel(model.isMuted ? "Unmute microphone" : "Mute microphone")
            .accessibilityValue(model.isMuted ? "Muted" : "Unmuted")
            Button { model.flipCamera() } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
            }
            .disabled(model.isBusy)
            .opacity(model.isBusy ? 0.4 : 1)
            .accessibilityLabel("Flip camera")
            Button { activeSheet = .settings } label: { Image(systemName: "gearshape.fill") }
                .accessibilityLabel("Settings")
        }
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(.white).buttonStyle(CameraControlStyle())
        .padding(.top, 4)
    }

    private var statusBadge: some View {
        VStack(spacing: 4) {
            AssistantStatusBadge(model: model, speech: speech)
            if settings.demoMode {
                Text("DEMO").font(.caption2.bold()).foregroundStyle(.yellow)
            }
        }
        .padding(.top, 12)
        .allowsHitTesting(false)
    }

    private var overlayControls: some View {
        VStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { settings.captionsEnabled.toggle() }
            } label: {
                Image(systemName: settings.captionsEnabled ? "text.bubble.fill" : "text.bubble")
                    .foregroundStyle(settings.captionsEnabled ? Color.mint : Color.white)
            }
            .accessibilityLabel(settings.captionsEnabled ? "Hide captions" : "Show captions")
            .accessibilityValue(settings.captionsEnabled ? "On" : "Off")
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { settings.webInfoEnabled.toggle() }
            } label: {
                Image(systemName: settings.webInfoEnabled ? "info.circle.fill" : "info.circle")
                    .foregroundStyle(settings.webInfoEnabled ? Color.mint : Color.white)
                    .overlay(alignment: .topTrailing) {
                        if !settings.webInfoEnabled && hasWebResults {
                            Circle().fill(.mint).frame(width: 7, height: 7)
                                .overlay(Circle().stroke(.black.opacity(0.5), lineWidth: 1))
                                .offset(x: 5, y: -3)
                        }
                    }
            }
            .accessibilityLabel(settings.webInfoEnabled ? "Hide web info" : "Show web info")
            .accessibilityValue(!settings.webInfoEnabled && hasWebResults ? "Hidden, results available" : settings.webInfoEnabled ? "Visible" : "Hidden")
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { settings.selectionEnabled.toggle() }
            } label: {
                Image(systemName: "viewfinder")
                    .foregroundStyle(settings.selectionEnabled ? Color.mint : Color.white)
            }
            .accessibilityLabel(settings.selectionEnabled ? "Turn off region selection" : "Select a region")
            .accessibilityValue(settings.selectionEnabled ? "On. Tap or drag over the camera." : "Off")
        }
        .font(.system(size: 20, weight: .semibold))
        .buttonStyle(CameraControlStyle()).padding(.trailing, 16).padding(.top, 60)
    }

    @ViewBuilder
    private func presentedSheet(_ sheet: CameraSheet) -> some View {
        switch sheet {
        case .settings: SettingsView(settings: settings, model: model)
        case .conversation: ConversationView(model: model)
        }
    }

}

private struct CameraControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 52, height: 52)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

@MainActor
private struct ImmersiveCamera: View {
    @ObservedObject var camera: CameraService
    let enabled: Bool
    let onSelect: (NormalizedBox) -> Void

    var body: some View {
        GeometryReader { geometry in
            // Enlarge preview, pointers and selection geometry together.
            let aspect = max(camera.aspectRatio, 0.01)
            let width = max(geometry.size.width, geometry.size.height * aspect)
            let height = width / aspect
            CameraStage(camera: camera, enabled: enabled, onSelect: onSelect, showsChrome: false)
                .frame(width: width, height: height)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .clipped()
    }
}

@MainActor
private struct CaptionsOverlay: View {
    @ObservedObject var model: AssistantViewModel
    @ObservedObject var speech: SpeechService
    @Binding var heightFraction: Double
    let availableHeight: CGFloat
    let maximumHeight: CGFloat
    let showHistory: () -> Void
    @GestureState private var resizeOffset: CGFloat = 0

    private var minimumFraction: Double { min(0.55, 112 / Double(max(availableHeight, 1))) }
    private func clamped(_ fraction: Double) -> Double {
        min(0.55, max(minimumFraction, fraction.isFinite ? fraction : 0.22))
    }
    private var currentHeight: CGFloat {
        min(maximumHeight, CGFloat(clamped(heightFraction - Double(resizeOffset / max(availableHeight, 1)))) * availableHeight)
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text("Captions").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                Spacer()
                Capsule().fill(.white.opacity(0.4)).frame(width: 32, height: 3)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2)
                        .updating($resizeOffset) { value, state, _ in state = value.translation.height }
                        .onEnded { value in
                            heightFraction = clamped(heightFraction - Double(value.translation.height / max(availableHeight, 1)))
                        })
                    .accessibilityElement()
                    .accessibilityLabel("Caption height")
                    .accessibilityValue("\(Int(clamped(heightFraction) * 100)) percent of screen")
                    .accessibilityHint("Drag up to make captions taller or down to make them shorter.")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: heightFraction = clamped(heightFraction + 0.05)
                        case .decrement: heightFraction = clamped(heightFraction - 0.05)
                        @unknown default: break
                        }
                    }
                Spacer()
                Button(action: showHistory) { Image(systemName: "clock.arrow.circlepath").font(.caption).frame(width: 36, height: 32) }
                    .foregroundStyle(.white.opacity(0.6)).accessibilityLabel("Full conversation")
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 7) {
                        if model.messages.isEmpty && model.pendingQuestion == nil && speech.transcript.isEmpty {
                            Text("Speak to start captions.").font(.caption).foregroundStyle(.white.opacity(0.55))
                                .padding(.vertical, 8)
                        }
                        ForEach(model.messages) { message in
                            CaptionBubble(text: message.content, isUser: message.role == .user)
                        }
                        if let pending = model.pendingQuestion {
                            CaptionBubble(text: pending, isUser: true)
                        } else if speech.isRecording && !speech.transcript.isEmpty {
                            CaptionBubble(text: speech.transcript, isUser: true, isDraft: true)
                        }
                        if model.isBusy {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini).tint(.white.opacity(0.6))
                                Text("Thinking…").font(.caption2).foregroundStyle(.white.opacity(0.6))
                                Spacer()
                            }
                        }
                        Color.clear.frame(height: 1).id("latest-caption").accessibilityHidden(true)
                    }
                }
                .onAppear { proxy.scrollTo("latest-caption", anchor: .bottom) }
                .onChange(of: model.messages.count) { _, _ in proxy.scrollTo("latest-caption", anchor: .bottom) }
                .onChange(of: model.pendingQuestion) { _, _ in proxy.scrollTo("latest-caption", anchor: .bottom) }
                .onChange(of: speech.transcript) { _, _ in proxy.scrollTo("latest-caption", anchor: .bottom) }
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 9)
        .frame(height: currentHeight)
        .background(Color(white: 0.18).opacity(0.20), in: RoundedRectangle(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

private struct CaptionBubble: View {
    let text: String
    let isUser: Bool
    var isDraft = false

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 42) }
            VStack(alignment: .leading, spacing: 3) {
                Text(isUser ? (isDraft ? "You · listening" : "You") : "TaskLens")
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                Text(text).font(.subheadline).foregroundStyle(.white.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color(white: isUser ? 0.30 : 0.20).opacity(0.44), in: RoundedRectangle(cornerRadius: 13))
            if !isUser { Spacer(minLength: 42) }
        }
    }
}

@MainActor
private struct WebInfoStrip: View {
    let info: WebInfo
    @Binding var heightFraction: Double
    @Binding var widthFraction: Double
    let availableSize: CGSize
    let reportHeight: (CGFloat) -> Void
    let dismiss: () -> Void
    @State private var expanded = false
    @GestureState private var resizeOffset = CGSize.zero

    private var usableWidth: CGFloat { max(1, availableSize.width - 32) }
    private var screenHeight: CGFloat { max(1, availableSize.height) }
    // Even at maximum size, leave a camera margin and room for the status badge.
    private var maximumPanelHeight: CGFloat { max(1, screenHeight - 76) }
    private var maximumFraction: Double { Double(maximumPanelHeight / screenHeight) }
    private func clampedHeight(_ value: Double) -> Double {
        let minimum = min(maximumFraction, 170 / Double(screenHeight))
        return min(maximumFraction, max(minimum, value.isFinite ? value : 0.25))
    }
    private func clampedWidth(_ value: Double) -> Double {
        min(1, max(0.55, value.isFinite ? value : 1))
    }
    private var panelWidth: CGFloat {
        let fraction = clampedWidth(widthFraction + Double(resizeOffset.width * 2 / usableWidth))
        return CGFloat(fullScreen ? 1 : fraction) * usableWidth
    }
    private var panelHeight: CGFloat {
        CGFloat(clampedHeight(clampedHeight(heightFraction) - Double(resizeOffset.height / screenHeight))) * screenHeight
    }
    private var fullScreen: Bool { expanded && panelHeight >= maximumPanelHeight * 0.96 }
    private var bottomInset: CGFloat { expanded ? min(88, max(16, screenHeight - panelHeight - 60)) : 88 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            resizeHandles
            heading
            sourceLinks
            if expanded {
                WebInfoDetails(info: info).transition(.opacity)
            }
        }
        .padding(.horizontal, 11).padding(.bottom, 8)
        .padding(.top, 2)
        .frame(width: panelWidth, height: expanded ? panelHeight : nil)
        .background(Color(white: 0.15).opacity(fullScreen ? 0.48 : 0.32),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(.white.opacity(0.10), lineWidth: 0.75))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .foregroundStyle(.white.opacity(0.8))
        .padding(.bottom, bottomInset)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { reportHeight(geometry.size.height) }
                    .onChange(of: geometry.size.height) { _, height in reportHeight(height) }
            }
        }
    }

    private var resizeHandles: some View {
        HStack(spacing: 6) {
            Image(systemName: "globe").font(.system(size: 10)).frame(width: 26)
            Capsule().fill(.white.opacity(0.4)).frame(width: 32, height: 3)
                .frame(maxWidth: .infinity, minHeight: 25)
                .contentShape(Rectangle())
                .gesture(heightResize)
                .accessibilityElement()
                .accessibilityLabel("Info box height")
                .accessibilityHint("Drag up to fill the screen or down to make the info box shorter.")
                .accessibilityAdjustableAction { direction in
                    expanded = true
                    switch direction {
                    case .increment: heightFraction = clampedHeight(heightFraction + 0.1)
                    case .decrement: heightFraction = clampedHeight(heightFraction - 0.1)
                    @unknown default: break
                    }
                }
            Image(systemName: "arrow.up.right.and.arrow.down.left")
                .font(.system(size: 11)).frame(width: 30, height: 25)
                .contentShape(Rectangle())
                .gesture(cornerResize)
                .accessibilityElement()
                .accessibilityLabel("Info box size")
                .accessibilityHint("Drag upward and outward to increase height and width.")
                .accessibilityAdjustableAction { direction in
                    expanded = true
                    let delta: Double
                    switch direction {
                    case .increment: delta = 0.04
                    case .decrement: delta = -0.04
                    @unknown default: return
                    }
                    heightFraction = clampedHeight(heightFraction + delta)
                    widthFraction = clampedWidth(widthFraction + delta)
                }
        }
    }

    private var heightResize: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .updating($resizeOffset) { value, state, _ in state = CGSize(width: 0, height: value.translation.height) }
            .onChanged { _ in expanded = true }
            .onEnded { value in
                let next = clampedHeight(clampedHeight(heightFraction) - Double(value.translation.height / screenHeight))
                heightFraction = next >= maximumFraction * 0.9 ? maximumFraction : next
            }
    }

    private var cornerResize: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .updating($resizeOffset) { value, state, _ in state = value.translation }
            .onChanged { _ in expanded = true }
            .onEnded { value in
                let next = clampedHeight(clampedHeight(heightFraction) - Double(value.translation.height / screenHeight))
                heightFraction = next >= maximumFraction * 0.9 ? maximumFraction : next
                widthFraction = clampedWidth(widthFraction + Double(value.translation.width * 2 / usableWidth))
            }
    }

    private var heading: some View {
        HStack(spacing: 6) {
            Text(info.summary ?? "Related sources")
                .font(.caption).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if fullScreen { heightFraction = 0.3 }
                    else { expanded = true; heightFraction = maximumFraction; widthFraction = 1 }
                }
            } label: {
                Image(systemName: fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.caption2).frame(width: 30, height: 30)
            }
            .accessibilityLabel(fullScreen ? "Restore info box size" : "Fill screen with web info")
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.up").font(.caption2)
                    .frame(width: 30, height: 30)
            }
            .accessibilityLabel(expanded ? "Collapse web details" : "Expand web details inside the camera view")
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10)).frame(width: 30, height: 30) }
                .accessibilityLabel("Hide web info; keep results available")
        }
    }

    private var sourceLinks: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(info.sources) { source in
                    Link(destination: source.url) {
                        HStack(spacing: 4) {
                            Text(source.title).lineLimit(1)
                            Image(systemName: "arrow.up.right").font(.system(size: 8))
                        }
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(.white.opacity(0.07), in: Capsule())
                    }
                    .frame(maxWidth: 170)
                }
            }
        }
        .frame(height: 28)
    }
}

@MainActor
private struct WebInfoDetails: View {
    let info: WebInfo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                if let summary = info.summary { Text(summary).font(.caption).textSelection(.enabled) }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(info.sources) { source in
                            VStack(alignment: .leading, spacing: 5) {
                                Link(source.title, destination: source.url).font(.caption).lineLimit(2)
                                SourcePreview(url: source.url).frame(width: 220, height: 100).clipped()
                            }
                            .frame(width: 220)
                        }
                    }
                }
                Text("Check the source for the current price and exact product match.")
                    .font(.caption2).foregroundStyle(.secondary)
                if let html = info.searchSuggestionHTML, !html.isEmpty {
                    SearchSuggestions(html: html).frame(height: 76).clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(.vertical, 5)
        }
        // Expanded details scroll within the user-sized, camera-local box.
        .frame(maxHeight: .infinity)
    }
}

@MainActor
private struct SourcePreview: UIViewRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> LPLinkView {
        let view = LPLinkView(url: url)
        context.coordinator.load(url, into: view)
        return view
    }
    func updateUIView(_ view: LPLinkView, context: Context) { context.coordinator.load(url, into: view) }
    static func dismantleUIView(_ view: LPLinkView, coordinator: Coordinator) { coordinator.cancel() }

    @MainActor final class Coordinator {
        private var currentURL: URL?
        private var provider: LPMetadataProvider?
        func load(_ url: URL, into view: LPLinkView) {
            guard url != currentURL, url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { return }
            cancel()
            currentURL = url
            let provider = LPMetadataProvider()
            provider.timeout = 8
            self.provider = provider
            provider.startFetchingMetadata(for: url) { [weak self, weak view] metadata, _ in
                DispatchQueue.main.async {
                    guard self?.currentURL == url, let metadata else { return }
                    view?.metadata = metadata
                }
            }
        }
        func cancel() {
            currentURL = nil
            provider?.cancel()
            provider = nil
        }
    }
}

@MainActor
private struct SearchSuggestions: UIViewRepresentable {
    let html: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.navigationDelegate = context.coordinator
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.html != html else { return }
        context.coordinator.html = html
        view.loadHTMLString("<meta name='viewport' content='width=device-width, initial-scale=1'>" + html, baseURL: nil)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { view.stopLoading(); view.navigationDelegate = nil }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        var html = ""
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url, url.scheme == "https" { UIApplication.shared.open(url) }
                decisionHandler(.cancel)
            } else {
                decisionHandler(navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
            }
        }
    }
}

@MainActor
private struct ConversationView: View {
    @ObservedObject var model: AssistantViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if model.messages.isEmpty { Text("Start speaking to see your conversation here.").foregroundStyle(.secondary) }
                    ForEach(model.messages) { message in
                        CaptionBubble(text: message.content, isUser: message.role == .user)
                    }
                }.padding()
            }
            .navigationTitle("Conversation")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("New") { model.resetConversation(); dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}
