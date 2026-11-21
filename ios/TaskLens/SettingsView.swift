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
                Section {
                    Toggle("Search online when needed", isOn: $settings.researchEnabled)
                } header: { Text("Research") }
                footer: { Text("The assistant can search for relevant information and read source pages or manuals. Research uses extra API calls and may have separate search charges. Results open with sources and Google Search suggestions; dismiss them to resume listening.") }

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
                    Toggle("Read replies aloud", isOn: $settings.spokenReplies)
                } footer: {
                    Text("When connected, questions send a camera image, recent conversation, and task context to your backend and AI provider. Research may generate web searches. Task memory expires on the backend after inactivity and resets when you start a new task. Demo mode stays on the phone.")
                }
                Section {
                    Toggle("Captions", isOn: $settings.captionsEnabled)
                    Toggle("Automatic web info", isOn: $settings.webInfoEnabled)
                } header: { Text("Camera overlays") }
<<<<<<< HEAD
                footer: { Text("Captions show both sides of the conversation over the camera. Web info adds optional source cards, price details when found, and online page previews. Search online when needed controls whether the assistant can research; turning Web info off hides the cards without disabling task research. Research can add latency and provider charges. Opening previews contacts the source websites.") }
=======
                footer: { Text("Drag the handle above captions up or down to change their height. Automatic web info is on by default: useful links appear as a small strip only when a reply has web results. Tap its chevron for details and previews, or × to dismiss that reply’s links. You can disable automatic web info here. Search may add latency and provider charges; opening previews contacts source websites.") }
>>>>>>> 70ef7a0a1e0d60728c308f85a59e138ffcd9ad5a
            }
            .navigationTitle("TaskLens settings")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
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
