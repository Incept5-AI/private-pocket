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
    /// Dynamic Island and Lock Screen while the Pocket records.
    let activity = RecordingActivity()
    private var activityTicker: Task<Void, Never>?
    /// The user tapped Disconnect: do not reconnect until they tap Connect.
    @Published var userDisconnected = false
    private var keepAlive: Task<Void, Never>?
    /// Scene is active: reconnect by scanning; otherwise leave a background standby.
    private var active = false

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
            self.locator.recordingStarted(name)
            if let d = self.connectedDevice { self.live.begin(name: name, device: d.id) }
            self.startActivity(name: name)
        }
        StopRecordingIntent.handler = { [weak self] in
            guard let self, self.canCommand, self.link.status.recordingSince != nil else { return }
            await self.toggleRecording()
        }
        StartRecordingIntent.handler = { [weak self] in
            guard let self else { return }
            guard self.canCommand else { throw PocketIntentError(message: "Pair your Pocket in the app first.") }
            guard self.link.status.recordingSince == nil else { return }
            await self.toggleRecording()
            if self.link.status.recordingSince == nil {
                throw PocketIntentError(message: self.link.lastError ?? "Could not reach your Pocket.")
            }
        }
        link.onLiveAudio = { [weak self] data in self?.live.append(data) }
        link.onLinkLost = { [weak self] in
            guard let self else { return }
            live.markGap()
            if active {
                Task { try? await Task.sleep(for: .seconds(2)); await self.ensureConnected() }
            } else {
                standby()   // at once: background runtime after a Bluetooth event is short
            }
        }
        link.onConnected = { [weak self] in
            self?.link.note("connected in the background")
            Task { await self?.autoSync() }
        }
        link.onPaired = { [weak self] d in
            guard let self else { return }
            devices.update(d)   // the key lives in the Keychain; this refreshes the views
            Task { await self.autoSync(d) }
        }
        link.onRecordingStopped = { [weak self] name in
            guard let self, let d = self.connectedDevice else { self?.endActivity(name: name); return }
            Task {
                await self.link.run("Saving") { try await self.completeRecording(name: name, device: d) }
                self.endActivity(name: name)
            }
        }
    }

    // MARK: - Staying connected

    /// Keep the selected Pocket connected so recordings stream live. In the foreground
    /// that means scanning every 15 s; in the background a pending connection that iOS
    /// completes whenever the Pocket is in range (an existing connection just stays up).
    func setActive(_ active: Bool) {
        self.active = active
        keepAlive?.cancel()
        guard active else { standby(); return }
        if link.phase == .waiting { link.disconnect() }   // scan instead, which also notices new Pockets
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                await self?.ensureConnected()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private var wantsConnection: DeviceConfig? {
        guard Prefs.stayConnected, !userDisconnected, !link.isDiscovering else { return nil }
        return devices.selected
    }

    /// The selected Pocket answers commands: it has a key the Pocket still accepts.
    var canCommand: Bool { (devices.selected?.isPaired ?? false) && !link.keyRejected
    }

    func ensureConnected() async {
        guard let d = wantsConnection else { return }
        guard active else { link.standby(d); return }
        guard link.phase == .idle else { return }
        await link.run("Connecting", quiet: true) { try await link.connect(d) }
        await autoSync(d)
    }

    private var autoSyncing = false

    /// Fetch whatever the phone is missing, quietly, once the Pocket is connected and
    /// not recording. Runs after every connection, foreground or background.
    func autoSync(_ device: DeviceConfig? = nil) async {
        guard let d = device ?? devices.selected, d.isPaired, !link.keyRejected, d.syncsAutomatically, !autoSyncing,
              link.isReady, link.connectedDeviceID == d.id, link.status.recordingSince == nil else { return }
        autoSyncing = true
        defer { autoSyncing = false }
        await sync(quiet: true)
    }

    func standby() {
        guard let d = wantsConnection else { return }
        link.standby(d)
    }

    /// With the Pocket in pairing mode (side button held 5 s, blinking blue), give it a new key.
    func pairSelected() async {
        guard let d = devices.selected else { return }
        userDisconnected = false
        await link.run("Pairing") { try await link.pair(d) }
        devices.update(d)   // the key lives in the Keychain; this refreshes the views
        await autoSync(d)
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
        await autoSync(d)
    }

    /// Fetch every recording on the device that is not on the phone yet.
    func sync(quiet: Bool = false) async {
        guard let d = devices.selected else { return }
        guard d.isPaired, !link.keyRejected else {
            if !quiet { link.lastError = "Pair the Pocket to fetch recordings from it." }
            return
        }
        await link.run("Fetching", quiet: quiet) {
            try await link.connect(d)
            let remote = try await link.listFiles()
            let missing = remote.filter { !library.has(device: d.id, day: $0.day, name: $0.name) }
            for f in missing {
                let data = try await link.download(f)
                let place = await locator.place(for: f.name, seconds: f.seconds)
                let r = try library.save(device: d.id, day: f.day, name: f.name, audio: data, seconds: f.seconds, place: place,
                                         pocket: pocketID(d))
                if d.autoTranscribe { Task { await transcribe(r) } }
            }
            try await link.refreshStatus()
        }
    }

    func toggleRecording() async {
        guard let d = devices.selected, canCommand else { return }
        await link.run(link.status.recordingSince == nil ? "Starting" : "Stopping") {
            try await link.connect(d)
            if link.status.recordingSince == nil {
                try await link.startRecording()
            } else if let name = try await link.stopRecording() {
                defer { endActivity(name: name) }
                try await completeRecording(name: name, device: d)
            }
        }
    }

    // MARK: - Live Activity

    private func startActivity(name: String) {
        guard let d = connectedDevice else { return }
        activity.start(device: d, startedAt: PocketTime.parse(name) ?? Date(), paired: canCommand)
        activityTicker?.cancel()
        activityTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                self.activity.update(line: String(self.live.text.suffix(140)), streaming: self.live.isActive,
                                     gap: self.live.gap, paired: self.canCommand)
            }
        }
    }

    /// Ends the activity, showing the saved length if the recording made it to the phone.
    private func endActivity(name: String) {
        activityTicker?.cancel()
        activityTicker = nil
        activity.end(savedSeconds: library.recordings.first { $0.name == name }?.meta.seconds)
    }

    /// After a stop: keep the streamed copy if it is the whole recording, else
    /// download the device's file (if downloading after stop is on).
    private func completeRecording(name: String, device d: DeviceConfig) async throws {
        let streamed = await live.end(name: name)
        guard let date = PocketTime.parse(name) else { return }
        let day = PocketTime.day.string(from: date)
        guard !library.has(device: d.id, day: day, name: name) else { return }

        let audio: Data
        let remote: RemoteFile
        if !d.isPaired {
            // Not paired: the Pocket answers no commands, so the stream is all there is.
            guard let s = streamed, !s.audio.isEmpty else { return }
            audio = s.audio
            remote = RemoteFile(day: day, name: name, seconds: Int((Self.duration(of: s.audio) ?? 0).rounded()))
            link.note(s.complete ? "kept the streamed copy of \(name): \(s.audio.count) bytes"
                                 : "stream had a gap; kept \(s.audio.count) bytes of \(name). Pair to download the Pocket's file")
        } else {
            try await Task.sleep(for: .milliseconds(500))   // let the device close the file
            remote = try await link.listFiles().first { $0.name == name }
                ?? RemoteFile(day: day, name: name, seconds: 0)
            if let s = streamed, s.complete, Self.matches(s.audio, seconds: remote.seconds) {
                audio = s.audio
                link.note("kept the streamed copy of \(name): \(s.audio.count) bytes")
            } else if d.downloadAfterStop {
                if let s = streamed { link.note("streamed copy incomplete (\(s.audio.count) bytes); downloading") }
                audio = try await link.download(remote)
            } else {
                return
            }
        }
        let place = await locator.place(for: name, seconds: remote.seconds)
        var r = try library.save(device: d.id, day: remote.day, name: name, audio: audio, seconds: remote.seconds, place: place,
                                 pocket: pocketID(d))
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

    /// Seconds of audio in an MP3, by decoding its header chain.
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
            var r = r
            let id = localeID ?? r.meta.locale ?? Prefs.transcriptionLocale
            // Who spoke when runs alongside the words; it only needs the audio.
            let url = r.audioURL
            let speakers: Task<[SpeakerSegment], Error>? = Prefs.diarize
                ? Task { try await Diarizer.diarize(try Data(contentsOf: url), filename: url.lastPathComponent) } : nil
            let t = try await Transcriber.transcribe(url, localeID: id)
            r.meta.transcript = t.text
            r.meta.words = t.words.isEmpty ? nil : t.words
            // With auto-detect, record the language that came back so summaries match it.
            r.meta.locale = id == Languages.auto ? NLLanguageRecognizer.dominantLanguage(for: t.text)?.rawValue : id
            r.meta.liveTranscript = nil
            r.meta.transcribedAt = Date()
            r.meta.turns = nil
            r.meta.speakersError = nil
            if let speakers { applySpeakers(await speakers.result, to: &r) }
            library.update(r)
        } catch {
            aiError = "Transcription failed: \(error.localizedDescription)"
        }
    }

    /// Diarises again and re-matches the stored word times.
    func findSpeakers(_ r: Recording) async {
        working.insert(r.id)
        defer { working.remove(r.id) }
        var r = r
        do {
            let segments = try await Diarizer.diarize(try Data(contentsOf: r.audioURL), filename: r.audioURL.lastPathComponent)
            applySpeakers(.success(segments), to: &r)
        } catch {
            applySpeakers(.failure(error), to: &r)
        }
        library.update(r)
    }

    private func applySpeakers(_ result: Result<[SpeakerSegment], Error>, to r: inout Recording) {
        switch result {
        case .success(let segments):
            let turns = Speakers.align(r.meta.words ?? [], segments)
            r.meta.turns = turns.isEmpty ? nil : turns
            r.meta.speakersError = turns.isEmpty && !(r.meta.words ?? []).isEmpty ? "No speech found by the diarizer." : nil
        case .failure(let e):
            r.meta.speakersError = e.localizedDescription
        }
    }

    func renameSpeaker(_ r: Recording, speaker: Int, to name: String) {
        var r = r
        var names = r.meta.speakerNames ?? [:]
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        names[String(speaker)] = n.isEmpty ? nil : n
        r.meta.speakerNames = names.isEmpty ? nil : names
        library.update(r)
    }

    func summarise(_ r: Recording) async {
        guard let transcript = r.transcriptForModel else { return }
        working.insert(r.id)
        defer { working.remove(r.id) }
        do {
            var r = r
            r.meta.summary = try await Summariser.summarise(transcript, instructions: Prefs.summaryInstructions,
                                                            localeID: r.meta.locale)
            r.meta.summarisedAt = Date()
            library.update(r)
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
        var r = r
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        r.meta.title = t.isEmpty ? nil : t
        library.update(r)
    }

    /// Tags a recording with where the phone is now, for when it was not captured.
    func tagHere(_ r: Recording) async {
        guard var place = await locator.currentPlace(approximate: false) else {
            aiError = "No location. Allow location access for Private Pocket in Settings."
            return
        }
        place.approximate = false
        var r = r
        r.meta.place = place
        library.update(r)
    }

    func clearPlace(_ r: Recording) {
        var r = r
        r.meta.place = nil
        library.update(r)
    }

    // MARK: - USB

    /// Copies drive files that are missing on the phone into the library.
    func importFromDrive(_ files: [DriveFile], device: DeviceConfig) {
        for f in files where !library.has(device: device.id, day: f.day, name: f.name) {
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
