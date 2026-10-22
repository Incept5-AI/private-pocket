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

    /// The month of the oldest moment shown, for the foot of the rail.
    private var earliestLabel: String {
        shown.compactMap(\.startedAt).min().map { $0.formatted(.dateTime.month(.abbreviated).year(.twoDigits)) } ?? ""
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
            ScrollViewReader { proxy in
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
                    Section {
                        ForEach(items) { r in
                            NavigationLink(value: r.id) { MomentRow(recording: r, showDevice: pockets.count > 1) }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                        }
                        .onDelete { idx in idx.map { items[$0] }.forEach(library.delete) }
                    } header: {
                        Text(day).id(day)
                    }
                }
            }
                .scrollContentBackground(.hidden)
                .background(Brand.ground)
                .scrollIndicators(.hidden)
                .overlay(alignment: .trailing) {
                    if grouped.count >= 3, search.isEmpty {
                        DateRail(days: grouped.map(\.0), earliest: earliestLabel) { day in
                            withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(day, anchor: .top) }
                        }
                        .padding(.vertical, 28).padding(.trailing, 2)
                    }
                }
            }
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

/// A moment's page (see `MomentView`); the name the navigation destinations use.
struct RecordingDetail: View {
    let id: String
    var body: some View { MomentView(id: id) }
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

    func play(from t: TimeInterval) {
        seek(t)
        if !playing { toggle() }
    }

    func stop() { player?.stop(); playing = false; timer?.invalidate() }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated { playing = false; timer?.invalidate(); position = 0 }
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


// MARK: - The date rail

/// The date filter on the right edge of Moments: slide a thumb up or down and the
/// list follows, now at the top, the past at the bottom, one tick per day that has
/// moments. A glass lens names the day under the thumb.
struct DateRail: View {
    let days: [String]
    let earliest: String
    let scrollTo: (String) -> Void
    @State private var dragging = false
    @State private var index = 0
    @State private var y: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 4) {
                    Text("Now").font(.system(size: 9, weight: .semibold)).foregroundStyle(Brand.muted)
                    Canvas { ctx, size in
                        let n = max(2, min(days.count, Int(size.height / 7)))
                        for k in 0..<n {
                            let ty = size.height * CGFloat(k) / CGFloat(n - 1)
                            let day = Int((CGFloat(k) / CGFloat(n - 1) * CGFloat(days.count - 1)).rounded())
                            let active = dragging && day == index
                            let w: CGFloat = active ? 14 : (k % 5 == 0 ? 10 : 6)
                            ctx.fill(Path(roundedRect: CGRect(x: size.width - w, y: ty - 1, width: w, height: 2), cornerRadius: 1),
                                     with: .color(active ? Brand.act : Color.white.opacity(0.4)))
                        }
                    }
                    .frame(width: 16)
                    Text(earliest).font(.system(size: 9, weight: .semibold)).foregroundStyle(Brand.muted).lineLimit(1).fixedSize()
                }
                .padding(.horizontal, 6).padding(.vertical, 8)
                .glassEffect(.regular.interactive(), in: Capsule())
                .frame(height: h)
                if dragging {
                    HStack(spacing: 8) {
                        Text(days[min(max(index, 0), days.count - 1)]).font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
                        Circle().fill(Brand.act).frame(width: 8, height: 8)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .glassEffect(.regular.tint(Brand.act.opacity(0.18)), in: Capsule())
                    .offset(x: -40, y: min(max(y - 18, 0), h - 36))
                    .transition(.scale(scale: 0.5, anchor: .trailing).combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: h, alignment: .topTrailing)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let inner = max(1, h - 48)   // the track, inside the Now and month labels
                        y = min(max(0, g.location.y), h)
                        let f = min(max(0, (y - 24) / inner), 1)
                        let i = days.isEmpty ? 0 : Int((f * CGFloat(days.count - 1)).rounded())
                        if !dragging { withAnimation(.spring(duration: 0.3)) { dragging = true } }
                        if i != index || !dragging { index = i; scrollTo(days[i]) }
                    }
                    .onEnded { _ in withAnimation(.spring(duration: 0.35)) { dragging = false } }
            )
            .sensoryFeedback(.selection, trigger: index)
        }
        .frame(width: 44)
    }
}
