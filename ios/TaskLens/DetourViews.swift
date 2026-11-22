import SwiftUI
import MapKit
import UIKit

private enum DetourStyle {
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.66, green: 0.77, blue: 0.63, alpha: 1) : UIColor(red: 0.09, green: 0.24, blue: 0.21, alpha: 1)
    })
    static let forest = Color(red: 0.09, green: 0.24, blue: 0.21)
    static let sage = Color(red: 0.66, green: 0.77, blue: 0.63)
    static let orange = Color(red: 0.90, green: 0.65, blue: 0.36)
}
private struct DetourPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).foregroundStyle(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 17)
            .background(DetourStyle.forest.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 19))
    }
}
private extension View {
    func detourCard() -> some View {
        padding(18).background(.background, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(.primary.opacity(0.08), lineWidth: 1))
    }
}

@MainActor
struct DetourRootView: View {
    @StateObject private var store = DetourStore()
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            screen
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(store.screen == .home ? .hidden : .visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if store.screen != .home {
                            Button { store.cancelGeneration(); store.screen = .home } label: { Image(systemName: "house") }
                                .accessibilityLabel("Detour home")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if store.screen != .home { Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") } }
                    }
                }
                .safeAreaInset(edge: .bottom) { messageBanner }
        }
        .tint(DetourStyle.accent)
        .sheet(isPresented: $showSettings) { SettingsView(settings: store.connection, model: store.scanner) }
        .onChange(of: showSettings) { _, open in
            store.navigation.voiceIdentifier = store.connection.voiceIdentifier
            store.navigation.setScannerOpen(open)
        }
        .fullScreenCover(item: $store.scannerPresentation, onDismiss: store.closeScanner) { presentation in
            ContentView(model: store.scanner, discoveryContext: presentation.context)
                .overlay(alignment: .topLeading) {
                    Button { store.scannerPresentation = nil } label: {
                        Image(systemName: "chevron.down").font(.headline).foregroundStyle(.white)
                            .frame(width: 42, height: 42).background(.ultraThinMaterial, in: Circle())
                    }
                    .padding(.leading, 16).padding(.top, 12).accessibilityLabel("Return to Detour")
                }
        }
        .onChange(of: scenePhase) { _, phase in store.setForeground(phase == .active) }
    }
    private var title: String {
        switch store.screen { case .home: "Detour"; case .preferences: "Your kind of walk"; case .preview: "A little out of the ordinary"; case .walk: "Your Detour"; case .summary: "A walk worth taking" }
    }
    @ViewBuilder private var screen: some View {
        switch store.screen {
        case .home: DetourHome(store: store, navigation: store.navigation, settings: { showSettings = true })
        case .preferences: DetourPreferencesView(store: store, navigation: store.navigation)
        case .preview:
            if let plan = store.plan { DetourPreview(store: store, plan: plan) }
        case .walk: DetourWalkView(store: store, navigation: store.navigation)
        case .summary:
            if let summary = store.lastSummary { DetourSummaryView(summary: summary) { store.screen = .home } }
        }
    }
    @ViewBuilder private var messageBanner: some View {
        if let message = store.message {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle")
                Text(message).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                Button { store.message = nil } label: { Image(systemName: "xmark").padding(5) }.accessibilityLabel("Dismiss message")
            }
            .padding(14).background(DetourStyle.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 16)).padding(.horizontal)
        }
    }
}

