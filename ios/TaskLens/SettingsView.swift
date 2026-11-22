import AVFoundation
import SwiftUI
import WebKit

@MainActor
struct SettingsView: View {
    @ObservedObject var settings: ConnectionSettings
    @ObservedObject var model: AssistantViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let error = model.errorMessage {
                    Section("Last issue") { Text(error).foregroundStyle(.orange) }
                }
                if !model.sources.isEmpty {
                    Section {
                        NavigationLink("Sources and research") { ResearchDetails(model: model) }
                    }
                }

                if !model.taskMemory.goal.isEmpty || !model.taskMemory.plan.isEmpty || !model.taskMemory.facts.isEmpty || !model.taskMemory.openQuestions.isEmpty {
                    Section("Current task") {
                        if !model.taskMemory.goal.isEmpty { Text(model.taskMemory.goal) }
                        ForEach(model.taskMemory.facts, id: \.self) { Text($0).font(.subheadline) }
                        ForEach(model.taskMemory.openQuestions, id: \.self) { Text($0).foregroundStyle(.secondary) }
                        ForEach(model.taskMemory.plan) { step in
                            VStack(alignment: .leading, spacing: 6) {
                                Label(step.text, systemImage: step.completed ? "checkmark.circle.fill" : "circle")
                                if !step.completed {
                                    Button("Mark completed") { model.confirmStep(step.id) }.disabled(model.isBusy)
                                }
                            }
                        }
                    }
                }
                Section {
                    Button("Start a new task", role: .destructive) { model.resetConversation() }
                }
                Section {
                    TextField("What are you trying to do?", text: $settings.task, axis: .vertical).lineLimit(3...6)
                } header: { Text("Task and instructions") }
                footer: { Text("Describe the goal and add any short, relevant instructions. Clear context helps the assistant avoid guessing.") }

                Section {
                    Toggle("Demo responses", isOn: $settings.demoMode)
                } footer: {
                    Text("Demo mode runs without an AI account. It does not identify objects. Turn it off to use your connected backend.")
                }

                if !settings.demoMode {
                    Section {
                        TextField("Backend URL", text: $settings.serverURL)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Connection token", text: $settings.token)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        if let error = settings.credentialError {
                            Text(error).font(.caption).foregroundStyle(.orange)
                        }
                    } header: { Text("Connection") }
                    footer: { Text("Use the backend’s address and APP_TOKEN. Your Gemini API key stays on the backend. On a physical iPhone, localhost refers to the phone.") }
                }

                Section {
                    Toggle("Guided steps", isOn: $settings.guidedMode)
                } footer: {
                    Text("Ask anything as usual. When you ask how to do something hands-on (fix, install, take apart…), the assistant switches to one step at a time and watches the camera, moving on when a step looks done. Say “done”, “skip”, “repeat” or “stop” at any time, or keep asking questions. Movement detection stays on the phone; each step check is one AI request.")
                }
                Section {
                    Toggle("Read replies aloud", isOn: $settings.spokenReplies)
                    Toggle("Interrupt by talking", isOn: $settings.interruptionsEnabled)
                        .disabled(!settings.spokenReplies)
                    Toggle("Natural AI voice (Gemini)", isOn: $settings.cloudVoiceEnabled)
                        .disabled(!settings.spokenReplies)
                    if settings.cloudVoiceEnabled {
                        Picker("AI voice", selection: $settings.cloudVoiceName) {
                            ForEach(CloudVoice.all) { voice in
                                Text("\(voice.name) · \(voice.style)").tag(voice.name)
                            }
                        }
                        .disabled(!settings.spokenReplies)
                    }
                    AssistantVoicePicker(settings: settings, speech: model.speech)
                } header: { Text("Assistant voice") } footer: {
                    Text("With Interrupt by talking on, the microphone stays on while replies play (the phone cancels its own voice), so you can say “wait” or ask something new to cut the reply off. Turn it off if it interrupts itself in a noisy room. The natural AI voice is made by Gemini on your backend (about a second per reply, and it uses your Gemini quota); the iPhone voice below is used in demo mode and whenever the AI voice is unavailable. When connected, questions send a camera image, recent conversation, and task context to your backend and AI provider. Research may generate web searches. Task memory expires on the backend after inactivity and resets when you start a new task. Demo mode stays on the phone.")
                }
                Section {
                    Toggle("Captions", isOn: $settings.captionsEnabled)
                    Toggle("Show web info", isOn: $settings.webInfoEnabled)
                    Toggle("Select a region", isOn: $settings.selectionEnabled)
                } header: { Text("Camera overlays") }
                footer: { Text("Every new question requests a web lookup when search is connected, even when web info is hidden. The info button shows a dot when hidden results are available. Drag the info handle upward to fill the screen, down to shrink it, or use its corner to adjust width. Captions have their own height handle. Turn on Select a region to tap or drag over the camera. Opening results does not search again.") }
            }
            .navigationTitle("TaskLens settings")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .onAppear { model.speech.refreshVoices() }
        .onChange(of: settings.voiceIdentifier) { _, _ in model.speech.stopSpeaking() }
        .onDisappear { model.speech.stopSpeaking() }
    }
}


