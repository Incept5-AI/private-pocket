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
    /// The recording takeover is on screen (`RecordingTakeover`): raised when a recording
    /// starts or the app opens during one, lowered by Hide or a moment after the stop.
    @Published var takeover = false
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
            // A recording still open here whose stop never came (stopped while the phone was
            // away): it is finished now, before the new one takes the room, not thrown away.
            if let old = self.live.name, old != name { self.recordingStopped(old, heard: false) }
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
            settleActivity()
            Task { await self.autoSync() }
        }
        link.onPaired = { [weak self] d in
            guard let self else { return }
            devices.update(d)   // the key lives in the Keychain; this refreshes the views
            refreshPresence()
            Task { await self.autoSync(d) }
        }
        link.onRecordingStopped = { [weak self] name, heard in self?.recordingStopped(name, heard: heard) }
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
                           hoursFree: link.status.freeMiB.map { PocketFacts.hours(mib: $0) }, paired: canCommand)
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
        settleActivity()
        await autoSync(d)
    }

    /// The Dynamic Island left showing a recording by an earlier run of the app is put right
    /// once the Pocket is connected and plainly not recording: no start, and no audio.
    private func settleActivity() {
        guard activity.isRecording, link.status.recordingSince == nil else { return }
        let since = Date()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.link.isReady, self.link.status.recordingSince == nil, self.link.lastLiveAudioAt < since else { return }
            self.activity.clearRecording()
            self.refreshPresence()
        }
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

    /// A sync is running: one at a time, so two never share the download channel.
    private var syncing = false
    /// Partial copies checked against the Pocket's file this session.
    private var recheckedPartial: Set<String> = []

    /// Fetch every recording on the device that is not on the phone yet, and was not deleted here.
    func sync(quiet: Bool = false) async {
        guard let d = devices.selected else { return }
        guard d.isPaired, !link.keyRejected else {
            if !quiet { link.lastError = "Pair the Pocket to fetch recordings from it." }
            return
        }
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        await link.run("Fetching", quiet: quiet) {
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
                    if fetched.data.count > local, let r = library.replaceAudio(here.id, with: fetched.data, seconds: f.seconds, partial: !fetched.whole) {
                        link.note("replaced the partial copy of \(f.name) with the Pocket's file")
                        if d.autoTranscribe { enqueueTranscription(r) }
                    } else if fetched.whole, fetched.data.count == local {
                        library.mutate(here.id) { $0.partial = nil }   // the same file: it was whole after all
                    }
                    continue
                }
                let place = await locator.place(for: f.name, seconds: f.seconds)
                var r = try library.save(device: d.id, day: f.day, name: f.name, audio: fetched.data, seconds: f.seconds, place: place,
                                         pocket: pocketID(d))
                if !fetched.whole, let marked = library.mutate(r.id, { $0.partial = true }) { r = marked }
                if d.autoTranscribe { enqueueTranscription(r) }
            }
            try await link.refreshStatus()
        }
    }

    private var transcriptions: Task<Void, Never>?

    /// Transcriptions one after another, as the launch sweep does: a first sync of thirty
    /// recordings is thirty in a row, not thirty uploads at once.
    func enqueueTranscription(_ r: Recording) {
        let previous = transcriptions
        let id = r.id
        transcriptions = Task { [weak self] in
            await previous?.value
            guard let self, let now = self.library.recordings.first(where: { $0.id == id }) else { return }
            await self.transcribe(now)
        }
    }

    /// Record or Stop is being sent: the buttons wait, so a second tap is not a second command.
    @Published private(set) var toggling = false
    /// Recordings being saved after their stop: the takeover says Saving… until they are done.
    @Published private(set) var saving: Set<String> = []

    func toggleRecording() async {
        guard let d = devices.selected, canCommand, !toggling else { return }
        toggling = true
        defer { toggling = false }
        let starting = link.status.recordingSince == nil
        if starting { pendingContext = pageContext }
        defer { if starting, link.status.recordingSince == nil { pendingContext = nil } }
        var stopped: String?
        await link.run(starting ? "Starting" : "Stopping") {
            try await link.connect(d)
            if starting {
                guard link.status.recordingSince == nil else { return }   // the card's button got there first
                try await link.startRecording()
            } else if let name = try await link.stopRecording() {
                stopped = name
            }
        }
        if let name = stopped {
            wrapUp(name)
            await saveStopped(name, device: d, inferred: false)
        } else if starting ? link.status.recordingSince == nil : link.status.recordingSince != nil {
            // Said where the person is looking, not only on the Pocket's own screen.
            aiError = starting ? "Your Pocket didn't start recording. Check it's on and nearby, then try again."
                               : "Your Pocket didn't stop. Press its side button to stop it."
        }
    }

    /// A recording stopped by the card's button, or found stopped (`heard` false): what the
    /// room gathered is taken at once, then the recording is saved in the background.
    private func recordingStopped(_ name: String, heard: Bool) {
        wrapUp(name)
        guard let d = connectedDevice ?? devices.selected else { endActivity(name: name); return }
        Task { await saveStopped(name, device: d, inferred: !heard) }
    }

    /// Streams detached at a stop, waiting for their save: whichever path saves a recording
    /// takes its stream, and a second path finds it taken.
    private var stoppedStreams: [String: LiveSession.Ending] = [:]

    /// What a recording gathered while it ran, taken the moment it stops: the reader's
    /// catches, the thread it was for, and its stream, detached so a new recording can start.
    private func wrapUp(_ name: String) {
        liveReader?.cancel()
        recordingContext = nil
        liveThread = nil
        if !liveItems.isEmpty {
            liveCarry[name] = (liveItems.filter { liveConfirmed.contains($0.id) },
                               liveItems.filter { liveDismissed.contains($0.id) }.map { $0.text.lowercased() })
        }
        if let e = live.detach(name: name) { stoppedStreams[name] = e }
    }

    private func saveStopped(_ name: String, device d: DeviceConfig, inferred: Bool) async {
        guard !saving.contains(name) else { return }   // already being saved, by the other path
        let ending = stoppedStreams.removeValue(forKey: name)
        if link.status.recordingSince == nil { activity.showSaving() }
        saving.insert(name)
        await link.run("Saving") { try await self.completeRecording(name: name, device: d, ending: ending, inferred: inferred) }
        saving.remove(name)
        endActivity(name: name)
        fetchSoonIfMissing(name, device: d)
    }

    /// A recording whose save failed (the link dropped as it stopped, say) is fetched by the
    /// next sync; this makes that happen soon, not at the next connection.
    private func fetchSoonIfMissing(_ name: String, device d: DeviceConfig) {
        guard d.isPaired, !name.hasPrefix("PH"), let date = PocketTime.parse(name) else { return }
        let day = PocketTime.day.string(from: date)
        guard !library.has(device: d.id, day: day, name: name) else { return }
        Task { [weak self] in
            for wait in [20.0, 120.0] {
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !self.library.has(device: d.id, day: day, name: name) else { return }
                await self.autoSync(d)
            }
        }
    }

    // MARK: - Live Activity

    private func startActivity(name: String) {
        guard let d = connectedDevice else { return }
        activity.showRecording(device: d, startedAt: PocketTime.parse(name) ?? Date(), paired: canCommand, context: recordingContext?.label)
        activityTicker?.cancel()
        activityTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                let streaming = self.live.isActive && !self.live.levels.stalled
                self.activity.updateRecording(line: String(self.live.text.suffix(140)), streaming: self.live.isActive,
                                              gap: self.live.gap, paired: self.canCommand,
                                              levels: streaming ? self.live.levels.bars(30, seconds: 7.5) : nil,
                                              context: self.recordingContext?.label, caught: self.caughtLine,
                                              recall: self.liveThread.map { h in h.name + (h.last.map { " · last spoken \(Findings.dayName($0))" } ?? "") })
            }
        }
    }

    /// What the reader has caught in the room so far, for the Dynamic Island.
    private var caughtLine: String? {
        let items = liveItems.filter { !liveDismissed.contains($0.id) }
        guard !items.isEmpty else { return nil }
        var parts: [String] = []
        let todo = items.filter(\.isAction).count, dates = items.filter(\.isDate).count, promises = items.filter(\.isPromise).count
        if todo > 0 { parts.append("\(todo) to-do\(todo == 1 ? "" : "s")") }
        if dates > 0 { parts.append("\(dates) date\(dates == 1 ? "" : "s")") }
        if promises > 0 { parts.append("\(promises) promise\(promises == 1 ? "" : "s")") }
        return parts.joined(separator: " · ") + " caught"
    }

    /// Shows the saved length for a moment, then the Pocket's light and battery again.
    private func endActivity(name: String) {
        // A newer recording has the Dynamic Island now: it keeps it.
        if let current = link.status.recordingName, current != name { return }
        activityTicker?.cancel()
        activityTicker = nil
        activity.lastSavedName = name
        activity.showStopped(savedSeconds: library.recordings.first { $0.name == name }?.meta.seconds,
                             keepPresence: Prefs.islandPresence && connectedDevice != nil)
    }

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
        cardSeen = []   // a phrase said in an earlier recording is heard again in this one
        cardWatch = live.$finalText
            .debounce(for: .seconds(1.5), scheduler: DispatchQueue.main)
            .sink { [weak self] text in self?.scanForCard(text); self?.scanForThreads(text) }
    }

    private func scanForCard(_ text: String) {
        // "Pocket," at the start of a sentence, addressed: not "it's in my pocket and left."
        guard let re = try? NSRegularExpression(pattern: #"(?:^|[.?!]\s+)pocket[,:]\s+([^.?!]{4,140})[.?!]"#, options: .caseInsensitive) else { return }
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
        let qa = conversations["card"]?.last { $0.question == phrase }   // its own answer, if two overlap
        finish(qa?.answer ?? qa?.error ?? "I couldn't find that.")
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

    /// A calendar switched back on in Settings: moments that found no event look again on the
    /// next sweep, and those that find one are read again.
    func calendarSwitchedOn() {
        for r in library.recordings where r.meta.event == nil && r.meta.calendarChecked != nil && r.meta.sampleID == nil {
            var r = r
            r.meta.calendarChecked = nil
            library.update(r)
        }
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

    /// After a stop: keep the streamed copy if it is the whole recording, else download the
    /// Pocket's file. `inferred`: the stop was worked out, not heard (see PocketLink), so what
    /// is kept is marked partial, for a sync to check against the Pocket's own file.
    private func completeRecording(name: String, device d: DeviceConfig, ending: LiveSession.Ending?, inferred: Bool) async throws {
        let streamed = await ending?.finish()
        guard let date = PocketTime.parse(name) else { return }
        let day = PocketTime.day.string(from: date)
        guard !library.has(device: d.id, day: day, name: name) else { return }

        let audio: Data
        var remote: RemoteFile
        var partial = inferred
        if !d.isPaired || link.keyRejected {
            // Not paired: the Pocket answers no commands, so the stream is all there is.
            guard let s = streamed, !s.audio.isEmpty else { return }
            audio = s.audio
            remote = RemoteFile(day: day, name: name, seconds: Int((Self.duration(of: s.audio) ?? 0).rounded()))
            if !s.complete { partial = true }
            link.note(s.complete ? "kept the streamed copy of \(name): \(s.audio.count) bytes"
                                 : "stream had a gap; kept \(s.audio.count) bytes of \(name). Pair to download the Pocket's file")
        } else {
            // The Pocket lists a recording once it has closed the file; a call recording (PH…) never.
            let call = name.hasPrefix("PH")
            var listed: RemoteFile?
            var listError: Error?
            for round in 0..<(call ? 1 : 3) where listed == nil {
                try? await Task.sleep(for: .milliseconds(round == 0 ? 500 : 1_500))
                do { listed = try await link.listFiles().first { $0.name == name } } catch { listError = error; break }
            }
            remote = listed ?? RemoteFile(day: day, name: name, seconds: 0)
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
                    // The fetch failed (a new recording took the channel, say): the stream, if any,
                    // is kept for now, and a sync replaces it with the Pocket's file.
                    guard let s = streamed, !s.audio.isEmpty else { throw error }
                    audio = s.audio
                    partial = true
                    link.note("fetching \(name) failed; kept the streamed \(s.audio.count) bytes for now")
                }
            } else if let listError {
                throw listError
            } else {
                return
            }
        }
        guard !audio.isEmpty else { return }
        let place = await locator.place(for: name, seconds: remote.seconds)
        var r = try library.save(device: d.id, day: remote.day, name: name, audio: audio, seconds: remote.seconds, place: place,
                                 pocket: pocketID(d))
        r.meta.mode = name.hasPrefix("PH") ? "CALL" : link.status.mode
        if partial { r.meta.partial = true }
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
                enqueueTranscription(rec)
            } else if Prefs.diarize, !s.words.isEmpty {
                Task {
                    await findSpeakers(rec)   // the whole recording, so ids hold throughout
                    await analyse(library.recordings.first { $0.id == rec.id } ?? rec, quiet: true)
                }
            } else {
                Task { await analyse(rec, quiet: true) }
            }
        } else if d.autoTranscribe {
            enqueueTranscription(r)
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
        guard let r = library.recordings.first(where: { $0.id == r.id }) else { return }   // the moment as it is now
        working.insert(r.id)
        defer { working.remove(r.id) }
        let id = localeID ?? r.meta.locale ?? Prefs.transcriptionLocale
        // Who spoke when runs alongside the words; it only needs the audio.
        let url = r.audioURL
        let speakers: Task<[SpeakerSegment], Error>? = Prefs.diarize
            ? Task { try await Diarizer.diarize(try Data(contentsOf: url), filename: url.lastPathComponent) } : nil
        do {
            let t = try await Transcriber.transcribe(url, localeID: id)
            let segments = await speakers?.result
            // Only what transcription owns is written, onto the moment as it is now.
            guard let saved = library.mutate(r.id, { m in
                m.transcript = t.text
                m.words = t.words.isEmpty ? nil : t.words
                // With auto-detect, record the language that came back so summaries match it.
                m.locale = id == Languages.auto ? NLLanguageRecognizer.dominantLanguage(for: t.text)?.rawValue : id
                m.liveTranscript = nil
                m.transcribedAt = Date()
                m.turns = nil
                m.speakersError = nil
                if let segments { Self.applySpeakers(segments, to: &m) }
            }) else { return }   // deleted meanwhile
            Task { await self.analyse(saved, quiet: true) }
        } catch {
            speakers?.cancel()
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
        await ServerStatus.shared.check()
        guard let transcript = r.transcriptForModel else { return }
        working.insert(r.id)
        defer { working.remove(r.id) }
        do {
            let summary = try await Summariser.summarise(transcript, instructions: Prefs.summaryInstructions, localeID: r.meta.locale)
            library.mutate(r.id) { $0.summary = summary; $0.summarisedAt = Date() }
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
        guard var r = library.recordings.first(where: { $0.id == r.id }) else { return }   // the moment as it is now
        working.insert(r.id)
        defer { working.remove(r.id) }
        // The calendar event it happened in, if Calendar is allowed: the reader is told who was invited.
        if let e = r.meta.event, !e.isReadable { r.meta.event = nil }   // its calendar has been switched off
        if r.meta.calendarChecked == nil, r.meta.sampleID == nil, Briefs.calendarAllowed, let start = r.startedAt {
            r.meta.event = Briefs.event(during: start, seconds: r.meta.seconds ?? 0)
            r.meta.calendarChecked = Date()
        }
        var reading: MomentInsight?
        if LLM.availability == nil {
            do {
                reading = try await Analyst.analyse(r, config: LLM.config)
            } catch {
                if !quiet {
                    aiError = Prefs.llmRemoteNow ? "Your server didn't answer, so this moment hasn't been read yet. It's read again the next time the app opens."
                                                 : "This moment couldn't be read on your iPhone yet. It's read again the next time the app opens."
                }
            }
        }
        let fallback = Analyst.heuristic(r)
        let event = r.meta.event, checked = r.meta.calendarChecked
        let carry = liveCarry.removeValue(forKey: r.name)
        // Only what reading owns is written, onto the moment as it is now: a rename, a speaker
        // named or a tick made while the model read is kept.
        guard let saved = library.mutate(r.id, { m in
            m.event = event
            m.calendarChecked = checked
            var insight: MomentInsight
            if let reading {
                insight = Self.carryOver(from: m.insight, into: reading)
            } else {
                insight = m.insight ?? fallback
            }
            if let carry {
                // What was confirmed in the room stays; what was waved away goes.
                var items = insight.items
                for c in carry.confirmed where !items.contains(where: { $0.text.lowercased() == c.text.lowercased() }) {
                    var kept = c
                    kept.sure = true
                    kept.byHand = true
                    items.append(kept)
                }
                for idx in items.indices where carry.dismissed.contains(items[idx].text.lowercased()) { items[idx].dismissed = true }
                insight.next = items
            }
            if let names = insight.inferredSpeakers, !names.isEmpty {
                var current = m.speakerNames ?? [:]
                for (k, v) in names where (current[k] ?? "").isEmpty { current[k] = v }
                m.speakerNames = current
            }
            m.insight = insight
            m.analysedAt = Date()
        }) else { return }   // deleted meanwhile
        // The Lock Screen gets the first sentence, if this is the moment it just showed as Saved.
        if activity.lastSavedName == saved.name, let first = saved.meta.insight?.brief?.first?.text, saved.meta.insight?.readByModel == true {
            activity.showRead("\(saved.kind.label) · \(first)")
        }
        let read = saved.id
        threads.enqueue { [weak self] in await self?.readThreads(containing: read) }
        await placeNext(saved)
    }

    /// A new reading keeps what was done with the last one. An item read again keeps its id,
    /// its reminder or event, its tick, its Not mine and, once placed or added by hand, its
    /// wording, so nothing is placed twice and nothing done is undone; placed, ticked or
    /// dismissed items the new reading did not find, and items added by hand, stay as they were.
    static func carryOver(from old: MomentInsight?, into new: MomentInsight) -> MomentInsight {
        guard let old else { return new }
        func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        var fresh = new.items
        let before = old.items
        var used = Set<String>()
        for idx in fresh.indices {
            let n = fresh[idx]
            guard let o = before.first(where: { o in
                !used.contains(o.id) && o.kind == n.kind
                    && (key(o.text) == key(n.text) || (o.quote != nil && o.quote == n.quote) || Ageing.similar(o.text, n.text))
            }) else { continue }
            used.insert(o.id)
            fresh[idx].id = o.id
            fresh[idx].reminderID = o.reminderID
            fresh[idx].eventID = o.eventID
            fresh[idx].done = o.done
            fresh[idx].doneAt = o.doneAt
            fresh[idx].dismissed = o.dismissed
            fresh[idx].unplaced = o.unplaced
            fresh[idx].byHand = o.byHand
            if o.reminderID != nil || o.eventID != nil || o.byHand == true { fresh[idx].text = o.text }
        }
        for o in before where !used.contains(o.id)
            && (o.reminderID != nil || o.eventID != nil || o.isDone || o.isDismissed || o.byHand == true) {
            fresh.append(o)
        }
        var out = new
        out.next = fresh
        out.actions = fresh.filter(\.isAction).map(\.text)
        out.promises = fresh.filter(\.isPromise).map(\.text)
        return out
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

    /// Items on their way into Reminders or Calendar now, so no two paths place one twice.
    private var placing: Set<String> = []

    /// Puts new actions in Reminders and new dates in Calendar, when those are on.
    func placeNext(_ r: Recording) async {
        guard Prefs.autoReminders || Prefs.autoCalendar,
              let items = library.recordings.first(where: { $0.id == r.id })?.meta.insight?.next else { return }
        for item in items where item.isSolid && !item.isDismissed && item.unplaced != true {
            let wanted = (item.isAction && Prefs.autoReminders && item.reminderID == nil)
                || (item.isDate && Prefs.autoCalendar && item.eventID == nil && item.date != nil)
            guard wanted else { continue }
            do {
                try await placeItem(r.id, item.id)
            } catch {
                report(error)   // once: a refused permission would refuse every item
                break
            }
        }
    }

    /// Places one item, read again first, unless it is there already or on its way.
    private func placeItem(_ rid: String, _ iid: String) async throws {
        guard !placing.contains(iid), let rec = library.recordings.first(where: { $0.id == rid }),
              let now = rec.meta.insight?.items.first(where: { $0.id == iid }), !now.isDismissed else { return }
        placing.insert(iid)
        defer { placing.remove(iid) }
        if now.isAction, now.reminderID == nil {
            let id = try await Planner.addReminder(now.text, due: now.date, note: "From \(rec.sourceLabel), in Private Pocket.", link: Planner.momentURL(rec))
            setItem(rid, iid) { $0.reminderID = id; $0.unplaced = nil }
        } else if now.isDate, now.eventID == nil, let d = now.date {
            let id = try await Planner.addEvent(now.text, at: d, duration: now.duration, location: now.location, note: eventNote(rec, now), link: Planner.momentURL(rec))
            setItem(rid, iid) { $0.eventID = id; $0.unplaced = nil }
        }
    }

    /// Places one item by hand, whatever the settings. True when it went in.
    @discardableResult
    func place(_ r: Recording, _ item: NextItem) async -> Bool {
        do {
            try await placeItem(r.id, item.id)
            let now = library.recordings.first(where: { $0.id == r.id })?.meta.insight?.items.first(where: { $0.id == item.id })
            return now?.reminderID != nil || now?.eventID != nil
        } catch {
            report(error)
            return false
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
        guard !t.isEmpty, let now = library.recordings.first(where: { $0.id == r.id }) else { return }
        let fallback = Analyst.heuristic(now)
        library.mutate(r.id) { m in
            var i = m.insight ?? fallback
            var items = i.items
            items.append(NextItem(kind: "action", text: t, at: at, quote: quote, sure: true, byHand: true))
            i.next = items
            m.insight = i
        }
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
    @discardableResult
    func remindMe(_ r: Recording, item: NextItem) async -> Bool {
        let now = library.recordings.first(where: { $0.id == r.id })?.meta.insight?.items.first(where: { $0.id == item.id }) ?? item
        guard now.reminderID == nil, !placing.contains(item.id) else { return now.reminderID != nil }
        placing.insert(item.id)
        defer { placing.remove(item.id) }
        let due = now.date ?? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date().addingTimeInterval(86_400)) ?? Date()
        let who = now.who ?? "them"
        do {
            let id = try await Planner.addReminder("Chase \(who): \(now.text)", due: due, note: "From \(r.sourceLabel), in Private Pocket.", link: Planner.momentURL(r))
            setItem(r.id, item.id) { $0.reminderID = id }
            return true
        } catch {
            report(error)
            return false
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
            // Only what can be read is synced: with access off, nothing looks removed.
            if let id = item.reminderID, Planner.canRead(.reminder) {
                switch Planner.lookup(id) {
                case .missing:
                    change(r, item) { $0.reminderID = nil; $0.unplaced = true }
                case .found(let p):
                    await Planner.ensureLink(id, link)
                    change(r, item) { Self.take(p, into: &$0) }
                case .unknown:
                    break
                }
            }
            if let id = item.eventID, Planner.canRead(.event) {
                switch Planner.lookup(id) {
                case .missing:
                    change(r, item) { $0.eventID = nil; $0.unplaced = true }
                case .found(let p):
                    await Planner.ensureLink(id, link)
                    change(r, item) { Self.take(p, into: &$0) }
                case .unknown:
                    break
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
        setItem(r.id, item.id, edit)
    }

    /// One item of a moment, changed on the moment as it is now; nothing written if nothing changed.
    private func setItem(_ rid: String, _ iid: String, _ edit: (inout NextItem) -> Void) {
        library.mutate(rid) { m in
            guard var i = m.insight else { return }
            var items = i.items
            guard let idx = items.firstIndex(where: { $0.id == iid }) else { return }
            edit(&items[idx])
            i.next = items
            m.insight = i
        }
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
    /// Moments whose failed reading was tried again this session.
    private var readThisSession: Set<String> = []

    /// Every recording on this phone that was never transcribed, one at a time, quietly:
    /// nothing should need a tap to become a moment. Each is tried once per session.
    func transcribeWhatLanded() async {
        MomentShare.sweep()
        threads.discover(library.recordings)
        await ServerStatus.shared.check()
        await respreadSamples()
        for r in library.recordings where r.meta.transcript == nil && !working.contains(r.id) && !sweptThisSession.contains(r.id) {
            sweptThisSession.insert(r.id)
            await transcribe(r, quiet: true)
        }
        // Moments read by an older reader are read again, so Insights has what the new one finds.
        await rereadOutdated(library.recordings)
        // Moments whose reading failed (the server away, the model busy) are read again, once a session.
        if LLM.availability == nil {
            for r in library.recordings where r.meta.transcript != nil && r.meta.insight?.readByModel != true
                && !working.contains(r.id) && !readThisSession.contains(r.id) {
                readThisSession.insert(r.id)
                await analyse(r, quiet: true)
            }
        }
        syncAllPlaced()
        Briefs.schedule(library.recordings)
        // Moments from before Calendar was allowed: the event each happened in, read again where there was one.
        if Briefs.calendarAllowed {
            var again = 0
            for r in library.recordings where r.meta.calendarChecked == nil && r.meta.sampleID == nil && r.meta.transcript != nil && !working.contains(r.id) {
                guard let start = r.startedAt else { continue }
                let event = Briefs.event(during: start, seconds: r.meta.seconds ?? 0)
                guard let saved = library.mutate(r.id, { $0.event = event; $0.calendarChecked = Date() }) else { continue }
                if event != nil, again < 10, LLM.availability == nil {
                    again += 1
                    await analyse(saved, quiet: true)
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
        readThisSession = []
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

    // MARK: - USB

    /// Copies drive files that are missing on the phone into the library.
    /// A copy from the Pocket's drive under way: how many of how many.
    @Published private(set) var importing: (done: Int, total: Int)?

    /// Copies what the phone lacks from the Pocket's drive. Each file is read off the main
    /// thread (a drive is slow), so the screen stays live and shows how far it has got.
    func importFromDrive(_ files: [DriveFile], device: DeviceConfig) async {
        let todo = files.filter { !library.has(device: device.id, day: $0.day, name: $0.name) && !library.wasDeleted(device: device.id, day: $0.day, name: $0.name) }
        guard !todo.isEmpty, importing == nil else { return }
        importing = (0, todo.count)
        defer { importing = nil }
        for (i, f) in todo.enumerated() {
            do {
                let url = f.url
                let audio = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
                try library.save(device: device.id, day: f.day, name: f.name, audio: audio, seconds: nil, pocket: PocketID(device))
            } catch {
                drive.error = "Import of \(f.name) failed: \(error.localizedDescription)"
            }
            importing = (i + 1, todo.count)
        }
    }

    /// A drive file is backed up when the phone holds a copy of exactly the same size.
    func isBackedUp(_ f: DriveFile, device: DeviceConfig) -> Bool {
        library.localSize(device: device.id, day: f.day, name: f.name) == f.size
    }
}