@MainActor
private struct DetourHome: View {
    @ObservedObject var store: DetourStore
    @ObservedObject var navigation: DetourNavigation
    let settings: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                HStack {
                    Label("detour", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                        .font(.system(size: 29, weight: .bold, design: .rounded))
                    Spacer()
                    Button(action: settings) { Image(systemName: "slider.horizontal.3").padding(12).background(.primary.opacity(0.05), in: Circle()) }
                        .accessibilityLabel("Settings")
                }
                DetourHero().frame(height: 210).clipShape(RoundedRectangle(cornerRadius: 30))
                VStack(alignment: .leading, spacing: 10) {
                    Text("Take the\nscenic way.").font(.system(size: 43, weight: .bold, design: .rounded)).tracking(-1.6)
                    Text("Look up. Listen in. Discover more.").font(.headline).foregroundStyle(.secondary)
                    Label(navigation.locationName ?? (navigation.location == nil ? "Discover Montréal, one little detour at a time." : "Current location ready"), systemImage: "location")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Button { store.screen = navigation.active ? .walk : .preferences } label: {
                    Label(navigation.active ? "Continue My Walk" : "Start Exploring", systemImage: "figure.walk")
                }.buttonStyle(DetourPrimaryButton())
                Button { store.openScanner() } label: {
                    Label("Explore with AI", systemImage: "viewfinder").font(.headline).frame(maxWidth: .infinity).padding(16)
                        .background(DetourStyle.sage.opacity(0.22), in: RoundedRectangle(cornerRadius: 19))
                }
                if let recent = store.history.first {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text("YOUR LAST DETOUR").font(.caption.weight(.bold)); Spacer(); if recent.simulated { Text("SIMULATION").font(.caption2.bold()).foregroundStyle(.orange) } }
                        Text("\(recent.discoveries.count) discoveries · \(Int(recent.metres)) m").font(.title3.bold())
                        Text(recent.date, style: .date).font(.caption).foregroundStyle(.secondary)
                        if let first = recent.discoveries.first { Text(first).font(.subheadline) }
                    }.frame(maxWidth: .infinity, alignment: .leading).detourCard()
                }
                Text("Real walking routes. Small discoveries. More eyes-up time.").font(.footnote).foregroundStyle(.secondary)
            }.padding(22)
        }.background(DetourStyle.sage.opacity(0.10))
    }
}
private struct DetourHero: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                DetourStyle.forest
                Canvas { context, size in
                    for index in 0..<7 {
                        var street = Path(); let x = CGFloat(index) * size.width / 5
                        street.move(to: CGPoint(x: x, y: 0)); street.addLine(to: CGPoint(x: x - 70, y: size.height))
                        context.stroke(street, with: .color(.white.opacity(0.07)), lineWidth: 18)
                    }
                    var path = Path(); path.move(to: CGPoint(x: 30, y: size.height - 35))
                    path.addCurve(to: CGPoint(x: size.width - 35, y: 38), control1: CGPoint(x: size.width * 0.85, y: size.height), control2: CGPoint(x: size.width * 0.12, y: 0))
                    context.stroke(path, with: .color(DetourStyle.sage), style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [5, 8]))
                }
                Image(systemName: "leaf.fill").font(.system(size: 31)).foregroundStyle(DetourStyle.sage).position(x: geometry.size.width * 0.31, y: 53)
                Image(systemName: "building.columns.fill").font(.system(size: 32)).foregroundStyle(DetourStyle.orange).position(x: geometry.size.width * 0.7, y: 133)
                Image(systemName: "location.north.circle.fill").font(.system(size: 42)).foregroundStyle(.white).position(x: geometry.size.width - 35, y: 38)
                Text("A good walk\nhas a few surprises.").font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.8)).position(x: 100, y: geometry.size.height - 43)
            }
        }.accessibilityLabel("An illustrated walking route connecting nature and architecture")
    }
}

