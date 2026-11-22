import Combine
import Foundation
import Security

@MainActor
final class ConnectionSettings: ObservableObject {
    @Published var researchEnabled: Bool { didSet { defaults.set(researchEnabled, forKey: "researchEnabled") } }
    @Published var demoMode: Bool { didSet { defaults.set(demoMode, forKey: "demoMode") } }
    @Published var serverURL: String { didSet { defaults.set(serverURL, forKey: "serverURL") } }
    @Published var task: String { didSet { defaults.set(task, forKey: "task") } }
    @Published var spokenReplies: Bool { didSet { defaults.set(spokenReplies, forKey: "spokenReplies") } }
    @Published var guidedMode: Bool { didSet { defaults.set(guidedMode, forKey: "guidedMode") } }
    @Published var interruptionsEnabled: Bool { didSet { defaults.set(interruptionsEnabled, forKey: "interruptionsEnabled") } }
    /// Empty means "Automatic": the most natural installed English voice.
    @Published var voiceIdentifier: String { didSet { defaults.set(voiceIdentifier, forKey: "voiceIdentifier") } }
    @Published var captionsEnabled: Bool { didSet { defaults.set(captionsEnabled, forKey: "captionsEnabled") } }
    @Published var webInfoEnabled: Bool { didSet { defaults.set(webInfoEnabled, forKey: "webInfoEnabled") } }
    @Published var token: String { didSet { saveToken() } }
    @Published private(set) var credentialError: String?
    private let defaults = UserDefaults.standard
    private let service = "TaskLens.ProxyToken"

    init() {
        let defaults = UserDefaults.standard
        let service = "TaskLens.ProxyToken"
        researchEnabled = defaults.object(forKey: "researchEnabled") as? Bool ?? true
        demoMode = defaults.object(forKey: "demoMode") as? Bool ?? true
        serverURL = defaults.string(forKey: "serverURL") ?? "http://localhost:8787"
        task = defaults.string(forKey: "task") ?? ""
        spokenReplies = defaults.object(forKey: "spokenReplies") as? Bool ?? true
        guidedMode = defaults.object(forKey: "guidedMode") as? Bool ?? true
        interruptionsEnabled = defaults.object(forKey: "interruptionsEnabled") as? Bool ?? true
        voiceIdentifier = defaults.string(forKey: "voiceIdentifier") ?? ""
        captionsEnabled = defaults.object(forKey: "captionsEnabled") as? Bool ?? false
        // Adopt the new automatic default once, including existing installations.
        // Later explicit opt-outs remain saved across launches.
        if !defaults.bool(forKey: "automaticWebInfoDefaultV1") {
            defaults.set(true, forKey: "webInfoEnabled")
            defaults.set(true, forKey: "automaticWebInfoDefaultV1")
        }
        webInfoEnabled = defaults.object(forKey: "webInfoEnabled") as? Bool ?? true
        var item: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: "proxy",
                                   kSecReturnData as String: true]
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        token = status == errSecSuccess ? String(data: item as? Data ?? Data(), encoding: .utf8) ?? "" : ""
    }

    private func saveToken() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: "proxy"]
        SecItemDelete(query as CFDictionary)
        guard !token.isEmpty else { credentialError = nil; return }
        var entry = query
        entry[kSecValueData as String] = Data(token.utf8)
        entry[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(entry as CFDictionary, nil)
        credentialError = status == errSecSuccess ? nil : "The connection token could not be saved securely."
    }
}
