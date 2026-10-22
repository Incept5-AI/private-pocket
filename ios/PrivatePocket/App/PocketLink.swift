import CoreBluetooth
import Foundation
import WidgetKit

/// Pocket BLE protocol (see ble/PROTOCOL.md): ASCII commands `APP&…` written to
/// 001120a2, ASCII replies `MCU&…` notified on 001120a3, raw MP3 notified on 001120a1.
enum PocketUUID {
    static let service = CBUUID(string: "001120A0-2233-4455-6677-889912345678")
    static let audio = CBUUID(string: "001120A1-2233-4455-6677-889912345678")
    static let command = CBUUID(string: "001120A2-2233-4455-6677-889912345678")
    static let reply = CBUUID(string: "001120A3-2233-4455-6677-889912345678")
    /// Standard Battery Service: readable without a session key.
    static let batteryService = CBUUID(string: "180F")
    static let batteryLevel = CBUUID(string: "2A19")
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

    var isCallMode: Bool { mode == "CALL" }
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
    case bluetoothOff, notFound, timeout(String), notReady, rejected, notPairing

    var errorDescription: String? {
        switch self {
        case .bluetoothOff: "Bluetooth is off or not allowed for this app."
        case .notFound: "Pocket not found. Is it on, nearby, and not connected to another phone or app?"
        case .timeout(let what): "Timed out waiting for \(what)."
        case .notReady: "Not connected."
        case .rejected: "The Pocket rejected this phone's key, which happens after another app pairs it. Hold its side button for 5 seconds until the light blinks blue, then tap Pair."
        case .notPairing: "The Pocket did not take a new key. Hold its side button for 5 seconds until the light blinks blue, then tap Pair straight away."
        }
    }
}

