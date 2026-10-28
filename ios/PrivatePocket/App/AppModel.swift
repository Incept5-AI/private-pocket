import AVFoundation
import NaturalLanguage
import SwiftUI

@main
struct PrivatePocketApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.devices)
                .environmentObject(model.link)
                .environmentObject(model.library)
                .environmentObject(model.drive)
                .environmentObject(model.locator)
                .environmentObject(model.live)
        }
    }
}

struct QA: Identifiable {
    let id = UUID()
    let question: String
    let scopeCount: Int
    var answer: String?
    var error: String?
    var progress: String?
}

/// Ties the BLE link, the device list and the local library together.
@MainActor
final class AppModel: ObservableObject {
    let devices = DeviceStore()
    let link = PocketLink()
    let library = Library()
    let drive = USBDrive()
    let locator = Locator()
    let live = LiveSession()
    /// The user tapped Disconnect: do not reconnect until they tap Connect.
    @Published var userDisconnected = false
    private var keepAlive: Task<Void, Never>?
    /// Pairing tries since the app came to the foreground (see `keepPairing`).
    private var pairTicks = 0

    @Published var working: Set<String> = []   // recording ids being transcribed/summarised
    @Published var aiError: String?
    /// Questions and answers for this session, keyed by scope ("all" or a recording id).
    @Published var conversations: [String: [QA]] = [:]

    init() {
        if !DefaultServer.key.isEmpty, LLM.key.isEmpty, !UserDefaults.standard.bool(forKey: "seededServerKey") {
            LLM.key = DefaultServer.key
            UserDefaults.standard.set(true, forKey: "seededServerKey")
        }
        library.backfillPockets(devices.devices)
        link.onPeripheralLearned = { [weak self] deviceID, peripheralID in
            guard let self, var d = self.devices.devices.first(where: { $0.id == deviceID }) else { return }
            d.peripheralID = peripheralID
            self.devices.update(d)
        }
        link.onRecordingStarted = { [weak self] name in
            guard let self else { return }
            // A recording still open here whose stop never came (stopped while the link was
            // down): it is saved now, before the new one takes the live session, not thrown away.
            if let old = self.live.name, old != name { self.recordingStopped(old, heard: false) }
            self.locator.recordingStarted(name)
            if let d = self.connectedDevice { self.live.begin(name: name, device: d.id) }
        }
        link.onLiveAudio = { [weak self] data in self?.live.append(data) }
        link.onLinkLost = { [weak self] in
            self?.live.markGap()
            Task { try? await Task.sleep(for: .seconds(2)); await self?.ensureConnected() }
        }
        link.onRecordingStopped = { [weak self] name in self?.recordingStopped(name, heard: true) }
        link.onPaired = { [weak self] d in self?.devices.update(d) }   // the key lives in the Keychain; this refreshes the views
    }

    // MARK: - Staying connected

