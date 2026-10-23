import AVFoundation
import NaturalLanguage
import Combine
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
                .environmentObject(model.threads)
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
    /// Threads kept, and the people book.
    let threads = ThreadStore(root: Library.rootURL)
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
    /// A moment to open, from a link in Reminders or Calendar; Now picks it up.
    @Published var openMomentID: String?
    /// The reader in the room: what has been said so far, while it is still being said.
    @Published var liveItems: [NextItem] = []
    @Published var liveDecisions: [String] = []
    @Published var liveConfirmed: Set<String> = []
    @Published var liveDismissed: Set<String> = []
    private var liveReader: Task<Void, Never>?
    private var liveReadLength = 0
    /// Said to the card: "Pocket, …" in the live transcript, answered from the recordings.
    struct CardAnswer: Identifiable {
        let id = UUID()
        let question: String
        var answer: String
    }
    @Published var cardAnswers: [CardAnswer] = []
    private var cardSeen: Set<String> = []
    private var cardWatch: AnyCancellable?
    /// What the screen in front shows, so Record can be pressed into it.
    @Published var pageContext: RecordContext?
    /// What the recording now running was pressed into.
    @Published var recordingContext: RecordContext?
    /// A thread named in the room, with what was said last time.
    @Published var liveThread: ThreadHint?
    private var pendingContext: RecordContext?
    private var recordContexts: [String: RecordContext] = [:]
    /// Confirmations made in the room, carried into the moment once it is read.
    private var liveCarry: [String: (confirmed: [NextItem], dismissed: [String])] = [:]
    @Published var aiError: String?
    /// The notice offers Open Settings: a permission iOS will not ask for again.
    @Published var aiErrorOpensSettings = false
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
            if let ctx = self.pendingContext { self.recordContexts[name] = ctx; self.pendingContext = nil }
            self.recordingContext = self.recordContexts[name]
            self.liveThread = nil
            self.startActivity(name: name)
            self.startLiveReader()
            self.watchForCard()
            if self.recordingContext?.thread != nil { self.scanForThreads("") }
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
            guard let self, let d = self.connectedDevice else { self?.recordingContext = nil; self?.liveThread = nil; self?.endActivity(name: name); return }
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
    private var storeObserver: NSObjectProtocol?

    func setActive(_ active: Bool) {
        if storeObserver == nil {
            storeObserver = Planner.onChange { [weak self] in Task { @MainActor in self?.syncAllPlaced(after: 1) } }
        }
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
        let starting = link.status.recordingSince == nil
        if starting { pendingContext = pageContext }
        defer { if starting, link.status.recordingSince == nil { pendingContext = nil } }
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
        activity.lastSavedName = name
        activity.showStopped(savedSeconds: library.recordings.first { $0.name == name }?.meta.seconds,
                             keepPresence: Prefs.islandPresence && connectedDevice != nil)
    }

    /// After a stop: keep the streamed copy if it is the whole recording, else
    /// download the device's file (if downloading after stop is on).
    /// Every twenty-five seconds while it records, the reader reads the rolling transcript;
    /// new items keep their ids, so a tick in the room survives the next pass.
    func startLiveReader() {
        liveReader?.cancel()
        liveItems = []; liveDecisions = []; liveConfirmed = []; liveDismissed = []
        liveReadLength = 0
        liveReader = Task { [weak self] in
            while let self, !Task.isCancelled, self.link.status.recordingSince != nil {
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled, self.link.status.recordingSince != nil else { break }
                let text = self.live.text
                guard Prefs.liveTranscript, LLM.availability == nil, text.count >= self.liveReadLength + 160 else { continue }
                self.liveReadLength = text.count
                guard let read = try? await Analyst.liveRead(text: text, config: LLM.config) else { continue }
                var merged = self.liveItems
                for item in read.items {
                    let key = item.text.lowercased().trimmingCharacters(in: .punctuationCharacters)
                    if !merged.contains(where: { $0.text.lowercased().trimmingCharacters(in: .punctuationCharacters) == key }) { merged.append(item) }
                }
                self.liveItems = merged
                self.liveDecisions = read.decisions
            }
        }
    }

    /// "Pocket, remind me to ring the garage." "Pocket, what did Ravi say the date was?"
    /// The card is a microphone with a private model behind it: address it, and the answer
    /// lands on Now and the Lock Screen, phone still in the bag.
    private func watchForCard() {
        cardWatch?.cancel()
        cardWatch = live.$finalText
            .debounce(for: .seconds(1.5), scheduler: DispatchQueue.main)
            .sink { [weak self] text in self?.scanForCard(text); self?.scanForThreads(text) }
    }

    private func scanForCard(_ text: String) {
        guard let re = try? NSRegularExpression(pattern: #"\bpocket[,:]?\s+([^.?!]{4,140})[.?!]"#, options: .caseInsensitive) else { return }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let phrase = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let key = phrase.lowercased()
            guard !cardSeen.contains(key) else { continue }
            cardSeen.insert(key)
            Task { await self.answerCard(phrase) }
        }
    }

    private func answerCard(_ phrase: String) async {
        let lower = phrase.lowercased()
        var entry = CardAnswer(question: phrase, answer: "…")
        cardAnswers.append(entry)
        func finish(_ a: String) {
            entry.answer = a
            if let i = cardAnswers.firstIndex(where: { $0.id == entry.id }) { cardAnswers[i] = entry }
            Notify.now(title: "Pocket", body: a)
            link.note("card: \(phrase) → \(a.prefix(80))")
        }
        for lead in ["remind me to ", "remind me ", "add a to-do to ", "note to "] where lower.hasPrefix(lead) {
            let what = String(phrase.dropFirst(lead.count)).capitalizedFirst
            let due = Planner.date(in: what) ?? Findings.tomorrowMorning(Date())
            if await quickReminder(what, due: due, note: "Said to the card. From Private Pocket.") {
                finish("Done. " + (due.map { "\(Findings.dayName($0).capitalizedFirst) at \($0.formatted(date: .omitted, time: .shortened)), in Reminders." } ?? "In Reminders."))
            } else {
                finish("I couldn't add that to Reminders.")
            }
            return
        }
        let sources = library.recordings.filter { $0.meta.transcript != nil }
        guard !sources.isEmpty, LLM.availability == nil else { finish("Nothing to answer from yet."); return }
        await ask(phrase, scope: "card", recordings: sources)
        finish(conversations["card"]?.last?.answer ?? conversations["card"]?.last?.error ?? "I couldn't find that.")
    }

    /// A thread named in the room that has been quiet a while, or the one Record was
    /// pressed into: what was said last time, while it is still being talked about.
    func scanForThreads(_ text: String) {
        let live = threads.live(library.recordings)
        if let tid = recordingContext?.thread.flatMap({ threads.resolve($0)?.id }), let t = live.first(where: { $0.id == tid }) {
            if liveThread?.id != t.id { liveThread = hint(t) }
            return
        }
        guard liveThread == nil, !text.isEmpty else { return }
        let said = " " + Self.normalised(text) + " "
        let named = live.filter { t in
            t.daysSinceLast >= 14 && t.record.aliases.contains { a in a.count >= 4 && said.contains(" " + Self.normalised(a) + " ") }
        }
        if let t = named.max(by: { $0.daysSinceLast < $1.daysSinceLast }) { liveThread = hint(t) }
    }

    private func hint(_ t: LiveThread) -> ThreadHint {
        if let rc = t.recall(before: Date()) { return ThreadHint(id: t.id, name: t.name, last: rc.date, line: rc.line) }
        return ThreadHint(id: t.id, name: t.name, last: t.last, line: t.plainStory)
    }

    /// Lowercase letters and digits with single spaces between words, so a phrase can be found in speech.
    static func normalised(_ s: String) -> String {
        String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }).split(separator: " ").joined(separator: " ")
    }

    /// A moment just read: the threads it starts, and every thread it is in, read on with it.
    func readThreads(containing id: String) async {
        let all = library.recordings
        threads.discover(all)
        for t in threads.live(all) where t.moments.contains(where: { $0.id == id }) {
            await threads.catchUp(t)
        }
    }

    func confirmLive(_ item: NextItem) { liveConfirmed.insert(item.id); liveDismissed.remove(item.id) }
    func dismissLive(_ item: NextItem) { liveDismissed.insert(item.id); liveConfirmed.remove(item.id) }

    private func completeRecording(name: String, device d: DeviceConfig) async throws {
        liveReader?.cancel()
        recordingContext = nil
        liveThread = nil
        if !liveItems.isEmpty {
            liveCarry[name] = (liveItems.filter { liveConfirmed.contains($0.id) },
                               liveItems.filter { liveDismissed.contains($0.id) }.map { $0.text.lowercased() })
        }
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
        if let ctx = recordContexts.removeValue(forKey: name) {
            r.meta.context = ctx
            if let t = ctx.thread { threads.pin(r.id, to: t) }
        }
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
            if !quiet {
                aiError = Prefs.sttRemoteNow ? "Your server didn't answer, so this moment wasn't transcribed. It's tried again on the next launch."
                                             : "This moment couldn't be transcribed on your iPhone. It's tried again on the next launch."
            }
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
            aiError = Prefs.llmRemoteNow ? "Your server didn't answer, so there's no summary yet. Try again in a moment."
                                         : "The summary didn't come through on your iPhone. Try again in a moment."
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
        // The calendar event it happened in, if Calendar is allowed: the reader is told who was invited.
        if r.meta.calendarChecked == nil, r.meta.sampleID == nil, Briefs.calendarAllowed, let start = r.startedAt {
            r.meta.event = Briefs.event(during: start, seconds: r.meta.seconds ?? 0)
            r.meta.calendarChecked = Date()
        }
        defer {   // the Lock Screen gets the first sentence, if this is the moment it just showed as Saved
            if activity.lastSavedName == r.name, let first = r.meta.insight?.brief?.first?.text, r.meta.insight?.readByModel == true {
                activity.showRead("\(r.kind.label) · \(first)")
            }
        }
        if LLM.availability == nil {
            do {
                r.meta.insight = try await Analyst.analyse(r, config: LLM.config)
            } catch {
                if !quiet {
                    aiError = Prefs.llmRemoteNow ? "Your server didn't answer, so this moment hasn't been read yet. It's tried again when Insights opens."
                                                 : "This moment couldn't be read on your iPhone yet. It's tried again when Insights opens."
                }
                if r.meta.insight == nil { r.meta.insight = Analyst.heuristic(r) }
            }
        } else if r.meta.insight == nil {
            r.meta.insight = Analyst.heuristic(r)
        }
        if let carry = liveCarry.removeValue(forKey: r.name), var i = r.meta.insight {
            // What was confirmed in the room stays; what was waved away goes.
            var items = i.items
            for c in carry.confirmed where !items.contains(where: { $0.text.lowercased() == c.text.lowercased() }) {
                var kept = c
                kept.sure = true
                items.append(kept)
            }
            for idx in items.indices where carry.dismissed.contains(items[idx].text.lowercased()) { items[idx].dismissed = true }
            i.next = items
            r.meta.insight = i
        }
        if let names = r.meta.insight?.inferredSpeakers, !names.isEmpty {
            var current = r.meta.speakerNames ?? [:]
            for (k, v) in names where (current[k] ?? "").isEmpty { current[k] = v }
            r.meta.speakerNames = current
        }
        r.meta.analysedAt = Date()
        library.update(r)
        let read = r.id
        threads.enqueue { [weak self] in await self?.readThreads(containing: read) }
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
        for (idx, item) in items.enumerated() where !item.isDismissed && item.unplaced != true {
            do {
                if item.isAction, item.reminderID == nil, Prefs.autoReminders, item.isSolid {
                    items[idx].reminderID = try await Planner.addReminder(item.text, due: item.date, note: "From \(r.sourceLabel), in Private Pocket.", link: Planner.momentURL(r))
                    changed = true
                }
                if item.isDate, item.eventID == nil, Prefs.autoCalendar, item.isSolid, let d = item.date {
                    items[idx].eventID = try await Planner.addEvent(item.text, at: d, duration: item.duration, location: item.location, note: eventNote(r, item), link: Planner.momentURL(r))
                    changed = true
                }
            } catch {
                report(error)   // once: a refused permission would refuse every item
                break
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
                let id = try await Planner.addReminder(item.text, due: item.date, note: "From \(r.sourceLabel), in Private Pocket.", link: Planner.momentURL(r))
                change(r, item) { $0.reminderID = id; $0.unplaced = nil }
            } else if item.isDate, let d = item.date {
                let id = try await Planner.addEvent(item.text, at: d, duration: item.duration, location: item.location, note: eventNote(r, item), link: Planner.momentURL(r))
                change(r, item) { $0.eventID = id; $0.unplaced = nil }
            }
        } catch {
            report(error)
        }
    }

    /// What to say when Reminders or Calendar refused, in plain words. iOS asks for a
    /// permission once; after a Don't Allow it never asks again, so the notice carries
    /// an Open Settings button instead (`aiErrorOpensSettings`).
    static func placingFailed(_ error: Error) -> String {
        let d = error.localizedDescription
        if d.localizedCaseInsensitiveContains("reminder") { return "Private Pocket isn't allowed to use Reminders yet. Open Settings, switch Reminders on, and try again." }
        if d.localizedCaseInsensitiveContains("calendar") { return "Private Pocket isn't allowed to use Calendar yet. Open Settings, switch Calendars on, and try again." }
        return "That didn't go in. Try again in a moment."
    }

    /// A notice for a failed placing; a refused permission gets the Open Settings button.
    func report(_ error: Error) {
        aiError = Self.placingFailed(error)
        if case PlannerError.denied = error { aiErrorOpensSettings = true } else { aiErrorOpensSettings = false }
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

    /// A line of the transcript made into a to-do by hand, anchored to where it was said.
    func addItem(_ r: Recording, text: String, at: Double?, quote: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, var r = library.recordings.first(where: { $0.id == r.id }) else { return }
        var i = r.meta.insight ?? Analyst.heuristic(r)
        var items = i.items
        items.append(NextItem(kind: "action", text: t, at: at, quote: quote, sure: true))
        i.next = items
        r.meta.insight = i
        library.update(r)
    }

    /// A corrected wording, here and in Reminders if it is there already.
    func editItem(_ r: Recording, item: NextItem, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != item.text else { return }
        if let id = item.reminderID { Planner.renameReminder(id, to: t) }
        if let id = item.eventID { Planner.renameEvent(id, to: t) }
        change(r, item) { $0.text = t }
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
            let id = try await Planner.addReminder("Chase \(who): \(item.text)", due: due, note: "From \(r.sourceLabel), in Private Pocket.", link: Planner.momentURL(r))
            change(r, item) { $0.reminderID = id }
        } catch {
            report(error)
        }
    }

    /// Reads completion back from Reminders, so a tick there shows here.
    /// A reminder that stands on its own, from Insights: settle something, call someone.
    func quickReminder(_ title: String, due: Date?, note: String) async -> Bool {
        do {
            _ = try await Planner.addReminder(title, due: due, note: note)
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Two-way sync for everything this moment placed: a tick, a new wording, a moved
    /// date or a removal made in Reminders or Calendar comes back here, and an older
    /// item is given its link.
    func syncPlaced(_ r: Recording) async {
        guard let items = r.meta.insight?.next else { return }
        await Planner.warm()
        let link = Planner.momentURL(r)
        for item in items where !item.isDismissed {
            if let id = item.reminderID {
                switch Planner.lookup(id) {
                case .missing:
                    change(r, item) { $0.reminderID = nil; $0.unplaced = true }
                case .found(let p):
                    await Planner.ensureLink(id, link)
                    change(r, item) { Self.take(p, into: &$0) }
                }
            }
            if let id = item.eventID {
                switch Planner.lookup(id) {
                case .missing:
                    change(r, item) { $0.eventID = nil; $0.unplaced = true }
                case .found(let p):
                    await Planner.ensureLink(id, link)
                    change(r, item) { Self.take(p, into: &$0) }
                }
            }
        }
    }

    /// What Reminders or Calendar now says, onto the item; only fields that differ.
    private static func take(_ p: Planner.Placed, into item: inout NextItem) {
        let title = p.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, title != item.text, !title.hasPrefix("Chase ") { item.text = title }
        if let c = p.completed, c != item.isDone { item.done = c; item.doneAt = c ? Date() : nil }
        if let d = p.date, abs(d.timeIntervalSince(item.date ?? .distantPast)) > 60 { item.date = d }
        if let l = p.location, !l.isEmpty, l != item.location { item.location = l }
        if let dur = p.duration, item.isDate, dur != item.duration { item.duration = dur }
    }

    private var placedSync: Task<Void, Never>?

    /// Every moment with something placed, a moment after Reminders or Calendar change
    /// (several notices arrive together), and on every return to the foreground.
    func syncAllPlaced(after delay: Double = 0) {
        placedSync?.cancel()
        placedSync = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, !Task.isCancelled else { return }
            for r in library.recordings where r.meta.insight?.next?.contains(where: { $0.reminderID != nil || $0.eventID != nil }) == true {
                await syncPlaced(r)
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
        threads.discover(library.recordings)
        await ServerStatus.shared.check()
        await respreadSamples()
        for r in library.recordings where r.meta.transcript == nil && !working.contains(r.id) && !sweptThisSession.contains(r.id) {
            sweptThisSession.insert(r.id)
            await transcribe(r, quiet: true)
        }
        // Moments read by an older reader are read again, so Insights has what the new one finds.
        await rereadOutdated(library.recordings)
        syncAllPlaced()
        Briefs.schedule(library.recordings)
        // Moments from before Calendar was allowed: the event each happened in, read again where there was one.
        if Briefs.calendarAllowed {
            var again = 0
            for r in library.recordings where r.meta.calendarChecked == nil && r.meta.sampleID == nil && r.meta.transcript != nil && !working.contains(r.id) {
                guard let start = r.startedAt else { continue }
                var r = r
                r.meta.event = Briefs.event(during: start, seconds: r.meta.seconds ?? 0)
                r.meta.calendarChecked = Date()
                library.update(r)
                if r.meta.event != nil, again < 10, LLM.availability == nil {
                    again += 1
                    await analyse(r, quiet: true)
                }
            }
        }
        // Threads: new ones found, and the live ones with moments not yet read into them, read on.
        threads.discover(library.recordings)
        for t in threads.live(library.recordings).filter({ $0.isLive && !$0.unread.isEmpty }).sorted(by: { $0.weight > $1.weight }).prefix(6) {
            let tid = t.id
            threads.enqueue { [weak self] in
                guard let self, let fresh = self.threads.live(self.library.recordings).first(where: { $0.id == tid }) else { return }
                await self.threads.catchUp(fresh)
            }
        }
    }

    /// Everything under Recordings as one zip, for the share sheet: a copy to keep
    /// somewhere else, or to move to another phone.
    func exportAll() async throws -> URL {
        let root = library.root
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("Private Pocket moments.zip")
        try? FileManager.default.removeItem(at: out)
        return try await Task.detached(priority: .userInitiated) {
            var copyError: Error?
            var coordError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: root, options: .forUploading, error: &coordError) { url in
                do { try FileManager.default.copyItem(at: url, to: out) } catch { copyError = error }
            }
            if let e = coordError ?? copyError { throw e }
            return out
        }.value
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
        threads.clear()
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
