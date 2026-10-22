import Foundation

/// A recording held on this phone: `Documents/Recordings/<device id>/<day>/<name>.mp3`
/// with a `<name>.json` sidecar for transcript and summary. Documents is visible in
/// the Files app (UIFileSharingEnabled), so recordings can also be copied off by hand.
struct Recording: Identifiable, Hashable {
    let deviceID: UUID
    let day: String        // yyyy-MM-dd, the device's folder name
    let name: String       // yyyyMMddHHmmss in UTC, the device's file name
    let audioURL: URL
    var meta: RecordingMeta

    var id: String { "\(deviceID.uuidString)/\(day)/\(name)" }
    var startedAt: Date? { PocketTime.parse(name) }
    /// The user's title, else the place, else the start time.
    var displayTitle: String {
        meta.title ?? meta.place?.name ?? startedAt?.formatted(date: .omitted, time: .shortened) ?? name
    }
    var size: Int { (try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
    /// Made with the switch on call: the contact mic, with the card on the phone.
    var isCall: Bool { meta.mode == "CALL" || name.hasPrefix("PH") }
}

extension Recording {
    /// The Pocket's current name in Settings, else the name saved with the recording.
    func pocketName(_ devices: [DeviceConfig]) -> String {
        devices.first { $0.id == deviceID }?.name ?? meta.pocket?.name ?? "Unknown Pocket"
    }

    /// Speaker-labelled when there are two or more speakers, else the plain text.
    var transcriptForModel: String? {
        if let t = meta.turns, Speakers.count(t) > 1 { return Speakers.text(t, names: meta.speakerNames) }
        return meta.transcript
    }

    /// How a recording is named to the language model: title, date, time, place.
    var sourceLabel: String {
        var parts = [meta.title ?? meta.place?.name ?? "Recording"]
        if let t = startedAt { parts.append(t.formatted(date: .abbreviated, time: .shortened)) }
        if meta.title != nil, let p = meta.place?.name { parts.append(p) }
        return parts.joined(separator: ", ")
    }
}

/// Which physical Pocket made a recording, stored in the sidecar so it survives
/// the device being removed from Settings (the folder name is only the app's id).
struct PocketID: Codable, Hashable {
    /// The name given in Settings when the recording was saved.
    var name: String
    /// Advertised BLE name, e.g. `PKT01_GREY_2617abcd`; ends with the last 4 bytes of the MAC.
    var advertised: String
    var mac: String?

    init(_ d: DeviceConfig, mac: String? = nil) {
        name = d.name
        advertised = d.advertisedName
        self.mac = mac
    }

    /// "abcd", from the advertised name, to tell same-coloured cards apart.
    var shortID: String { String(advertised.split(separator: "_").last?.suffix(4) ?? "") }
}

struct RecordingMeta: Codable, Hashable {
    var title: String?
    /// The Pocket that recorded it.
    var pocket: PocketID?
    var place: Place?
    var seconds: Int?
    /// The Pocket's side switch when it was made: `CON` (audio) or `CALL` (phone call).
    var mode: String?
    /// Locale the transcript was made in, e.g. fr-FR.
    var locale: String?
    /// The transcript was made live while recording (quicker, a little less accurate).
    var liveTranscript: Bool?
    /// Word times, kept so speakers can be found (again) later.
    var words: [TimedWord]?
    var turns: [Turn]?
    /// Names given to speakers, keyed by speaker number ("0", "1"…).
    var speakerNames: [String: String]?
    var speakersError: String?
    var downloadedAt = Date()
    var transcript: String?
    var transcribedAt: Date?
    var summary: String?
    var summarisedAt: Date?
    /// What the conversation was and what came out of it (see `MomentInsight`).
    var insight: MomentInsight?
    var analysedAt: Date?
    /// Your correction of the kind, which wins over the reading.
    var labelKind: String?
    /// Sample moments (see `SampleMoments`): which one, and the kind it is meant to be read as.
    var sampleID: String?
    var expectedKind: String?
}

enum PocketTime {
    /// Pocket file names are UTC timestamps (the official app sets the clock in UTC).
    static let fileName: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        return f
    }()

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Call-mode recordings (the card on the back of the phone, contact mic) are named
    /// `PH` + `yyMMddHHmmss` instead.
    static let shortName: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyMMddHHmmss"
        return f
    }()