    /// While the app is in the foreground, keep the selected Pocket connected so
    /// recordings stream live (iOS keeps an existing connection in the background).
    func setActive(_ active: Bool) {
        keepAlive?.cancel()
        guard active else { return }
        pairTicks = 0
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                await self?.ensureConnected()
                await self?.keepPairing()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// Connected but without a key the Pocket accepts: try to pair, every 15 s for the
    /// first two minutes in the foreground and every minute after, never while it
    /// records. In pairing mode the try succeeds; outside it the Pocket drops the link,
    /// which `ensureConnected` restores a moment later.
    private func keepPairing() async {
        guard link.isReady, !canCommand, link.status.recordingSince == nil else { return }
        if case .busy = link.phase { return }   // never on top of another command
        pairTicks += 1
        // Holding the button makes the Pocket drop the link, and that drop triggers a try
        // at once (`PocketLink.handshake`). This is the safety net.
        guard pairTicks <= 8 || pairTicks % 4 == 0 else { return }
        try? await link.tryPairing(quiet: true)
    }

    /// The selected Pocket answers commands: it has a key the Pocket still accepts.
    var canCommand: Bool { (devices.selected?.isPaired ?? false) && !link.keyRejected }

    /// Connected even without a key, so recordings started with the Pocket's button stream.
    func ensureConnected() async {
        guard Prefs.stayConnected, !userDisconnected, link.phase == .idle, !link.isDiscovering,
              let d = devices.selected else { return }
        await link.run("Connecting", quiet: true) { try await link.connect(d) }
    }

    /// With the Pocket in pairing mode (side button held 5 s, blinking blue), give it a new key.
    func pairSelected() async {
        guard let d = devices.selected else { return }
        userDisconnected = false
        await link.run("Pairing") { try await link.pair(d) }
        devices.update(d)   // the key lives in the Keychain; this refreshes the views
    }

    func userConnect() async {
        userDisconnected = false
        await connectSelected()
    }

    func userDisconnect() {
        userDisconnected = true
        link.disconnect()
    }

    /// Identity to save with a recording; the MAC is known while connected to it.
    func pocketID(_ d: DeviceConfig) -> PocketID {
        PocketID(d, mac: link.connectedDeviceID == d.id ? link.status.mac : nil)
    }

    var connectedDevice: DeviceConfig? { devices.devices.first { $0.id == link.connectedDeviceID } }

    func connectSelected() async {
        guard let d = devices.selected else { return }
        await link.run("Connecting") { try await link.connect(d) }
    }

    /// A sync is running: one at a time, so two never share the download channel.
    private var syncing = false
    /// Partial copies checked against the Pocket's file this session.
    private var recheckedPartial: Set<String> = []

    /// Download every recording on the device that is not on the phone yet, and was not deleted here.
    func sync() async {
        guard let d = devices.selected, !syncing else { return }
        guard canCommand else { link.lastError = "Pair the Pocket to download recordings from it."; return }
        syncing = true
        defer { syncing = false }
        await link.run("Syncing") {
            try await link.connect(d)
            let remote = try await link.listFiles()
            // What is not here yet, and what was kept from an incomplete stream (checked once a
            // session against the Pocket's own file); never what was deleted here.
            let missing = remote.filter { f in
                guard !library.wasDeleted(device: d.id, day: f.day, name: f.name) else { return false }
                guard let here = library.recording(device: d.id, day: f.day, name: f.name) else { return true }
                return here.meta.partial == true && !recheckedPartial.contains(here.id)
            }
            for f in missing {
                // A recording starting takes the audio channel: the rest waits for the next sync.
                guard link.status.recordingSince == nil else { break }
                let fetched = try await link.download(f)
                guard !fetched.data.isEmpty, link.status.recordingSince == nil else { break }
                if let here = library.recording(device: d.id, day: f.day, name: f.name) {
                    recheckedPartial.insert(here.id)
                    let local = library.localSize(device: d.id, day: f.day, name: f.name) ?? 0
                    if fetched.data.count > local,
                       let r = library.replaceAudio(here.id, with: fetched.data, seconds: f.seconds, partial: !fetched.whole) {
                        link.note("replaced the partial copy of \(f.name) with the Pocket's file")
                        if d.autoTranscribe { Task { await transcribe(r) } }
                    } else if fetched.whole, fetched.data.count == local {
                        library.mutate(here.id) { $0.partial = nil }   // the same file: it was whole after all
                    }
                    continue
                }
                let place = await locator.place(for: f.name, seconds: f.seconds)
                var r = try library.save(device: d.id, day: f.day, name: f.name, audio: fetched.data, seconds: f.seconds, place: place,
                                         pocket: pocketID(d))
                if !fetched.whole, let marked = library.mutate(r.id, { $0.partial = true }) { r = marked }
                if d.autoTranscribe { Task { await transcribe(r) } }
            }
            try await link.refreshStatus()
        }
    }

    /// Record or Stop is being sent: a second tap is not a second command.
    private var toggling = false

    func toggleRecording() async {
        guard let d = devices.selected, canCommand, !toggling else { return }
        toggling = true
        defer { toggling = false }
        let starting = link.status.recordingSince == nil
        var stopped: String?
        await link.run(starting ? "Starting" : "Stopping") {
            try await link.connect(d)
            if starting {
                guard link.status.recordingSince == nil else { return }   // the Pocket's button got there first
                try await link.startRecording()
            } else if let name = try await link.stopRecording() {
                stopped = name
            }
        }
        if let name = stopped {
            wrapUp(name)
            await saveStopped(name, device: d, inferred: false)
        }
    }

    /// A recording stopped by the Pocket's button, or found still open when a new one started
    /// (`heard` false): its stream is taken at once, then the recording is saved.
    private func recordingStopped(_ name: String, heard: Bool) {
        wrapUp(name)
        guard let d = connectedDevice ?? devices.selected else { return }
        Task { await saveStopped(name, device: d, inferred: !heard) }
    }

    /// Streams detached at a stop, waiting for their save: whichever path saves a recording
    /// takes its stream, and a second path finds it taken.
    private var stoppedStreams: [String: LiveSession.Ending] = [:]
    /// Recordings being saved after their stop, so two paths never save one twice.
    private var saving: Set<String> = []

    /// Detaches the stopped recording's stream from the live session, so a recording started
    /// right after gets a session of its own.
    private func wrapUp(_ name: String) {
        if let e = live.detach(name: name) { stoppedStreams[name] = e }
    }

    private func saveStopped(_ name: String, device d: DeviceConfig, inferred: Bool) async {
        guard !saving.contains(name) else { return }   // already being saved, by the other path
        let ending = stoppedStreams.removeValue(forKey: name)
        saving.insert(name)
        defer { saving.remove(name) }
        await link.run("Saving") { try await completeRecording(name: name, device: d, ending: ending, inferred: inferred) }
    }

    /// After a stop: keep the streamed copy if it is the whole recording, else download the
    /// device's file (if downloading after stop is on). A stream kept because the listing or
    /// the download failed is marked partial, for a later sync to replace with the Pocket's
    /// file; so is anything kept for a stop that was `inferred` rather than heard.
    private func completeRecording(name: String, device d: DeviceConfig, ending: LiveSession.Ending?, inferred: Bool) async throws {
        let streamed = await ending?.finish()
        guard let date = PocketTime.parse(name) else { return }
        let day = PocketTime.day.string(from: date)
        guard !library.has(device: d.id, day: day, name: name) else { return }
        // The Pocket lists a recording once it has closed the file; a call recording (PH…) never.
        // Unpaired, it answers no commands, so the stream is all there is.
        let call = name.hasPrefix("PH")
        let tries = !(d.isPaired && !link.keyRejected) ? 0 : call ? 1 : 3
        var listed: RemoteFile?
        var listError: Error?
        for round in 0..<tries where listed == nil {
            try? await Task.sleep(for: .milliseconds(round == 0 ? 500 : 1_500))
            do { listed = try await link.listFiles().first { $0.name == name } } catch { listError = error; break }
        }
        var remote = listed ?? RemoteFile(day: day, name: name, seconds: 0)

        let audio: Data
        var partial = inferred
        if let s = streamed, s.complete, Self.matches(s.audio, seconds: remote.seconds) {
            audio = s.audio
            link.note("kept the streamed copy of \(name): \(s.audio.count) bytes")
        } else if listed == nil, let s = streamed, !s.audio.isEmpty {
            // Not in the listing (a call recording, or the listing failed): the stream is what
            // there is. Unless it is a whole call recording, a sync checks it against the Pocket's file.
            audio = s.audio
            remote = RemoteFile(day: day, name: name, seconds: Int((Self.duration(of: s.audio) ?? 0).rounded()))
            if !s.complete || !call { partial = true }
            link.note(s.complete ? "kept the streamed copy of \(name), which the Pocket does not list: \(s.audio.count) bytes"
                                 : "stream had a gap and the Pocket does not list \(name); kept \(s.audio.count) bytes")
        } else if listed != nil, d.downloadAfterStop {
            if let s = streamed { link.note("streamed copy incomplete (\(s.audio.count) bytes); downloading") }
            do {
                let fetched = try await link.download(remote)
                audio = fetched.data
                if !fetched.whole { partial = true }
            } catch {
                // The download failed (a new recording took the channel, say): the stream, if any,
                // is kept for now, and a sync replaces it with the Pocket's file.
                guard let s = streamed, !s.audio.isEmpty else { throw error }
                audio = s.audio
                partial = true
                link.note("downloading \(name) failed; kept the streamed \(s.audio.count) bytes for now")
            }
        } else if let listError {
            throw listError
        } else {
            return
        }
        guard !audio.isEmpty else { return }
        let place = await locator.place(for: name, seconds: remote.seconds)
        var r = try library.save(device: d.id, day: remote.day, name: name, audio: audio, seconds: remote.seconds, place: place,
                                 pocket: pocketID(d))
        r.meta.mode = name.hasPrefix("PH") ? "CALL" : link.status.mode
        if partial { r.meta.partial = true }
        library.update(r)
        if let s = streamed, let t = s.transcript {
            r.meta.transcript = t
            r.meta.words = s.words.isEmpty ? nil : s.words
            r.meta.locale = s.locale ?? NLLanguageRecognizer.dominantLanguage(for: t)?.rawValue
            r.meta.transcribedAt = Date()
            r.meta.liveTranscript = true
            library.update(r)
            if d.autoTranscribe {
                Task { await transcribe(r) }
            } else if Prefs.diarize, !s.words.isEmpty {
                let rec = r
                Task { await findSpeakers(rec) }   // the whole recording, so ids hold throughout
            }
        } else if d.autoTranscribe {
            Task { await transcribe(r) }
        }
    }

    /// The streamed MP3 lasts as long as the device says the recording does
    /// (LIST reports whole seconds), so nothing was missed.
    static func matches(_ mp3: Data, seconds: Int) -> Bool {
        guard seconds > 0, let duration = duration(of: mp3) else { return false }
        return abs(duration - Double(seconds)) <= 2
    }

    /// Seconds of audio in an MP3.
    static func duration(of mp3: Data) -> Double? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("check-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? mp3.write(to: tmp)) != nil, let f = try? AVAudioFile(forReading: tmp) else { return nil }
        return Double(f.length) / f.processingFormat.sampleRate
    }

    func setWebSync(_ on: Bool) async {
        guard let d = devices.selected else { return }
        await link.run("Web Sync") {
            try await link.connect(d)
            try await link.setWebSync(on)
        }
    }

    // MARK: - On-device AI

    /// Transcribes in `localeID`, else the language last used for this recording,
    /// else the default from Settings.
    func transcribe(_ r: Recording, localeID: String? = nil) async {
        working.insert(r.id)
        defer { working.remove(r.id) }
        do {
            let id = localeID ?? r.meta.locale ?? Prefs.transcriptionLocale
            // Who spoke when runs alongside the words; it only needs the audio.
            let url = r.audioURL
            let speakers: Task<[SpeakerSegment], Error>? = Prefs.diarize
                ? Task { try await Diarizer.diarize(try Data(contentsOf: url), filename: url.lastPathComponent) } : nil
            let t = try await Transcriber.transcribe(url, localeID: id)
            let segments = await speakers?.result
            // Only what transcription owns is written, onto the recording as it is now.
            library.mutate(r.id) { m in
                m.transcript = t.text
                m.words = t.words.isEmpty ? nil : t.words
                // With auto-detect, record the language that came back so summaries match it.
                m.locale = id == Languages.auto ? NLLanguageRecognizer.dominantLanguage(for: t.text)?.rawValue : id
                m.liveTranscript = nil
                m.transcribedAt = Date()
                m.turns = nil
                m.speakersError = nil
                if let segments { Self.applySpeakers(segments, to: &m) }
            }
        } catch {
            aiError = "Transcription failed: \(error.localizedDescription)"
        }
    }

    /// Diarises again and re-matches the stored word times.
    func findSpeakers(_ r: Recording) async {
        working.insert(r.id)
        defer { working.remove(r.id) }
        let result: Result<[SpeakerSegment], Error>
        do {
            result = .success(try await Diarizer.diarize(try Data(contentsOf: r.audioURL), filename: r.audioURL.lastPathComponent))
        } catch {
            result = .failure(error)
        }
        library.mutate(r.id) { Self.applySpeakers(result, to: &$0) }
    }

    private static func applySpeakers(_ result: Result<[SpeakerSegment], Error>, to m: inout RecordingMeta) {
        switch result {
        case .success(let segments):
            let turns = Speakers.align(m.words ?? [], segments)
            m.turns = turns.isEmpty ? nil : turns
            m.speakersError = turns.isEmpty && !(m.words ?? []).isEmpty ? "No speech found by the diarizer." : nil
        case .failure(let e):
            m.speakersError = e.localizedDescription
        }
    }

    func renameSpeaker(_ r: Recording, speaker: Int, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        library.mutate(r.id) { m in
            var names = m.speakerNames ?? [:]
            names[String(speaker)] = n.isEmpty ? nil : n
            m.speakerNames = names.isEmpty ? nil : names
        }
    }

    func summarise(_ r: Recording) async {
        guard let transcript = r.transcriptForModel else { return }
        working.insert(r.id)
        defer { working.remove(r.id) }
        do {
            let summary = try await Summariser.summarise(transcript, instructions: Prefs.summaryInstructions,
                                                         localeID: r.meta.locale)
            library.mutate(r.id) { $0.summary = summary; $0.summarisedAt = Date() }
        } catch {
            aiError = "Summary failed: \(error.localizedDescription)"
        }
    }

    func ask(_ question: String, scope: String, recordings: [Recording]) async {
        let qa = QA(question: question, scopeCount: recordings.count)
        conversations[scope, default: []].append(qa)
        func set(_ change: (inout QA) -> Void) {
            guard let i = conversations[scope]?.firstIndex(where: { $0.id == qa.id }) else { return }
            change(&conversations[scope]![i])
        }
        let sources = recordings.compactMap { r in r.transcriptForModel.map { Asker.Source(label: r.sourceLabel, text: $0) } }
        do {
            let answer = try await Asker.answer(question, sources: sources) { done, total in
                set { $0.progress = "Reading part \(done) of \(total)…" }
            }
            set { $0.answer = answer; $0.progress = nil }
        } catch {
            set { $0.error = error.localizedDescription; $0.progress = nil }
        }
    }

    /// Transcribes, one at a time, recordings that have no transcript.
    func transcribeMissing(_ rs: [Recording]) async {
        for r in rs where r.meta.transcript == nil && !working.contains(r.id) {
            await transcribe(r)
        }
    }

    /// Sets the title (empty clears it, so the place or time shows instead).
    func rename(_ r: Recording, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        library.mutate(r.id) { $0.title = t.isEmpty ? nil : t }
    }

    /// Tags a recording with where the phone is now, for when it was not captured.
    func tagHere(_ r: Recording) async {
        guard var place = await locator.currentPlace(approximate: false) else {
            aiError = "No location. Allow location access for Private Pocket in Settings."
            return
        }
        place.approximate = false
        library.mutate(r.id) { $0.place = place }
    }

    func clearPlace(_ r: Recording) {
        library.mutate(r.id) { $0.place = nil }
    }

    /// Everything under Recordings as one zip, for the share sheet: a copy to keep
    /// somewhere else, or to move to another phone.
    func exportAll() async throws -> URL {
        let root = library.root
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("Private Pocket recordings.zip")
        try? FileManager.default.removeItem(at: out)
        return try await Task.detached(priority: .userInitiated) {
            var copyError: Error?
            var coordError: NSError?
            // `.forUploading` hands over a zip of the folder.
            NSFileCoordinator().coordinate(readingItemAt: root, options: .forUploading, error: &coordError) { url in
                do { try FileManager.default.copyItem(at: url, to: out) } catch { copyError = error }
            }
            if let e = coordError ?? copyError { throw e }
            return out
        }.value
    }

    // MARK: - USB

    /// Copies drive files that are missing on the phone into the library.
    func importFromDrive(_ files: [DriveFile], device: DeviceConfig) {
        for f in files where !library.has(device: device.id, day: f.day, name: f.name)
                              && !library.wasDeleted(device: device.id, day: f.day, name: f.name) {
            do {
                try library.save(device: device.id, day: f.day, name: f.name, audio: try drive.read(f), seconds: nil,
                                 pocket: PocketID(device))
            } catch {
                drive.error = "Import of \(f.name) failed: \(error.localizedDescription)"
            }
        }
    }

    /// A drive file is backed up when the phone holds a copy of exactly the same size.
    func isBackedUp(_ f: DriveFile, device: DeviceConfig) -> Bool {
        library.localSize(device: device.id, day: f.day, name: f.name) == f.size
    }
}