@MainActor
/// A few of Gemini's prebuilt voices that suit a friendly helper.
private struct CloudVoice: Identifiable {
    let name: String
    let style: String
    var id: String { name }

    static let all: [CloudVoice] = [
        CloudVoice(name: "Achird", style: "friendly"),
        CloudVoice(name: "Sulafat", style: "warm"),
        CloudVoice(name: "Aoede", style: "breezy"),
        CloudVoice(name: "Puck", style: "upbeat"),
        CloudVoice(name: "Kore", style: "firm, clear"),
        CloudVoice(name: "Charon", style: "calm, informative"),
        CloudVoice(name: "Leda", style: "youthful"),
        CloudVoice(name: "Zephyr", style: "bright"),
    ]
}

private struct AssistantVoicePicker: View {
    @ObservedObject var settings: ConnectionSettings
    @ObservedObject var speech: SpeechService

    var body: some View {
        Group {
            Picker("Voice", selection: $settings.voiceIdentifier) {
                Text("Automatic · best available").tag("")
                if !settings.voiceIdentifier.isEmpty,
                   !speech.availableVoices.contains(where: { $0.identifier == settings.voiceIdentifier }) {
                    Text("Saved voice unavailable · using Automatic").tag(settings.voiceIdentifier)
                }
                ForEach(speech.availableVoices, id: \.identifier) { voice in
                    Text(SpeechService.voiceLabel(voice)).tag(voice.identifier)
                }
            }
            if let voice = speech.voice(for: settings.voiceIdentifier) {
                Text("Using \(SpeechService.voiceLabel(voice))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                if speech.isSpeaking { speech.stopSpeaking() }
                else {
                    speech.speak("Hi, I'm TaskLens. Show me what you're working on, and we'll figure it out together.",
                                 voiceIdentifier: settings.voiceIdentifier)
                }
            } label: {
                Label(speech.isSpeaking ? "Stop preview" : "Preview voice",
                      systemImage: speech.isSpeaking ? "stop.fill" : "speaker.wave.2")
            }
            Text("Optional: download an Enhanced or Premium English voice for more natural speech in iPhone Settings → Accessibility → Read & Speak → Voices, then return here. On older iOS, look for Spoken Content.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}


@MainActor
struct ResearchSourcesView: View {
    @ObservedObject var model: AssistantViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ResearchDetails(model: model)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

@MainActor
private struct ResearchDetails: View {
    @ObservedObject var model: AssistantViewModel

    var body: some View {
        List {
            Section("Answer") {
                Text(model.lastAnswer).textSelection(.enabled)
                ForEach(model.citedSourceIds, id: \.self) { id in
                    if let source = model.sources.first(where: { $0.id == id }),
                       let url = URL(string: source.url), url.scheme == "https" {
                        Link("[\(id)] \(source.title)", destination: url).font(.caption)
                    }
                }
            }
            Section("Sources") {
                ForEach(model.sources) { source in
                    if let url = URL(string: source.url), url.scheme == "https" {
                        Link(destination: url) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("[\(source.id)] \(source.title)")
                                Text(url.host ?? source.url).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            ForEach(Array(model.researchReports.enumerated()), id: \.offset) { _, report in
                if let html = report.searchSuggestionsHTML {
                    Section("Google Search") {
                        SearchSuggestions(html: html).frame(height: 220)
                    }
                }
                Section(report.kind == "read_source" ? "Document evidence" : "Search evidence") {
                    ForEach(Array(report.supports.enumerated()), id: \.offset) { _, support in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(support.text).font(.subheadline).textSelection(.enabled)
                            ForEach(support.sourceIds, id: \.self) { id in
                                if let source = model.sources.first(where: { $0.id == id }),
                                   let url = URL(string: source.url), url.scheme == "https" {
                                    Link("[\(id)] \(source.title)", destination: url).font(.caption)
                                }
                            }
                        }
                    }
                    DisclosureGroup("Research notes") { Text(report.text).font(.subheadline).textSelection(.enabled) }
                }
            }
        }
        .navigationTitle("Sources and research")
    }
}

// Display Google's supplied Search suggestions without altering the markup.
// No JavaScript or native message bridge; links open in the user's browser.
private struct SearchSuggestions: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        view.loadHTMLString(html, baseURL: URL(string: "https://www.google.com"))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML = ""
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url, url.scheme == "https" { UIApplication.shared.open(url) }
                decisionHandler(.cancel)
            } else {
                decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
            }
        }
    }
}
