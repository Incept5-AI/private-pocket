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
                .preferredColorScheme(.dark)
                .tint(Brand.act)
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
    /// The moments it was read from.
    var sources: [String] = []
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
    /// Pairing tries since the app came to the foreground (see `setActive`).
    private var pairTicks = 0
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
        // Everything is automatic now: Pockets added before that was the default transcribe what arrives too.
        if !UserDefaults.standard.bool(forKey: "autoTranscribeOn") {
            for var d in devices.devices where !d.autoTranscribe {
                d.autoTranscribe = true
                devices.update(d)
            }
            UserDefaults.standard.set(true, forKey: "autoTranscribeOn")
        }
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
            guard let self else { return }
            guard self.canCommand else { throw PocketIntentError(message: "Pair your Pocket in the app first.") }
            guard self.link.status.recordingSince != nil else { return }
            await self.toggleRecording()
        }
        ToggleRecordingIntent.handler = { [weak self] on in
            guard let self else { return }
            guard self.canCommand else { throw PocketIntentError(message: "Pair your Pocket in the app first.") }
            guard on != (self.link.status.recordingSince != nil) else { return }
            await self.toggleRecording()
            if on, self.link.status.recordingSince == nil {
                throw PocketIntentError(message: self.link.lastError ?? "Could not reach your Pocket.")
            }
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
        activity.note = { [weak self] s in self?.link.note(s) }
        link.onLinkLost = { [weak self] in
            guard let self else { return }
            live.markGap()
            activity.showWaiting()
            if active {
                Task { try? await Task.sleep(for: .seconds(2)); await self.ensureConnected() }
            } else {
                standby()   // at once: background runtime after a Bluetooth event is short
            }
        }
        link.onConnected = { [weak self] in
            guard let self else { return }
            link.note("connected in the background")
            refreshPresence()
            Task { await self.autoSync() }
        }
        link.onPaired = { [weak self] d in
            guard let self else { return }
            devices.update(d)   // the key lives in the Keychain; this refreshes the views
            refreshPresence()
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
        if active { Task { await ServerStatus.shared.check() } }
        if active { Task { await self.transcribeWhatLanded() } }
        self.active = active
        keepAlive?.cancel()
        guard active else { standby(); return }
        if link.phase == .waiting { link.disconnect() }   // scan instead, which also notices new Pockets
        pairTicks = 0
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                await self?.ensureConnected()
                self?.refreshPresence()
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
        // at once (`handshake`). This is the safety net: every tick for the first two
        // minutes, then once a minute, quietly; the screen stays steady through the bounce.
        guard pairTicks <= 8 || pairTicks % 4 == 0 else { return }
        try? await link.tryPairing(quiet: true)
    }

    /// Keep the Dynamic Island in step with the Pocket: light and battery while
    /// connected (started only while the app is open, which is iOS's rule), gone when
    /// the user turns it off or disconnects. Recording is handled by `startActivity`.
    func refreshPresence() {
        guard Prefs.islandPresence, let d = connectedDevice, link.isReady else {
            if !Prefs.islandPresence, !activity.isRecording { activity.end() }
            return
        }
        activity.showReady(device: d, battery: link.status.battery,
                           hoursFree: link.status.freeMiB.map { PocketFacts.hours(mib: $0) })
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
        refreshPresence()
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
        activity.end()
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
        activity.showRecording(device: d, startedAt: PocketTime.parse(name) ?? Date(), paired: canCommand)
        activityTicker?.cancel()
        activityTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                self.activity.updateRecording(line: String(self.live.text.suffix(140)), streaming: self.live.isActive,
                                              gap: self.live.gap, paired: self.canCommand)
            }
        }
    }

    /// Shows the saved length for a moment, then the Pocket's light and battery again.
    private func endActivity(name: String) {
        activityTicker?.cancel()
        activityTicker = nil
        activity.showStopped(savedSeconds: library.recordings.first { $0.name == name }?.meta.seconds,
                             keepPresence: Prefs.islandPresence && connectedDevice != nil)
    }

    /// After a stop: keep the streamed copy if it is the whole recording, else
    /// download the device's file (if downloading after stop is on).
    private func completeRecording(name: String, device d: DeviceConfig) async throws {
        let streamed = await live.end(name: name)
        guard let date = PocketTime.parse(name) else { return }
        let day = PocketTime.day.string(from: date)
        guard !library.has(device: d.id, day: day, name: name) else { return }

        let audio: Data
        var remote: RemoteFile
        if !d.isPaired {
            // Not paired: the Pocket answers no commands, so the stream is all there is.
            guard let s = streamed, !s.audio.isEmpty else { return }
            audio = s.audio
            remote = RemoteFile(day: day, name: name, seconds: Int((Self.duration(of: s.audio) ?? 0).rounded()))
            link.note(s.complete ? "kept the streamed copy of \(name): \(s.audio.count) bytes"
                                 : "stream had a gap; kept \(s.audio.count) bytes of \(name). Pair to download the Pocket's file")
        } else {
            try await Task.sleep(for: .milliseconds(500))   // let the device close the file
            let listed = try await link.listFiles().first { $0.name == name }
            remote = listed ?? RemoteFile(day: day, name: name, seconds: 0)
            if let s = streamed, s.complete, Self.matches(s.audio, seconds: remote.seconds) {
                audio = s.audio
                link.note("kept the streamed copy of \(name): \(s.audio.count) bytes")
            } else if listed == nil, let s = streamed, !s.audio.isEmpty {
                // Call-mode recordings (PH…) are not in the Pocket's listing, so they
                // cannot be fetched: the stream is all there is.
                audio = s.audio
                remote = RemoteFile(day: day, name: name, seconds: Int((Self.duration(of: s.audio) ?? 0).rounded()))
                link.note(s.complete ? "kept the streamed copy of \(name), which the Pocket does not list: \(s.audio.count) bytes"
                                     : "stream had a gap and the Pocket does not list \(name); kept \(s.audio.count) bytes")
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
        r.meta.mode = name.hasPrefix("PH") ? "CALL" : link.status.mode
        library.update(r)
        if let s = streamed, let t = s.transcript {
            r.meta.transcript = t
            r.meta.words = s.words.isEmpty ? nil : s.words
            r.meta.locale = s.locale ?? NLLanguageRecognizer.dominantLanguage(for: t)?.rawValue
            r.meta.transcribedAt = Date()
            r.meta.liveTranscript = true
            library.update(r)
            let rec = r
            if d.autoTranscribe {
                Task { await transcribe(rec) }
            } else if Prefs.diarize, !s.words.isEmpty {
                Task {
                    await findSpeakers(rec)   // the whole recording, so ids hold throughout
                    await analyse(library.recordings.first { $0.id == rec.id } ?? rec, quiet: true)
                }
            } else {
                Task { await analyse(rec, quiet: true) }
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
    func transcribe(_ r: Recording, localeID: String? = nil, quiet: Bool = false) async {
        await ServerStatus.shared.check()
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
            let read = r
            Task { await self.analyse(read, quiet: true) }
        } catch {
            if !quiet { aiError = "Transcription failed: \(error.localizedDescription)" }
            link.note("transcription failed for \(r.name): \(error.localizedDescription)")
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
        await ServerStatus.shared.check()
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
        await ServerStatus.shared.check()
        let qa = QA(question: question, scopeCount: recordings.count, sources: recordings.map(\.id))
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

    /// Reads a transcript for what the conversation was and what came out of it. With a
    /// language model available it reads it properly; without one the switch, the
    /// speakers and the dates in the text still give the kind, the people and what is
    /// coming up.
    func analyse(_ r: Recording, quiet: Bool = false) async {
        await ServerStatus.shared.check()
        working.insert(r.id)
        defer { working.remove(r.id) }
        var r = r
        if LLM.availability == nil {
            do {
                r.meta.insight = try await Analyst.analyse(r, config: LLM.config)
            } catch {
                if !quiet { aiError = "Could not read the conversation: \(error.localizedDescription)" }
                if r.meta.insight == nil { r.meta.insight = Analyst.heuristic(r) }
            }
        } else if r.meta.insight == nil {
            r.meta.insight = Analyst.heuristic(r)
        }
        if let names = r.meta.insight?.inferredSpeakers, !names.isEmpty {
            var current = r.meta.speakerNames ?? [:]
            for (k, v) in names where (current[k] ?? "").isEmpty { current[k] = v }
            r.meta.speakerNames = current
        }
        r.meta.analysedAt = Date()
        library.update(r)
        await placeNext(r)
    }

    /// Moments read by an older reader, read again one at a time, quietly.
    func rereadOutdated(_ rs: [Recording]) async {
        for r in rs where r.meta.transcript != nil && !working.contains(r.id)
            && r.meta.insight?.readByModel == true && (r.meta.insight?.version ?? 1) < MomentInsight.readerVersion {
            await analyse(r, quiet: true)
        }
    }

    func analyseMissing(_ rs: [Recording]) async {
        for r in rs where r.meta.transcript != nil && !working.contains(r.id) { await analyse(r, quiet: true) }
    }

    /// Puts new actions in Reminders and new dates in Calendar, when those are on.
    func placeNext(_ r: Recording) async {
        guard var r = library.recordings.first(where: { $0.id == r.id }), var i = r.meta.insight, var items = i.next else { return }
        var changed = false
        for (idx, item) in items.enumerated() where !item.isDismissed {
            if item.isAction, item.reminderID == nil, Prefs.autoReminders,
               let id = try? await Planner.addReminder(item.text, due: item.date, note: "From \(r.sourceLabel), in Private Pocket.") {
                items[idx].reminderID = id
                changed = true
            }
            if item.isDate, item.eventID == nil, Prefs.autoCalendar, let d = item.date,
               let id = try? await Planner.addEvent(item.text, at: d, duration: item.duration, location: item.location, note: eventNote(r, item)) {
                items[idx].eventID = id
                changed = true
            }
        }
        if changed {
            i.next = items
            r.meta.insight = i
            library.update(r)
        }
    }

    /// Places one item by hand, whatever the settings.
    func place(_ r: Recording, _ item: NextItem) async {
        do {
            if item.isAction {
                let id = try await Planner.addReminder(item.text, due: item.date, note: "From \(r.sourceLabel), in Private Pocket.")
                change(r, item) { $0.reminderID = id }
            } else if item.isDate, let d = item.date {
                let id = try await Planner.addEvent(item.text, at: d, duration: item.duration, location: item.location, note: eventNote(r, item))
                change(r, item) { $0.eventID = id }
            }
        } catch {
            aiError = error.localizedDescription
        }
    }

    /// What the event or reminder says about where it came from.
    private func eventNote(_ r: Recording, _ item: NextItem) -> String {
        var lines = ["From \(r.sourceLabel), in Private Pocket."]
        if let q = item.quote { lines.append("“\(q)”") }
        if !r.people.isEmpty { lines.append("With " + r.people.joined(separator: ", ") + ".") }
        return lines.joined(separator: "\n")
    }

    /// Ticked here, done in Reminders too.
    func setDone(_ r: Recording, item: NextItem, done: Bool) {
        if let id = item.reminderID { Planner.setReminder(id, completed: done) }
        change(r, item) { $0.done = done; $0.doneAt = done ? Date() : nil }
    }

    /// "Not mine": gone from the list, and from Reminders or Calendar.
    func dismiss(_ r: Recording, item: NextItem) {
        if let id = item.reminderID { Planner.removeReminder(id) }
        if let id = item.eventID { Planner.removeEvent(id) }
        change(r, item) { $0.dismissed = true }
    }

    /// A reminder to chase a promise, on the day it was due, else tomorrow morning.
    func remindMe(_ r: Recording, item: NextItem) async {
        guard item.reminderID == nil else { return }
        let due = item.date ?? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date().addingTimeInterval(86_400)) ?? Date()
        let who = item.who ?? "them"
        do {
            let id = try await Planner.addReminder("Chase \(who): \(item.text)", due: due, note: "From \(r.sourceLabel), in Private Pocket.")
            change(r, item) { $0.reminderID = id }
        } catch {
            aiError = error.localizedDescription
        }
    }

    /// Reads completion back from Reminders, so a tick there shows here.
    /// A reminder that stands on its own, from Insights: settle something, call someone.
    func quickReminder(_ title: String, due: Date?, note: String) async -> Bool {
        do {
            _ = try await Planner.addReminder(title, due: due, note: note)
            return true
        } catch {
            aiError = error.localizedDescription
            return false
        }
    }

    func refreshDone(_ r: Recording) {
        guard let items = r.meta.insight?.next else { return }
        for item in items where item.isAction {
            if let id = item.reminderID, let c = Planner.reminderCompleted(id), c != item.isDone {
                change(r, item) { $0.done = c; $0.doneAt = c ? Date() : nil }
            }
        }
    }

    private func change(_ r: Recording, _ item: NextItem, _ edit: (inout NextItem) -> Void) {
        guard var r = library.recordings.first(where: { $0.id == r.id }), var i = r.meta.insight else { return }
        var items = i.items
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        edit(&items[idx])
        i.next = items
        r.meta.insight = i
        library.update(r)
    }

    /// The moment as a note to send: title, when, the brief, what's next.
    func notes(for r: Recording) -> String {
        var lines = [r.displayTitle,
                     [r.startedAt?.formatted(date: .abbreviated, time: .shortened), r.meta.place?.name].compactMap { $0 }.joined(separator: " · ")]
        if let b = r.meta.insight?.brief, !b.isEmpty {
            lines.append("")
            lines.append(b.map(\.text).joined(separator: " "))
        }
        let items = NextList.ordered(r.meta.insight?.items ?? []).filter { !$0.isDone }
        if !items.isEmpty {
            lines.append("")
            lines.append("Next:")
            for i in items { lines.append("• " + [i.text, i.when].compactMap { $0 }.joined(separator: ", ")) }
        }
        lines.append("")
        lines.append("From Private Pocket.")
        return lines.joined(separator: "\n")
    }

    private var sweptThisSession: Set<String> = []

    /// Every recording on this phone that was never transcribed, one at a time, quietly:
    /// nothing should need a tap to become a moment. Each is tried once per session.
    func transcribeWhatLanded() async {
        await ServerStatus.shared.check()
        await respreadSamples()
        for r in library.recordings where r.meta.transcript == nil && !working.contains(r.id) && !sweptThisSession.contains(r.id) {
            sweptThisSession.insert(r.id)
            await transcribe(r, quiet: true)
        }
        // Moments read by an older reader are read again, so Insights has what the new one finds.
        await rereadOutdated(library.recordings)
    }

    // MARK: - Starting over

    /// Every moment on this iPhone, with the reminders and calendar events made from
    /// them, the briefings and the Ask history. Pockets and settings stay.
    func clearMoments() {
        for r in library.recordings {
            for item in r.meta.insight?.next ?? [] {
                if let id = item.reminderID { Planner.removeReminder(id) }
                if let id = item.eventID { Planner.removeEvent(id) }
            }
        }
        library.deleteAll()
        conversations = [:]
        sweptThisSession = []
        UserDefaults.standard.removeObject(forKey: "briefings")
        let live = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Live", isDirectory: true)
        try? FileManager.default.removeItem(at: live)
        link.note("cleared every moment")
    }

    /// Everything: the moments, the Pockets and their keys, every setting and server key.
    /// The app is as it was when first installed, and the walkthrough shows again.
    func resetEverything() {
        clearMoments()
        link.disconnect()
        userDisconnected = false
        for d in devices.devices { devices.remove(d) }
        LLM.key = ""
        RemoteSTT.key = ""
        if let bundle = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: bundle) }
        activity.end()
        link.note("reset: everything cleared")
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
