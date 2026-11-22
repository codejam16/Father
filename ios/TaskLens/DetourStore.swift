import Foundation
import Combine
import MapKit

@MainActor
final class DetourStore: ObservableObject {
    enum Screen: Equatable { case home, preferences, preview, walk, summary }
    struct ScannerPresentation: Identifiable { let id = UUID(); let context: String? }
    @Published var screen = Screen.home
    @Published var preferences: DetourPreferences { didSet { save(preferences, key: "detour.preferences") } }
    @Published var useCurrentLocation = true
    @Published var start = DetourPoint.montreal
    @Published var startName = "Square Phillips, Montréal"
    @Published private(set) var landmarks: [DetourPOI] = []
    @Published private(set) var plan: DetourPlan?
    @Published private(set) var isGenerating = false
    @Published private(set) var loadingStory = false
    @Published private(set) var status = ""
    @Published var message: String?
    @Published private(set) var history: [DetourWalkSummary]
    @Published private(set) var lastSummary: DetourWalkSummary?
    @Published var scannerPresentation: ScannerPresentation?
    let scanner = AssistantViewModel()
    let navigation = DetourNavigation()
    var connection: ConnectionSettings { scanner.settings }
    private let planner = DetourRoutePlanner()
    private var generation: Task<Void, Never>?
    private var storyTask: Task<Void, Never>?
    private var generationId = UUID()
    private var storyId = UUID()
    private let bundled: [DetourPOI]

