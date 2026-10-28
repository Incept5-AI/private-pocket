import Foundation
import Security

/// Everything specific to one physical Pocket. The session key is kept in the
/// Keychain, not in this struct, so the JSON in UserDefaults holds no secret.
struct DeviceConfig: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// Advertised BLE name, e.g. `PKT01_GREY_2617abcd`. Used to find the device
    /// the first time; after that `peripheralID` is used.
    var advertisedName: String
    /// CoreBluetooth's per-phone identifier, learned on first connect.
    var peripheralID: UUID?
    /// Set the device clock (UTC, as the official app does) on every connect.
    var setClockOnConnect = true
    /// After stopping a recording from this app, download it straight away.
    var downloadAfterStop = true
    /// Transcribe each recording as soon as it is downloaded.
    var autoTranscribe = false
    /// Download recordings made while the phone was away as soon as the Pocket connects.
    /// Optional so device lists saved before this field existed still decode.
    var autoSync: Bool?
    var syncsAutomatically: Bool {
        get { autoSync ?? true }
        set { autoSync = newValue }
    }

    var sessionKey: String {
        get { Keychain.get("sk.\(id.uuidString)") ?? "" }
        nonmutating set { Keychain.set(newValue, for: "sk.\(id.uuidString)") }
    }

    /// Has a key, so the Pocket answers commands (start, stop, list, download).
    /// Without one it still streams recordings started with its button.
    var isPaired: Bool { !sessionKey.isEmpty }
}

@MainActor
final class DeviceStore: ObservableObject {
    @Published var devices: [DeviceConfig] = [] { didSet { save() } }
    @Published var selectedID: UUID? {
        didSet { UserDefaults.standard.set(selectedID?.uuidString, forKey: "selectedDevice") }
    }

    private let key = "devices.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([DeviceConfig].self, from: data) {
            devices = list
        } else if !DefaultDevice.advertisedName.isEmpty {
            let d = DeviceConfig(name: DefaultDevice.name, advertisedName: DefaultDevice.advertisedName)
            if !DefaultDevice.sessionKey.isEmpty { d.sessionKey = DefaultDevice.sessionKey }
            devices = [d]
        }
        renameToShortIDs()
        if let s = UserDefaults.standard.string(forKey: "selectedDevice"), let u = UUID(uuidString: s),
           devices.contains(where: { $0.id == u }) {
            selectedID = u
        } else {
            selectedID = devices.first?.id
        }
    }

    /// "Pocket-abcd": the last 4 characters of the advertised name (the end of the
    /// MAC), which is what tells same-coloured cards apart.
    static func defaultName(_ advertised: String) -> String {
        guard let tail = advertised.split(separator: "_").last, advertised.contains("_") else { return "Pocket" }
        return "Pocket-\(tail.suffix(4))"
    }

    /// Once: names made by earlier builds ("Grey Pocket", "Grey Pocket abcd") become
    /// "Pocket-abcd" style. Names the user typed are left alone.
    private func renameToShortIDs() {
        guard !UserDefaults.standard.bool(forKey: "renamedToShortIDs") else { return }
        devices = devices.map { d in
            var d = d
            let colour = d.advertisedName.split(separator: "_").dropFirst().first.map { $0.capitalized } ?? ""
            let tail = String(d.advertisedName.suffix(4))
            if [DefaultDevice.name, "\(colour) Pocket", "\(colour) Pocket \(tail)", "Pocket"].contains(d.name) {
                d.name = Self.defaultName(d.advertisedName)
            }
            return d
        }
        UserDefaults.standard.set(true, forKey: "renamedToShortIDs")
    }

    var selected: DeviceConfig? { devices.first { $0.id == selectedID } }

    func update(_ d: DeviceConfig) {
        if let i = devices.firstIndex(where: { $0.id == d.id }) { devices[i] = d }
    }

    func add(_ d: DeviceConfig) {
        devices.append(d)
        selectedID = d.id   // a Pocket you just added is the one you want to use
    }

    func remove(_ d: DeviceConfig) {
        Keychain.delete("sk.\(d.id.uuidString)")
        Keychain.delete(PocketLink.triedAccount(d))
        devices.removeAll { $0.id == d.id }
        if selectedID == d.id { selectedID = devices.first?.id }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(devices) { UserDefaults.standard.set(data, forKey: key) }
    }
}

enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Bundle.main.bundleIdentifier ?? "private-pocket",
         kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        delete(account)
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

