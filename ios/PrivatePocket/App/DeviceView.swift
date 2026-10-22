import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var link: PocketLink
    @EnvironmentObject var live: LiveSession
    @Environment(\.scenePhase) private var scenePhase

    private var recording: Bool { link.status.recordingSince != nil }

    var body: some View {
        TabView {
            Tab("Pocket", systemImage: "creditcard") { PocketView() }
            Tab("Recordings", systemImage: "waveform") { RecordingsView() }
            Tab("Ask", systemImage: "questionmark.bubble") { AskTab() }
            Tab("Settings", systemImage: "gear") { SettingsView() }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            if recording || live.isActive { NowRecordingBar() }
        }
        .sensoryFeedback(trigger: recording) { _, now in now ? .start : .stop }
        .sensoryFeedback(.success, trigger: model.canCommand) { was, now in !was && now }
        .alert("Error", isPresented: Binding(get: { model.aiError != nil }, set: { if !$0 { model.aiError = nil } })) {
            Button("OK") {}
        } message: { Text(model.aiError ?? "") }
        .task { if Prefs.tagLocation { model.locator.requestPermission() } }
        .onChange(of: scenePhase, initial: true) { model.setActive(scenePhase == .active) }
    }
}

/// The home tab, built around the card itself. The Pocket has a side button, a status
/// light and a lot of storage, and that is what this screen shows: the card in its own
/// colour with a light that mirrors the real one (blue: ready, blinking blue: pair me,
/// amber: recording), a round button that is the side button's twin, storage in hours,
/// what is being recorded right now, and today's recordings.
struct PocketView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var devices: DeviceStore
    @EnvironmentObject var link: PocketLink
    @EnvironmentObject var live: LiveSession
    @EnvironmentObject var library: Library
    @State private var adding = false
    @State private var showDetails = false

    private var isConnected: Bool { link.connectedDeviceID != nil && link.connectedDeviceID == devices.selectedID }
    private var busy: Bool { if case .busy = link.phase { true } else { link.phase == .scanning || link.phase == .connecting } }
    private var recording: Bool { link.status.recordingSince != nil }
    /// Has a key the Pocket accepts, so commands work. A rejected key counts as unpaired.
    private var paired: Bool { model.canCommand }

    private var today: [Recording] {
        library.recordings
            .filter { $0.deviceID == devices.selectedID && $0.startedAt.map { Calendar.current.isDateInToday($0) } == true }
            .sorted { $0.name > $1.name }
    }

    var body: some View {
        NavigationStack {
            List {
                if devices.devices.isEmpty {
                    setupSection
                } else {
                    cardSection
                    if !paired { pairSection }
                    if recording || live.isActive {
                        liveSection
                    } else if paired {
                        recordSection
                    } else {
                        buttonHintSection
                    }
                    todaySection
                }
            }
            .navigationTitle(devices.selected?.name ?? "Pocket")
            .toolbar { if !devices.devices.isEmpty { toolbarMenu } }
            .refreshable { await model.sync() }
            .sheet(isPresented: $adding) { AddDeviceSheet() }
            .sheet(isPresented: $showDetails) { PocketDetails() }
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

    // MARK: Sections

    private var setupSection: some View {
        Section {
            VStack(spacing: 16) {
                PocketCard(name: "Your Pocket", advertised: "", light: .off, status: "Not added yet", detail: nil)
                Text("Have it nearby and switched on. Nothing leaves this iPhone.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Find my Pocket") { adding = true }.buttonStyle(.glassProminent)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    private var cardSection: some View {
        Section {
            PocketCard(name: devices.selected?.name ?? "Pocket", advertised: devices.selected?.advertisedName ?? "",
                       light: light, status: statusText, detail: detailText)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            if !isConnected, let other = unknownNearby {
                Button { adding = true } label: {
                    Label("New Pocket nearby: \(other). Add it", systemImage: "plus.circle")
                }
            }
        } footer: {
            if !isConnected, model.userDisconnected {
                Text("Disconnected. Recordings will not stream until you connect.")
            } else if !isConnected {
                Text("Connects by itself when your Pocket is in range, also with the app in the background.")
            }
        }
    }

    private var pairSection: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                LightDot(state: .pairing).frame(width: 14, height: 14).padding(.top, 4)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Hold the side button for 5 seconds").font(.headline)
                    Text("When the light blinks blue, your Pocket is ready to pair. The app does the rest, and the light turns solid a little later.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if isConnected {
                        Button("Pair now") { Task { await model.pairSelected() } }
                            .buttonStyle(.glass).disabled(busy).padding(.top, 4)
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text(link.keyRejected ? "Pair again" : "Pair your Pocket")
        } footer: {
            Text(link.keyRejected
                 ? "Your Pocket no longer accepts this phone's key, which happens after a reset. Recordings started with the side button still stream in meanwhile."
                 : "Recordings started with the side button already stream in. Pairing adds recording from here, getting recordings made while the phone was away, and battery and storage.")
        }
    }

    private var recordSection: some View {
        Section {
            VStack(spacing: 10) {
                Button { Task { await model.toggleRecording() } } label: {
                    Circle().fill(.orange)
                        .shadow(color: .orange.opacity(0.5), radius: 8)
                        .frame(width: 64, height: 64)
                        .padding(18)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(.orange.opacity(0.3)).interactive(), in: .circle)
                .disabled(busy || !isConnected)
                .accessibilityLabel("Start recording")
                Text(isConnected ? "Record" : "Connect to record from here")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        } footer: {
            Text("Starts a recording on your Pocket, like its side button; the light turns amber. Either way it streams here as it records.")
        }
    }

    private var buttonHintSection: some View {
        Section {
            Label {
                Text(isConnected ? "Press the side button on your Pocket to record. It streams here as it records."
                                 : "Press the side button on your Pocket to record. It streams here once the phone connects.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "record.circle").foregroundStyle(.orange)
            }
        }
    }

    private var liveSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    LightDot(state: .recording).frame(width: 14, height: 14)
                    if let since = link.status.recordingSince {
                        Text(timerInterval: since...Date.distantFuture, countsDown: false)
                            .font(.system(.largeTitle, design: .rounded).monospacedDigit().weight(.semibold))
                    } else {
                        Text("Finishing…").font(.title3)
                    }
                    Spacer()
                    if paired, recording {
                        Button { Task { await model.toggleRecording() } } label: { Label("Stop", systemImage: "stop.fill") }
                            .buttonStyle(.glassProminent).tint(.orange).disabled(busy)
                    }
                }
                Text(streamText).font(.footnote).foregroundStyle(live.gap ? .orange : .secondary)
                if live.isActive {
                    if !live.turns.isEmpty, Speakers.count(live.turns) > 1 {
                        ForEach(live.turns.suffix(8)) { t in TurnRow(turn: t, names: nil) }
                    } else if !live.text.isEmpty {
                        Text(live.text.suffix(1_200)).font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if Prefs.liveTranscript {
                        Text("Listening…").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Recording")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let n = live.engineNote { Text(n) }
                if let n = live.speakersNote { Text(n) }
            }
        }
    }

    private var todaySection: some View {
        Section {
            if today.isEmpty {
                Text("Nothing recorded today.").foregroundStyle(.secondary)
            }
            ForEach(today) { r in
                NavigationLink(value: r.id) { RecordingRow(recording: r) }
            }
        } header: {
            Text("Today")
        } footer: {
            if !today.isEmpty { Text("Everything else is on the Recordings tab.") }
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
                Button { adding = true } label: { Label("Add another Pocket", systemImage: "plus") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: State to words

    private var light: LightState {
        if recording { return .recording }
        guard isConnected else { return .off }
        return paired ? .on : .pairing
    }

    private var statusText: String {
        if let since = link.status.recordingSince {
            return "Recording since \(since.formatted(date: .omitted, time: .shortened))"
        }
        switch link.phase {
        case .idle: return model.userDisconnected ? "Disconnected" : "Not connected"
        case .waiting: return "Waiting for your Pocket"
        case .scanning: return "Looking for your Pocket…"
        case .connecting: return "Connecting…"
        case .busy(let what): return "\(what)…"
        case .ready: return paired ? "Ready" : "Connected, not paired yet"
        }
    }

    private var detailText: String? {
        if let p = link.progress {
            let pct = p.total > 0 ? Int(Double(p.done) / Double(p.total) * 100) : 0
            return "Getting \(p.label) · \(pct)%"
        }
        guard isConnected else { return nil }
        let s = link.status
        var parts: [String] = []
        if let b = s.battery { parts.append("Battery \(b)%") }
        if let f = s.freeMiB { parts.append("\(PocketFacts.hours(mib: f)) free") }
        if s.webSync == true { parts.append("USB drive on") }
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

// MARK: - The card and its light

/// The card itself, in its own colour, with the light in the corner.
struct PocketCard: View {
    let name: String
    let advertised: String
    let light: LightState
    let status: String
    let detail: String?

    var body: some View {
        let look = PocketLook(advertised: advertised)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                // The light sits under a small glass lens, as it does on the card.
                LightDot(state: light).frame(width: 14, height: 14)
                    .padding(9)
                    .glassEffect(.regular, in: .circle)
                Spacer()
                Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(look.ink.opacity(0.85))
            }
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(status).font(.title3.weight(.semibold)).foregroundStyle(look.ink)
                Text(detail ?? " ").font(.footnote).foregroundStyle(look.ink.opacity(0.75))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 172, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(look.fill.gradient)
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
        )
        .accessibilityElement(children: .combine)
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
                .tint(.orange)
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
                    ForEach(Array(link.log.suffix(80).reversed().enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
            }
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

    static let colours: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo]

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