    init() {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let url = Bundle.main.url(forResource: "montreal-landmarks", withExtension: "json")
        bundled = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? decoder.decode(DetourCatalog.self, from: $0).landmarks } ?? []
        preferences = UserDefaults.standard.data(forKey: "detour.preferences").flatMap { try? JSONDecoder().decode(DetourPreferences.self, from: $0) } ?? DetourPreferences()
        history = UserDefaults.standard.data(forKey: "detour.history").flatMap { try? JSONDecoder().decode([DetourWalkSummary].self, from: $0) } ?? []
        landmarks = bundled
        navigation.onFinish = { [weak self] in self?.finish(completed: true) }
        navigation.onSkipStory = { [weak self] in self?.skipStory() }
        navigation.onStory = { [weak self] poi in self?.readStory(poi) }
        navigation.onScan = { [weak self] in self?.openScanner() }
        if bundled.isEmpty { message = "The bundled landmark file is missing. Check the Xcode resource build phase." }
    }
    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
    func chooseStart(_ point: DetourPoint, name: String) { start = point; startName = name; useCurrentLocation = false }
    func generate() {
        cancelGeneration(); message = nil
        let prefs = preferences
        let starting: DetourPoint
        if prefs.simulation { starting = .montreal }
        else if useCurrentLocation {
            guard let fix = navigation.location, fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 65,
                  abs(fix.timestamp.timeIntervalSinceNow) < 30 else {
                navigation.requestLocation(); message = "Waiting for GPS. Try Generate again after your location appears, or choose a start on the map."; return
            }
            starting = DetourPoint(fix.coordinate); start = starting; startName = "Current location"
        } else { starting = start }
        let id = UUID(); generationId = id; isGenerating = true; status = "Finding nearby discoveries…"
        generation = Task {
            defer { if generationId == id { isGenerating = false } }
            do {
                var pool = bundled
                var warning: String?
                let radius = min(3000, max(600, Double(prefs.minutes) * 45))
                if !prefs.simulation && !connection.demoMode {
                    do {
                        let response: DetourLandmarkResponse = try await get("detour/landmarks", query: [
                            URLQueryItem(name: "lat", value: String(starting.latitude)), URLQueryItem(name: "lon", value: String(starting.longitude)),
                            URLQueryItem(name: "radius", value: String(radius)), URLQueryItem(name: "discover", value: "1"), URLQueryItem(name: "enrich", value: "1"),
                        ])
                        pool = response.landmarks; warning = response.warning
                    } catch is CancellationError { throw CancellationError() }
                    catch { warning = "Live discovery could not connect. Using bundled municipal landmarks." }
                }
                if !prefs.simulation { pool = pool.filter { starting.distance(to: $0.point) <= radius } }
                try Task.checkCancellation()
                let visited = Set(history.filter { !$0.simulated }.flatMap(\.discoveryIds))
                let result = try await planner.generate(start: starting, landmarks: pool, preferences: prefs,
                                                        visited: visited, status: { [weak self] in self?.status = $0 })
                guard generationId == id else { return }
                landmarks = pool; plan = result; message = warning; screen = .preview
                save(prefs, key: "detour.preferences")
            } catch is CancellationError { }
            catch { if generationId == id { message = (error as? TaskLensError)?.localizedDescription ?? "Could not generate this walking route. Try again with another start or a longer duration." } }
        }
    }
    func cancelGeneration() { generationId = UUID(); generation?.cancel(); generation = nil; isGenerating = false }
    func startWalk() {
        guard let plan else { return }
        do { navigation.voiceIdentifier = connection.voiceIdentifier; try navigation.start(plan, preferences: preferences); message = nil; screen = .walk }
        catch { message = error.localizedDescription }
    }
    func finish(completed: Bool) {
        guard navigation.active, let plan else { return }
        cancelGeneration()
        storyId = UUID(); storyTask?.cancel(); loadingStory = false
        let summary = DetourWalkSummary(id: UUID(), date: Date(), seconds: navigation.elapsed,
            metres: navigation.metresWalked, discoveries: navigation.visited.map(\.name), discoveryIds: navigation.visited.map(\.id),
            simulated: plan.simulated, completed: completed)
        navigation.stop(); history.insert(summary, at: 0); history = Array(history.prefix(30))
        save(history, key: "detour.history"); lastSummary = summary; screen = .summary
    }
    func openScanner() {
        storyId = UUID(); storyTask?.cancel(); loadingStory = false
        navigation.setScannerOpen(true)
        scannerPresentation = ScannerPresentation(context: navigation.active ? navigation.arrival?.scannerContext
            ?? plan?.stops.first(where: { poi in !navigation.visited.contains(where: { $0.id == poi.id }) })?.scannerContext : nil)
    }
    func closeScanner() { scanner.pause(); navigation.setScannerOpen(false) }
    func setForeground(_ foreground: Bool) {
        navigation.setForeground(foreground)
        if foreground { navigation.speech.refreshVoices() }
        else { scanner.pause() }
    }
    func readStory(_ poi: DetourPOI) {
        guard navigation.active, !navigation.paused else { return }
        storyTask?.cancel(); let id = UUID(); storyId = id
        let generateAI = preferences.aiStories && !preferences.simulation && !connection.demoMode && bundled.contains(where: { $0.id == poi.id })
        loadingStory = true
        storyTask = Task {
            defer { if storyId == id { loadingStory = false } }
            var text = poi.summary(language: preferences.language)
            if generateAI {
                do {
                    let story: DetourStory = try await post("detour/story", body: ["landmarkId": poi.id, "language": preferences.language])
                    text = story.story
                } catch is CancellationError { return }
                catch {
                    guard storyId == id, navigation.active, !Task.isCancelled else { return }
                    message = "The optional AI story was unavailable. Reading the sourced record instead."
                }
            }
            guard storyId == id, navigation.active, !Task.isCancelled else { return }
            await navigation.narrate(text, for: poi.id)
        }
    }
    func skipStory() { storyId = UUID(); storyTask?.cancel(); loadingStory = false; navigation.skipStory() }
    func reroute() {
        guard navigation.active, !navigation.isSimulated, let fix = navigation.location, let old = plan else { return }
        cancelGeneration(); let id = UUID(); generationId = id; isGenerating = true
        generation = Task {
            defer { if generationId == id { isGenerating = false } }
            do {
                let remaining = old.stops.filter { poi in !navigation.visited.contains(where: { $0.id == poi.id }) }
                var legs: [DetourLeg] = [], previous = DetourPoint(fix.coordinate)
                for poi in remaining {
                    try Task.checkCancellation(); status = "Recalculating walking paths…"
                    let leg = try await planner.leg(from: previous, to: poi.point, landmark: poi)
                    legs.append(leg); previous = poi.point
                }
                if preferences.returnToStart { legs.append(try await planner.leg(from: previous, to: old.start, landmark: nil)) }
                guard !legs.isEmpty else { finish(completed: true); return }
                guard generationId == id, navigation.active else { return }
                let update = DetourPlan(start: DetourPoint(fix.coordinate), stops: remaining, legs: legs,
                    estimatedSeconds: legs.reduce(0) { $0 + $1.seconds } * preferences.pace.multiplier,
                    simulated: false, notes: ["Route recalculated from your current position; the new estimate can exceed the original time budget."])
                plan = update; navigation.replaceRoute(update)
            } catch is CancellationError { }
            catch { message = "Could not recalculate. The previous route is still visible; no replacement path was invented." }
        }
    }
    private func request(_ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard let base = URL(string: connection.serverURL), ["http", "https"].contains(base.scheme ?? ""), base.host != nil,
              base.user == nil, base.password == nil else { throw TaskLensError.message("Check the backend URL in Settings.") }
        var parts = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url else { throw TaskLensError.message("The backend URL is invalid.") }
        var request = URLRequest(url: url); request.timeoutInterval = 50
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        return request
    }
    private func decode<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw TaskLensError.message("The Detour service is unavailable.") }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
    private func get<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> T { try await decode(request(path, query: query)) }
    private func post<T: Decodable>(_ path: String, body: [String: String]) async throws -> T {
        var request = try request(path); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONEncoder().encode(body)
        return try await decode(request)
    }
}
