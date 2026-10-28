import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            Tab("Recorder", systemImage: "record.circle") { DeviceView() }
            Tab("Recordings", systemImage: "waveform") { RecordingsView() }
            Tab("Ask", systemImage: "questionmark.bubble") { AskTab() }
            Tab("Translate", systemImage: "character.bubble") { TranslateView() }
            Tab("Settings", systemImage: "gear") { SettingsView() }
        }
        .alert("Error", isPresented: Binding(get: { model.aiError != nil }, set: { if !$0 { model.aiError = nil } })) {
            Button("OK") {}
        } message: { Text(model.aiError ?? "") }
        .task {
            // Location is set up after launch: doing it while the app is being created can stall past the watchdog.
            try? await Task.sleep(for: .seconds(1))
            model.locator.prepare()
            if Prefs.tagLocation { model.locator.requestPermission() }
        }
        .onChange(of: scenePhase, initial: true) { model.setActive(scenePhase == .active) }
    }
}

/// The recorder: connection, record button, live transcript while recording, sync.
struct DeviceView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var devices: DeviceStore
    @EnvironmentObject var link: PocketLink
    @EnvironmentObject var live: LiveSession
    @State private var adding = false

    private var isConnected: Bool { link.connectedDeviceID != nil && link.connectedDeviceID == devices.selectedID }
    private var busy: Bool { if case .busy = link.phase { true } else { link.phase == .scanning || link.phase == .connecting } }
    private var recording: Bool { link.status.recordingSince != nil }

    var body: some View {
        NavigationStack {
            List {
                if devices.devices.isEmpty {
                    ContentUnavailableView {
                        Label("No Pocket yet", systemImage: "record.circle")
                    } description: {
                        Text("Add your Pocket in Settings → Devices.")
                    }
                } else {
                    deviceSection
                    if !model.canCommand { pairSection }
                    recordSection
                    if recording || live.isActive { liveSection }
                    syncSection
                    infoSection
                }
            }
            .navigationTitle(devices.selected?.name ?? "Recorder")
            .refreshable { await model.sync() }
            .sheet(isPresented: $adding) { AddDeviceSheet() }
            .alert("Pocket", isPresented: Binding(get: { link.lastError != nil }, set: { if !$0 { link.lastError = nil } })) {
                Button("OK") {}
            } message: { Text(link.lastError ?? "") }
        }
    }

    // MARK: Sections

    private var deviceSection: some View {
        Section {
            if devices.devices.count > 1 {
                Picker("Pocket", selection: $devices.selectedID) {
                    ForEach(devices.devices) { Text($0.name).tag(Optional($0.id)) }
                }
                .onChange(of: devices.selectedID) {
                    link.disconnect()
                    Task { await model.ensureConnected() }
                }
            }
            HStack(spacing: 12) {
                Circle().fill(isConnected ? .green : .secondary).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(phaseText)
                    if isConnected { Text(statusLine).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if busy {
                    ProgressView()
                } else if isConnected {
                    Button("Disconnect") { model.userDisconnect() }.buttonStyle(.borderless)
                } else {
                    Button("Connect") { Task { await model.userConnect() } }.buttonStyle(.borderless)
                }
            }
            if !isConnected, let other = unknownNearby {
                Button { adding = true } label: {
                    Label("New Pocket nearby: \(other). Add it", systemImage: "plus.circle")
                }
            }
        } footer: {
            if !isConnected, model.userDisconnected {
                Text("Disconnected. Recordings will not stream until you connect.")
            } else if !isConnected {
                Text("Connects by itself, also while the app is in the background, so recordings stream in as they are made. The Pocket talks to one phone or app at a time.")
            }
        }
    }

    /// Unpaired: the two steps, and a Pair button that works whether or not the link is up.
    private var pairSection: some View {
        Section {
            Label("Hold the side button for 5 seconds, until the light blinks blue.", systemImage: "1.circle")
            Label("Tap Pair while it blinks. The light goes solid once it's done.", systemImage: "2.circle")
            Button { Task { await model.pairSelected() } } label: {
                Text(link.phase == .busy("Pairing") ? "Pairing…" : "Pair").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)
        } header: {
            Text(link.keyRejected ? "Pair your Pocket again" : "Pair your Pocket")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(isConnected || link.bouncingAfterKey
                     ? "Connected without a key yet. Recordings started with its button still stream here, and the app keeps trying to pair by itself."
                     : "Not connected right now; Pair connects first.")
                if link.keyRejected {
                    Text("Your Pocket no longer accepts this phone's key, which happens after a reset or when another app paired it.")
                }
            }
        }
    }

    private var recordSection: some View {
        Section {
            VStack(spacing: 10) {
                Button { Task { await model.toggleRecording() } } label: {
                    ZStack {
                        Circle().fill(recording ? Color.orange.opacity(0.15) : Color.red.opacity(0.12))
                            .frame(width: 112, height: 112)
                        Image(systemName: recording ? "stop.fill" : "circle.fill")
                            .font(.system(size: recording ? 40 : 64))
                            .foregroundStyle(recording ? .orange : .red)
                    }
                }
                .buttonStyle(.plain)
                .disabled((busy && !recording) || !model.canCommand)
                .accessibilityLabel(recording ? "Stop recording" : "Start recording")
                if let since = link.status.recordingSince {
                    Text(timerInterval: since...Date.distantFuture, countsDown: false)
                        .font(.title2.monospacedDigit().weight(.medium))
                    Text("Recording on the Pocket").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(!model.canCommand ? "Pair to record from here. The Pocket's button records, and streams here, meanwhile."
                         : isConnected ? "Tap to record on the Pocket" : "Connect to record from here, or use the Pocket's button")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private var liveSection: some View {
        Section {
            if live.isActive {
                HStack {
                    Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(live.gap ? .orange : .green)
                        .symbolEffect(.variableColor.iterative, isActive: !live.gap)
                    Text(live.gap ? "Stream interrupted, the Pocket's file will be downloaded"
                                  : "Streaming · \(live.seconds) s received")
                        .font(.footnote)
                }
                if !live.turns.isEmpty, Speakers.count(live.turns) > 1 {
                    ForEach(live.turns.suffix(8)) { t in TurnRow(turn: t, names: nil) }
                } else if !live.text.isEmpty {
                    Text(live.text.tail(1_200)).font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if Prefs.liveTranscript {
                    Text("Listening…").foregroundStyle(.secondary)
                }
            } else {
                Text("Started before the phone connected, so this one is not streaming. It will be downloaded when it stops.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Live")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let n = live.engineNote { Text(n) }
                if let n = live.speakersNote { Text(n) }
            }
        }
    }

    private var syncSection: some View {
        Section {
            if let p = link.progress {
                VStack(alignment: .leading) {
                    Text("Downloading \(p.label)").font(.footnote)
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                    Text("\(p.done.formatted(.byteCount(style: .file))) of \(p.total.formatted(.byteCount(style: .file)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button { Task { await model.sync() } } label: {
                Label("Download new recordings", systemImage: "arrow.down.circle")
            }
            .disabled(busy || recording || !model.canCommand)
        } footer: {
            Text("Recordings made while connected are saved as they stream. Anything made while the phone was away is downloaded by itself when the Pocket connects (Settings → Devices). This does it now; pulling down does the same.")
        }
    }

    private var infoSection: some View {
        Section {
            DisclosureGroup("Device details") {
                let s = link.status
                LabeledContent("Battery", value: s.battery.map { "\($0)%" } ?? "–")
                LabeledContent("Storage free") {
                    if let f = s.freeMiB, let t = s.totalMiB { Text("\(gb(f)) of \(gb(t))") } else { Text("–") }
                }
                LabeledContent("Firmware",
                               value: [s.firmware, s.wifiFirmware.map { "Wi-Fi \($0)" }].compactMap { $0 }.joined(separator: " · "))
                LabeledContent("MAC", value: s.mac ?? "–")
                LabeledContent("Web Sync (USB)", value: s.webSync.map { $0 ? "On" : "Off" } ?? "–")
                Button("Refresh") { Task { await link.run("Status") { try await link.refreshStatus() } } }
                    .disabled(!isConnected || busy)
            }
            DisclosureGroup("Protocol log") {
                ShareLink(item: DiskLog.url) { Label("Share the full log", systemImage: "square.and.arrow.up") }
                ForEach(Array(link.log.suffix(80).reversed().enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            }
        }
    }

    // MARK: Text

    /// A Pocket heard while looking for the selected one that is not added yet.
    private var unknownNearby: String? {
        let known = Set(devices.devices.map(\.advertisedName))
        return link.othersNearby.subtracting(known).sorted().first
    }

    private var statusLine: String {
        let s = link.status
        var parts: [String] = []
        if let b = s.battery { parts.append("Battery \(b)%") }
        if let f = s.freeMiB { parts.append("\(gb(f)) free") }
        if s.webSync == true { parts.append("Web Sync on") }
        return parts.joined(separator: " · ")
    }

    private var phaseText: String {
        switch link.phase {
        case .idle: "Not connected"
        case .waiting: "Waiting for the Pocket"
        case .scanning: "Looking for the Pocket…"
        case .connecting: "Connecting…"
        case .ready: model.canCommand ? "Connected" : "Connected, not paired"
        case .busy(let what): "\(what)…"
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
