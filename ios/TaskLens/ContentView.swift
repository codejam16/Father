import SwiftUI
import LinkPresentation
import WebKit

@MainActor
struct ContentView: View {
    @StateObject private var model = AssistantViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        CameraExperience(model: model, speech: model.speech, settings: model.settings, library: model.library)
            .preferredColorScheme(.dark)
            .statusBarHidden()
            .task { await model.resume() }
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

    private enum Phase: Equatable { case preparing, muted, listening, hearing, thinking, speaking, answered, watching, checking }

    private var phase: Phase {
        if model.isBusy { return .thinking }
        if speech.isSpeaking { return .speaking }
        if model.justAnswered { return .answered }
        if model.isChecking { return .checking }
        if speech.isRecording && !speech.transcript.isEmpty { return .hearing }
        if model.isWatching { return .watching }
        if model.isMuted { return .muted }
        if speech.isRecording { return .listening }
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
        case .watching: "eye"
        case .checking: "viewfinder"
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
        case .watching: "Watching your work"
        case .checking: "Checking the step"
        }
    }

    private var tint: Color {
        switch phase {
        case .preparing: .white
        case .muted: .red
        case .listening, .hearing: .mint
        case .thinking: .purple
        case .speaking, .answered: .cyan
        case .watching: .teal
        case .checking: .yellow
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(tint.opacity(0.22))
                if phase == .thinking || phase == .checking {
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
                    .symbolEffect(.pulse, options: .repeating, isActive: phase == .listening || phase == .thinking || phase == .watching || phase == .checking)
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
        case settings, conversation, saved
        var id: String { rawValue }
    }

    @ObservedObject var model: AssistantViewModel
    @ObservedObject var speech: SpeechService
    @ObservedObject var settings: ConnectionSettings
    @ObservedObject var library: WalkthroughLibrary
    @State private var activeSheet: CameraSheet?
    @State private var webPanelHeight: CGFloat = 0
    @AppStorage("captionHeightFraction") private var captionHeightFraction = 0.22
    @AppStorage("webInfoHeightFraction") private var webInfoHeightFraction = 0.25
    @AppStorage("webInfoWidthFraction") private var webInfoWidthFraction = 1.0

    var body: some View {
        GeometryReader { geometry in
            cameraCanvas(availableSize: geometry.size)
        }
        .overlay {
            if let walkthrough = model.walkthrough {
                WalkthroughOverlay(walkthrough: walkthrough, model: model,
                                   onClose: { model.closeWalkthrough() },
                                   onDiscard: { model.discardWalkthrough() })
                    .id(walkthrough.id)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.walkthrough?.id)
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
        .onChange(of: settings.guidedMode) { _, _ in model.updateWatching() }
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
        .overlay(alignment: .bottomTrailing) { savedButton }
        .overlay(alignment: .topLeading) {
            if !infoIsLarge(in: availableSize) {
                VStack(alignment: .leading, spacing: 8) {
                    selectionIndicator
                    VStack(alignment: .leading, spacing: 8) {
                        toolsCard
                        stepCard
                    }
                    .padding(.leading, 16)
                    .padding(.top, model.selectedFrame == nil ? 62 : 0)
                }
            }
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

    /// "What you'll need" for a guided task: ticks for what the camera saw (or the user ticked).
    @ViewBuilder
    private var toolsCard: some View {
        if !model.tools.isEmpty, model.currentStep != nil {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { model.toolsExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text("YOU'LL NEED").font(.caption2.weight(.bold)).foregroundStyle(.mint)
                        Text("\(model.tools.filter(\.visible).count)/\(model.tools.count)")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                        Spacer(minLength: 8)
                        Image(systemName: model.toolsExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.7))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.toolsExpanded ? "Hide tools list" : "Show tools list")
                if model.toolsExpanded {
                    ForEach(model.tools) { tool in
                        Button { model.toggleTool(tool.name) } label: {
                            Label(tool.name, systemImage: tool.visible ? "checkmark.circle.fill" : "circle")
                                .font(.caption)
                                .foregroundStyle(tool.visible ? Color.mint : Color.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(tool.visible ? "Found" : "Not found yet")
                    }
                    Button { model.scanTools() } label: {
                        Label(model.isScanningTools ? "Checking…" : "Check my tools", systemImage: "camera.viewfinder")
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.caption.weight(.semibold))
                    .disabled(model.isScanningTools || model.isBusy)
                }
            }
            .padding(12)
            .frame(maxWidth: 290, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.mint.opacity(0.35), lineWidth: 1))
        }
    }

    /// Guided steps: the current instruction, with Done / Skip / Repeat.
    @ViewBuilder
    private var stepCard: some View {
        if let step = model.currentStep, let number = model.stepNumber {
            VStack(alignment: .leading, spacing: 8) {
                Text("STEP \(number) OF \(model.taskMemory.plan.count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.mint)
                Text(step.text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
                if let notice = model.guidedNotice {
                    Label(notice, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                stepButtons
            }
            .padding(12)
            .frame(maxWidth: 290, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.mint.opacity(0.35), lineWidth: 1))
            .transition(.opacity.combined(with: .move(edge: .top)))
            .animation(.easeInOut(duration: 0.25), value: step.id)
        }
    }

    private var stepButtons: some View {
        HStack(spacing: 6) {
            Button { model.markCurrentStepDone() } label: {
                Label("Done", systemImage: "checkmark").lineLimit(1).fixedSize()
            }
            .buttonStyle(.borderedProminent)
            .tint(.mint)
            Button { model.skipCurrentStep() } label: { Text("Skip").lineLimit(1).fixedSize() }
                .buttonStyle(.bordered)
            Button { model.showCurrentStepPart() } label: { Image(systemName: "scope") }
                .buttonStyle(.bordered)
                .accessibilityLabel("Show where")
            Button { model.repeatCurrentStep() } label: { Image(systemName: "speaker.wave.2.fill") }
                .buttonStyle(.bordered)
                .accessibilityLabel("Repeat step")
            Button { model.endSteps() } label: { Image(systemName: "xmark") }
                .buttonStyle(.bordered)
                .accessibilityLabel("Stop the steps")
        }
        .font(.caption.weight(.semibold))
        .controlSize(.small)
        .disabled(model.isBusy || model.isChecking)
    }

    /// Bottom-right: the latest saved explanation's picture and how many are saved.
    @ViewBuilder
    private var savedButton: some View {
        if let latest = library.items.first {
            Button { activeSheet = .saved } label: {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let thumbnail = library.thumbnail(for: latest.id) {
                            Image(uiImage: thumbnail).resizable().scaledToFill()
                        } else {
                            Image(systemName: "rectangle.stack").font(.title3).foregroundStyle(.white)
                        }
                    }
                    .frame(width: 52, height: 52)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.7), lineWidth: 1.5))
                    Text("\(library.items.count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.mint, in: Capsule())
                        .offset(x: 6, y: -6)
                }
            }
            .accessibilityLabel("Saved explanations")
            .accessibilityValue("\(library.items.count)")
            .padding(.trailing, 16)
            .padding(.bottom, 20)
        }
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
            .accessibilityLabel(settings.webInfoEnabled ? "Turn off web info and search" : "Turn on web info and search")
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
        case .saved:
            SavedWalkthroughsView(library: library) { item in
                activeSheet = nil
                model.openSaved(item)
            }
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

/// Explains a diagram over a frozen copy of the photo the AI looked at, one beat at a time:
/// boxes light up, paths draw themselves along the lines with a moving "flow", captions below.
@MainActor
private struct WalkthroughOverlay: View {
    let walkthrough: Walkthrough
    let model: AssistantViewModel
    /// Save (or, for a reopened one, back to the camera).
    let onClose: () -> Void
    /// The X: close without saving.
    let onDiscard: () -> Void
    @State private var index = 0
    @State private var beatStart = Date()
    @State private var autoplay = true
    @State private var run = UUID()
    /// Follow the voice: move to each beat when its spoken line starts.
    @State private var followVoice = true
    @State private var heardVoice = false
    @State private var showAllSteps = false

    private var count: Int { walkthrough.beats.count }
    private static let accent = Color(red: 0.30, green: 0.82, blue: 1.0)

    /// Roughly in step with the spoken explanation.
    private var beatSeconds: Double {
        let perBeat = Double(walkthrough.answer.count) / Double(max(count, 1)) / 14
        return min(7, max(2.8, perBeat))
    }

    var body: some View {
        GeometryReader { geometry in
            let size = walkthrough.image.size
            let fitted = FrameGeometry.fittedRect(in: geometry.size, aspect: size.width / max(size.height, 1))
            ZStack {
                Color.black.opacity(0.92)
                Image(uiImage: walkthrough.image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: fitted.width, height: fitted.height)
                    .position(x: fitted.midX, y: fitted.midY)
                TimelineView(.animation) { timeline in
                    Canvas { context, _ in
                        draw(in: &context, rect: fitted, elapsed: timeline.date.timeIntervalSince(beatStart))
                    }
                }
                .allowsHitTesting(false)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .onTapGesture { step(1) }
        }
        .background(Color.black.opacity(0.92).ignoresSafeArea())
        .overlay(alignment: .bottom) { captionBar() }
        .overlay(alignment: .topTrailing) {
            Button { onDiscard() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
            }
            .accessibilityLabel(walkthrough.reopened ? "Close" : "Close without saving")
            .padding(.top, 12)
            .padding(.trailing, 16)
        }
        .onChange(of: index) { _, _ in beatStart = Date() }
        .onAppear {
            // A saved explanation opens paused on its last step, the way the original ended:
            // every arrow drawn, earlier ones faded. ◀ steps back; Replay plays it from the start.
            if walkthrough.reopened {
                followVoice = false
                autoplay = false
                index = max(count - 1, 0)
            }
        }
        .task(id: run) {
            // With the voice on, the voice leads: poll where it is and show that beat.
            // If no voice starts (spoken replies off, or it failed), fall back to a timer.
            let waitForVoiceUntil = Date().addingTimeInterval(model.voiceDrivesWalkthrough ? 12 : 0)
            var timerBeatStart = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard followVoice else { return }
                if let progress = model.speechProgress {
                    heardVoice = true
                    let beat = walkthrough.beat(at: progress)
                    if beat != index { index = beat }
                } else if heardVoice {
                    // The voice finished (or was interrupted): stay where it got to.
                    return
                } else if Date() > waitForVoiceUntil, autoplay {
                    if Date().timeIntervalSince(timerBeatStart) >= beatSeconds {
                        guard index < count - 1 else { return }
                        index += 1
                        timerBeatStart = Date()
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func step(_ delta: Int) {
        autoplay = false
        followVoice = false
        index = min(max(index + delta, 0), count - 1)
    }

    private func captionBar() -> some View {
        let beat = walkthrough.beats[index]
        return VStack(alignment: .leading, spacing: 10) {
            Text("\(index + 1) / \(count)")
                .font(.caption.weight(.bold))
                .foregroundStyle(Self.accent)
            Text(beat.caption)
                .font(.headline)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            // The full spoken line, to read along (or instead of listening).
            if let line = beat.say, !line.isEmpty, line != beat.caption {
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if showAllSteps { allSteps }
            HStack(spacing: 10) {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(index == 0)
                    .accessibilityLabel("Previous")
                Button {
                    autoplay = true
                    followVoice = true
                    heardVoice = false
                    index = 0
                    model.replayWalkthrough()
                    run = UUID()
                } label: { Image(systemName: "arrow.counterclockwise") }
                    .accessibilityLabel("Replay")
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(index == count - 1)
                    .accessibilityLabel("Next")
                Button { withAnimation(.easeInOut(duration: 0.2)) { showAllSteps.toggle() } } label: {
                    Image(systemName: showAllSteps ? "list.bullet.circle.fill" : "list.bullet")
                }
                .accessibilityLabel(showAllSteps ? "Hide all steps" : "Show all steps")
                Spacer(minLength: 4)
                // A saved explanation only closes with the X at the top right.
                if !walkthrough.reopened {
                    Button { onClose() } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                            .lineLimit(1).fixedSize()
                    }
                    .accessibilityLabel("Save and go back to the camera")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.callout.weight(.semibold))
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
    }

    /// Every step written out; tap one to show it.
    private var allSteps: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(walkthrough.beats.enumerated()), id: \.offset) { offset, beat in
                    Button {
                        autoplay = false
                        followVoice = false
                        index = offset
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(offset + 1)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.black)
                                .frame(width: 20, height: 20)
                                .background(offset == index ? Self.accent : Color.white.opacity(0.6), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(beat.caption)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                if let line = beat.say, !line.isEmpty, line != beat.caption {
                                    Text(line).font(.caption).foregroundStyle(.white.opacity(0.75))
                                }
                            }
                            .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 220)
    }

    // MARK: Drawing

    private func place(_ unit: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + unit.x * rect.width, y: rect.minY + unit.y * rect.height)
    }

    private func draw(in context: inout GraphicsContext, rect: CGRect, elapsed: Double) {
        for (offset, beat) in walkthrough.beats.enumerated() where offset <= index {
            let current = offset == index
            let region = beat.unitRegion.map { place($0, in: rect) }
            if region.count >= 3 { drawRegion(region, current: current, in: &context, elapsed: elapsed) }
            if let box = beat.box { drawBox(box, number: offset + 1, current: current, in: &context, rect: rect, elapsed: elapsed) }
            if let box = beat.box, let to = beat.to {
                drawConnection(from: screenRect(box, rect), to: screenRect(to, rect), current: current, in: &context, elapsed: elapsed)
            }
            let points = beat.unitPath.map { place($0, in: rect) }
            if points.count >= 2 { drawPath(points, current: current, in: &context, elapsed: elapsed) }
            if let label = beat.label {
                let anchor: CGRect? = beat.box.map { screenRect($0, rect) }
                    ?? points.first.map { CGRect(x: $0.x - 6, y: $0.y - 6, width: 12, height: 12) }
                    ?? region.first.map { CGRect(x: $0.x, y: $0.y, width: 1, height: 1) }
                if let anchor { drawLabel(label, near: anchor, current: current, bounds: rect, in: &context) }
            }
        }
        if index < count, walkthrough.beats[index].zoom == true, let box = walkthrough.beats[index].box {
            drawZoom(screenRect(box, rect), bounds: rect, in: &context, elapsed: elapsed)
        }
    }

    private func screenRect(_ box: NormalizedBox, _ rect: CGRect) -> CGRect {
        let unit = box.unitRect
        return CGRect(x: rect.minX + unit.minX * rect.width, y: rect.minY + unit.minY * rect.height,
                      width: unit.width * rect.width, height: unit.height * rect.height)
    }

    /// A shaded area with a "marching" dashed outline.
    private func drawRegion(_ points: [CGPoint], current: Bool, in context: inout GraphicsContext, elapsed: Double) {
        var shape = Path()
        shape.move(to: points[0])
        for point in points.dropFirst() { shape.addLine(to: point) }
        shape.closeSubpath()
        if current {
            let fade = min(1, elapsed / 0.6)
            context.fill(shape, with: .color(Self.accent.opacity(0.22 * fade)))
            context.stroke(shape, with: .color(Self.accent.opacity(0.9 * fade)),
                           style: StrokeStyle(lineWidth: 2, lineJoin: .round, dash: [8, 5], dashPhase: CGFloat(-elapsed * 20)))
        } else {
            context.fill(shape, with: .color(.white.opacity(0.06)))
            context.stroke(shape, with: .color(.white.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
        }
    }

    /// A curved arrow from one part to another, with the second part outlined.
    private func drawConnection(from: CGRect, to: CGRect, current: Bool, in context: inout GraphicsContext, elapsed: Double) {
        let target = Path(roundedRect: to.insetBy(dx: -4, dy: -4), cornerRadius: 10)
        context.stroke(target, with: .color(current ? Self.accent : .white.opacity(0.4)),
                       style: StrokeStyle(lineWidth: current ? 2.5 : 1.5, dash: [6, 4]))
        let a = CGPoint(x: from.midX, y: from.midY)
        let b = CGPoint(x: to.midX, y: to.midY)
        let dx = b.x - a.x, dy = b.y - a.y
        let distance = max(hypot(dx, dy), 1)
        let bend: CGFloat = 0.25
        let control = CGPoint(x: (a.x + b.x) / 2 - dy / distance * distance * bend,
                              y: (a.y + b.y) / 2 + dx / distance * distance * bend)
        var points: [CGPoint] = []
        for step in 0...24 {
            let t = CGFloat(step) / 24, u = 1 - t
            points.append(CGPoint(x: u * u * a.x + 2 * u * t * control.x + t * t * b.x,
                                  y: u * u * a.y + 2 * u * t * control.y + t * t * b.y))
        }
        // Start and end at the parts' edges, not their centres.
        let fromPad = from.insetBy(dx: -6, dy: -6), toPad = to.insetBy(dx: -6, dy: -6)
        points = Array(points.drop(while: { fromPad.contains($0) }))
        while let last = points.last, toPad.contains(last) { points.removeLast() }
        if points.count >= 2 { drawPath(points, current: current, in: &context, elapsed: elapsed) }
    }

    /// A short tag next to the part (above it, or below if there is no room).
    private func drawLabel(_ text: String, near anchor: CGRect, current: Bool, bounds: CGRect, in context: inout GraphicsContext) {
        let resolved = context.resolve(Text(text).font(.system(size: 13, weight: .bold))
            .foregroundColor(current ? .black : .white))
        let size = resolved.measure(in: CGSize(width: 220, height: 40))
        var pill = CGRect(x: anchor.minX + 12, y: anchor.minY - size.height - 16, width: size.width + 16, height: size.height + 8)
        if pill.minY < bounds.minY + 4 { pill.origin.y = anchor.maxY + 8 }
        pill.origin.x = min(max(pill.minX, bounds.minX + 4), bounds.maxX - pill.width - 4)
        let shape = Path(roundedRect: pill, cornerRadius: pill.height / 2)
        context.fill(shape, with: .color(current ? Self.accent : .black.opacity(0.6)))
        context.draw(resolved, at: CGPoint(x: pill.midX, y: pill.midY))
    }

    /// A magnified bubble of a small part, in the corner farthest from it, linked by a dashed line.
    private func drawZoom(_ target: CGRect, bounds: CGRect, in context: inout GraphicsContext, elapsed: Double) {
        guard target.width > 2, target.height > 2 else { return }
        let diameter = min(150, bounds.width * 0.42)
        let inset = diameter / 2 + 12
        let corners = [
            CGPoint(x: bounds.minX + inset, y: bounds.minY + inset), CGPoint(x: bounds.maxX - inset, y: bounds.minY + inset),
            CGPoint(x: bounds.minX + inset, y: bounds.maxY - inset), CGPoint(x: bounds.maxX - inset, y: bounds.maxY - inset),
        ]
        let part = CGPoint(x: target.midX, y: target.midY)
        guard let center = corners.max(by: { hypot($0.x - part.x, $0.y - part.y) < hypot($1.x - part.x, $1.y - part.y) }) else { return }
        let appear = min(1, elapsed / 0.4)
        let bubble = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        var link = Path()
        link.move(to: part)
        link.addLine(to: center)
        context.stroke(link, with: .color(Self.accent.opacity(0.7 * appear)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
        // Scale so the part (with a margin) fills the bubble, at least 1.5× magnified.
        let scale = max(1.5, diameter / max(max(target.width, target.height) * 1.3, 1))
        let imageRect = CGRect(x: center.x - (part.x - bounds.minX) * scale, y: center.y - (part.y - bounds.minY) * scale,
                               width: bounds.width * scale, height: bounds.height * scale)
        var inside = context
        inside.opacity = appear
        inside.clip(to: Path(ellipseIn: bubble))
        inside.fill(Path(ellipseIn: bubble), with: .color(.black))
        inside.draw(inside.resolve(Image(uiImage: walkthrough.image)), in: imageRect)
        var ring = context
        ring.addFilter(.shadow(color: .black.opacity(0.5), radius: 6))
        ring.stroke(Path(ellipseIn: bubble), with: .color(Self.accent.opacity(appear)), lineWidth: 3)
    }

    private func drawBox(_ box: NormalizedBox, number: Int, current: Bool, in context: inout GraphicsContext,
                         rect: CGRect, elapsed: Double) {
        let unit = box.unitRect
        let frame = CGRect(x: rect.minX + unit.minX * rect.width, y: rect.minY + unit.minY * rect.height,
                           width: unit.width * rect.width, height: unit.height * rect.height)
        let shape = Path(roundedRect: frame.insetBy(dx: -4, dy: -4), cornerRadius: 10)
        if current {
            let pulse = 0.5 + 0.5 * sin(elapsed * 4)
            var glow = context
            glow.addFilter(.shadow(color: Self.accent.opacity(0.9), radius: 10))
            glow.stroke(shape, with: .color(Self.accent), lineWidth: 3)
            context.fill(shape, with: .color(Self.accent.opacity(0.10 + 0.08 * pulse)))
        } else {
            context.stroke(shape, with: .color(.white.opacity(0.4)), lineWidth: 1.5)
        }
        // Number badge, so earlier beats stay easy to refer to.
        let badge = CGRect(x: frame.minX - 14, y: frame.minY - 14, width: 22, height: 22)
        context.fill(Path(ellipseIn: badge), with: .color(current ? Self.accent : .white.opacity(0.55)))
        context.draw(Text("\(number)").font(.system(size: 12, weight: .bold)).foregroundColor(.black),
                     at: CGPoint(x: badge.midX, y: badge.midY))
    }

    private func drawPath(_ points: [CGPoint], current: Bool, in context: inout GraphicsContext, elapsed: Double) {
        var lengths: [CGFloat] = [0]
        for index in 1..<points.count {
            lengths.append(lengths[index - 1] + hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y))
        }
        let total = lengths.last ?? 0
        guard total > 1 else { return }
        func segment(at distance: CGFloat) -> Int {
            var part = 1
            while part < points.count - 1 && lengths[part] < distance { part += 1 }
            return part
        }
        func point(at distance: CGFloat) -> CGPoint {
            let d = min(max(distance, 0), total)
            let part = segment(at: d)
            let start = points[part - 1], end = points[part]
            let span = max(lengths[part] - lengths[part - 1], 0.001)
            let t = (d - lengths[part - 1]) / span
            return CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        }
        /// Unit direction of travel at `distance`, so arrows turn with the wire at corners.
        func direction(at distance: CGFloat) -> CGVector {
            let part = segment(at: min(max(distance, 0), total))
            let start = points[part - 1], end = points[part]
            let length = max(hypot(end.x - start.x, end.y - start.y), 0.001)
            return CGVector(dx: (end.x - start.x) / length, dy: (end.y - start.y) / length)
        }

        // The path draws itself first, led by an arrowhead, then stays.
        let progress = current ? min(1, CGFloat(elapsed / 1.4)) : 1
        let drawn = total * progress
        var line = Path()
        line.move(to: points[0])
        for index in 1..<points.count where lengths[index] <= drawn { line.addLine(to: points[index]) }
        line.addLine(to: point(at: drawn))

        if !current {
            let faded = Color.white.opacity(0.35)
            context.stroke(line, with: .color(faded), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            arrowhead(at: point(at: total), direction: direction(at: total), size: 12, color: faded, in: &context)
            return
        }
        var glow = context
        glow.addFilter(.shadow(color: Self.accent.opacity(0.9), radius: 8))
        glow.stroke(line, with: .color(Self.accent), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        context.stroke(line, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

        // Start (A): a solid dot.
        let start = points[0]
        context.fill(Path(ellipseIn: CGRect(x: start.x - 6, y: start.y - 6, width: 12, height: 12)), with: .color(Self.accent))

        if progress < 1 {
            // The pen tip: an arrowhead tracing the route.
            arrowhead(at: point(at: drawn), direction: direction(at: drawn), size: 20, color: Self.accent, in: &context)
            return
        }
        // Flowing chevrons show the direction all along the route, turning at corners.
        let spacing: CGFloat = 34
        let phase = CGFloat(elapsed * 45).truncatingRemainder(dividingBy: spacing)
        var distance = phase + 14
        while distance < total - 18 {
            chevron(at: point(at: distance), direction: direction(at: distance), in: &context)
            distance += spacing
        }
        // End (B): a solid arrowhead.
        arrowhead(at: point(at: total), direction: direction(at: total), size: 22, color: Self.accent, in: &context)
    }

    /// A filled arrowhead whose tip sits at `tip`, pointing along `direction`.
    private func arrowhead(at tip: CGPoint, direction: CGVector, size: CGFloat, color: Color, in context: inout GraphicsContext) {
        let normal = CGVector(dx: -direction.dy, dy: direction.dx)
        let base = CGPoint(x: tip.x - direction.dx * size, y: tip.y - direction.dy * size)
        let half = size * 0.55
        var head = Path()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: base.x + normal.dx * half, y: base.y + normal.dy * half))
        head.addLine(to: CGPoint(x: base.x + direction.dx * size * 0.25, y: base.y + direction.dy * size * 0.25))
        head.addLine(to: CGPoint(x: base.x - normal.dx * half, y: base.y - normal.dy * half))
        head.closeSubpath()
        var shadowed = context
        shadowed.addFilter(.shadow(color: .black.opacity(0.45), radius: 3))
        shadowed.fill(head, with: .color(color))
        context.stroke(head, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
    }

    /// A small "›" pointing along `direction`.
    private func chevron(at center: CGPoint, direction: CGVector, in context: inout GraphicsContext) {
        let normal = CGVector(dx: -direction.dy, dy: direction.dx)
        let size: CGFloat = 7
        var mark = Path()
        mark.move(to: CGPoint(x: center.x - direction.dx * size + normal.dx * size, y: center.y - direction.dy * size + normal.dy * size))
        mark.addLine(to: CGPoint(x: center.x + direction.dx * size * 0.6, y: center.y + direction.dy * size * 0.6))
        mark.addLine(to: CGPoint(x: center.x - direction.dx * size - normal.dx * size, y: center.y - direction.dy * size - normal.dy * size))
        context.stroke(mark, with: .color(.white), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }
}

/// The saved explanations: picture, title, steps and date. Tap to open, swipe to delete.
@MainActor
private struct SavedWalkthroughsView: View {
    @ObservedObject var library: WalkthroughLibrary
    let onOpen: (SavedWalkthrough) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if library.items.isEmpty {
                    ContentUnavailableView("No saved explanations", systemImage: "rectangle.stack",
                                           description: Text("Ask the assistant to explain a diagram; each explanation is saved here."))
                }
                ForEach(library.items) { item in
                    Button { onOpen(item) } label: {
                        HStack(spacing: 12) {
                            Group {
                                if let thumbnail = library.thumbnail(for: item.id) {
                                    Image(uiImage: thumbnail).resizable().scaledToFill()
                                } else {
                                    Image(systemName: "photo").foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                Text("\(item.beats.count) steps · \(item.date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { library.items[$0].id }
                    ids.forEach { library.delete($0) }
                }
            }
            .navigationTitle("Saved explanations")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}
