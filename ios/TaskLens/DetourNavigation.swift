import Foundation
import Combine
import CoreLocation
import UserNotifications

@MainActor
final class DetourNavigation: NSObject, ObservableObject, CLLocationManagerDelegate, UNUserNotificationCenterDelegate {
    @Published private(set) var locationName: String?
    @Published private(set) var location: CLLocation?
    @Published private(set) var authorization = CLAuthorizationStatus.notDetermined
    @Published private(set) var active = false
    @Published private(set) var paused = false
    @Published private(set) var fraction = 0.0
    @Published private(set) var metresWalked = 0.0
    @Published private(set) var instruction = "Ready when you are"
    @Published private(set) var arrival: DetourPOI?
    @Published private(set) var visited: [DetourPOI] = []
    @Published private(set) var offRoute = false
    @Published private(set) var locationIssue: String?
    @Published private(set) var voiceCommands = false
    let speech = SpeechService()
    var voiceIdentifier = ""
    var onFinish: (() -> Void)?
    var onSkipStory: (() -> Void)?
    var onStory: ((DetourPOI) -> Void)?
    var onScan: (() -> Void)?
    private let manager = CLLocationManager()
    private var plan: DetourPlan?
    private var preferences = DetourPreferences()
    private var globalSteps: [DetourStep] = []
    private var stepIndex = 0
    private var processed = Set<String>()
    private var progress = 0.0
    private var pathLength = 0.0
    private var started: Date?
    private var pauseStarted: Date?
    private var pauseSeconds = 0.0
    private var previousLocation: CLLocation?
    private var lastGeocode = Date.distantPast
    private var foreground = true
    private var scannerOpen = false
    private var simulationLeg = 0
    var isSimulated: Bool { plan?.simulated == true }
    var elapsed: Double { max(0, Date().timeIntervalSince(started ?? Date()) - pauseSeconds - (pauseStarted.map { Date().timeIntervalSince($0) } ?? 0)) }
    var canUseLocation: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.activityType = .fitness
        authorization = manager.authorizationStatus
        UNUserNotificationCenter.current().delegate = self
        speech.onUtterance = { [weak self] text in self?.command(text) }
        speech.onFailure = { [weak self] message in self?.locationIssue = message; self?.voiceCommands = false }
        let category = UNNotificationCategory(identifier: "DETOUR_LANDMARK", actions: [
            UNNotificationAction(identifier: "DETOUR_LISTEN", title: "Listen", options: []),
            UNNotificationAction(identifier: "DETOUR_SKIP", title: "Skip", options: []),
            UNNotificationAction(identifier: "DETOUR_SCAN", title: "Scan", options: [.foreground]),
        ], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func requestLocation() {
        locationIssue = nil
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
        else if canUseLocation { manager.requestLocation() }
        else { locationIssue = "Location access is off. You can choose a start manually and preview routes, or enable location in iPhone Settings to navigate." }
    }

    func start(_ plan: DetourPlan, preferences: DetourPreferences) throws {
        if !plan.simulated {
            guard canUseLocation else { throw TaskLensError.message("Allow location access before starting live navigation. Manual route previews and simulation are still available.") }
            guard let location, location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 65,
                  abs(location.timestamp.timeIntervalSinceNow) < 30 else {
                requestLocation(); throw TaskLensError.message("Waiting for an accurate GPS fix. Please try Start Walk again outdoors.")
            }
            guard location.distance(from: plan.start.location) <= 150 else {
                throw TaskLensError.message("You are away from this route’s start. Go to the marked start or generate a route from your current location.")
            }
        }
        stop()
        self.plan = plan; self.preferences = preferences
        active = true; started = Date(); pauseSeconds = 0; pauseStarted = nil
        visited = []; processed = []; metresWalked = 0; previousLocation = nil; simulationLeg = 0
        preparePath(plan)
        speech.configureRecognition(language: preferences.language == "fr" ? "fr-CA" : "en-US")
        if !plan.simulated {
            manager.pausesLocationUpdatesAutomatically = false
            manager.allowsBackgroundLocationUpdates = true
            manager.startUpdatingLocation()
            Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        }
        say(plan.simulated ? localized("Simulation started. Use Advance Demo to explore the stops.", "Simulation démarrée. Utilisez Avancer pour explorer les arrêts.") : instruction)
    }

    func replaceRoute(_ plan: DetourPlan) {
        self.plan = plan; previousLocation = nil; preparePath(plan)
        say(localized("Walking route updated. ", "Itinéraire mis à jour. ") + instruction)
    }
    private func preparePath(_ plan: DetourPlan) {
        progress = 0; fraction = 0; offRoute = false; arrival = nil; stepIndex = 0
        pathLength = zip(plan.points, plan.points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        globalSteps = []
        var offset = 0.0
        for leg in plan.legs {
            let geometryLength = zip(leg.points, leg.points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
            for step in leg.steps {
                globalSteps.append(DetourStep(instruction: step.instruction, startDistance: offset + step.startDistance * geometryLength / max(1, leg.distance)))
            }
            offset += geometryLength
        }
        instruction = globalSteps.first?.instruction ?? localized("Follow the highlighted walking route.", "Suivez le parcours piéton sur la carte.")
    }

    func stop() {
        manager.stopUpdatingLocation(); manager.allowsBackgroundLocationUpdates = false
        speech.setListening(false); speech.stopSpeaking()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["detour-landmark"])
        active = false; paused = false; voiceCommands = false; scannerOpen = false
    }
    func togglePause() {
        guard active else { return }
        if paused && !isSimulated && !canUseLocation { requestLocation(); return }
        paused.toggle()
        if paused {
            pauseStarted = Date(); manager.stopUpdatingLocation(); speech.setListening(false); speech.stopSpeaking()
        } else {
            if let pauseStarted { pauseSeconds += Date().timeIntervalSince(pauseStarted) }
            pauseStarted = nil; previousLocation = nil
            if !isSimulated { manager.startUpdatingLocation() }
            updateListening(); say(instruction)
        }
    }
    func setForeground(_ foreground: Bool) { self.foreground = foreground; updateListening() }
    func setScannerOpen(_ open: Bool) {
        scannerOpen = open
        if open { speech.setListening(false); speech.stopSpeaking() }
        else { updateListening() }
    }
    func toggleVoiceCommands() { voiceCommands.toggle(); updateListening() }
    private func updateListening() { speech.setListening(active && !paused && foreground && !scannerOpen && voiceCommands) }
    func say(_ text: String) {
        guard active, !paused, !scannerOpen, !text.isEmpty else { return }
        speech.speak(text, voiceIdentifier: voiceIdentifier, language: preferences.language == "fr" ? "fr-CA" : "en-US", background: true)
    }
    func skipStory() { arrival = nil; speech.stopSpeaking(); updateListening() }
    func repeatInstruction() { say(instruction) }
    func narrate(_ text: String, for landmarkId: String) async {
        // Let a currently spoken turn/arrival prompt finish. New directions can
        // interrupt narration; a delayed story must never interrupt a turn.
        for _ in 0..<80 {
            guard !Task.isCancelled, active, !paused, !scannerOpen, !offRoute, arrival?.id == landmarkId else { return }
            if !speech.isSpeaking { say(text); return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        }
    }
    private func localized(_ en: String, _ fr: String) -> String { preferences.language == "fr" ? fr : en }

    private func command(_ text: String) {
        let value = text.lowercased()
        if ["skip", "continue", "passer", "suivant"].contains(where: value.contains) { if let onSkipStory { onSkipStory() } else { skipStory() } }
        else if ["story", "tell me", "histoire", "raconte"].contains(where: value.contains), let arrival { onStory?(arrival) }
        else if ["repeat", "répète"].contains(where: value.contains) { repeatInstruction() }
        else if value.contains("scan") { onScan?() }
        else if ["pause", "resume", "reprendre"].contains(where: value.contains) { togglePause() }
        else { say(localized("Say story, skip, repeat, scan, or pause.", "Dites histoire, passer, répète, scan ou pause.")) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }; self.authorization = status
            if self.canUseLocation { self.manager.requestLocation() }
            else if status == .denied || status == .restricted {
                if self.active && !self.isSimulated && !self.paused { self.togglePause() }
                self.locationIssue = "Location permission is unavailable. Live guidance is stopped; manual preview and simulation remain available."
            }
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor [weak self] in self?.receive(last) }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.locationIssue = "GPS is unavailable or inaccurate. Check your location permission and try outdoors." }
    }
    private func receive(_ fix: CLLocation) {
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 65, abs(fix.timestamp.timeIntervalSinceNow) < 20 else {
            if active && !isSimulated { locationIssue = "Waiting for an accurate GPS fix. Guidance is not advancing." }
            return
        }
        location = fix; locationIssue = nil
        if foreground && Date().timeIntervalSince(lastGeocode) > 120 {
            lastGeocode = Date()
            Task { [weak self] in
                guard let marks = try? await CLGeocoder().reverseGeocodeLocation(fix), let mark = marks.first else { return }
                self?.locationName = [mark.subLocality, mark.locality].compactMap { $0 }.joined(separator: ", ")
            }
        }
        guard active, !paused, !isSimulated, let plan else { return }
        let movement = previousLocation.map { fix.distance(from: $0) } ?? 0
        let fixInterval = previousLocation.map { fix.timestamp.timeIntervalSince($0.timestamp) } ?? 1
        let plausibleMovement = movement <= max(25, fixInterval * 3.5)
        if plausibleMovement && movement >= 3 { metresWalked += movement }
        previousLocation = fix
        let point = DetourPoint(fix.coordinate)
        // Progress cannot leap around a loop or jump across a nearby parallel street.
        let projected = DetourGeometry.projection(point, path: plan.points, after: max(0, progress - 15),
                                                  through: progress + min(180, max(60, movement + fix.horizontalAccuracy * 2)))
        let wasOff = offRoute; offRoute = projected.separation > 55
        if offRoute {
            if !wasOff { say(localized("You seem to be away from the route. Check the map when convenient, or recalculate.", "Vous semblez hors du parcours. Consultez la carte ou recalculez l’itinéraire.")) }
            return
        }
        progress = max(progress, projected.progress); fraction = min(1, progress / max(1, pathLength))
        var next = stepIndex
        while next + 1 < globalSteps.count && globalSteps[next + 1].startDistance <= progress + 22 { next += 1 }
        let spokeTurn = next != stepIndex
        if spokeTurn { stepIndex = next; instruction = globalSteps[next].instruction; say(instruction) }
        if let arrival, point.distance(to: arrival.point) > 110 {
            if let onSkipStory { onSkipStory() } else { skipStory() }
        }
        var endDistance = 0.0
        for leg in plan.legs {
            endDistance += zip(leg.points, leg.points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
            if let landmark = leg.landmark, !processed.contains(landmark.id), abs(progress - endDistance) < 90,
               point.distance(to: landmark.point) <= 45 { arrive(landmark, announce: !spokeTurn) }
        }
        if fraction > 0.94, let end = plan.points.last, point.distance(to: end) < 30 { onFinish?() }
    }
    private func arrive(_ landmark: DetourPOI, announce: Bool = true) {
        guard !processed.contains(landmark.id) else { return }
        processed.insert(landmark.id); visited.append(landmark); arrival = landmark
        if announce { say(localized("Nearby: \(landmark.name). Listen to its story, scan it, or keep walking.", "À proximité : \(landmark.name). Écoutez son histoire, scannez ou continuez votre balade.")) }
        if preferences.automaticStories { onStory?(landmark) }
        if !isSimulated {
            let content = UNMutableNotificationContent()
            content.title = landmark.name; content.body = localized("Listen, scan, or keep exploring.", "Écoutez, scannez ou continuez à explorer.")
            content.categoryIdentifier = "DETOUR_LANDMARK"; content.userInfo = ["landmarkId": landmark.id]
            let request = UNNotificationRequest(identifier: "detour-landmark", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { _ in }
        }
    }
    func advanceSimulation() {
        guard active, isSimulated, !paused, let plan else { return }
        guard simulationLeg < plan.legs.count else { onFinish?(); return }
        let leg = plan.legs[simulationLeg]
        metresWalked += leg.distance; simulationLeg += 1
        fraction = Double(simulationLeg) / Double(plan.legs.count)
        instruction = leg.steps.first?.instruction ?? "Simulation"
        if let landmark = leg.landmark { arrive(landmark) }
        if simulationLeg == plan.legs.count { instruction = "Simulation complete. Finish to see your demo summary." }
    }
    var simulationPosition: DetourPoint? {
        guard isSimulated, let plan else { return nil }
        return simulationLeg == 0 ? plan.start : plan.legs[min(simulationLeg - 1, plan.legs.count - 1)].end
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner]) }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["landmarkId"] as? String
        let action = response.actionIdentifier
        Task { @MainActor [weak self] in
            guard let self, self.active, self.arrival?.id == id, let landmark = self.arrival else { return }
            switch action {
            case "DETOUR_LISTEN": self.onStory?(landmark)
            case "DETOUR_SKIP": if let onSkipStory = self.onSkipStory { onSkipStory() } else { self.skipStory() }
            case "DETOUR_SCAN": self.onScan?()
            default: break
            }
        }
        completionHandler()
    }
}
