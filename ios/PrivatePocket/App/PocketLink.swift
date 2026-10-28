import CoreBluetooth
import Foundation

/// Pocket BLE protocol (see ble/PROTOCOL.md): ASCII commands `APP&…` written to
/// 001120a2, ASCII replies `MCU&…` notified on 001120a3, raw MP3 notified on 001120a1.
enum PocketUUID {
    static let service = CBUUID(string: "001120A0-2233-4455-6677-889912345678")
    static let audio = CBUUID(string: "001120A1-2233-4455-6677-889912345678")
    static let command = CBUUID(string: "001120A2-2233-4455-6677-889912345678")
    static let reply = CBUUID(string: "001120A3-2233-4455-6677-889912345678")
    static let namePrefix = "PKT01"
}

struct DeviceStatus: Equatable {
    var battery: Int?
    var firmware: String?
    var wifiFirmware: String?
    var mac: String?
    var freeMiB: Int?
    var totalMiB: Int?
    var webSync: Bool?
    var recordingSince: Date?
    /// The device's file name for the recording in progress (`yyyyMMddHHmmss`, or
    /// `PH…` for call mode), as announced by `MCU&STA&`.
    var recordingName: String?
    /// The side switch: `CON` (audio) or `CALL` (phone call, contact mic). Read on
    /// connect with `REC&SECEN` and announced before every recording start.
    var mode: String?
}

struct RemoteFile: Hashable {
    let day: String
    let name: String
    let seconds: Int
}

struct Discovered: Identifiable, Hashable {
    let id: UUID
    let name: String
    var rssi: Int
}

enum PocketError: LocalizedError {
    case bluetoothOff, notFound, timeout(String), notReady, rejected, noKey, interrupted, superseded

    var errorDescription: String? {
        switch self {
        case .bluetoothOff: "Bluetooth is off or not allowed for this app."
        case .notFound: "Pocket not found. Is it on, nearby, and not connected to another phone or app?"
        case .timeout(let what): "Timed out waiting for \(what)."
        case .notReady: "Not connected."
        case .rejected: "The Pocket did not accept the session key."
        case .noKey: "This device has no session key. Add it in Settings."
        case .superseded: "The Pocket couldn't be reached just then. Try again in a moment."
        case .interrupted: "Downloading stopped because the Pocket started recording. Sync again after the recording."
        }
    }
}

