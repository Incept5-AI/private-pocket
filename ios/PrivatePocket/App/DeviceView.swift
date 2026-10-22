import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var link: PocketLink
    @EnvironmentObject var live: LiveSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var walkthrough = !Prefs.walkthroughSeen

    private var recording: Bool { link.status.recordingSince != nil }

    var body: some View {
        TabView {
            Tab("Pocket", systemImage: "creditcard") { PocketView() }
            Tab("Moments", systemImage: "quote.bubble") { RecordingsView() }
            Tab("Insights", systemImage: "chart.bar.xaxis") { InsightsView() }
            Tab("Ask", systemImage: "questionmark.bubble") { AskTab() }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory(isEnabled: recording || live.isActive) { NowRecordingBar() }
        .sensoryFeedback(trigger: recording) { _, now in now ? .start : .stop }
        .sensoryFeedback(.success, trigger: model.canCommand) { was, now in !was && now }
        .alert("Error", isPresented: Binding(get: { model.aiError != nil }, set: { if !$0 { model.aiError = nil } })) {
            Button("OK") {}
        } message: { Text(model.aiError ?? "") }
        .task { if Prefs.tagLocation { model.locator.requestPermission() } }
        .onChange(of: scenePhase, initial: true) { model.setActive(scenePhase == .active) }
        .fullScreenCover(isPresented: $walkthrough) { WalkthroughView() }
    }
}

/// The home tab: the card itself, large, with the light that mirrors the real one and
/// the atmosphere in that light's colour; what it is doing; the shutter; today's moments.
struct PocketView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var devices: DeviceStore
    @EnvironmentObject var link: PocketLink
    @EnvironmentObject var live: LiveSession
    @EnvironmentObject var library: Library
    @State private var adding = false
    @State private var showDetails = false
    @State private var showSettings = false
    @State private var showWalkthrough = false

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
                if !devices.devices.isEmpty { toolbarMenu }
            }
            .refreshable { await model.sync() }
            .sheet(isPresented: $adding) { AddDeviceSheet() }
            .sheet(isPresented: $showDetails) { PocketDetails() }
            .sheet(isPresented: $showSettings) { SettingsView(onDone: { showSettings = false }) }
            .fullScreenCover(isPresented: $showWalkthrough) { WalkthroughView() }
            .navigationDestination(for: String.self) { id in RecordingDetail(id: id) }
            .onChange(of: devices.selectedID) {
                link.disconnect()
                Task { await model.ensureConnected() }
            }
            .alert("Pocket", isPresented: Binding(get: { link.lastError != nil }, set: { if !$0 { link.lastError = nil } })) {
                Button("OK") {}
            } message: { Text(link.lastError ?? "") }
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
                .frame(height: 236)
                .padding(.top, 6)
                .onTapGesture { showDetails = true }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Pocket details")
            VStack(spacing: 5) {
                if recording, let since = link.status.recordingSince {
                    Text(timerInterval: since...Date.distantFuture, countsDown: false)
                        .font(.system(size: 54, weight: .semibold, design: .rounded).monospacedDigit())
                } else {
                    Text(statusText).font(.title2.weight(.bold))
                }
                if let detailText { Text(detailText).font(.subheadline).foregroundStyle(Brand.muted) }
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
            Text(streamText).font(.caption).foregroundStyle(live.gap ? Brand.record : Brand.dim)
            if let n = live.engineNote { Text(n).font(.caption2).foregroundStyle(Brand.dim) }
            if let n = live.speakersNote { Text(n).font(.caption2).foregroundStyle(Brand.dim) }
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
                Text("Have it nearby and switched on. Nothing leaves this iPhone.")
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

    private var statusText: String {
        if link.bouncingAfterKey, !paired { return "Connected, not paired yet" }   // a refused key bounces the link; it is back in a moment
        switch link.phase {
        case .idle: return model.userDisconnected ? "Disconnected" : "Not connected"
        case .waiting: return "Waiting for your Pocket"
        case .scanning: return "Looking for your Pocket…"
        case .connecting: return "Connecting…"
        case .busy(let what): return "\(what)…"
        case .ready: return paired ? "Ready" : (link.keyRejected ? "Connected, pair again" : "Connected, not paired yet")
        }
    }

    private var detailText: String? {
        if let p = link.progress {
            let pct = p.total > 0 ? Int(Double(p.done) / Double(p.total) * 100) : 0
            return "Getting \(p.label) · \(pct)%"
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
                            : "Streaming to this iPhone · \(Int(Double(live.bytes) / PocketFacts.bytesPerSecond)) s"
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

/// The bar above the tab bar while the Pocket records, on every tab: light, timer, the
/// latest words, and Stop when the phone can stop it.
struct NowRecordingBar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var link: PocketLink
    @EnvironmentObject var live: LiveSession

    var body: some View {
        HStack(spacing: 10) {
            LightDot(state: .recording).frame(width: 10, height: 10)
            if let since = link.status.recordingSince {
                Text(timerInterval: since...Date.distantFuture, countsDown: false)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            } else {
                Text("Saving…").font(.subheadline)
            }
            Text(live.text.isEmpty ? (live.isActive ? "Streaming to this iPhone" : "Recording on the Pocket")
                                   : String(live.text.suffix(80)))
                .font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 0)
            if model.canCommand, link.status.recordingSince != nil {
                Button { Task { await model.toggleRecording() } } label: {
                    Image(systemName: "stop.fill")
                }
                .tint(Brand.record)
                .accessibilityLabel("Stop recording")
            }
        }
        .padding(.horizontal, 14)
    }
}

// MARK: - Details sheet

struct PocketDetails: View {
    @EnvironmentObject var link: PocketLink
    @EnvironmentObject var devices: DeviceStore
    @Environment(\.dismiss) private var dismiss

    private var busy: Bool { if case .busy = link.phase { true } else { false } }

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
            Text(turn.text).textSelection(.enabled)
        }
    }
}