/// Preferences that are not per-device.
enum Prefs {
    @MainActor static var transcriptionLocale: String {
        get { UserDefaults.standard.string(forKey: "locale") ?? Locale.current.identifier(.bcp47) }
        set { UserDefaults.standard.set(newValue, forKey: "locale") }
    }

    /// Tag recordings with the phone's location.
    @MainActor static var tagLocation: Bool {
        get { UserDefaults.standard.object(forKey: "tagLocation") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "tagLocation") }
    }

    /// Turn coordinates into place names with Apple's geocoder (a network request).
    @MainActor static var lookUpPlaceNames: Bool {
        get { UserDefaults.standard.object(forKey: "lookUpPlaceNames") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "lookUpPlaceNames") }
    }

    /// Languages offered first when picking one for a recording.
    @MainActor static var favouriteLocales: [String] {
        get { UserDefaults.standard.stringArray(forKey: "favouriteLocales") ?? [transcriptionLocale] }
        set { UserDefaults.standard.set(newValue, forKey: "favouriteLocales") }
    }

    /// Reconnect to the selected Pocket whenever the app is open, so recordings stream.
    @MainActor static var stayConnected: Bool {
        get { UserDefaults.standard.object(forKey: "stayConnected") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "stayConnected") }
    }

    /// Transcribe while recording, from the Bluetooth stream.
    @MainActor static var liveTranscript: Bool {
        get { UserDefaults.standard.object(forKey: "liveTranscript") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "liveTranscript") }
    }

    /// Label speakers with a diarisation server.
    @MainActor static var diarize: Bool {
        get { UserDefaults.standard.object(forKey: "diarize") as? Bool ?? !Diarizer.defaultURLs.isEmpty }
        set { UserDefaults.standard.set(newValue, forKey: "diarize") }
    }

    /// Diarizer base URLs, comma-separated, tried in order.
    @MainActor static var diarizeURLs: String {
        get { UserDefaults.standard.string(forKey: "diarizeURLs") ?? Diarizer.defaultURLs }
        set { UserDefaults.standard.set(newValue, forKey: "diarizeURLs") }
    }

    /// Speech to text on a server (Whisper) instead of on the phone.
    @MainActor static var sttRemote: Bool {
        get { UserDefaults.standard.object(forKey: "sttRemote") as? Bool ?? LLMConfig.hasDefault }
        set { UserDefaults.standard.set(newValue, forKey: "sttRemote") }
    }

    @MainActor static var sttURL: String {
        get { UserDefaults.standard.string(forKey: "sttURL") ?? LLMConfig.defaultURL }
        set { UserDefaults.standard.set(newValue, forKey: "sttURL") }
    }

    @MainActor static var sttModel: String {
        get { UserDefaults.standard.string(forKey: "sttModel") ?? RemoteSTT.defaultModel }
        set { UserDefaults.standard.set(newValue, forKey: "sttModel") }
    }

    /// Summaries and questions on a server instead of on the phone (see `LLM`).
    @MainActor static var llmRemote: Bool {
        get { UserDefaults.standard.object(forKey: "llmRemote") as? Bool ?? LLMConfig.hasDefault }
        set { UserDefaults.standard.set(newValue, forKey: "llmRemote") }
    }

    @MainActor static var llmURL: String {
        get { UserDefaults.standard.string(forKey: "llmURL") ?? LLMConfig.defaultURL }
        set { UserDefaults.standard.set(newValue, forKey: "llmURL") }
    }

    @MainActor static var llmModel: String {
        get { UserDefaults.standard.string(forKey: "llmModel") ?? LLMConfig.defaultModel }
        set { UserDefaults.standard.set(newValue, forKey: "llmModel") }
    }

    @MainActor static var llmNoThinking: Bool {
        get { UserDefaults.standard.object(forKey: "llmNoThinking") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "llmNoThinking") }
    }

    @MainActor static var llmContextChars: Int {
        get { UserDefaults.standard.object(forKey: "llmContextChars") as? Int ?? 120_000 }
        set { UserDefaults.standard.set(newValue, forKey: "llmContextChars") }
    }

    static let defaultSummaryInstructions = """
    You summarise transcripts of recorded conversations and voice notes. \
    Write a short summary paragraph, then "Key points:" as a bulleted list, \
    then "Action items:" as a bulleted list (write "None" if there are none). \
    Use only what is in the transcript. Do not invent names, dates or facts.
    """

    @MainActor static var summaryInstructions: String {
        get { UserDefaults.standard.string(forKey: "summaryInstructions") ?? defaultSummaryInstructions }
        set { UserDefaults.standard.set(newValue, forKey: "summaryInstructions") }
    }
}