    /// `yyyyMMddHHmmss`, or any letter prefix followed by 12 or 14 digits.
    static func parse(_ name: String) -> Date? {
        if let d = fileName.date(from: name) { return d }
        let digits = String(name.drop { !$0.isNumber })
        guard digits.allSatisfy(\.isNumber) else { return nil }
        switch digits.count {
        case 12: return shortName.date(from: digits)
        case 14: return fileName.date(from: digits)
        default: return nil
        }
    }
    static func now() -> String { fileName.string(from: Date()) }
}

@MainActor
final class Library: ObservableObject {
    @Published private(set) var recordings: [Recording] = []

    let root: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let r = docs.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        return r
    }()

    init() { reload() }

    func folder(device: UUID, day: String) -> URL {
        root.appendingPathComponent(device.uuidString).appendingPathComponent(day)
    }

    func reload() {
        let fm = FileManager.default
        var out: [Recording] = []
        for devDir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            guard let dev = UUID(uuidString: devDir.lastPathComponent) else { continue }
            for dayDir in (try? fm.contentsOfDirectory(at: devDir, includingPropertiesForKeys: nil)) ?? [] {
                for f in (try? fm.contentsOfDirectory(at: dayDir, includingPropertiesForKeys: nil)) ?? []
                where f.pathExtension.lowercased() == "mp3" {
                    let name = f.deletingPathExtension().lastPathComponent
                    out.append(Recording(deviceID: dev, day: dayDir.lastPathComponent, name: name,
                                         audioURL: f, meta: loadMeta(f)))
                }
            }
        }
        // Newest first by time, not by name: call recordings are named `PH…` and would
        // otherwise all sort above the digit-named audio ones.
        recordings = out.sorted { ($0.startedAt ?? .distantPast, $0.name) > ($1.startedAt ?? .distantPast, $1.name) }
    }

    func recordings(for device: UUID) -> [Recording] { recordings.filter { $0.deviceID == device } }

    func has(device: UUID, day: String, name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder(device: device, day: day).appendingPathComponent("\(name).mp3").path)
    }

    func localSize(device: UUID, day: String, name: String) -> Int? {
        let u = folder(device: device, day: day).appendingPathComponent("\(name).mp3")
        return (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    @discardableResult
    func save(device: UUID, day: String, name: String, audio: Data, seconds: Int?, place: Place? = nil,
              pocket: PocketID? = nil) throws -> Recording {
        let dir = folder(device: device, day: day)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).mp3")
        try audio.write(to: url, options: .atomic)
        var meta = RecordingMeta()
        meta.seconds = seconds
        meta.place = place
        meta.pocket = pocket
        try writeMeta(meta, for: url)
        reload()
        return Recording(deviceID: device, day: day, name: name, audioURL: url, meta: meta)
    }

    /// Stamps recordings saved before `pocket` existed with the device whose folder
    /// they are in, while that device is still in Settings.
    func backfillPockets(_ devices: [DeviceConfig]) {
        for r in recordings where r.meta.pocket == nil {
            guard let d = devices.first(where: { $0.id == r.deviceID }) else { continue }
            var r = r
            r.meta.pocket = PocketID(d)
            update(r)
        }
    }

    func update(_ r: Recording) {
        try? writeMeta(r.meta, for: r.audioURL)
        if let i = recordings.firstIndex(where: { $0.id == r.id }) { recordings[i] = r }
    }

    func delete(_ r: Recording) {
        try? FileManager.default.removeItem(at: r.audioURL)
        try? FileManager.default.removeItem(at: metaURL(r.audioURL))
        reload()
    }

    /// Everything under Recordings, then an empty library.
    func deleteAll() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    private func metaURL(_ audio: URL) -> URL { audio.deletingPathExtension().appendingPathExtension("json") }

    private func loadMeta(_ audio: URL) -> RecordingMeta {
        guard let d = try? Data(contentsOf: metaURL(audio)),
              let m = try? JSONDecoder().decode(RecordingMeta.self, from: d) else { return RecordingMeta() }
        return m
    }

    private func writeMeta(_ m: RecordingMeta, for audio: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(m).write(to: metaURL(audio), options: .atomic)
    }
}