@MainActor
private struct DetourPreferencesView: View {
    @ObservedObject var store: DetourStore
    @ObservedObject var navigation: DetourNavigation
    @State private var startMode = 0
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    var body: some View {
        Form {
            Section {
                Toggle("Indoor simulation", isOn: $store.preferences.simulation)
                if store.preferences.simulation { Text("SIMULATION · no GPS, AI calls or real pedestrian directions. Positions, dashed lines and timings are schematic.").font(.caption).foregroundStyle(.orange) }
            } header: { Text("Walk mode") }
            if !store.preferences.simulation {
                Section("Starting point") {
                    Picker("Choose a start", selection: $startMode) { Text("GPS").tag(0); Text("Search").tag(1); Text("Map pin").tag(2) }.pickerStyle(.segmented)
                        .onChange(of: startMode) { _, mode in store.useCurrentLocation = mode == 0 }
                    if startMode == 0 {
                        Button("Use current location", action: navigation.requestLocation)
                        if let location = navigation.location { Text(String(format: "%.4f, %.4f", location.coordinate.latitude, location.coordinate.longitude)).font(.caption).foregroundStyle(.secondary) }
                        if let issue = navigation.locationIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
                    } else if startMode == 1 {
                        HStack {
                            TextField("Neighbourhood, address or place", text: $query).onSubmit { search() }
                            Button(action: search) { if searching { ProgressView() } else { Image(systemName: "magnifyingglass") } }.disabled(searching || query.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        ForEach(Array(results.enumerated()), id: \.offset) { _, item in
                            Button { store.chooseStart(DetourPoint(item.placemark.coordinate), name: item.name ?? "Selected place"); results = [] } label: {
                                VStack(alignment: .leading) { Text(item.name ?? "Place"); Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    } else {
                        DetourMap(start: store.start, stops: [], plan: nil, showUser: navigation.canUseLocation) { point in store.chooseStart(point, name: "Dropped map pin") }
                            .frame(height: 230).clipShape(RoundedRectangle(cornerRadius: 18))
                        Text("Tap the map to set a start.").font(.caption).foregroundStyle(.secondary)
                    }
                    if startMode != 0 { Text(store.startName).font(.subheadline) }
                }
            }
            Section("Time outside") {
                Picker("Duration", selection: $store.preferences.minutes) { ForEach([15, 30, 45, 60], id: \.self) { Text("\($0) min").tag($0) } }.pickerStyle(.segmented)
            }
            Section("What catches your eye?") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                    ForEach(DetourInterest.allCases) { interest in
                        Button { toggle(interest) } label: {
                            Label(interest.title, systemImage: interest.symbol).font(.subheadline)
                                .frame(maxWidth: .infinity, minHeight: 35).padding(6)
                                .background(store.preferences.interests.contains(interest) ? DetourStyle.sage.opacity(0.5) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain).accessibilityAddTraits(store.preferences.interests.contains(interest) ? .isSelected : [])
                    }
                }
            }
            Section("Make it yours") {
                Toggle("Return to starting point", isOn: $store.preferences.returnToStart)
                Toggle("Prefer new discoveries", isOn: $store.preferences.preferNew)
                Picker("Discovery frequency", selection: $store.preferences.frequency) { ForEach(DetourFrequency.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                Picker("Walking pace", selection: $store.preferences.pace) { ForEach(DetourPace.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                Picker("Narration", selection: $store.preferences.language) { Text("English").tag("en"); Text("Français").tag("fr") }
                Toggle("Automatically read source summaries", isOn: $store.preferences.automaticStories)
                Toggle("Optional AI-written stories", isOn: $store.preferences.aiStories)
                Text("AI stories use your connected backend. Without one, sourced summaries still work. Street instruction wording follows the map service’s device language.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if store.isGenerating {
                    ProgressView(store.status).font(.caption)
                    Button("Cancel generation", role: .cancel, action: store.cancelGeneration)
                } else {
                    Button(action: store.generate) { Text(store.preferences.simulation ? "Generate Demo Detour" : "Generate My Detour").frame(maxWidth: .infinity) }
                        .buttonStyle(DetourPrimaryButton()).disabled(store.preferences.interests.isEmpty)
                }
            }
        }.onAppear { startMode = store.useCurrentLocation ? 0 : 2 }
    }
    private func toggle(_ interest: DetourInterest) {
        if store.preferences.interests.contains(interest) { store.preferences.interests.remove(interest) }
        else { store.preferences.interests.insert(interest) }
    }
    private func search() {
        guard !searching, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }; searching = true
        let text = query
        Task {
            defer { searching = false }
            let request = MKLocalSearch.Request(); request.naturalLanguageQuery = text
            request.region = MKCoordinateRegion(center: store.start.coordinate, latitudinalMeters: 8000, longitudinalMeters: 8000)
            do { results = try await MKLocalSearch(request: request).start().mapItems }
            catch { store.message = "Place search is unavailable. Choose a point on the map instead." }
        }
    }
}

@MainActor
private struct DetourPreview: View {
    @ObservedObject var store: DetourStore
    let plan: DetourPlan
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if plan.simulated { DetourSimulationBanner() }
                DetourMap(start: plan.start, stops: plan.stops, plan: plan, showUser: store.navigation.canUseLocation && !plan.simulated)
                    .frame(height: 320).clipShape(RoundedRectangle(cornerRadius: 26))
                HStack(spacing: 20) {
                    metric("\(Int(ceil(plan.estimatedSeconds / 60))) min", caption: plan.simulated ? "Demo timing" : "Walk + brief stops")
                    metric(String(format: "%.1f km", plan.distance / 1000), caption: plan.simulated ? "Schematic distance" : "Pedestrian paths")
                    metric("\(plan.stops.count)", caption: "Discoveries")
                }.frame(maxWidth: .infinity).detourCard()
                ForEach(plan.notes, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
                Text("ALONG YOUR WAY").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                ForEach(Array(plan.stops.enumerated()), id: \.element.id) { index, poi in
                    NavigationLink { DetourPOIDetail(poi: poi, language: store.preferences.language) } label: {
                        HStack(spacing: 12) {
                            Text("\(index + 1)").font(.headline).frame(width: 34, height: 34).background(DetourStyle.sage.opacity(0.3), in: Circle())
                            VStack(alignment: .leading, spacing: 4) { Text(poi.name).font(.headline); Text(poi.sourceName).font(.caption).foregroundStyle(.secondary) }
                            Spacer(); Image(systemName: "chevron.right").font(.caption)
                        }.frame(maxWidth: .infinity, alignment: .leading).detourCard()
                    }.buttonStyle(.plain)
                }
                Button(action: store.startWalk) { Label(plan.simulated ? "Start Indoor Simulation" : "Start Walk", systemImage: "figure.walk") }.buttonStyle(DetourPrimaryButton())
                Button("Change preferences") { store.screen = .preferences }.frame(maxWidth: .infinity)
                DetourAttributionLink()
            }.padding(20)
        }.background(DetourStyle.sage.opacity(0.08))
    }
    private func metric(_ value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(value).font(.title3.bold()); Text(caption).font(.caption2).foregroundStyle(.secondary) }
    }
}

@MainActor
private struct DetourWalkView: View {
    @ObservedObject var store: DetourStore
    @ObservedObject var navigation: DetourNavigation
    var body: some View {
        if let plan = store.plan {
            VStack(spacing: 0) {
                if plan.simulated { DetourSimulationBanner() }
                DetourMap(start: plan.start, stops: plan.stops, plan: plan, showUser: navigation.canUseLocation && !plan.simulated,
                          simulatedPosition: navigation.simulationPosition)
                    .overlay(alignment: .top) { guidance.padding(14) }
                    .safeAreaInset(edge: .bottom) { controls(plan: plan) }
            }
        }
    }
    private var guidance: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(navigation.paused ? "Walk paused" : navigation.offRoute ? "Away from the route" : "Your next step",
                  systemImage: navigation.paused ? "pause.circle" : navigation.offRoute ? "location.slash" : "arrow.triangle.turn.up.right.diamond")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(navigation.offRoute ? "Return to the highlighted path, or recalculate from your location." : navigation.instruction).font(.headline)
            if let issue = navigation.locationIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
            if navigation.offRoute { Button("Recalculate walking route", action: store.reroute).disabled(store.isGenerating) }
            if store.isGenerating { ProgressView(store.status).font(.caption) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(17)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
    }
    private func controls(plan: DetourPlan) -> some View {
        VStack(spacing: 13) {
            ProgressView(value: navigation.fraction).tint(DetourStyle.forest)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack {
                    Label("\(Int(navigation.elapsed / 60)) min", systemImage: "clock")
                    Spacer(); Text("\(navigation.visited.count) / \(plan.stops.count) discovered")
                    Spacer(); Text("\(Int(navigation.metresWalked)) m")
                }.font(.caption).foregroundStyle(.secondary)
            }
            if let poi = navigation.arrival {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A LITTLE DISCOVERY").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    Text(poi.name).font(.title3.bold())
                    HStack {
                        Button { store.readStory(poi) } label: { Label(store.loadingStory ? "Preparing…" : "Listen", systemImage: "speaker.wave.2") }.disabled(store.loadingStory)
                        Spacer(); Button("Scan", action: store.openScanner)
                        Spacer(); Button("Skip story", action: store.skipStory)
                    }.font(.subheadline.weight(.semibold))
                    NavigationLink("About this place and sources") { DetourPOIDetail(poi: poi, language: store.preferences.language) }.font(.caption)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(15).background(DetourStyle.sage.opacity(0.22), in: RoundedRectangle(cornerRadius: 20))
            }
            if plan.simulated {
                Button(action: navigation.advanceSimulation) { Label("Advance Demo", systemImage: "forward.end") }.buttonStyle(DetourPrimaryButton()).disabled(navigation.paused)
            }
            HStack(spacing: 20) {
                Button(action: navigation.togglePause) { Label(navigation.paused ? "Resume" : "Pause", systemImage: navigation.paused ? "play.fill" : "pause.fill") }
                Spacer()
                Button(action: navigation.repeatInstruction) { Image(systemName: "speaker.wave.2") }.accessibilityLabel("Repeat direction")
                Button(action: store.openScanner) { Image(systemName: "viewfinder") }.accessibilityLabel("Explore with AI")
                Button(action: navigation.toggleVoiceCommands) { Image(systemName: navigation.voiceCommands ? "mic.fill" : "mic.slash") }.accessibilityLabel(navigation.voiceCommands ? "Disable voice commands" : "Enable foreground voice commands")
            }.font(.headline)
            if navigation.voiceCommands { Text("While this screen is open: say story, skip, repeat, scan or pause. Locked-screen guidance continues with the microphone off.").font(.caption2).foregroundStyle(.secondary) }
            HStack {
                DetourAttributionLink()
                Spacer()
                Button("End walk") { store.finish(completed: navigation.fraction >= 0.94) }.font(.caption.weight(.semibold))
            }
        }.padding(18).background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26))
    }
}

private struct DetourSimulationBanner: View {
    var body: some View {
        Label("INDOOR SIMULATION · schematic route and positions", systemImage: "testtube.2")
            .font(.caption.weight(.bold)).frame(maxWidth: .infinity).padding(10)
            .background(DetourStyle.orange.opacity(0.25)).accessibilityLabel("Indoor simulation. This is not live navigation.")
    }
}

@MainActor
private struct DetourMap: View {
    let start: DetourPoint
    let stops: [DetourPOI]
    let plan: DetourPlan?
    let showUser: Bool
    var simulatedPosition: DetourPoint? = nil
    var select: ((DetourPoint) -> Void)? = nil
    @State private var camera: MapCameraPosition = .automatic
    var body: some View {
        MapReader { proxy in
            Map(position: $camera) {
                if showUser { UserAnnotation() }
                Marker("Starting point", systemImage: "flag.fill", coordinate: start.coordinate).tint(DetourStyle.forest)
                ForEach(stops) { poi in
                    Marker(poi.name, systemImage: "sparkles", coordinate: poi.point.coordinate).tint(DetourStyle.orange)
                }
                if let plan {
                    ForEach(plan.legs) { leg in
                        MapPolyline(leg.polyline)
                            .stroke(plan.simulated ? DetourStyle.orange : DetourStyle.forest,
                                    style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: plan.simulated ? [7, 6] : []))
                    }
                }
                if let simulatedPosition {
                    Annotation("SIMULATED", coordinate: simulatedPosition.coordinate) {
                        Image(systemName: "figure.walk.circle.fill").font(.largeTitle).foregroundStyle(DetourStyle.orange)
                            .padding(4).background(.background, in: Circle())
                    }
                }
            }
            .mapControls { MapCompass(); MapScaleView() }
            .onTapGesture { location in
                guard let select, let coordinate = proxy.convert(location, from: .local) else { return }
                select(DetourPoint(coordinate))
            }
        }
        .onAppear { fit() }
        .onChange(of: plan?.id) { _, _ in fit() }
        .onChange(of: start) { _, _ in if select == nil { fit() } }
    }
    private func fit() {
        let points = plan?.points ?? [start]
        let latitudes = points.map(\.latitude), longitudes = points.map(\.longitude)
        let minLat = latitudes.min() ?? start.latitude, maxLat = latitudes.max() ?? start.latitude
        let minLon = longitudes.min() ?? start.longitude, maxLon = longitudes.max() ?? start.longitude
        camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max(0.009, (maxLat - minLat) * 1.5), longitudeDelta: max(0.009, (maxLon - minLon) * 1.5))))
    }
}

