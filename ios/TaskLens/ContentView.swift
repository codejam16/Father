import SwiftUI

@MainActor
struct ContentView: View {
    @StateObject private var model = AssistantViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false
    @State private var showingConversation = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "viewfinder.circle.fill").font(.title).foregroundStyle(.mint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("TaskLens").font(.title3.bold())
                        Text("A second pair of eyes").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { showingConversation = true } label: { Image(systemName: "text.bubble") }
                        .accessibilityLabel("Conversation")
                    Button { showingSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Connection and task settings")
                }
                .buttonStyle(.bordered).tint(.white)

                CameraStage(camera: model.camera, enabled: !model.isBusy, onSelect: model.select)
                    .frame(maxHeight: .infinity)
                    .layoutPriority(1)

                AssistantControls(model: model, speech: model.speech, settings: model.settings)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Color(red: 0.035, green: 0.065, blue: 0.085))
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingSettings) { SettingsView(settings: model.settings) }
        .sheet(isPresented: $showingConversation) { ConversationView(model: model) }
        .task { await model.camera.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.camera.start() } }
            else if phase == .background { model.pause() }
        }
    }
}

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
                Text(speech.transcript.isEmpty ? "Listening… tap the microphone to finish." : speech.transcript)
                    .font(.caption).foregroundStyle(.mint).lineLimit(3)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask about what you see…", text: $model.question, axis: .vertical)
                    .lineLimit(1...3).font(.subheadline).padding(12)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                    .focused($questionFocused)
                    .disabled(model.isBusy || speech.isRecording)
                Button {
                    questionFocused = false
                    Task { await model.toggleMicrophone() }
                } label: {
                    Image(systemName: speech.isRecording ? "stop.fill" : "mic.fill")
                        .frame(width: 42, height: 44)
                        .background(speech.isRecording ? Color.red.opacity(0.8) : .white.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
                }
                .disabled(model.isBusy || speech.isPreparing)
                .accessibilityLabel(speech.isRecording ? "Finish speaking" : "Speak a question")
                Button {
                    questionFocused = false
                    if model.isBusy { model.cancel() } else { model.send() }
                } label: {
                    Image(systemName: model.isBusy ? "xmark" : "arrow.up")
                        .fontWeight(.bold).frame(width: 42, height: 44)
                        .foregroundStyle(.black).background(.mint, in: RoundedRectangle(cornerRadius: 13))
                }
                .disabled(speech.isRecording || speech.isPreparing || (!model.isBusy && model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
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
