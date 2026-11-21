import SwiftUI
import LinkPresentation
import WebKit

@MainActor
struct ContentView: View {
    @StateObject private var model = AssistantViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        CameraExperience(model: model, speech: model.speech, settings: model.settings)
            .preferredColorScheme(.dark)
            .statusBarHidden()
            .task { await model.resume() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.resume() } }
                else { model.pause() }
            }
    }
}

@MainActor
private struct CameraExperience: View {
    @ObservedObject var model: AssistantViewModel
    @ObservedObject var speech: SpeechService
    @ObservedObject var settings: ConnectionSettings
    @State private var showingSettings = false
    @State private var showingConversation = false
    @State private var dismissedWebReply: UUID?
    @AppStorage("captionHeightFraction") private var captionHeightFraction = 0.22

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                ImmersiveCamera(camera: model.camera, enabled: !model.isBusy, onSelect: model.select)
                    .ignoresSafeArea()

                VStack(spacing: 10) {
                    if let error = model.errorMessage {
                        ScrollView {
                            Text(error).font(.caption).foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        }
                        .frame(maxHeight: 70)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
                    }
                    if model.selectedFrame != nil {
                        HStack {
                            Label("Selected view", systemImage: "scope").font(.caption)
                            Spacer()
                            Button("Clear", action: model.clearSelection).font(.caption.bold())
                        }
                        .padding(10).background(.ultraThinMaterial, in: Capsule())
                    }
                    if settings.captionsEnabled {
                        CaptionsOverlay(model: model, speech: speech, heightFraction: $captionHeightFraction,
                                        availableHeight: geometry.size.height, showHistory: { showingConversation = true })
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    if settings.webInfoEnabled, let info = model.webInfo, !info.sources.isEmpty,
                       let replyID = model.messages.last?.id, dismissedWebReply != replyID {
                        WebInfoStrip(info: info) { dismissedWebReply = replyID }
                            .id(replyID)
                            .transition(.opacity)
                    }
                    HStack(spacing: 24) {
                        Button { model.toggleMicrophone() } label: {
                            Image(systemName: model.isMuted ? "mic.slash.fill" : "mic.fill")
                                .foregroundStyle(model.isMuted ? Color.red : Color.white)
                        }
                        .accessibilityLabel(model.isMuted ? "Unmute microphone" : "Mute microphone")
                        .accessibilityValue(model.isMuted ? "Muted" : "Unmuted")
                        Button { activeSheet = .settings } label: { Image(systemName: "gearshape.fill") }
                            .accessibilityLabel("Settings")
                    }
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white).buttonStyle(CameraControlStyle())
                    .padding(.top, 4)
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
            }
            .overlay(alignment: .topLeading) {
                Text(settings.demoMode ? "DEMO · \(voiceStatus)" : voiceStatus)
                    .font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule()).padding(16)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topTrailing) {
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
                    }
                    .accessibilityLabel(settings.webInfoEnabled ? "Disable automatic web info" : "Enable automatic web info")
                    .accessibilityValue(settings.webInfoEnabled ? "On" : "Off")
                }
                .font(.system(size: 20, weight: .semibold))
                .buttonStyle(CameraControlStyle()).padding(.trailing, 16).padding(.top, 60)
            }
        }
        .background(.black)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .settings: SettingsView(settings: settings, model: model)
            case .conversation: ConversationView(model: model)
            case .sources: ResearchSourcesView(model: model)
            }
        }
        .onChange(of: activeSheet) { _, sheet in
            model.setVoiceSuspended(sheet != nil, stopPlayback: sheet != .sources)
        }
        .onChange(of: model.researchReviewID) { _, review in
            if review != nil { activeSheet = .sources }
        }
    }

    private var voiceStatus: String {
        if model.isBusy { return "Thinking…" }
        if speech.isSpeaking { return "Speaking…" }
        if model.isMuted { return "Microphone muted" }
        return speech.isRecording ? "Listening" : "Preparing microphone…"
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
    let showHistory: () -> Void
    @GestureState private var resizeOffset: CGFloat = 0

    private var minimumFraction: Double { min(0.55, 112 / Double(max(availableHeight, 1))) }
    private func clamped(_ fraction: Double) -> Double {
        min(0.55, max(minimumFraction, fraction.isFinite ? fraction : 0.22))
    }
    private var currentHeight: CGFloat {
        CGFloat(clamped(heightFraction - Double(resizeOffset / max(availableHeight, 1)))) * availableHeight
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text("Captions").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.5))
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
        .background(Color(white: 0.18).opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
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
            .background(Color(white: isUser ? 0.30 : 0.20).opacity(0.32), in: RoundedRectangle(cornerRadius: 13))
            if !isUser { Spacer(minLength: 42) }
        }
    }
}

@MainActor
private struct WebInfoStrip: View {
    let info: WebInfo
    let dismiss: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "globe").font(.caption2).foregroundStyle(.white.opacity(0.6))
                Text(info.summary ?? "Related sources")
                    .font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.up").font(.caption2)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel(expanded ? "Collapse web details" : "Expand web details and images")
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10)).frame(width: 32, height: 32) }
                    .accessibilityLabel("Dismiss these sources")
            }
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
            if expanded {
                WebInfoDetails(info: info)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 5)
        .background(Color(white: 0.15).opacity(0.48), in: RoundedRectangle(cornerRadius: 16))
        .foregroundStyle(.white.opacity(0.7))
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
        // Only explicitly expanded details scroll; the automatic strip sizes to its content.
        .frame(maxHeight: 230)
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
