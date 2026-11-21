import SwiftUI

@MainActor
struct ContentView: View {
    @StateObject private var model = AssistantViewModel()
    @Environment(\.scenePhase) private var scenePhase
    private enum Sheet: String, Identifiable { case settings, sources; var id: String { rawValue } }
    @State private var activeSheet: Sheet?

    var body: some View {
        ZStack(alignment: .bottom) {
            ImmersiveCamera(camera: model.camera, enabled: !model.isBusy, onSelect: model.select)
                .ignoresSafeArea()

                HStack(spacing: 24) {
                    Button { model.toggleMicrophone() } label: {
                        Image(systemName: model.isMuted ? "mic.slash.fill" : "mic.fill")
                            .foregroundStyle(model.isMuted ? Color.red : Color.white)
                    }
                    .accessibilityLabel(model.isMuted ? "Unmute microphone" : "Mute microphone")
                    .accessibilityValue(model.isMuted ? "Muted" : "Unmuted")

                    Button { activeSheet = .settings } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel("Settings")
                }
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .buttonStyle(CameraControlStyle())
                .padding(.bottom, 20)
            }
            .background(.black)
            .preferredColorScheme(.dark)
            .statusBarHidden()
            .sheet(item: $activeSheet) { sheet in
                if sheet == .settings { SettingsView(settings: model.settings, model: model) }
                else { ResearchSourcesView(model: model) }
            }
            .task { await model.resume() }
            .onChange(of: activeSheet) { _, sheet in
                model.setVoiceSuspended(sheet != nil, stopPlayback: sheet == .settings)
            }
            .onChange(of: model.researchReviewID) { _, review in
                if review != nil { activeSheet = .sources }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.resume() } }
                else { model.pause() }
            }
    }
}

private struct CameraControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 58, height: 58)
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
            // Enlarge the entire stage together, keeping selection and pointer
            // coordinates aligned with the camera image after the edge crop.
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

// Retained for a future transcript/typed-input interface; not mounted on the camera screen.

@MainActor
private struct AssistantControls: View {
    @ObservedObject var model: AssistantViewModel
    @ObservedObject var speech: SpeechService
    @ObservedObject var settings: ConnectionSettings
    @FocusState private var questionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(model.isBusy ? "Looking…" : "Your assistant", systemImage: "sparkles")
                    .font(.caption.weight(.semibold)).foregroundStyle(.mint)
                Spacer()
                if settings.demoMode || (!model.messages.isEmpty && model.lastReplyWasDemo) {
                    Text("DEMO REPLIES").font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.yellow)
                }
                Button { speech.stopSpeaking() } label: { Image(systemName: "speaker.slash") }
                    .accessibilityLabel("Stop spoken reply").foregroundStyle(.secondary)
            }
            ScrollView {
                Text(model.lastAnswer).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 85)
            if model.selectedFrame != nil {
                HStack {
                    Label("Selected view attached to next question", systemImage: "scope")
                        .font(.caption2).foregroundStyle(.yellow)
                    Spacer()
                    Button("Clear") { model.clearSelection() }.font(.caption)
                }
            }
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if speech.isRecording {
                Text(speech.transcript.isEmpty ? "Listening… pause to send your question." : speech.transcript)
                    .font(.caption).foregroundStyle(.mint).lineLimit(3)
            }
            if !speech.isRecording {
                Text(model.isMuted ? "Microphone muted" : speech.isSpeaking ? "Speaking… listening resumes after the reply." : model.isBusy ? "Thinking… listening resumes after the reply." : "Preparing microphone…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask about what you see…", text: $model.question, axis: .vertical)
                    .lineLimit(1...3).font(.subheadline).padding(12)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                    .focused($questionFocused)
                    .disabled(model.isBusy)
                Button {
                    questionFocused = false
                    model.toggleMicrophone()
                } label: {
                    Image(systemName: model.isMuted ? "mic.slash.fill" : "mic.fill")
                        .frame(width: 42, height: 44)
                        .background(model.isMuted ? .white.opacity(0.1) : Color.mint.opacity(0.25), in: RoundedRectangle(cornerRadius: 13))
                }
                .accessibilityLabel(model.isMuted ? "Unmute microphone" : "Mute microphone")
                Button {
                    questionFocused = false
                    if model.isBusy { model.cancel() } else { model.send() }
                } label: {
                    Image(systemName: model.isBusy ? "xmark" : "arrow.up")
                        .fontWeight(.bold).frame(width: 42, height: 44)
                        .foregroundStyle(.black).background(.mint, in: RoundedRectangle(cornerRadius: 13))
                }
                .disabled(!model.isBusy && model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(model.isBusy ? "Cancel question" : "Send question")
            }
        }
        .padding(16)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 22))
    }
}

@MainActor
private struct ConversationView: View {
    @ObservedObject var model: AssistantViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.messages.isEmpty {
                    ContentUnavailableView("Start a conversation", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Your questions and the assistant’s replies appear here."))
                }
                ForEach(model.messages) { message in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message.role == .user ? "You" : "TaskLens").font(.caption.bold()).foregroundStyle(.secondary)
                        Text(message.content).textSelection(.enabled)
                    }.padding(.vertical, 5)
                }
            }
            .navigationTitle("Conversation")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("New") { model.resetConversation(); dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}
