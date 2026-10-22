import AVFoundation
import SwiftUI

struct RecordingsView: View {
    @EnvironmentObject var model: AppModel
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
                    ContentUnavailableView {
                        Label("No moments yet", systemImage: "waveform")
                    } description: {
                        Text("Press the side button on your Pocket. Recordings stream in as they are made, and ones made while the phone was away arrive when it reconnects.")
                    } actions: {
                        Button("Add sample moments") { Task { await model.addSamples() } }
                    }
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
                ForEach(grouped, id: \.0) { day, items in
                    Section(day) {
                        ForEach(items) { r in
                            NavigationLink(value: r.id) { MomentRow(recording: r, showDevice: pockets.count > 1) }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                        }
                        .onDelete { idx in idx.map { items[$0] }.forEach(library.delete) }
                    }
                }
            }
                .scrollContentBackground(.hidden)
                .background(Brand.ground)
            .navigationTitle("Moments")
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
        let auto = Prefs.sttRemoteNow ? [Languages.auto] : []
        for id in auto + [Prefs.transcriptionLocale] + Prefs.favouriteLocales + [r.meta.locale, language].compactMap({ $0 })
        where !out.contains(id) && (Prefs.sttRemoteNow || id != Languages.auto) { out.append(id) }
        return out
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
                MomentSections(recording: r)
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
                                           ? Brand.record.opacity(0.12) : Brand.surface)
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
                        Text(Prefs.sttRemoteNow
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
                .scrollContentBackground(.hidden)
                .background(Brand.ground)
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
                        Button {
                            Task { await model.analyse(r) }
                        } label: {
                            Label(r.meta.insight?.readByModel == true ? "Read the conversation again" : "Read the conversation", systemImage: "text.magnifyingglass")
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
                piece.foregroundColor = Brand.record
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
                .tint(Brand.record)
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
                .glassEffect(.regular.tint(Brand.record.opacity(0.3)).interactive(), in: .circle)
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

// MARK: - Moments

/// A moment as a card: the kind, when and how long, the line that stands for it, who and
/// where, and for a sample whether it was read as expected.
struct MomentCard: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    var showTime = true
    /// Which Pocket, when more than one has recordings here.
    var device: String? = nil

    var body: some View {
        let r = recording
        let when = [showTime ? r.startedAt?.formatted(date: .omitted, time: .shortened) : nil,
                    r.meta.seconds.map { PocketFacts.length($0) }].compactMap { $0 }.joined(separator: " · ")
        let foot = [r.subline, device].compactMap { $0 }.joined(separator: " · ")
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                KindChip(kind: r.kind).layoutPriority(1)
                Spacer(minLength: 8)
                if model.working.contains(r.id) { ProgressView().controlSize(.small) }
                Text(when).font(.caption.monospacedDigit()).foregroundStyle(Brand.muted).lineLimit(1)
            }
            Text(r.quote)
                .font(.body.weight(.medium))
                .lineLimit(2)
                .foregroundStyle(r.meta.transcript == nil && r.meta.title == nil ? Brand.muted : Brand.text)
            if !foot.isEmpty || verdict != nil {
                HStack(alignment: .center, spacing: 10) {
                    if !foot.isEmpty { Text(foot).font(.caption).foregroundStyle(Brand.muted).lineLimit(1) }
                    Spacer(minLength: 8)
                    if let v = verdict {
                        HStack(spacing: 4) {
                            Image(systemName: v.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            Text(v.text)
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(v.ok ? Brand.good : Brand.bad)
                        .lineLimit(1)
                        .fixedSize()
                        .layoutPriority(1)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// For a sample moment that has been read: whether the kind matched.
    private var verdict: (ok: Bool, text: String)? {
        guard let e = recording.meta.expectedKind, let i = recording.meta.insight, i.readByModel else { return nil }
        let ok = e == i.kind
        return (ok, ok ? "As expected" : "Expected \(MomentKind(rawValue: e)?.label ?? e)")
    }
}

/// A moment in the day's list: the time on a rail, the card beside it.
struct MomentRow: View {
    @EnvironmentObject var devices: DeviceStore
    let recording: Recording
    var showDevice = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(recording.startedAt?.formatted(date: .omitted, time: .shortened) ?? "–")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(Brand.muted)
                .frame(width: 50, alignment: .leading)
                .padding(.top, 14)
            MomentCard(recording: recording, showTime: false,
                       device: showDevice ? recording.pocketName(devices.devices) : nil)
        }
    }
}

/// What the conversation was and what came out of it, above the details: the kind and
/// the people; the actions, each with Add for Reminders; what was promised; what is
/// coming up, each with Add for Calendar.
struct MomentSections: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording

    var body: some View {
        let r = recording
        let i = r.meta.insight
        Section {
            HStack {
                Menu {
                    ForEach([MomentKind.businessCall, .personalCall, .businessMeeting, .personalMeeting, .note], id: \.self) { k in
                        Button { model.setKind(r, k) } label: { Label(k.label, systemImage: k.symbol) }
                    }
                    if r.meta.labelKind != nil {
                        Divider()
                        Button("Back to the reading") { model.setKind(r, nil) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        KindChip(kind: r.kind)
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(Brand.muted)
                    }
                }
                if r.meta.labelKind != nil { Text("your correction").font(.caption2).foregroundStyle(Brand.dim) }
                Spacer()
                if r.meta.transcript != nil, i?.readByModel != true {
                    Button("Read it") { Task { await model.analyse(r) } }
                        .font(.subheadline.weight(.semibold))
                        .disabled(model.working.contains(r.id) || Summariser.availability != nil)
                }
            }
            if let p = i?.people, !p.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(p, id: \.self) { n in
                            Text(n).font(.caption.weight(.semibold))
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Brand.raised, in: Capsule())
                        }
                    }
                }
            }
        } footer: {
            if r.meta.transcript == nil {
                Text("Transcribe it, and it can be read for what it was and what came out of it.")
            } else if i?.readByModel != true, let why = Summariser.availability {
                Text(why)
            }
        }
        if let i, !i.actions.isEmpty {
            Section {
                ForEach(i.actions, id: \.self) { a in
                    HStack(spacing: 10) {
                        Image(systemName: i.isAdded(a) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(i.isAdded(a) ? Brand.good : Brand.act)
                        Text(a)
                        Spacer()
                        if !i.isAdded(a) {
                            Button("Add") { Task { await model.addToReminders(r, action: a) } }
                                .font(.subheadline.weight(.semibold)).buttonStyle(.borderless)
                        }
                    }
                }
            } header: { Text("Actions") } footer: { Text("Add puts one in Reminders, with a note saying where it came from.") }
        }
        if let i, !i.promises.isEmpty {
            Section("Promised to you") {
                ForEach(i.promises, id: \.self) { Text($0) }
            }
        }
        if let i, !i.upcoming.isEmpty {
            Section {
                ForEach(i.upcoming, id: \.self) { u in
                    let date = Planner.date(in: u)
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(u)
                            if let date { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Brand.muted) }
                        }
                        Spacer()
                        if i.isAdded(u) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.good)
                        } else if date != nil {
                            Button("Add") { Task { await model.addToCalendar(r, item: u) } }
                                .font(.subheadline.weight(.semibold)).buttonStyle(.borderless)
                        }
                    }
                }
            } header: { Text("Coming up") } footer: { Text("Add puts one in Calendar, an hour long, at the time it mentions.") }
        }
    }
}
