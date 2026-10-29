import SwiftUI

struct RootView: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var link: PocketLink
    @EnvironmentObject var live: LiveSession
    @EnvironmentObject var library: Library
    @EnvironmentObject var devices: DeviceStore
    @Environment(\.scenePhase) private var scenePhase
    /// The walkthrough waits for the splash on first launch.
    @State private var walkthrough = false
    @State private var splash = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tab = 0
    /// The app went to the background, not just inactive for a glance at Control Center.
    @State private var wasAway = false

    private var recording: Bool { link.status.recordingSince != nil }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Now", systemImage: "clock", value: 0) { NowView() }
            Tab("Threads", systemImage: "line.3.horizontal", value: 1) { ThreadsView() }
            Tab("People", systemImage: "person.2", value: 2) { PeopleView() }
            Tab("You", systemImage: "person.crop.circle", value: 3) { YouView() }
            Tab("Ask", systemImage: "magnifyingglass", value: 4, role: .search) { AskView() }
        }
        // privatepocket://moment?id=…, from a reminder or an event: the moment it came from.
        .onOpenURL { url in
            guard url.scheme == "privatepocket", url.host == "moment",
                  let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value else { return }
            tab = 0
            model.openMomentID = id
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        // A moment being transcribed or read, above the tab bar while the app is open.
        .tabViewBottomAccessory(isEnabled: model.workNow != nil) {
            if let w = model.workNow {
                WorkAccessory(work: w) {
                    tab = 0
                    model.openMomentID = w.id
                }
            }
        }
        .sensoryFeedback(trigger: recording) { _, now in now ? .start : .stop }
        .sensoryFeedback(.success, trigger: model.canCommand) { was, now in !was && now }
        .sensoryFeedback(.impact(weight: .light), trigger: library.recordings.count) { was, now in now > was }   // a moment landed
        .overlay(alignment: .top) {
            NoticeBar(text: model.aiError,
                      action: model.aiErrorOpensSettings
                          ? NoticeBar.Action(label: "Open Settings") { if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) } }
                          : nil) {
                model.aiError = nil
                model.aiErrorOpensSettings = false
            }
            .animation(.easeInOut(duration: 0.25), value: model.aiError)
        }

        // While it records, the whole screen: rises out of the Dynamic Island at the start,
        // and again when the app opens during a recording.
        .overlay {
            if model.takeover {
                RecordingTakeover { withAnimation(.spring(duration: 0.5)) { model.takeover = false } }
                    .transition(reduceMotion ? .opacity : .islandReveal)
                    .accessibilityAddTraits(.isModal)
            }
        }
        // On start, the splash above everything; the walkthrough follows it the first time.
        .overlay {
            if splash {
                SplashView { withAnimation(.easeOut(duration: 0.45)) { splash = false } }
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
            }
        }
        .onChange(of: splash) { _, showing in
            if !showing, !Prefs.walkthroughSeen { walkthrough = true }
        }
        .onChange(of: recording, initial: true) { _, now in
            if now { withAnimation(.spring(duration: 0.7)) { model.takeover = true } }
        }
        .onChange(of: scenePhase) { _, now in
            // Back from the background during a recording: the takeover again. Not after a glance
            // at Control Center or an alert, which only make the app inactive for a moment.
            if now == .background { wasAway = true }
            if now == .active {
                if wasAway, recording, !model.takeover { withAnimation(.spring(duration: 0.7)) { model.takeover = true } }
                wasAway = false
            }
        }
        .task {
            // Location is set up after launch: doing it while the app is being created can stall past the watchdog.
            try? await Task.sleep(for: .seconds(1))
            model.locator.prepare()
            if Prefs.tagLocation { model.locator.requestPermission() }
        }
        .onChange(of: scenePhase, initial: true) { model.setActive(scenePhase == .active) }
        .fullScreenCover(isPresented: $walkthrough) { WalkthroughView() }
    }
}

