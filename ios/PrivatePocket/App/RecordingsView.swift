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
        let byDay = Dictionary(grouping: shown) { r in
            r.startedAt.map { $0.formatted(date: .complete, time: .omitted) } ?? r.day
        }
        return byDay.sorted { ($0.value.first?.name ?? "") > ($1.value.first?.name ?? "") }
    }

    var body: some View {
        NavigationStack {
            List {
                if library.recordings.isEmpty {
                    ContentUnavailableView("No recordings yet", systemImage: "waveform",
                                           description: Text("Recordings appear here as they stream from the Pocket, or when you download them on the Recorder tab."))
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
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.displayTitle).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    if recording.meta.title != nil || recording.meta.place?.name != nil,
                       let t = recording.startedAt {
                        Text(t.formatted(date: .omitted, time: .shortened))
                    }
                    if let s = recording.meta.seconds { Text(Duration.seconds(s).formatted(.time(pattern: .minuteSecond))) }
                    Text(recording.size.formatted(.byteCount(style: .file)))
                    if showDevice { Text(recording.pocketName(devices.devices)) }
                }
                .font(.caption).foregroundStyle(.secondary)
                if recording.meta.title != nil, let place = recording.meta.place {
                    Label(place.label, systemImage: "mappin.and.ellipse")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let s = recording.meta.summary ?? recording.meta.transcript {
                    Text(s).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.working.contains(recording.id) {
                ProgressView()
            } else {
                if recording.meta.transcript != nil { Image(systemName: "text.quote").foregroundStyle(.secondary) }
                if recording.meta.summary != nil { Image(systemName: "sparkles").foregroundStyle(.secondary) }
            }
        }
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

    private var recording: Recording? { library.recordings.first { $0.id == id } }

    var body: some View {
        if let r = recording {
            List {
                Section {
                    PlayerControls(player: player, url: r.audioURL)
                    ShareLink(item: r.audioURL) { Label("Share audio", systemImage: "square.and.arrow.up") }
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
                    Picker("Language", selection: $language) {
                        ForEach(languageChoices(r), id: \.self) { Text(Languages.name($0)).tag($0) }
                    }
                    if let turns = r.meta.turns, Speakers.count(turns) > 1 {
                        ForEach(turns) { t in
                            TurnRow(turn: t, names: r.meta.speakerNames) { speaker in
                                newName = r.meta.speakerNames?[String(speaker)] ?? ""
                                renaming = speaker
                            }
                        }
                    } else if let t = r.meta.transcript {
                        Text(t).textSelection(.enabled)
                    }
                    if let t = r.transcriptForModel {
                        ShareLink(item: t) { Label("Share transcript", systemImage: "square.and.arrow.up") }
                    }
                    if r.meta.words != nil, Prefs.diarize {
                        Button {
                            Task { await model.findSpeakers(r) }
                        } label: {
                            Label(r.meta.turns == nil ? "Find speakers" : "Find speakers again", systemImage: "person.2")
                        }
                        .disabled(model.working.contains(r.id))
                    }
                    Button {
                        Task { await model.transcribe(r, localeID: language) }
                    } label: {
                        Label(r.meta.transcript == nil ? "Transcribe in \(Languages.name(language))"
                                                       : "Transcribe again in \(Languages.name(language))",
                              systemImage: "text.quote")
                    }
                    .disabled(model.working.contains(r.id))
                } header: { Text("Transcript") } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if r.meta.liveTranscript == true {
                            Text("Made live while recording. Transcribe again for the most accurate version.")
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
                        ShareLink(item: s) { Label("Share summary", systemImage: "square.and.arrow.up") }
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
        } else {
            ContentUnavailableView("Recording deleted", systemImage: "trash")
        }
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
        VStack {
            HStack {
                Button { player.toggle() } label: {
                    Image(systemName: player.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 40))
                }
                .buttonStyle(.plain)
                Slider(value: Binding(get: { player.position }, set: { player.seek($0) }), in: 0...max(player.duration, 0.1))
            }
            HStack {
                Text(Duration.seconds(Int(player.position)).formatted(.time(pattern: .minuteSecond)))
                Spacer()
                Text(Duration.seconds(Int(player.duration)).formatted(.time(pattern: .minuteSecond)))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .onAppear { player.load(url) }
    }
}
