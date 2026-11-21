import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var settings: ConnectionSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
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
                    Text("When connected, asking a question sends the selected camera view and recent conversation to your backend and AI provider. Demo mode stays on the phone. Camera frames are held temporarily in memory.")
                }
            }
            .navigationTitle("TaskLens settings")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
