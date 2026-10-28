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
        let auto = Prefs.canDetectLanguage ? [Languages.auto] : []
        for id in auto + [Prefs.transcriptionLocale] + Prefs.favouriteLocales + [r.meta.locale, language].compactMap({ $0 })
        where !out.contains(id) && (Prefs.canDetectLanguage || id != Languages.auto) { out.append(id) }
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
                    if recording.isCall { Text("Call") }
                    if showDevice { Text(recording.pocketName(devices.devices)) }
                }
                .font(.caption).foregroundStyle(.secondary)
                if recording.meta.title != nil, let place = recording.meta.place {
                    Label(place.label, systemImage: "mappin.and.ellipse")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let s = recording.meta.summary.map(Analysis.preview) ?? recording.meta.transcript {
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

    /// Jumps to `t` and plays from there (a transcript time was tapped).
    func play(from t: TimeInterval) {
        seek(max(0, t - 0.5))
        if !playing { toggle() }
    }

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