/// The home tab: the card itself, large, with the light that mirrors the real one and
/// the atmosphere in that light's colour; what it is doing; the shutter; today's moments.
struct PocketView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var devices: DeviceStore
    @EnvironmentObject var link: PocketLink
    @EnvironmentObject var live: LiveSession
    @EnvironmentObject var library: Library
    @State private var adding = false
    @State private var showDetails = false
    @State private var showSettings = false
    @State private var showWalkthrough = false
    @ScaledMetric(relativeTo: .largeTitle) private var timerSize = 54.0

    private var isConnected: Bool { link.connectedDeviceID != nil && link.connectedDeviceID == devices.selectedID }
    private var busy: Bool { if case .busy = link.phase { true } else { link.phase == .scanning || link.phase == .connecting } }
    private var recording: Bool { link.status.recordingSince != nil }
    /// Has a key the Pocket accepts, so commands work. A rejected key counts as unpaired.
    private var paired: Bool { model.canCommand }
    private var look: PocketLook { PocketLook(advertised: devices.selected?.advertisedName ?? "") }

    private var today: [Recording] {
        library.recordings
            .filter { $0.deviceID == devices.selectedID && $0.startedAt.map { Calendar.current.isDateInToday($0) } == true }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }
    /// The card steps back once the day has moments, and fills the screen when idle or recording.
    private var compactHero: Bool { !today.isEmpty && !recording && !live.isActive }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Brand.ground.ignoresSafeArea()
                RadialGradient(colors: [atmosphere.opacity(0.22), .clear],
                               center: UnitPoint(x: 0.5, y: 0.2), startRadius: 0, endRadius: 380)
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.7), value: atmosphere)
                ScrollView {
                    VStack(spacing: 22) {
                        if devices.devices.isEmpty {
                            setup
                        } else {
                            hero
                            if let other = unknownNearby, !isConnected { nearbyPrompt(other) }
                            if !paired { pairCard }
                            if paired, isConnected {
                                shutter
                            } else {
                                buttonHint
                            }
                            todayList
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle(devices.selected?.name ?? "Pocket")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if !devices.devices.isEmpty { toolbarMenu }
            }
            .refreshable { await model.sync() }
            .sheet(isPresented: $adding) { AddDeviceSheet() }
            .sheet(isPresented: $showDetails) { PocketDetails() }
            .sheet(isPresented: $showSettings) { SettingsView(onDone: { showSettings = false }) }
            .fullScreenCover(isPresented: $showWalkthrough) { WalkthroughView() }
            .navigationDestination(for: String.self) { id in RecordingDetail(id: id) }
            .navigationDestination(for: ThreadLink.self) { ThreadView(id: $0.id) }
            .navigationDestination(for: MomentsFilter.self) { f in FilteredMoments(filter: f) }
            .onChange(of: devices.selectedID) {
                link.disconnect()
                Task { await model.ensureConnected() }
            }
            .overlay(alignment: .top) {
                NoticeBar(text: link.lastError) { link.lastError = nil }
                    .animation(.easeInOut(duration: 0.25), value: link.lastError)
            }
        }
    }

    // MARK: Pieces

    private var panel: some ShapeStyle { Brand.surface }
    private var panelShape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

    /// The screen's glow: the light's colour while recording, the brand's when ready.
    private var atmosphere: Color { recording ? Brand.record : (isConnected ? Brand.act : .clear) }

    private var hero: some View {
        VStack(spacing: 16) {
            PocketIllustration(fill: look.fill, light: lampColour, blink: light == .pairing, pulse: light == .recording,
                               switchDown: link.status.mode == "CALL")
                .frame(height: compactHero ? 132 : 236)
                .padding(.top, 6)
                .onTapGesture { showDetails = true }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Pocket details")
                .animation(.spring(duration: 0.4), value: compactHero)
            VStack(spacing: 5) {
                if recording, let since = link.status.recordingSince {
                    Text(timerInterval: since...Date.distantFuture, countsDown: false)
                        .font(.system(size: 54, weight: .semibold, design: .rounded).monospacedDigit())
                } else {
                    Text(statusText).font(.title2.weight(.bold))
                }
                if link.progress != nil {
                    FetchLine(fetch: link.fetch).font(.subheadline).foregroundStyle(Brand.muted)
                } else if let detailText {
                    Text(detailText).font(.subheadline).foregroundStyle(Brand.muted)
                }
            }
            .multilineTextAlignment(.center)
            if model.userDisconnected, !isConnected {
                Button("Connect") { Task { await model.userConnect() } }
                    .buttonStyle(.glass).disabled(busy)
            }
            if recording || live.isActive { captions }
        }
        .frame(maxWidth: .infinity)
    }

    private var lampColour: Color? {
        switch light {
        case .off: nil
        case .on, .pairing: Lamp.ready
        case .recording: Lamp.recording
        }
    }

    /// The last two things said, following the recording as it streams.
    private var captions: some View {
        VStack(spacing: 6) {
            if live.isActive, !live.text.isEmpty {
                let (previous, current) = Captions.split(live.finalText, live.volatileText)
                if !previous.isEmpty {
                    Text(previous).font(.subheadline).foregroundStyle(Brand.muted).lineLimit(2)
                }
                Text(current).font(.title3.weight(.medium)).lineLimit(3)
            } else if live.isActive, Prefs.liveTranscript {
                Text("Listening…").font(.subheadline).foregroundStyle(Brand.muted)
            }
            // Only when something needs saying: a gap, or a recording that is not streaming.
            if live.gap || !live.isActive {
                Text(streamText).font(.caption).foregroundStyle(live.gap ? Brand.record : Brand.dim)
            }
            if let n = live.engineNote, n.hasPrefix("No ") || n.contains("paused") {
                Text(n).font(.caption2).foregroundStyle(Brand.dim)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 8)
        .animation(.easeInOut(duration: 0.2), value: live.text)
    }

    /// The side button, on the phone: amber, in a cyan ring; a square while recording.
    private var shutter: some View {
        VStack(spacing: 10) {
            Button { Task { await model.toggleRecording() } } label: {
                ZStack {
                    Circle()
                        .strokeBorder(recording ? Brand.record.opacity(0.7) : Brand.act.opacity(0.7), lineWidth: 3)
                        .frame(width: 78, height: 78)
                    RoundedRectangle(cornerRadius: recording ? 8 : 30, style: .continuous)
                        .fill(Brand.record)
                        .frame(width: recording ? 30 : 60, height: recording ? 30 : 60)
                        .shadow(color: Brand.record.opacity(0.4), radius: 14, y: 6)
                }
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .animation(.spring(duration: 0.3), value: recording)
            .accessibilityLabel(recording ? "Stop recording" : "Record")
            Text(recording ? "Stop" : "Record").font(.caption.weight(.semibold)).foregroundStyle(Brand.muted)
        }
    }

    private var setup: some View {
        VStack(spacing: 18) {
            PocketIllustration().frame(height: 236).padding(.top, 6)
            VStack(spacing: 5) {
                Text("Your Pocket").font(.title2.weight(.bold))
                Text("Have it nearby and switched on. No account, no cloud.")
                    .font(.subheadline).foregroundStyle(Brand.muted).multilineTextAlignment(.center)
            }
            Button { adding = true } label: {
                Label("Find my Pocket", systemImage: "magnifyingglass")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            Button("Show me how it works") { showWalkthrough = true }
                .font(.subheadline.weight(.semibold))
        }
    }

    private func nearbyPrompt(_ name: String) -> some View {
        Button { adding = true } label: {
            Label("New Pocket nearby: \(name). Add it", systemImage: "plus.circle")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.glass)
    }

    /// Unpaired: the two steps, a Pair button that works whether or not the link is up,
    /// and what the link is doing meanwhile.
    private var pairCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                LightDot(state: .pairing).frame(width: 12, height: 12)
                Text(link.keyRejected ? "Pair your Pocket again" : "Pair your Pocket").font(.headline)
            }
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Hold the side button for five seconds, until the light blinks blue.")
                step(2, "Tap Pair while it blinks. The light goes solid once it's done.")
            }
            Button { Task { await model.pairSelected() } } label: {
                Text(busy ? "Pairing…" : "Pair").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(Brand.act)
            .disabled(busy)
            Text(isConnected
                 ? "Connected to your Pocket, without a key yet. Recordings started with its button still stream here meanwhile, and the app keeps trying to pair by itself."
                 : "Not connected right now; Pair connects first.")
                .font(.footnote).foregroundStyle(Brand.muted)
            if link.keyRejected {
                Text("Your Pocket no longer accepts this phone's key, which happens after a reset or when another app paired it.")
                    .font(.footnote).foregroundStyle(Brand.dim)
            }
            DisclosureGroup("Not pairing, or it keeps dropping out?") {
                VStack(alignment: .leading, spacing: 8) {
                    step(1, "Turn Bluetooth off on your iPhone, in Settings.")
                    step(2, "Reset the Pocket: press the side button three times, then hold it until the light blinks red.")
                    step(3, "Turn Bluetooth back on.")
                    step(4, "Hold the side button for five seconds until it blinks blue, then tap Pair.")
                }
                .padding(.top, 6)
            }
            .font(.footnote.weight(.semibold))
            .tint(Brand.act)
            Button("Show me") { showWalkthrough = true }.font(.footnote.weight(.semibold))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panel, in: panelShape)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.caption.weight(.bold)).foregroundStyle(Brand.act)
                .frame(width: 20, height: 20).background(Brand.act.opacity(0.18), in: Circle())
            Text(text).font(.subheadline).foregroundStyle(Brand.textSecondary)
        }
    }

    private var buttonHint: some View {
        HStack(spacing: 12) {
            Image(systemName: "record.circle").foregroundStyle(Brand.record)
            Text(isConnected ? "Press the side button on your Pocket to record. It streams here as it records."
                             : "Press the side button on your Pocket to record. It streams here once the phone connects.")
                .font(.subheadline).foregroundStyle(Brand.muted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panel, in: panelShape)
    }

    private var todayList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Today").font(.title3.weight(.semibold)).padding(.horizontal, 4)
            if today.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "waveform").foregroundStyle(Brand.muted)
                    Text("Nothing yet today.").font(.subheadline).foregroundStyle(Brand.muted)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(panel, in: panelShape)
            } else {
                ForEach(today) { r in
                    NavigationLink(value: r.id) { MomentCard(recording: r) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private var toolbarMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if devices.devices.count > 1 {
                    Picker("Pocket", selection: $devices.selectedID) {
                        ForEach(devices.devices) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                if paired {
                    Button { Task { await model.sync() } } label: {
                        Label("Get recordings from the Pocket", systemImage: "arrow.down.circle")
                    }
                    .disabled(busy || recording)
                }
                Button { showDetails = true } label: { Label("Pocket details", systemImage: "info.circle") }
                if isConnected {
                    Button { model.userDisconnect() } label: {
                        Label("Disconnect", systemImage: "antenna.radiowaves.left.and.right.slash")
                    }
                } else {
                    Button { Task { await model.userConnect() } } label: {
                        Label("Connect", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(busy)
                }
                Divider()
                Button { showWalkthrough = true } label: { Label("How the Pocket works", systemImage: "hand.tap") }
                Button { adding = true } label: { Label("Add another Pocket", systemImage: "plus") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: State to words

    private var light: LightState {
        if recording { return .recording }
        guard isConnected || (link.bouncingAfterKey && !paired) else { return .off }
        return paired ? .on : .pairing
    }

    /// Five words for the whole state: Ready, Recording (the timer stands in for it),
    /// Saving, Away, Needs pairing. The link's own phases are in Pocket details.
    private var statusText: String {
        if link.bouncingAfterKey, !paired { return "Needs pairing" }   // a refused key bounces the link; it is back in a moment
        switch link.phase {
        case .idle: return model.userDisconnected ? "Disconnected" : "Away"
        case .waiting, .scanning, .connecting: return "Away"
        case .busy: return link.progress != nil ? "Saving" : (paired ? "Ready" : "Needs pairing")
        case .ready: return paired ? "Ready" : "Needs pairing"
        }
    }

    private var detailText: String? {
        switch link.phase {
        case .waiting, .scanning, .connecting: return "Looking for your Pocket"
        case .idle: return model.userDisconnected ? nil : "Asleep, or out of range"
        case .busy(let what): return "\(what)…"
        case .ready: break
        }
        guard isConnected else { return nil }
        var parts: [String] = []
        if let b = link.status.battery { parts.append("\(b)%") }
        if let f = link.status.freeMiB { parts.append("\(PocketFacts.hours(mib: f)) free") }
        if link.status.mode == "CALL" { parts.append("Call") }
        if link.status.webSync == true { parts.append("USB drive on") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var streamText: String {
        if live.isActive {
            return live.gap ? "Stream interrupted. Your Pocket keeps recording; the file is fetched when it stops."
                            : "Streaming to this iPhone · \(live.seconds) s"
        }
        return paired ? "Started before the phone connected, so it is not streaming. It is fetched when it stops."
                      : "Started before the phone connected, so it is not streaming. Pair to fetch it when it stops."
    }

    /// A Pocket heard while looking for the selected one that is not added yet.
    private var unknownNearby: String? {
        let known = Set(devices.devices.map(\.advertisedName))
        return link.othersNearby.subtracting(known).sorted().first
    }
}

/// "Fetching the recording · 42%", the one view that redraws as a fetch moves.
private struct FetchLine: View {
    @ObservedObject var fetch: FetchProgress

    var body: some View {
        let pct = fetch.value.map { $0.total > 0 ? Int(Double($0.done) / Double($0.total) * 100) : 0 } ?? 0
        Text("Fetching the recording · \(pct)%")
    }
}

/// The live transcript as two lines: the last complete sentence, and what is being said now.
enum Captions {
    static func split(_ final: String, _ volatile: String) -> (previous: String, current: String) {
        var sentences: [String] = []
        final.enumerateSubstrings(in: final.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { sentences.append(s) }
        }
        let now = volatile.trimmingCharacters(in: .whitespacesAndNewlines)
        if now.isEmpty { return (sentences.dropLast().last ?? "", sentences.last ?? "") }
        return (sentences.last ?? "", now)
    }
}

// MARK: - Details sheet

struct PocketDetails: View {
    @EnvironmentObject var link: PocketLink
    @EnvironmentObject var devices: DeviceStore
    @Environment(\.dismiss) private var dismiss

    private var busy: Bool { if case .busy = link.phase { true } else { false } }

    /// The link's own phase, in its own words.
    private var linkText: String {
        switch link.phase {
        case .idle: "Not connected"
        case .waiting: "Waiting for the Pocket to advertise"
        case .scanning: "Scanning"
        case .connecting: "Connecting"
        case .busy(let what): what
        case .ready: link.keyRejected ? "Connected, key refused" : "Connected"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                let s = link.status
                let fw = [s.firmware, s.wifiFirmware.map { "Wi-Fi \($0)" }].compactMap { $0 }.joined(separator: " · ")
                Section {
                    LabeledContent("Battery", value: s.battery.map { "\($0)%" } ?? "–")
                    LabeledContent("Recording time left", value: s.freeMiB.map { PocketFacts.hours(mib: $0) } ?? "–")
                    LabeledContent("Storage") {
                        if let f = s.freeMiB, let t = s.totalMiB { Text("\(gb(f)) free of \(gb(t))") } else { Text("–") }
                    }
                    LabeledContent("Switch", value: s.mode.map { $0 == "CALL" ? "Call (contact mic)" : "Audio" } ?? "–")
                    LabeledContent("Firmware", value: fw.isEmpty ? "–" : fw)
                    LabeledContent("Link", value: linkText)
                    LabeledContent("Bluetooth name", value: devices.selected?.advertisedName ?? "–")
                    LabeledContent("MAC", value: s.mac ?? "–")
                    LabeledContent("USB drive (Web Sync)", value: s.webSync.map { $0 ? "On" : "Off" } ?? "–")
                    Button("Refresh") { Task { await link.run("Status") { try await link.refreshStatus() } } }
                        .disabled(!link.isReady || busy)
                } header: {
                    Text(devices.selected?.name ?? "Pocket")
                } footer: {
                    Text("Recording time assumes the Pocket's 32 kbps audio, about 14 MB an hour.")
                }
                Section("Protocol log") {
                    ShareLink(item: DiskLog.url) { Label("Share the full log", systemImage: "square.and.arrow.up") }
                    ForEach(Array(link.log.suffix(80).reversed().enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
            }
                .scrollContentBackground(.hidden)
                .background(Brand.ground)
            .navigationTitle("Pocket details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func gb(_ mib: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(mib) * 1_048_576, countStyle: .file)
    }
}

/// One speaker turn: name, time, words.
struct TurnRow: View {
    let turn: Turn
    let names: [String: String]?
    var onRename: ((Int) -> Void)?

    static let colours: [Color] = Brand.speakers

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                let name = Text(Speakers.name(turn.speaker, names)).font(.caption.weight(.semibold))
                    .foregroundStyle(Self.colours[turn.speaker % Self.colours.count])
                if let onRename {
                    Button { onRename(turn.speaker) } label: { name }.buttonStyle(.borderless)
                } else {
                    name
                }
                Text(Speakers.stamp(turn.start)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(turn.text)
        }
    }
}

/// A line at the top for something that went wrong, in plain words, with what happens
/// next. Gone on tap or after a few seconds; never a modal.
struct NoticeBar: View {
    struct Action {
        let label: String
        let run: () -> Void
    }

    let text: String?
    var action: Action? = nil
    let dismiss: () -> Void

    var body: some View {
        if let text {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(Brand.record).padding(.top, 2)
                VStack(alignment: .leading, spacing: 8) {
                    Text(text).font(.subheadline).foregroundStyle(Brand.text).fixedSize(horizontal: false, vertical: true)
                    if let action {
                        Button(action.label) { action.run(); dismiss() }
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Brand.act)
                            .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 0)
                Button(action: dismiss) { Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Brand.muted) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
            }
            .padding(14)
            .background(Brand.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Brand.hairline, lineWidth: 1))
            .padding(.horizontal, 16).padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onTapGesture(perform: dismiss)
            .task(id: text) {
                try? await Task.sleep(for: .seconds(action == nil ? 8 : 20))   // one with a button waits longer
                if !Task.isCancelled { dismiss() }
            }
        }
    }
}