@MainActor
final class PocketLink: NSObject, ObservableObject {
    enum Phase: Equatable { case idle, scanning, connecting, ready, busy(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = DeviceStatus()
    @Published private(set) var connectedDeviceID: UUID?
    @Published private(set) var discovered: [Discovered] = []
    /// Other Pockets heard while looking for the selected one (e.g. a new card not added yet).
    @Published private(set) var othersNearby: Set<String> = []
    @Published private(set) var progress: (label: String, done: Int, total: Int)?
    @Published private(set) var log: [String] = []
    @Published var lastError: String?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var commandChar: CBCharacteristic?
    private var device: DeviceConfig?
    private var notifyingReply = false
    private var notifyingAudio = false
    private var discoveryMode = false
    private var wantedName: String?

    private var lines: [String] = []
    private var audio = Data()
    private var capturingAudio = false
    private var stoppingFromApp = false
    /// A command is being exchanged. The Pocket answers on one channel, so a second command
    /// sent meanwhile takes the first one's reply (seen: the key and a listing, both timing out).
    private var exchanging = false
    /// A download in flight is to stop: a recording has started on the same channel.
    private var downloadStop = false
    /// Each connection attempt's number. A teardown or a newer attempt ends an older one's
    /// wait, so a stale wait never tears down the connection that replaced it.
    private var attempt = 0
    /// Connections this app cancelled. iOS answers a cancel with a disconnect, which is not a
    /// link loss: taken for one, it re-armed the reconnect, whose cancel was answered the same
    /// way, in a loop, and the Pocket never reconnected.
    private var cancelling: Set<UUID> = []

    /// Called with the learned CoreBluetooth identifier so it can be stored per device.
    var onPeripheralLearned: ((UUID, UUID) -> Void)?
    /// Audio streamed while the Pocket records (anything on the audio channel outside a download).
    var onLiveAudio: ((Data) -> Void)?
    /// Called when the connection drops without `disconnect()` being asked for.
    var onLinkLost: (() -> Void)?
    /// Called with the file name when a recording starts (button or app).
    var onRecordingStarted: ((String) -> Void)?
    /// Called when the device reports a recording stopped (button or app).
    var onRecordingStopped: ((String) -> Void)?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var isReady: Bool { if case .ready = phase { true } else { if case .busy = phase { true } else { false } } }

    // MARK: - Discovery (Settings → Add device)

    func startDiscovery() {
        discovered = []
        discoveryMode = true
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    var isDiscovering: Bool { discoveryMode }

    func stopDiscovery() {
        discoveryMode = false
        if phase != .scanning { stopScanning() }
    }

    // MARK: - Connection

    func connect(_ d: DeviceConfig) async throws {
        if connectedDeviceID == d.id, isReady { return }
        disconnect()
        let mine = attempt
        guard !d.sessionKey.isEmpty else { throw PocketError.noKey }
        try await waitForPoweredOn()
        guard attempt == mine else { throw PocketError.superseded }
        device = d
        lines = []
        phase = .scanning
        note("looking for \(d.name)")

        othersNearby = []
        if let pid = d.peripheralID, let p = central.retrievePeripherals(withIdentifiers: [pid]).first {
            attach(p)
        }
        // Scan as well, even with a known peripheral: it finds the device if its id
        // changed, and notices other Pockets nearby. Stopped once connected.
        wantedName = d.advertisedName
        central.scanForPeripherals(withServices: nil, options: nil)
        try await waitUntil(timeout: 20, what: "the Pocket to connect", attempt: mine) { [weak self] in
            guard let self else { return true }
            return self.notifyingReply && self.notifyingAudio && self.commandChar != nil
        }
        phase = .ready
        connectedDeviceID = d.id
        try await handshake()
    }

    func disconnect() { teardown(cancel: true) }

    /// Stops a scan only when one is running: stopping waits on the Bluetooth daemon, and
    /// called from a disconnect callback in the background that wait got the app killed by
    /// the watchdog.
    private func stopScanning() {
        if central.isScanning { central.stopScan() }
    }

    /// Back to idle. `cancel` cancels the connection, live or pending; once iOS has reported
    /// it gone there is nothing to cancel, and a cancel would be answered with another disconnect.
    private func teardown(cancel: Bool) {
        attempt += 1
        stopScanning()
        wantedName = nil
        if cancel, let p = peripheral { cancelConnection(p) }
        peripheral = nil
        commandChar = nil
        notifyingReply = false
        notifyingAudio = false
        connectedDeviceID = nil
        phase = .idle
        progress = nil
    }

    /// Cancels a live or pending connection, marked so that its disconnect is not taken for a loss.
    private func cancelConnection(_ p: CBPeripheral) {
        guard p.state == .connected || p.state == .connecting else { return }
        cancelling.insert(p.identifier)
        central.cancelPeripheralConnection(p)
    }

    private func attach(_ p: CBPeripheral) {
        if let old = peripheral, old != p { cancelConnection(old) }
        stopScanning()
        wantedName = nil
        peripheral = p
        p.delegate = self
        phase = .connecting
        central.connect(p)
    }

    private func handshake() async throws {
        guard let d = device else { throw PocketError.notReady }
        let r = try await send("SK&\(d.sessionKey)", until: { $0.hasPrefix("MCU&SK&") }, timeout: 5)
        guard r.last == "MCU&SK&OK" else { disconnect(); throw PocketError.rejected }
        if d.setClockOnConnect {
            _ = try await send("T&\(PocketTime.now())", until: { $0.hasPrefix("MCU&T&") })
        }
        try await refreshStatus()
    }

    // MARK: - Commands

    func refreshStatus() async throws {
        status.battery = Int(try await value("BAT", reply: "MCU&BAT&"))
        status.firmware = try await value("FW", reply: "MCU&FW&")
        status.wifiFirmware = try await value("WF", reply: "MCU&WF&")
        status.mac = try await value("MAC", reply: "MCU&MAC&")
        let spa = try await value("SPACE", reply: "MCU&SPA&").split(separator: "&")
        if spa.count == 2 { status.freeMiB = Int(spa[0]); status.totalMiB = Int(spa[1]) }
        status.webSync = try await value("GET&USB", reply: "MCU&USB&") == "1"
        status.mode = try await value("REC&SECEN", reply: "MCU&REC&")
    }

    func setWebSync(_ on: Bool) async throws {
        status.webSync = try await value("USB&\(on ? 1 : 0)", reply: "MCU&USB&") == "1"
    }

    func startRecording() async throws {
        if capturingAudio { downloadStop = true }   // recording comes first: a download stops
        try await send("STA", until: { $0.hasPrefix("MCU&STA&") })   // handleLine records the name and time
    }

    /// Returns the device's file name of the recording that was stopped.
    func stopRecording() async throws -> String? {
        let name = status.recordingName
        stoppingFromApp = true
        defer { stoppingFromApp = false }
        try await send("STO", until: { $0 == "MCU&STO" })
        status.recordingSince = nil
        status.recordingName = nil
        return name
    }

    func listFiles() async throws -> [RemoteFile] {
        let dirs = try await send("LIST_DIRS", until: { $0.hasPrefix("MCU&DIRS_SUM&") })
            .compactMap { $0.hasPrefix("MCU&DIRS&") ? String($0.dropFirst("MCU&DIRS&".count)) : nil }
        var files: [RemoteFile] = []
        for day in dirs {
            let r = try await send("LIST&\(day)", until: { $0.hasPrefix("MCU&LIST&") })
            for line in r where line.hasPrefix("MCU&F&") {
                let p = line.split(separator: "&").map(String.init)   // MCU F day name secs
                if p.count >= 5 { files.append(RemoteFile(day: p[2], name: p[3], seconds: Int(p[4]) ?? 0)) }
            }
        }
        return files.sorted { $0.name < $1.name }
    }

    /// A recording's file. The command channel is held throughout, and a recording starting
    /// stops it. `whole` is false when fewer bytes came than the Pocket announced: what came is
    /// kept, marked partial, and a later sync downloads it again.
    func download(_ f: RemoteFile) async throws -> FetchedFile {
        try await takeTurn()
        defer { exchanging = false }
        audio = Data()
        downloadStop = false
        capturingAudio = true
        defer { capturingAudio = false; downloadStop = false; progress = nil }
        let label = f.startedLabel
        let head = try await exchange("U&\(f.day)&\(f.name)", until: { $0.hasPrefix("MCU&U&") }, timeout: 10)
        let size = Int(head.last?.split(separator: "&").last ?? "") ?? 0
        progress = (label, 0, size)
        var lastCount = 0
        var lastChange = Date()
        while true {
            if downloadStop {
                note("downloading \(f.name) stopped: a recording started")
                throw PocketError.interrupted
            }
            if lines.contains("MCU&OFF") { lines.removeAll { $0 == "MCU&OFF" }; break }
            if size > 0, audio.count >= size { break }
            if audio.count != lastCount { lastCount = audio.count; lastChange = Date() }
            if Date().timeIntervalSince(lastChange) > 15 { throw PocketError.timeout("audio data (\(audio.count)/\(size) bytes)") }
            if peripheral?.state != .connected { throw PocketError.notReady }
            progress = (label, audio.count, size)
            try await Task.sleep(for: .milliseconds(150))
        }
        let whole = size == 0 || audio.count >= size
        note(whole ? "downloaded \(f.name): \(audio.count) bytes" : "downloaded \(f.name): only \(audio.count) of \(size) bytes")
        return FetchedFile(data: size > 0 ? audio.prefix(size) : audio, whole: whole)
    }

    /// Runs `body` with the phase shown as busy, recording any error for the UI.
    /// `quiet` keeps background reconnects out of alerts (the log still has them).
    func run(_ label: String, quiet: Bool = false, _ body: () async throws -> Void) async {
        if isReady { phase = .busy(label) }
        do { try await body() } catch is CancellationError {
            note("cancelled: \(label)")   // superseded or left the foreground: not a failure, never shown
        } catch {
            if !quiet { lastError = error.localizedDescription }
            note("error: \(error.localizedDescription)")
        }
        if case .busy = phase { phase = peripheral?.state == .connected ? .ready : .idle }
        progress = nil
    }

    private func value(_ cmd: String, reply prefix: String) async throws -> String {
        let r = try await send(cmd, until: { $0.hasPrefix(prefix) })
        return String((r.last ?? "").dropFirst(prefix.count))
    }

    /// Writes `APP&<cmd>` and collects reply lines until one satisfies `until`, once any
    /// command already in flight has had its answer.
    @discardableResult
    func send(_ cmd: String, until done: @escaping (String) -> Bool, timeout: TimeInterval = 5) async throws -> [String] {
        try await takeTurn()
        defer { exchanging = false }
        return try await exchange(cmd, until: done, timeout: timeout)
    }

    /// Waits for the command channel. A download holds it for the whole file; a recording
    /// starting cuts that short (`downloadStop`).
    private func takeTurn() async throws {
        let deadline = Date().addingTimeInterval(30)
        while exchanging {
            guard Date() < deadline else { throw PocketError.timeout("the Pocket to finish what it was doing") }
            try await Task.sleep(for: .milliseconds(30))
        }
        exchanging = true
    }

    private func exchange(_ cmd: String, until done: @escaping (String) -> Bool, timeout: TimeInterval) async throws -> [String] {
        guard let p = peripheral, let c = commandChar, p.state == .connected else { throw PocketError.notReady }
        lines.removeAll { !Self.isEvent($0) }
        p.writeValue(Data("APP&\(cmd)".utf8), for: c, type: .withResponse)
        note("→ APP&\(cmd.hasPrefix("SK&") ? "SK&•••" : cmd)")
        var collected: [String] = []
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            while !lines.isEmpty {
                let l = lines.removeFirst()
                collected.append(l)
                if done(l) { return collected }
            }
            if p.state != .connected { throw PocketError.notReady }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw PocketError.timeout("a reply to \(cmd.hasPrefix("SK&") ? "SK" : cmd)")
    }

    private static func isEvent(_ l: String) -> Bool { l == "MCU&OFF" }

    private func waitForPoweredOn() async throws {
        for _ in 0..<30 where central.state == .unknown || central.state == .resetting {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard central.state == .poweredOn else { throw PocketError.bluetoothOff }
    }

    private func waitUntil(timeout: TimeInterval, what: String, attempt mine: Int, _ cond: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            // Torn down, or a newer attempt began: this one is over, and leaves that alone.
            guard attempt == mine else { throw PocketError.superseded }
            if Date() > deadline {
                let neverFound = peripheral == nil
                disconnect()
                throw neverFound ? PocketError.notFound : PocketError.timeout(what)
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                // Cancelled: no half-made connection is left behind, unless something newer
                // has already taken its place.
                if attempt == mine { disconnect() }
                throw error
            }
        }
        guard attempt == mine else { throw PocketError.superseded }
    }

    private func handleLine(_ l: String) {
        note("← \(l)")
        if l.hasPrefix("MCU&STA&") {
            // The name is the device's file name: a UTC timestamp, or `PH…` in call
            // mode. Unknown forms still count as a recording, timed from now.
            let name = String(l.dropFirst("MCU&STA&".count))
            if capturingAudio {
                // A recording takes the audio channel: what follows is the room, not the file.
                downloadStop = true
                capturingAudio = false
            }
            let isNew = status.recordingName != name
            status.recordingSince = PocketTime.parse(name) ?? Date()
            status.recordingName = name
            if isNew { onRecordingStarted?(name) }
        } else if l == "MCU&STO" {
            let name = status.recordingName
            status.recordingSince = nil
            status.recordingName = nil
            if let name, !stoppingFromApp { onRecordingStopped?(name) }
        } else if l.hasPrefix("MCU&REC&") {
            status.mode = String(l.dropFirst("MCU&REC&".count))   // the switch, before a start and on request
        }
        lines.append(l)
    }

    func note(_ s: String) {
        log.append("\(Date().formatted(date: .omitted, time: .standard))  \(s)")
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }
}

/// A recording downloaded from the Pocket; `whole` when every byte it announced arrived.
struct FetchedFile {
    let data: Data
    let whole: Bool
}

extension RemoteFile {
    var startedLabel: String {
        PocketTime.parse(name).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? name
    }
}

// MARK: - CoreBluetooth delegates (main queue)

extension PocketLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            if central.state == .poweredOn, discoveryMode {
                central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            }
            if central.state != .poweredOn { disconnect() }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        MainActor.assumeIsolated {
            guard name.hasPrefix(PocketUUID.namePrefix) else { return }
            if discoveryMode {
                if let i = discovered.firstIndex(where: { $0.id == p.identifier }) {
                    discovered[i].rssi = RSSI.intValue
                } else {
                    discovered.append(Discovered(id: p.identifier, name: name, rssi: RSSI.intValue))
                }
            }
            if let wanted = wantedName {
                if name == wanted {
                    if peripheral?.identifier != p.identifier { attach(p) }
                } else if !othersNearby.contains(name) {
                    othersNearby.insert(name)
                }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        MainActor.assumeIsolated {
            cancelling.remove(p.identifier)   // any cancel before this connection has been answered
            stopScanning()
            wantedName = nil
            note("connected to \(p.name ?? "Pocket")")
            if let d = device, d.peripheralID != p.identifier { onPeripheralLearned?(d.id, p.identifier) }
            p.discoverServices([PocketUUID.service])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            note("connect failed: \(error?.localizedDescription ?? "unknown")")
            guard p == peripheral else { return }
            teardown(cancel: false)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            if cancelling.remove(p.identifier) != nil { return }   // the answer to a cancel of ours, not a loss
            guard p == peripheral else { return }
            note("disconnected")
            teardown(cancel: false)   // already gone: a cancel now would only be answered with another disconnect
            onLinkLost?()
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let s = p.services?.first(where: { $0.uuid == PocketUUID.service }) else {
                note("Pocket service not found"); disconnect(); return
            }
            p.discoverCharacteristics([PocketUUID.audio, PocketUUID.command, PocketUUID.reply], for: s)
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for c in s.characteristics ?? [] {
                switch c.uuid {
                case PocketUUID.command: commandChar = c
                case PocketUUID.reply, PocketUUID.audio: p.setNotifyValue(true, for: c)
                default: break
                }
            }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if c.uuid == PocketUUID.reply { notifyingReply = c.isNotifying }
            if c.uuid == PocketUUID.audio { notifyingAudio = c.isNotifying }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let v = c.value else { return }
        MainActor.assumeIsolated {
            if c.uuid == PocketUUID.audio {
                if capturingAudio { audio.append(v) } else { onLiveAudio?(v) }
            } else if c.uuid == PocketUUID.reply, let s = String(data: v, encoding: .utf8) {
                handleLine(s.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}
