import AVFoundation
import SwiftUI

struct RecordingsView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var devices: DeviceStore
    @State private var search = ""
    @State private var pocketFilter: UUID?

    /// Pockets that have recordings here, with their names.
    private var pockets: [(id: UUID, name: String)] {
        var seen: [UUID: String] = [:]
        for r in library.recordings where seen[r.deviceID] == nil { seen[r.deviceID] = r.pocketName(devices.devices) }
        return seen.map { ($0.key, $0.value) }.sorted { $0.name < $1.name }
    }

    private var shown: [Recording] {
        let pool = pocketFilter.map { id in library.recordings.filter { $0.deviceID == id } } ?? library.recordings
        guard !search.isEmpty else { return pool }
        return pool.filter { r in
            [r.displayTitle, r.meta.place?.name, r.meta.transcript, r.meta.summary,
             r.pocketName(devices.devices), r.meta.pocket?.advertised]
                .compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(search) }
                || r.meta.speakerNames?.values.contains { $0.localizedCaseInsensitiveContains(search) } == true
        }
    }

    private var grouped: [(String, [Recording])] {
        let byDay = Dictionary(grouping: shown) { Self.dayLabel($0) }
        return byDay.sorted { ($0.value.first?.startedAt ?? .distantPast) > ($1.value.first?.startedAt ?? .distantPast) }
    }

    /// "Today", "Yesterday", then "Monday 20 October" (with the year once it differs).
    static func dayLabel(_ r: Recording) -> String {
        guard let d = r.startedAt else { return r.day }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let sameYear = cal.component(.year, from: d) == cal.component(.year, from: Date())
        return sameYear ? d.formatted(.dateTime.weekday(.wide).day().month(.wide))
                        : d.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    var body: some View {
        NavigationStack {
            List {
                if library.recordings.isEmpty {
                    ContentUnavailableView("No recordings yet", systemImage: "waveform",
                                           description: Text("Press the side button on your Pocket. Recordings stream in as they are made, and ones made while the phone was away arrive when it reconnects."))
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
                ForEach(grouped, id: \.0) { day, items in
                    Section(day) {
                        ForEach(items) { r in
                            NavigationLink(value: r.id) { RecordingRow(recording: r, showDevice: pockets.count > 1) }
                        }
                        .onDelete { idx in idx.map { items[$0] }.forEach(library.delete) }
                    }
                }
            }
            .navigationTitle("Recordings")
            .searchable(text: $search, prompt: "Titles, places, transcripts, speakers, Pockets")
            .toolbar {
                if pockets.count > 1 {
                    Menu {
                        Picker("Pocket", selection: $pocketFilter) {
                            Text("All Pockets").tag(UUID?.none)
                            ForEach(pockets, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                        }
                    } label: {
                        Label("Pocket", systemImage: pocketFilter == nil ? "line.3.horizontal.decrease.circle"
                                                                         : "line.3.horizontal.decrease.circle.fill")
                    }
                }
            }
            .navigationDestination(for: String.self) { id in RecordingDetail(id: id) }
            .refreshable { library.reload() }
        }
    }
}

extension RecordingDetail {
    /// The default language, the favourites, and whatever this recording used.
    func languageChoices(_ r: Recording) -> [String] {
        var out: [String] = []
        let auto = Prefs.sttRemote ? [Languages.auto] : []
        for id in auto + [Prefs.transcriptionLocale] + Prefs.favouriteLocales + [r.meta.locale, language].compactMap({ $0 })
        where !out.contains(id) && (Prefs.sttRemote || id != Languages.auto) { out.append(id) }
        return out
    }
}

struct RecordingRow: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var devices: DeviceStore
    let recording: Recording
    var showDevice = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(recording.displayTitle).font(.headline).lineLimit(1)
                Spacer()
                if recording.meta.title != nil || recording.meta.place?.name != nil, let t = recording.startedAt {
                    Text(t.formatted(date: .omitted, time: .shortened)).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                if let s = recording.meta.seconds { Label(PocketFacts.length(s), systemImage: "clock") }
                if recording.isCall { Label("Call", systemImage: "phone") }
                if recording.meta.title != nil, let p = recording.meta.place?.name {
                    Label(p, systemImage: "mappin").lineLimit(1)
                }
                if let t = recording.meta.turns, Speakers.count(t) > 1 {
                    Label("\(Speakers.count(t)) speakers", systemImage: "person.2")
                }
                if showDevice { Text(recording.pocketName(devices.devices)) }
                Spacer()
                if model.working.contains(recording.id) {
                    ProgressView().controlSize(.small)
                } else {
                    if recording.meta.transcript != nil { Image(systemName: "text.quote") }
                    if recording.meta.summary != nil { Image(systemName: "sparkles") }
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let s = recording.meta.summary ?? recording.meta.transcript {
                Text(s).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text("Not transcribed yet").font(.subheadline).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct RecordingDetail: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: Library
    @EnvironmentObject var devices: DeviceStore
    let id: String
    @StateObject private var player = Player()
    @State private var title = ""
    @State private var language = Prefs.transcriptionLocale
    @State private var renaming: Int?
    @State private var newName = ""
    @State private var blocks: [TranscriptBlock] = []

    private var recording: Recording? { library.recordings.first { $0.id == id } }
    /// The paragraph the playhead is in.
    private var currentBlock: Int? { blocks.last { $0.start <= player.position }?.id }

    var body: some View {
        if let r = recording {
            ScrollViewReader { proxy in
            List {
                Section {
                    PlayerControls(player: player, url: r.audioURL)
                }
                Section("Details") {
                    TextField(r.meta.place?.name ?? r.startedAt?.formatted(date: .omitted, time: .shortened) ?? "Title",
                              text: $title)
                        .onSubmit { model.rename(r, to: title) }
                        .submitLabel(.done)
                    if let t = r.startedAt {
                        LabeledContent("Recorded", value: t.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let s = r.meta.seconds {
                        LabeledContent("Length", value: Duration.seconds(s).formatted(.time(pattern: .hourMinuteSecond)))
                    }
                    LabeledContent("Pocket", value: r.pocketName(devices.devices))
                    LabeledContent("Switch", value: r.isCall ? "Call (contact mic)" : "Audio")
                    if let place = r.meta.place {
                        Link(destination: place.mapsURL) {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(place.label, systemImage: "mappin.and.ellipse")
                                Text(place.approximate ? "Approximate: where the phone was when it downloaded" : place.coordinateText)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button("Remove location", role: .destructive) { model.clearPlace(r) }
                    }
                    Button {
                        Task { await model.tagHere(r) }
                    } label: {
                        Label(r.meta.place == nil ? "Tag with current location" : "Replace with current location",
                              systemImage: "location")
                    }
                }
                Section {
                    ForEach(blocks) { b in
                        TranscriptBlockRow(block: b, names: r.meta.speakerNames,
                                           position: b.id == currentBlock ? player.position : nil) { speaker in
                            newName = r.meta.speakerNames?[String(speaker)] ?? ""
                            renaming = speaker
                        }
                        .id(b.id)
                        .listRowBackground(b.id == currentBlock && player.playing
                                           ? Color.orange.opacity(0.12) : Color(.secondarySystemGroupedBackground))
                        .onTapGesture {
                            player.seek(b.start)
                            if !player.playing { player.toggle() }
                        }
                    }
                    if r.meta.transcript == nil {
                        Button {
                            Task { await model.transcribe(r, localeID: language) }
                        } label: {
                            Label("Transcribe in \(Languages.name(language))", systemImage: "text.quote")
                        }
                        .disabled(model.working.contains(r.id))
                    }
                } header: { Text("Transcript") } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if !blocks.isEmpty { Text("Follows the audio as it plays. Tap a line to play from there.") }
                        if r.meta.liveTranscript == true {
                            Text("Made live while recording. Transcribe again, from the ⋯ menu, for the most accurate version.")
                        }
                        if let e = r.meta.speakersError { Text("Speakers: \(e)") }
                        if let turns = r.meta.turns, Speakers.count(turns) > 1 { Text("Tap a speaker's name to rename them.") }
                        Text(Prefs.sttRemote
                             ? "Uses \(Prefs.sttModel) on \(URL(string: Prefs.sttURL)?.host() ?? "the server"); the audio is uploaded to it."
                             : "Apple's on-device speech recognition; the audio does not leave the phone.")
                    }
                }
                Section {
                    if let s = r.meta.summary {
                        Text(s).textSelection(.enabled)
                    }
                    Button {
                        Task { await model.summarise(r) }
                    } label: {
                        Label(r.meta.summary == nil ? "Summarise" : "Summarise again", systemImage: "sparkles")
                    }
                    .disabled(r.meta.transcript == nil || model.working.contains(r.id) || Summariser.availability != nil)
                } header: { Text("Summary") } footer: {
                    Text(Summariser.availability ?? "Needs a transcript first. Uses \(LLM.whereLabel)")
                }
                Section {
                    NavigationLink {
                        AskView(fixedRecording: r.id)
                    } label: {
                        Label("Ask about this recording", systemImage: "questionmark.bubble")
                    }
                    .disabled(r.meta.transcript == nil)
                } footer: {
                    Text("For example: who was mentioned, or which restaurant was it?")
                }
                if model.working.contains(r.id) {
                    Section { HStack { ProgressView(); Text("Working on this iPhone…").foregroundStyle(.secondary) } }
                }
                Section("File") {
                    LabeledContent("Device file", value: "\(r.day)/\(r.name).mp3")
                    if let p = r.meta.pocket {
                        LabeledContent("Pocket ID", value: p.advertised)
                        if let mac = p.mac { LabeledContent("Pocket MAC", value: mac) }
                    }
                    LabeledContent("Size", value: r.size.formatted(.byteCount(style: .file)))
                }
            }
            .navigationTitle(r.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Menu {
                            ForEach(languageChoices(r), id: \.self) { lang in
                                Button(Languages.name(lang)) { Task { await model.transcribe(r, localeID: lang) } }
                            }
                        } label: {
                            Label(r.meta.transcript == nil ? "Transcribe in…" : "Transcribe again in…", systemImage: "text.quote")
                        }
                        if r.meta.words != nil, Prefs.diarize {
                            Button {
                                Task { await model.findSpeakers(r) }
                            } label: {
                                Label(r.meta.turns == nil ? "Find speakers" : "Find speakers again", systemImage: "person.2")
                            }
                        }
                        Button {
                            Task { await model.summarise(r) }
                        } label: {
                            Label(r.meta.summary == nil ? "Summarise" : "Summarise again", systemImage: "sparkles")
                        }
                        .disabled(r.meta.transcript == nil || Summariser.availability != nil)
                        Divider()
                        ShareLink(item: r.audioURL) { Label("Share audio", systemImage: "waveform") }
                        if let t = r.transcriptForModel {
                            ShareLink(item: t) { Label("Share transcript", systemImage: "text.quote") }
                        }
                        if let s = r.meta.summary {
                            ShareLink(item: s) { Label("Share summary", systemImage: "sparkles") }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(model.working.contains(r.id))
                }
            }
            .onChange(of: r.meta, initial: true) { blocks = TranscriptBlock.make(r) }
            .onChange(of: currentBlock) {
                guard player.playing, let id = currentBlock else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
            .alert("Name this speaker", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField(renaming.map { "Speaker \($0 + 1)" } ?? "", text: $newName)
                Button("Save") { if let s = renaming { model.renameSpeaker(r, speaker: s, to: newName) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Used in this recording's transcript, summary and answers.")
            }
            .onAppear {
                title = r.meta.title ?? ""
                language = r.meta.locale ?? Prefs.transcriptionLocale
            }
            .onDisappear {
                player.stop()
                if title != (r.meta.title ?? "") { model.rename(r, to: title) }
            }
            }
        } else {
            ContentUnavailableView("Recording deleted", systemImage: "trash")
        }
    }
}

/// A paragraph of the transcript: one speaker's turn, or a run of words between pauses.
struct TranscriptBlock: Identifiable, Hashable {
    let id: Int
    let speaker: Int?
    let start: Double
    /// Timed words, when the transcript has them, so the current word can be shown.
    let words: [TimedWord]
    let text: String

    static func make(_ r: Recording) -> [TranscriptBlock] {
        let words = (r.meta.words ?? []).sorted { $0.start < $1.start }
        if let turns = r.meta.turns, Speakers.count(turns) > 1 {
            var byTurn = Array(repeating: [TimedWord](), count: turns.count)
            var i = 0
            for w in words {
                while i + 1 < turns.count, turns[i + 1].start <= w.start { i += 1 }
                byTurn[i].append(w)
            }
            return turns.enumerated().map { i, t in
                TranscriptBlock(id: i, speaker: t.speaker, start: t.start, words: byTurn[i], text: t.text)
            }
        }
        guard !words.isEmpty else {
            return r.meta.transcript.map { [TranscriptBlock(id: 0, speaker: nil, start: 0, words: [], text: $0)] } ?? []
        }
        var out: [TranscriptBlock] = []
        var run: [TimedWord] = []
        func flush() {
            guard let first = run.first else { return }
            out.append(TranscriptBlock(id: out.count, speaker: nil, start: first.start, words: run,
                                       text: run.map(\.word).joined(separator: " ")))
            run = []
        }
        for w in words {
            if let last = run.last, w.start - last.end > 1.5 || run.count >= 70 { flush() }
            run.append(w)
        }
        flush()
        return out
    }
}

/// One paragraph. With `position` set (the paragraph the playhead is in) the current
/// word is amber and the words still to come are dimmed.
struct TranscriptBlockRow: View {
    let block: TranscriptBlock
    let names: [String: String]?
    let position: Double?
    var onRename: ((Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let s = block.speaker {
                    let name = Text(Speakers.name(s, names)).font(.caption.weight(.semibold))
                        .foregroundStyle(TurnRow.colours[s % TurnRow.colours.count])
                    if let onRename {
                        Button { onRename(s) } label: { name }.buttonStyle(.borderless)
                    } else {
                        name
                    }
                }
                if block.speaker != nil || !block.words.isEmpty {
                    Text(Speakers.stamp(block.start)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Text(attributed).textSelection(.enabled)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var attributed: AttributedString {
        guard let position, !block.words.isEmpty else { return AttributedString(block.text) }
        var out = AttributedString()
        for w in block.words {
            var piece = AttributedString(w.word + " ")
            if position >= w.start, position < max(w.end, w.start + 0.25) {
                piece.foregroundColor = .orange
                piece.font = .body.weight(.semibold)
            } else if position < w.start {
                piece.foregroundColor = .secondary
            }
            out += piece
        }
        return out
    }
}

@MainActor
final class Player: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playing = false
    @Published var position: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ url: URL) {
        guard player?.url != url else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        duration = player?.duration ?? 0
        position = 0
    }

    func toggle() {
        guard let p = player else { return }
        if p.isPlaying { p.pause(); playing = false; timer?.invalidate(); return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        p.play()
        playing = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.position = self?.player?.currentTime ?? 0 }
        }
    }

    func seek(_ t: TimeInterval) { player?.currentTime = t; position = t }

    func stop() { player?.stop(); playing = false; timer?.invalidate() }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated { playing = false; timer?.invalidate(); position = 0 }
    }
}

struct PlayerControls: View {
    @ObservedObject var player: Player
    let url: URL

    var body: some View {
        VStack(spacing: 6) {
            Slider(value: Binding(get: { player.position }, set: { player.seek($0) }), in: 0...max(player.duration, 0.1))
                .tint(.orange)
            HStack {
                Text(Duration.seconds(Int(player.position)).formatted(.time(pattern: .minuteSecond)))
                Spacer()
                Text(Duration.seconds(Int(player.duration)).formatted(.time(pattern: .minuteSecond)))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            HStack(spacing: 36) {
                Button { player.seek(max(0, player.position - 15)) } label: {
                    Image(systemName: "gobackward.15").font(.title2)
                }
                Button { player.toggle() } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill")
                        .font(.title2.weight(.semibold))
                        .frame(width: 58, height: 58)
                }
                .glassEffect(.regular.tint(.orange.opacity(0.3)).interactive(), in: .circle)
                Button { player.seek(min(player.duration, player.position + 15)) } label: {
                    Image(systemName: "goforward.15").font(.title2)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
        .padding(.vertical, 6)
        .onAppear { player.load(url) }
    }
}
