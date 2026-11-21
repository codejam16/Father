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
                        CaptionsOverlay(model: model, speech: speech, showHistory: { showingConversation = true })
                            .frame(height: min(260, geometry.size.height * 0.30))
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    if settings.webInfoEnabled {
                        WebInfoPanel(info: model.webInfo, isBusy: model.isBusy, isDemo: settings.demoMode || (!model.messages.isEmpty && model.lastReplyWasDemo))
                            .frame(maxHeight: min(260, geometry.size.height * 0.30))
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    HStack(spacing: 24) {
                        Button { model.toggleMicrophone() } label: {
                            Image(systemName: model.isMuted ? "mic.slash.fill" : "mic.fill")
                                .foregroundStyle(model.isMuted ? Color.red : Color.white)
                        }
                        .accessibilityLabel(model.isMuted ? "Unmute microphone" : "Mute microphone")
                        .accessibilityValue(model.isMuted ? "Muted" : "Unmuted")
                        if speech.isSpeaking {
                            Button { speech.stopSpeaking() } label: { Image(systemName: "speaker.slash.fill") }
                                .accessibilityLabel("Stop spoken reply")
                        }
                        Button { showingSettings = true } label: { Image(systemName: "gearshape.fill") }
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
                    .accessibilityLabel(settings.webInfoEnabled ? "Hide web info and disable future searches" : "Show web info and enable searches")
                    .accessibilityValue(settings.webInfoEnabled ? "On" : "Off")
                }
                .font(.system(size: 20, weight: .semibold))
                .buttonStyle(CameraControlStyle()).padding(.trailing, 16).padding(.top, 60)
            }
        }
        .background(.black)
        .sheet(isPresented: $showingSettings) { SettingsView(settings: settings) }
        .sheet(isPresented: $showingConversation) { ConversationView(model: model) }
        .onChange(of: showingSettings) { _, _ in model.setVoiceSuspended(showingSettings || showingConversation) }
        .onChange(of: showingConversation) { _, _ in model.setVoiceSuspended(showingSettings || showingConversation) }
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
    let showHistory: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Live captions", systemImage: "captions.bubble").font(.caption.bold())
                Spacer()
                Button(action: showHistory) { Image(systemName: "clock.arrow.circlepath") }
                    .accessibilityLabel("Full conversation")
            }
            .foregroundStyle(.white.opacity(0.85))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if model.messages.isEmpty && model.pendingQuestion == nil && speech.transcript.isEmpty {
                            Text("Your words appear on the right. TaskLens replies on the left.")
                                .font(.caption).foregroundStyle(.secondary).padding(.vertical, 12)
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
                            HStack { ProgressView().tint(.mint); Text("TaskLens is thinking…").font(.caption); Spacer() }
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
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.16), lineWidth: 1))
    }
}

private struct CaptionBubble: View {
    let text: String
    let isUser: Bool
    var isDraft = false

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                Text(isUser ? (isDraft ? "You · listening" : "You") : "TaskLens")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(isUser ? Color.mint : .white.opacity(0.6))
                Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(isUser ? Color.mint.opacity(0.18) : Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 14))
            if !isUser { Spacer(minLength: 40) }
        }
    }
}

@MainActor
private struct WebInfoPanel: View {
    let info: WebInfo?
    let isBusy: Bool
    let isDemo: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Label("From the web", systemImage: "globe").font(.caption.bold()).foregroundStyle(.mint)
                if let info, !info.sources.isEmpty {
                    if let summary = info.summary { Text(summary).font(.subheadline).textSelection(.enabled) }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(info.sources) { source in
                                VStack(alignment: .leading, spacing: 5) {
                                    Link(destination: source.url) {
                                        HStack(alignment: .top, spacing: 6) {
                                            Text(source.title).font(.caption.bold()).lineLimit(2)
                                            Image(systemName: "arrow.up.right").font(.caption2)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    // Native preview loads actual page imagery when the site supplies it.
                                    SourcePreview(url: source.url).frame(width: 238, height: 110).clipped()
                                }
                                .frame(width: 238).padding(10)
                                .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                    }
                    Text("Check the source for the current price and exact product match.")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let html = info.searchSuggestionHTML, !html.isEmpty {
                        SearchSuggestions(html: html).frame(height: 76).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                } else {
                    Text(isBusy ? "Looking for useful sources…" : isDemo
                         ? "Connect Gemini for live prices, shopping links and further reading. Demo mode does not search the web."
                         : "Ask a question with Web info on. Relevant sources and price details appear here when found.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.16), lineWidth: 1))
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