@MainActor
final class PocketLink: NSObject, ObservableObject {
    /// `waiting`: a pending connection iOS completes whenever the Pocket advertises,
    /// with no timeout, also while the app is in the background.
    enum Phase: Equatable { case idle, waiting, scanning, connecting, ready, busy(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = DeviceStatus() {
        didSet {
            // Control Center's toggle reads this through the shared Keychain.
            let recording = status.recordingSince != nil
            if recording != (oldValue.recordingSince != nil) {
                SharedState.recording = recording
                ControlCenter.shared.reloadAllControls()
            }
        }
    }
    @Published private(set) var connectedDeviceID: UUID?
    @Published private(set) var discovered: [Discovered] = []
    /// Other Pockets heard while looking for the selected one (e.g. a new card not added yet).
    @Published private(set) var othersNearby: Set<String> = []
    @Published private(set) var progress: (label: String, done: Int, total: Int)?
    @Published private(set) var log: [String] = []
    @Published var lastError: String?
    /// The Pocket dropped the connection on the stored key (it was reset, most likely).
    /// The link then carries on without a key, so recordings still stream, and tries
    /// to pair afresh on each new connection until the user holds the button.
    @Published private(set) var keyRejected = false

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var commandChar: CBCharacteristic?
    private var device: DeviceConfig?
    private var notifyingReply = false
    private var notifyingAudio = false
    private var discoveryMode = false
    private var wantedName: String?
    /// Background standby (see `standby`): the pending connection in flight, and the
    /// device to arm it for once Bluetooth is powered on.
    private var standingBy = false
    private var standbyDevice: DeviceConfig?
    /// Try a fresh key on the next connection made without one (see `handshake`): at
    /// start, and after any link loss the Pocket caused on its own, which is what it
    /// may do when put into pairing mode. A try outside pairing mode just costs a
    /// reconnect, so the stream carries on.
    private var pairAttemptPending = true
    private var lastKeySentAt = Date.distantPast
    /// When the stored key was last refused, so it can be tried again after a while.
    private var rejectedAt = Date.distantPast
    /// One pairing try at a time, and automatic ones no closer than 8 s apart.
    private var pairing = false
    private var lastPairTryAt = Date.distantPast
    /// Called when a key was accepted, with the device that now holds it.
    var onPaired: ((DeviceConfig) -> Void)?

    private var lines: [String] = []
    private var audio = Data()
    private var capturingAudio = false
    private var stoppingFromApp = false

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
        // The restore identifier lets iOS relaunch the app for Bluetooth events after
        // it was terminated in the background, handing back the pending or connected
        // peripheral in `willRestoreState`.
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: "PocketLink"])
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
        if phase != .scanning { central.stopScan() }
    }

    // MARK: - Connection

    /// Connects and, if the device has a key, sends it. Without a key the link still
    /// delivers recording events and live audio; the Pocket just answers no commands.
    func connect(_ d: DeviceConfig) async throws {
        if connectedDeviceID == d.id, isReady { return }
        try await establish(d)
        try await handshake()
    }

    /// Pair now, on request: the same fresh-key try `handshake` makes by itself, but
    /// with an error if the Pocket is not in pairing mode.
    func pair(_ d: DeviceConfig) async throws {
        if !(connectedDeviceID == d.id && isReady) { try await establish(d) }
        guard !pairing else { return }
        pairing = true
        defer { pairing = false }
        lastPairTryAt = Date()
        try await tryNewKey(d, quiet: false)
    }

    /// Pairs the way the official app does. With the Pocket in pairing mode (side
    /// button held for 5 s, light blinking blue) it accepts whatever key is sent next
    /// and that key works from then on; outside pairing mode it drops the link instead.
    /// `quiet` swallows that drop: the reconnect then carries on without a key.
    private func tryNewKey(_ d: DeviceConfig, quiet: Bool) async throws {
        let key = Self.newKey()
        note("trying to pair")
        do { try await sendKey(key) } catch {
            if quiet { return }
            disconnect()
            throw PocketError.notPairing
        }
        d.sessionKey = key   // Keychain; the struct itself is unchanged
        note("paired: the Pocket took a new key")
        try await afterKey(d)
        onPaired?(d)
    }

    /// Clock and status, once a key was accepted.
    private func afterKey(_ d: DeviceConfig) async throws {
        keyRejected = false
        if d.setClockOnConnect {
            _ = try await send("T&\(PocketTime.now())", until: { $0.hasPrefix("MCU&T&") })
        }
        try await refreshStatus()
    }

    /// Background standby: asks iOS to connect to the known peripheral whenever it
    /// advertises, with no timeout. Nothing happens for a device never connected
    /// before (no peripheral id yet); that first connection is made in the foreground.
    /// When the connection completes, the handshake runs and `onConnected` fires.
    func standby(_ d: DeviceConfig) {
        if connectedDeviceID == d.id, isReady { return }
        disconnect()
        standbyDevice = d
        guard central.state == .poweredOn else { return }   // retried from centralManagerDidUpdateState
        guard let pid = d.peripheralID, let p = central.retrievePeripherals(withIdentifiers: [pid]).first else {
            note("cannot wait for \(d.name) in the background: never connected yet")
            return
        }
        device = d
        lines = []
        standingBy = true
        phase = .waiting
        note("waiting for \(d.name)")
        attach(p)
    }

    /// Called when a standby connection is up and the handshake has run.
    var onConnected: (() -> Void)?

    /// 16 characters, like the official app's keys, without look-alike letters.
    static func newKey() -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<16).map { _ in chars.randomElement()! })
    }

    /// Scan, connect and subscribe, without sending any key.
    private func establish(_ d: DeviceConfig) async throws {
        disconnect()
        try await waitForPoweredOn()
        if device?.id != d.id {
            keyRejected = false
            pairAttemptPending = true
        }
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
        try await waitUntil(timeout: 20, what: "the Pocket to connect") { [weak self] in
            guard let self else { return true }
            return self.notifyingReply && self.notifyingAudio && self.commandChar != nil
        }
        phase = .ready
        connectedDeviceID = d.id
    }

    func disconnect() {
        central.stopScan()
        wantedName = nil
        standingBy = false
        standbyDevice = nil
        if let p = peripheral { central.cancelPeripheralConnection(p) }   // also cancels a pending connection
        peripheral = nil
        commandChar = nil
        notifyingReply = false
        notifyingAudio = false
        connectedDeviceID = nil
        phase = .idle
        progress = nil
    }

    private func attach(_ p: CBPeripheral) {
        if let old = peripheral, old != p { central.cancelPeripheralConnection(old) }
        central.stopScan()
        wantedName = nil
        peripheral = p
        p.delegate = self
        if !standingBy { phase = .connecting }
        if p.state == .connected {
            connected(p)          // handed back already connected by state restoration
        } else {
            central.connect(p)
        }
    }

    private func connected(_ p: CBPeripheral) {
        central.stopScan()
        wantedName = nil
        note("connected to \(p.name ?? "Pocket")")
        if let d = device, d.peripheralID != p.identifier { onPeripheralLearned?(d.id, p.identifier) }
        p.discoverServices([PocketUUID.service, PocketUUID.batteryService])
    }

    /// A standby connection is fully subscribed: finish it the way `connect` would.
    private func checkStandbyReady() {
        guard standingBy, notifyingReply, notifyingAudio, commandChar != nil, let d = device else { return }
        standingBy = false
        standbyDevice = nil
        phase = .ready
        connectedDeviceID = d.id
        Task {
            await run("Connecting", quiet: true) { try await handshake() }
            if isReady { onConnected?() }
        }
    }

    /// After the link is up. With a key the Pocket has accepted before: send it and
    /// read the status. Without one, or after a refusal: stay connected for events
    /// and live audio, and try to pair in case the Pocket is in pairing mode. The
    /// foreground loop keeps trying every few seconds (`AppModel.setActive`).
    private func handshake() async throws {
        guard let d = device else { throw PocketError.notReady }
        let key = d.sessionKey
        if !key.isEmpty, !keyRejected {
            do { try await sendKey(key) } catch PocketError.rejected {
                // The Pocket drops the link on a key it does not hold (it was reset, or
                // another app paired it). AppModel reconnects, and this runs again on
                // the keyless path below. A timeout is not a refusal: it propagates, and
                // the next connection sends the key again.
                keyRejected = true
                rejectedAt = Date()
                note("key refused: carrying on without one")
                throw PocketError.rejected
            }
            try await afterKey(d)
            return
        }
        note(key.isEmpty ? "not paired: recording events and live audio only"
                         : "key refused earlier: recording events and live audio only")
        status = DeviceStatus(battery: status.battery)
        if pairAttemptPending {
            pairAttemptPending = false
            try await tryPairing(quiet: true)
        }
    }

    /// Tries to pair, in the order most likely to work. The stored key first, unless it
    /// was refused in the last while: a refusal is sometimes a missed reply, and a reset
    /// Pocket is not the common case. Else a fresh key, which the Pocket takes in
    /// pairing mode (side button held 5 s, light blinking blue) and keeps from then on.
    /// Outside pairing mode a wrong key drops the link, which costs a reconnect and
    /// nothing else: the link had no key anyway. Skipped while the Pocket records, so a
    /// stream started with the button is never cut.
    func tryPairing(quiet: Bool) async throws {
        guard let d = device, isReady, status.recordingSince == nil, !pairing,
              !quiet || Date().timeIntervalSince(lastPairTryAt) > 8 else { return }
        pairing = true
        defer { pairing = false }
        lastPairTryAt = Date()
        let key = d.sessionKey
        if !key.isEmpty, !keyRejected || Date().timeIntervalSince(rejectedAt) > 45 {
            do { try await sendKey(key) } catch PocketError.rejected {
                keyRejected = true
                rejectedAt = Date()
                note("key refused again")
                if quiet { return }
                throw PocketError.rejected
            }
            note("the Pocket took the stored key after all")
            try await afterKey(d)
            onPaired?(d)
            return
        }
        try await tryNewKey(d, quiet: quiet)
    }

    /// `APP&SK&<key>`: the Pocket answers `MCU&SK&OK`, or drops the connection at once
    /// when the key is wrong (outside pairing mode).
    private func sendKey(_ key: String) async throws {
        lastKeySentAt = Date()
        do {
            let r = try await send("SK&\(key)", until: { $0.hasPrefix("MCU&SK&") }, timeout: 5)
            guard r.last == "MCU&SK&OK" else { throw PocketError.rejected }
        } catch PocketError.notReady {
            throw PocketError.rejected
        }
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
        _ = try await send("STA", until: { $0.hasPrefix("MCU&STA&") })   // handleLine records the name and time
    }

    /// Returns the device's file name of the recording that was stopped.
    func stopRecording() async throws -> String? {
        let name = status.recordingName
        stoppingFromApp = true
        defer { stoppingFromApp = false }
        _ = try await send("STO", until: { $0 == "MCU&STO" })
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

    func download(_ f: RemoteFile) async throws -> Data {
        audio = Data()
        capturingAudio = true
        defer { capturingAudio = false; progress = nil }
        let label = f.startedLabel
        let head = try await send("U&\(f.day)&\(f.name)", until: { $0.hasPrefix("MCU&U&") }, timeout: 10)
        let size = Int(head.last?.split(separator: "&").last ?? "") ?? 0
        progress = (label, 0, size)
        var lastCount = 0
        var lastChange = Date()
        while true {
            if lines.contains("MCU&OFF") { lines.removeAll { $0 == "MCU&OFF" }; break }
            if size > 0, audio.count >= size { break }
            if audio.count != lastCount { lastCount = audio.count; lastChange = Date() }
            if Date().timeIntervalSince(lastChange) > 15 { throw PocketError.timeout("audio data (\(audio.count)/\(size) bytes)") }
            if peripheral?.state != .connected { throw PocketError.notReady }
            progress = (label, audio.count, size)
            try await Task.sleep(for: .milliseconds(150))
        }
        note("downloaded \(f.name): \(audio.count) bytes")
        return size > 0 ? audio.prefix(size) : audio
    }

    /// Runs `body` with the phase shown as busy, recording any error for the UI.
    /// `quiet` keeps background reconnects out of alerts (the log still has them).
    func run(_ label: String, quiet: Bool = false, _ body: () async throws -> Void) async {
        if isReady { phase = .busy(label) }
        do { try await body() } catch {
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

    /// Writes `APP&<cmd>` and collects reply lines until one satisfies `until`.
    @discardableResult
    func send(_ cmd: String, until done: @escaping (String) -> Bool, timeout: TimeInterval = 5) async throws -> [String] {
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

    private func waitUntil(timeout: TimeInterval, what: String, _ cond: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline {
                let neverFound = peripheral == nil
                disconnect()
                throw neverFound ? PocketError.notFound : PocketError.timeout(what)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func handleLine(_ l: String) {
        note("← \(l)")
        if l.hasPrefix("MCU&STA&") {
            // The name is the device's file name: a UTC timestamp, or `PH…` in call
            // mode. Unknown forms still count as a recording, timed from now.
            let name = String(l.dropFirst("MCU&STA&".count))
            let started = PocketTime.parse(name) ?? Date()
            let isNew = status.recordingName != name
            status.recordingSince = started
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
        DiskLog.append(s)
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }
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
            if central.state == .poweredOn, phase == .idle, let d = standbyDevice { standby(d) }
            if central.state != .poweredOn {
                let d = standbyDevice
                disconnect()
                standbyDevice = d   // arm again when Bluetooth comes back
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            // iOS relaunched the app for a Bluetooth event. The peripheral comes back
            // connected or with the pending connection still in place; AppModel's
            // standby picks it up through retrievePeripherals and `attach`.
            let ps = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
            for p in ps { p.delegate = self }
            note("restored by iOS with \(ps.count) peripheral(s)\(ps.first.map { ", \($0.state == .connected ? "connected" : "pending")" } ?? "")")
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
        MainActor.assumeIsolated { connected(p) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            note("connect failed: \(error?.localizedDescription ?? "unknown")")
            disconnect()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard p == peripheral else { return }
            note("disconnected")
            // A drop the Pocket made on its own, not on a key just sent, may mean it was
            // put into pairing mode: worth a fresh key on the next connection.
            if Date().timeIntervalSince(lastKeySentAt) > 3 { pairAttemptPending = true }
            disconnect()
            onLinkLost?()
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let s = p.services?.first(where: { $0.uuid == PocketUUID.service }) else {
                note("Pocket service not found"); disconnect(); return
            }
            p.discoverCharacteristics([PocketUUID.audio, PocketUUID.command, PocketUUID.reply], for: s)
            if let b = p.services?.first(where: { $0.uuid == PocketUUID.batteryService }) {
                p.discoverCharacteristics([PocketUUID.batteryLevel], for: b)
            }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for c in s.characteristics ?? [] {
                switch c.uuid {
                case PocketUUID.command: commandChar = c
                case PocketUUID.reply, PocketUUID.audio: p.setNotifyValue(true, for: c)
                case PocketUUID.batteryLevel: p.readValue(for: c); p.setNotifyValue(true, for: c)
                default: break
                }
            }
            checkStandbyReady()
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if c.uuid == PocketUUID.reply { notifyingReply = c.isNotifying }
            if c.uuid == PocketUUID.audio { notifyingAudio = c.isNotifying }
            checkStandbyReady()
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let v = c.value else { return }
        MainActor.assumeIsolated {
            if c.uuid == PocketUUID.audio {
                if capturingAudio { audio.append(v) } else { onLiveAudio?(v) }
            } else if c.uuid == PocketUUID.reply, let s = String(data: v, encoding: .utf8) {
                handleLine(s.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if c.uuid == PocketUUID.batteryLevel, let b = v.first {
                status.battery = Int(b)
            }
        }
    }
}