private struct DetourPOIDetail: View {
    let poi: DetourPOI
    let language: String
    var body: some View {
        List {
            Section { Text(poi.summary(language: language)).textSelection(.enabled) }
            Section("Source record") { ForEach(poi.verifiedFacts, id: \.self) { Text($0) } }
            Section("References") {
                ForEach(poi.sourceUrls, id: \.self) { source in
                    if let url = URL(string: source), url.scheme == "https" { Link(url.host ?? "Source", destination: url) }
                }
                Text("\(poi.sourceName) · \(poi.license)").font(.caption).foregroundStyle(.secondary)
            }
            Section { Text("Location: \(poi.coordinateKind). Keep to public paths and check access on site.").font(.caption).foregroundStyle(.secondary) }
        }.navigationTitle(poi.name).navigationBarTitleDisplayMode(.inline)
    }
}
private struct DetourAttributionLink: View {
    var body: some View {
        NavigationLink { DetourAttributionView() } label: { Text("Map & discovery sources").font(.caption2) }
    }
}
struct DetourAttributionView: View {
    var body: some View {
        List {
            Section("Map and pedestrian routes") { Text("Apple Maps / MapKit supplies live pedestrian paths, route distances and walking estimates. Detour chooses the stops and announces supplied directions.") }
            Section("OpenStreetMap") {
                Text("© OpenStreetMap contributors. OSM data is available under the Open Database License (ODbL). Live discovery queries Overpass once per cached area, not on every GPS update.")
                Link("OpenStreetMap copyright and licence", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
            }
            Section("Ville de Montréal") {
                Text("Municipal public-art metadata is licensed CC BY 4.0. Detour normalizes names, coordinates, artist names, materials and recorded production dates. The bundled catalog is a historical snapshot, not a current access inventory.")
                Link("Municipal source dataset", destination: URL(string: "https://www.donneesquebec.ca/recherche/dataset/vmtl-art-public-information-sur-les-oeuvres-de-la-collection-municipale")!)
                Text("Snapshot mirror: 5nguy/opendata, ec8c7325d9e0df7f00bbba09471cc0a999e96705.").font(.caption)
            }
            Section("Stories and privacy") {
                Text("Readings use sourced records. Optional AI-written stories can still contain mistakes; consult the linked sources. A walk’s preferences and summaries stay on this device. Starting coordinates go to the discovery backend and map provider; live discovery sends a bounded area query to Overpass. The scanner sends images only when used, using the existing connection settings.")
                Text("Simulation is explicitly schematic and does not count toward real discovery preferences. Live routes need connectivity and location permission. Turn timing, background audio and GPS accuracy require physical-device validation.")
            }
        }.navigationTitle("Sources & attribution")
    }
}
private struct DetourSummaryView: View {
    let summary: DetourWalkSummary
    let done: () -> Void
    var body: some View {
        ScrollView {
            VStack(spacing: 23) {
                Image(systemName: summary.completed ? "checkmark.seal.fill" : "leaf.circle.fill")
                    .font(.system(size: 72)).foregroundStyle(DetourStyle.sage).padding(.top, 30)
                Text(summary.simulated ? "A taste of your next Detour." : summary.completed ? "You took the scenic way." : "Every little walk counts.")
                    .font(.system(size: 31, weight: .bold, design: .rounded)).multilineTextAlignment(.center)
                if summary.simulated { DetourSimulationBanner() }
                HStack(spacing: 26) {
                    VStack { Text("\(Int(summary.seconds / 60))").font(.title.bold()); Text("minutes").font(.caption) }
                    VStack { Text("\(Int(summary.metres)) m").font(.title.bold()); Text(summary.simulated ? "schematic" : "walked").font(.caption) }
                    VStack { Text("\(summary.discoveries.count)").font(.title.bold()); Text("discoveries").font(.caption) }
                }.detourCard()
                ForEach(Array(summary.discoveries.enumerated()), id: \.offset) { _, name in Text(name).frame(maxWidth: .infinity, alignment: .leading).detourCard() }
                if summary.discoveries.isEmpty { Text("Your next discovery is waiting.").foregroundStyle(.secondary) }
                Button("Back to Detour", action: done).buttonStyle(DetourPrimaryButton())
            }.padding(23)
        }
    }
}
