import AVFoundation
import SwiftUI

/// A moment, on one screen: what happened, in your terms, and what's next, already
/// placed in Reminders and Calendar. The recording sits beneath as an instrument, and
/// every line is anchored to the words it came from: tap it and hear them.
struct MomentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: Library
    @EnvironmentObject var devices: DeviceStore
    @Environment(\.dismiss) private var dismiss
    let id: String
    @StateObject private var player = Player()
    @State private var envelope: [Float] = []
    @State private var listening = false
    @State private var behind: Behind?
    @State private var showDetails = false
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var confirmDelete = false
    @State private var confirmRedo = false

    private var recording: Recording? { library.recordings.first { $0.id == id } }

    var body: some View {
        if let r = recording {
            ZStack(alignment: .top) {
                Brand.ground.ignoresSafeArea()
                RadialGradient(colors: [r.kind.colour.opacity(0.2), .clear],
                               center: UnitPoint(x: 0.5, y: 0), startRadius: 0, endRadius: 420)
                    .ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        MomentHeader(recording: r) {
                            newTitle = r.meta.title ?? ""
                            renaming = true
                        }
                        stage(r)
                        if let brief = r.meta.insight?.brief, !brief.isEmpty {
                            BriefText(sentences: brief) { behind = Behind(sentence: $0) }
                                .padding(.top, 22)
                            if brief.contains(where: { $0.at != nil }) {
                                Text("Tap a sentence to hear where it came from.")
                                    .font(.caption).foregroundStyle(Brand.dim).padding(.top, 8)
                            }
                        }
                        NextList(recording: r) { behind = Behind(item: $0) }
                        footer(r)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
            .safeAreaInset(edge: .bottom) {
                PlayerBar(player: player, envelope: envelope, marks: marks(r),
                          caption: "The recording · tap to listen and find") { listening = true }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: model.notes(for: r)) { Image(systemName: "square.and.arrow.up") }
                }
            }
            .sheet(isPresented: $listening) { ListenView(id: r.id, player: player, envelope: envelope, marks: marks(r)) }
            .sheet(item: $behind) { b in BehindSheet(id: r.id, behind: b, player: player).presentationDetents([.medium]) }
            .sheet(isPresented: $showDetails) { MomentDetailsSheet(id: r.id) }
            .alert("Name this moment", isPresented: $renaming) {
                TextField(r.displayTitle, text: $newTitle)
                Button("Save") { model.rename(r, to: newTitle) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Leave it empty to go back to the title it was given.")
            }
            .confirmationDialog("Delete this moment?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    library.delete(r)
                    dismiss()
                }
            } message: {
                Text("The recording and everything read from it. Reminders and Calendar keep what was sent to them.")
            }
            .confirmationDialog("Redo this moment?", isPresented: $confirmRedo, titleVisibility: .visible) {
                Button("Transcribe and read again") { Task { await model.transcribe(r) } }
            } message: {
                Text("With the current speech-to-text and language-model settings.")
            }
            .task(id: r.audioURL) {
                player.load(r.audioURL)
                model.refreshDone(r)
                if let i = r.meta.insight, i.readByModel, i.brief == nil, r.meta.transcript != nil, !model.working.contains(r.id) {
                    Task { await model.analyse(r, quiet: true) }   // read before briefs existed: read again
                }
                let url = r.audioURL
                envelope = await Task.detached(priority: .utility) { Waveform.envelope(url: url) }.value
            }
            .onDisappear { player.stop() }
        } else {
            ContentUnavailableView("Moment deleted", systemImage: "trash")
        }
    }

    private func marks(_ r: Recording) -> [Double] { (r.meta.insight?.keyLines ?? []).compactMap(\.at) }

    /// While nothing has been read yet: what is happening, by itself.
    @ViewBuilder private func stage(_ r: Recording) -> some View {
        let working = model.working.contains(r.id)
        if r.meta.transcript == nil {
            StageRow(title: working ? "Transcribing \(Prefs.sttRemoteNow ? "on your server" : "on this iPhone")…" : "Not transcribed yet",
                     detail: working ? "Then it is read, and anything to do or to remember goes to Reminders and Calendar. Nothing for you to do." : nil,
                     spinning: working, action: working ? nil : "Transcribe") { Task { await model.transcribe(r) } }
        } else if r.meta.insight?.readByModel != true {
            StageRow(title: working ? "Reading it…" : "Not read yet",
                     detail: working ? nil : Summariser.availability,
                     spinning: working, action: working || Summariser.availability != nil ? nil : "Read") { Task { await model.analyse(r) } }
        }
    }

    private func footer(_ r: Recording) -> some View {
        VStack(spacing: 8) {
            Text(["Recorded on \(r.pocketName(devices.devices))", r.isCall ? "call switch" : "audio switch",
                  r.meta.locale.map { Languages.name($0) }].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(Brand.dim).multilineTextAlignment(.center)
            HStack(spacing: 18) {
                Button("Details") { showDetails = true }
                Button("Redo") { confirmRedo = true }.disabled(model.working.contains(r.id))
                Button("Delete", role: .destructive) { confirmDelete = true }
            }
            .font(.caption.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
    }
}

/// What is going on with a moment that is not ready yet.
struct StageRow: View {
    let title: String
    let detail: String?
    let spinning: Bool
    let action: String?
    let run: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if spinning { ProgressView().controlSize(.small) }
                Text(title).font(.body.weight(.semibold))
                if let action {
                    Spacer()
                    Button(action, action: run).font(.subheadline.weight(.semibold))
                }
            }
            if let detail { Text(detail).font(.subheadline).foregroundStyle(Brand.muted) }
        }
        .padding(.top, 22)
    }
}

/// Kind, title, when, where, with whom.
struct MomentHeader: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    let rename: () -> Void

    var body: some View {
        let r = recording
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Menu {
                    ForEach(MomentKind.choices, id: \.self) { k in
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
                Spacer()
                if let e = r.meta.expectedKind, let i = r.meta.insight, i.readByModel {
                    let ok = e == i.kind
                    HStack(spacing: 4) {
                        Image(systemName: ok ? "checkmark" : "xmark")
                        Text(ok ? "As expected" : "Expected \(MomentKind(rawValue: e)?.label ?? e)")
                    }
                    .font(.caption2.weight(.semibold)).foregroundStyle(ok ? Brand.good : Brand.bad).fixedSize()
                }
            }
            Text(r.displayTitle)
                .font(.system(size: 30, weight: .bold)).tracking(-0.3).lineLimit(2)
                .padding(.top, 6)
                .onTapGesture(perform: rename)
            Text(meta).font(.subheadline).foregroundStyle(Brand.muted)
            if !r.people.isEmpty {
                HStack(spacing: 10) {
                    HStack(spacing: -8) {
                        ForEach(Array(r.people.prefix(4).enumerated()), id: \.offset) { i, name in
                            Text(String(name.prefix(1)).uppercased())
                                .font(.system(size: 12, weight: .bold))
                                .frame(width: 30, height: 30)
                                .background(Brand.speakers[i % Brand.speakers.count].opacity(0.22), in: Circle())
                                .overlay(Circle().strokeBorder(Brand.ground, lineWidth: 2))
                                .foregroundStyle(Brand.speakers[i % Brand.speakers.count])
                        }
                    }
                    Text("with " + ListFormatter.localizedString(byJoining: r.people)).font(.subheadline).foregroundStyle(Brand.textSecondary).lineLimit(1)
                }
                .padding(.top, 10)
            }
        }
    }

    private var meta: String {
        let r = recording
        var parts: [String] = []
        if let d = r.startedAt {
            let cal = Calendar.current
            let day = cal.isDateInToday(d) ? "Today" : cal.isDateInYesterday(d) ? "Yesterday" : d.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
            parts.append("\(day), \(d.formatted(date: .omitted, time: .shortened))")
        }
        if let s = r.meta.seconds { parts.append(PocketFacts.length(s)) }
        if let p = r.meta.place?.name { parts.append(p) }
        return parts.joined(separator: " · ")
    }
}

/// The brief as one paragraph whose sentences can be tapped to hear where they came from.
struct BriefText: View {
    let sentences: [Anchored]
    let tap: (Anchored) -> Void

    var body: some View {
        Text(attributed)
            .font(.system(size: 19, weight: .medium))
            .lineSpacing(4)
            .tint(Brand.text)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "pocket", let i = Int(url.host() ?? ""), sentences.indices.contains(i) {
                    tap(sentences[i])
                    return .handled
                }
                return .systemAction
            })
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        for (i, s) in sentences.enumerated() {
            var piece = AttributedString(s.text)
            if s.at != nil { piece.link = URL(string: "pocket://\(i)") }
            out += piece
            if i < sentences.count - 1 { out += AttributedString(" ") }
        }
        return out
    }
}

/// Everything that follows from the conversation, in one list.
struct NextList: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    let open: (NextItem) -> Void

    var body: some View {
        let items = Self.ordered(recording.meta.insight?.items ?? [])
        if !items.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text("Next").font(.subheadline.weight(.semibold)).foregroundStyle(Brand.muted)
                Spacer()
                Text(placed(items)).font(.caption2.weight(.semibold)).foregroundStyle(Brand.good)
            }
            .padding(.top, 26).padding(.bottom, 2)
            ForEach(items) { item in
                NextRow(recording: recording, item: item) { open(item) }
                Divider().overlay(Brand.hairline)
            }
        }
    }

    /// Soonest first, undated after, done last; dismissed ones gone.
    static func ordered(_ items: [NextItem]) -> [NextItem] {
        items.filter { !$0.isDismissed }.sorted { a, b in
            if a.isDone != b.isDone { return !a.isDone }
            switch (a.date, b.date) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return false
            }
        }
    }

    private func placed(_ items: [NextItem]) -> String {
        let r = items.contains { $0.isAction && $0.reminderID != nil }
        let c = items.contains { $0.isDate && $0.eventID != nil }
        return r && c ? "in Reminders and Calendar" : r ? "in Reminders" : c ? "in Calendar" : ""
    }
}

struct NextRow: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    let item: NextItem
    let open: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            glyph
            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text).font(.body).strikethrough(item.isDone).foregroundStyle(item.isDone ? Brand.dim : Brand.text)
                    if let w = whenText { Text(w).font(.footnote).foregroundStyle(Brand.muted) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if item.isPromise {
                Button(item.reminderID == nil ? "Remind me" : "Reminder set") { Task { await model.remindMe(recording, item: item) } }
                    .font(.footnote.weight(.semibold)).disabled(item.reminderID != nil)
            }
        }
        .padding(.vertical, 11)
    }

    @ViewBuilder private var glyph: some View {
        if item.isAction {
            Button { model.setDone(recording, item: item, done: !item.isDone) } label: {
                ZStack {
                    Circle().strokeBorder(item.isDone ? Brand.good : Brand.act, lineWidth: 2)
                    if item.isDone {
                        Circle().fill(Brand.good)
                        Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(Brand.ground)
                    }
                }
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .padding(.top, 1)
        } else if item.isDate, let d = item.date {
            VStack(spacing: 0) {
                Text(d.formatted(.dateTime.month(.abbreviated)).uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(Brand.bad)
                Text(d.formatted(.dateTime.day())).font(.system(size: 18, weight: .semibold))
            }
            .frame(width: 40).padding(.vertical, 4)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else if item.isDate {
            Image(systemName: "calendar").foregroundStyle(Brand.muted).frame(width: 22).padding(.top, 2)
        } else {
            Text(String((item.who ?? "?").prefix(1)).uppercased())
                .font(.system(size: 11, weight: .bold))
                .frame(width: 24, height: 24)
                .background(Brand.life.opacity(0.2), in: Circle())
                .foregroundStyle(Brand.life)
                .padding(.top, 1)
        }
    }

    private var whenText: String? {
        if let d = item.date {
            return item.isDate
                ? "\(d.formatted(.dateTime.weekday(.wide))) \(d.formatted(date: .omitted, time: .shortened))"
                : d.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        }
        return item.when
    }
}

// MARK: - The recording

/// Play, the shape of the audio with the lines that mattered marked on it, and the way
/// into listening and finding.
struct PlayerBar: View {
    @ObservedObject var player: Player
    let envelope: [Float]
    let marks: [Double]
    var caption: String? = nil
    var onCaption: (() -> Void)? = nil

    var body: some View {
        let total = max(player.duration, 0.1)
        HStack(spacing: 12) {
            Button { player.toggle() } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill")
                    .font(.body.weight(.bold)).foregroundStyle(Brand.onRecord)
                    .frame(width: 40, height: 40).background(Brand.record, in: Circle())
            }
            .buttonStyle(.plain)
            VStack(spacing: 4) {
                WaveformView(envelope: envelope, progress: player.position / total, marks: marks.map { $0 / total }) { player.seek($0 * total) }
                    .frame(height: 26)
                HStack {
                    Text(Speakers.stamp(player.position))
                    Spacer()
                    if let caption {
                        Button(caption) { onCaption?() }.buttonStyle(.plain).foregroundStyle(Brand.muted).lineLimit(1)
                    }
                    Spacer()
                    Text(Speakers.stamp(total))
                }
                .font(.caption2.monospacedDigit()).foregroundStyle(Brand.muted)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 12).padding(.bottom, 6)
    }
}

struct WaveformView: View {
    let envelope: [Float]
    let progress: Double
    let marks: [Double]
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let n = max(envelope.count, 48)
                let gap: CGFloat = 2
                let bw = max(1, (size.width - gap * CGFloat(n - 1)) / CGFloat(n))
                for i in 0..<n {
                    let v: CGFloat = envelope.isEmpty ? 0.25 : CGFloat(max(envelope[min(i, envelope.count - 1)], 0.08))
                    let h = max(3, v * (size.height - 6))
                    let x = CGFloat(i) * (bw + gap)
                    let on = Double(i) / Double(n) <= progress
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: (size.height - h) / 2, width: bw, height: h), cornerRadius: 1.5),
                             with: .color(on ? Brand.record : Brand.hairline))
                }
                for m in marks {
                    ctx.fill(Path(ellipseIn: CGRect(x: size.width * CGFloat(m) - 2.5, y: 0, width: 5, height: 5)), with: .color(Brand.record))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in seek(max(0, min(1, g.location.x / geo.size.width))) })
        }
    }
}

/// The shape of a recording: the loudness of each of a few dozen slices.
enum Waveform {
    nonisolated static func envelope(url: URL, bars: Int = 64) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let frames = Int(file.length)
        guard frames > 0 else { return [] }
        let per = max(1, frames / bars)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(per)) else { return [] }
        var out: [Float] = []
        for _ in 0..<bars {
            do { try file.read(into: buf, frameCount: AVAudioFrameCount(per)) } catch { break }
            let n = Int(buf.frameLength)
            guard n > 0, let ch = buf.floatChannelData?[0] else { break }
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            out.append((sum / Float(n)).squareRoot())
        }
        let top = out.max() ?? 0
        return top > 0 ? out.map { $0 / top } : out
    }
}

/// The conversation following the audio, with one field that finds a word or answers a question.
struct ListenView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    let id: String
    @ObservedObject var player: Player
    let envelope: [Float]
    let marks: [Double]
    @State private var query = ""
    @State private var asked: String?
    @State private var renaming: Int?
    @State private var newName = ""

    private var recording: Recording? { library.recordings.first { $0.id == id } }
    private var isQuestion: Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.hasSuffix("?") || ["who", "what", "when", "where", "why", "how", "did", "was", "were", "is", "are", "do", "does", "can", "which"].contains { q.hasPrefix($0 + " ") }
    }

    var body: some View {
        NavigationStack {
            if let r = recording {
                let blocks = TranscriptBlock.make(r)
                let current = blocks.last { $0.start <= player.position }?.id
                let shown = query.isEmpty || isQuestion ? blocks : blocks.filter { $0.text.localizedCaseInsensitiveContains(query) }
                ScrollViewReader { proxy in
                    List {
                        if let asked, let qa = model.conversations[r.id]?.last(where: { $0.question == asked }) {
                            Section {
                                Text(qa.question).font(.subheadline.weight(.semibold))
                                if let a = qa.answer {
                                    Text(a).textSelection(.enabled)
                                } else if let e = qa.error {
                                    Text(e).foregroundStyle(Brand.muted)
                                } else {
                                    HStack { ProgressView(); Text(qa.progress ?? "Thinking…").foregroundStyle(Brand.muted) }
                                }
                            }
                            .listRowBackground(Brand.surface)
                        }
                        if blocks.isEmpty {
                            Text(r.meta.transcript == nil ? "Not transcribed yet." : "Nothing to show.").foregroundStyle(Brand.muted)
                                .listRowBackground(Color.clear)
                        } else if shown.isEmpty {
                            Text("Not said in this one.").foregroundStyle(Brand.muted).listRowBackground(Color.clear)
                        }
                        ForEach(shown) { b in
                            TranscriptBlockRow(block: b, names: r.meta.speakerNames, position: b.id == current ? player.position : nil) { s in
                                newName = r.meta.speakerNames?[String(s)] ?? ""
                                renaming = s
                            }
                            .id(b.id)
                            .listRowBackground(b.id == current && player.playing ? Brand.record.opacity(0.12) : Color.clear)
                            .listRowSeparator(.hidden)
                            .onTapGesture { player.play(from: b.start) }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Brand.ground)
                    .onChange(of: current) {
                        guard player.playing, query.isEmpty, let c = current else { return }
                        withAnimation { proxy.scrollTo(c, anchor: .center) }
                    }
                }
                .safeAreaInset(edge: .top) {
                    HStack {
                        TextField("Find a word, or ask a question…", text: $query).submitLabel(.go).onSubmit(ask)
                        if !query.isEmpty {
                            Button { query = ""; asked = nil } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(Brand.muted)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Brand.surface, in: Capsule())
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(Brand.ground)
                }
                .safeAreaInset(edge: .bottom) { PlayerBar(player: player, envelope: envelope, marks: marks) }
                .navigationTitle(r.displayTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .alert("Name this speaker", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                    TextField(renaming.map { "Speaker \($0 + 1)" } ?? "", text: $newName)
                    Button("Save") { if let s = renaming { model.renameSpeaker(r, speaker: s, to: newName) } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Used wherever this moment names them.")
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func ask() {
        guard isQuestion, let r = recording, r.meta.transcript != nil else { return }
        let q = query
        asked = q
        Task { await model.ask(q, scope: r.id, recordings: [r]) }
    }
}

/// What a tapped line opens: the item or the sentence, and so where in the audio.
struct Behind: Identifiable {
    let id = UUID()
    var item: NextItem?
    var sentence: Anchored?

    init(item: NextItem) { self.item = item }
    init(sentence: Anchored) { self.sentence = sentence }
}

/// The words behind a line, played from there, and what can be done with the item.
struct BehindSheet: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let id: String
    let behind: Behind
    @ObservedObject var player: Player

    private var recording: Recording? { library.recordings.first { $0.id == id } }
    /// The live copy of the item, so Done and placement show at once.
    private var item: NextItem? {
        guard let b = behind.item else { return nil }
        return recording?.meta.insight?.items.first { $0.id == b.id } ?? b
    }

    var body: some View {
        if let r = recording {
            let at = behind.item?.at ?? behind.sentence?.at
            let blocks = TranscriptBlock.make(r)
            let block = at.flatMap { t in blocks.last { $0.start <= t } }
            VStack(alignment: .leading, spacing: 16) {
                Text(behind.item?.text ?? behind.sentence?.text ?? "")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Brand.muted).padding(.top, 8)
                if let block {
                    HStack(alignment: .top, spacing: 12) {
                        Button { player.play(from: block.start) } label: {
                            Image(systemName: player.playing ? "pause.fill" : "play.fill")
                                .font(.body.weight(.bold)).foregroundStyle(Brand.onRecord)
                                .frame(width: 40, height: 40).background(Brand.record, in: Circle())
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Speakers.stamp(block.start) + (block.speaker.map { " · " + Speakers.name($0, r.meta.speakerNames) } ?? ""))
                                .font(.caption.weight(.semibold)).foregroundStyle(Brand.record)
                            Text("“\(block.text)”").font(.body)
                        }
                    }
                } else {
                    Text("The words behind this weren't found in the transcript.").font(.subheadline).foregroundStyle(Brand.muted)
                }
                if let item {
                    HStack(spacing: 10) {
                        if item.isAction {
                            if let rid = item.reminderID, let u = Planner.reminderURL(rid) {
                                pill("Open in Reminders", prominent: true) { openURL(u) }
                            } else {
                                pill("Add to Reminders", prominent: true) { Task { await model.place(r, item) } }
                            }
                            pill(item.isDone ? "Not done" : "Done") { model.setDone(r, item: item, done: !item.isDone) }
                            pill("Not mine", destructive: true) { model.dismiss(r, item: item); dismiss() }
                        } else if item.isDate {
                            if let d = item.date, let u = Planner.calendarURL(at: d) {
                                pill(item.eventID != nil ? "Open in Calendar" : "Add to Calendar", prominent: true) {
                                    if item.eventID != nil { openURL(u) } else { Task { await model.place(r, item) } }
                                }
                            }
                            pill("Not mine", destructive: true) { model.dismiss(r, item: item); dismiss() }
                        } else {
                            pill(item.reminderID == nil ? "Remind me to chase" : "Reminder set", prominent: true) { Task { await model.remindMe(r, item: item) } }
                            pill("Not mine", destructive: true) { model.dismiss(r, item: item); dismiss() }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24).padding(.top, 10)
            .presentationBackground(Brand.surface)
        }
    }

    private func pill(_ title: String, prominent: Bool = false, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity).padding(.vertical, 11)
        }
        .buttonStyle(.plain)
        .foregroundStyle(prominent ? Brand.onAct : destructive ? Brand.bad : Brand.text)
        .background(prominent ? Brand.act : Brand.raised, in: Capsule())
    }
}

/// The plumbing: recorded when, how long, which Pocket, where, the file.
struct MomentDetailsSheet: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: Library
    @EnvironmentObject var devices: DeviceStore
    @Environment(\.dismiss) private var dismiss
    let id: String

    var body: some View {
        NavigationStack {
            if let r = library.recordings.first(where: { $0.id == id }) {
                List {
                    Section("Recording") {
                        if let t = r.startedAt { LabeledContent("Recorded", value: t.formatted(date: .abbreviated, time: .shortened)) }
                        if let s = r.meta.seconds { LabeledContent("Length", value: Duration.seconds(s).formatted(.time(pattern: .hourMinuteSecond))) }
                        LabeledContent("Kind", value: r.kind.label + (r.meta.labelKind != nil ? ", your correction" : r.meta.insight?.readByModel == true ? ", as read" : ""))
                        if let l = r.meta.locale { LabeledContent("Language", value: Languages.name(l)) }
                        if r.meta.transcript != nil {
                            LabeledContent("Transcript", value: r.meta.liveTranscript == true ? "Made live while recording" : "Full")
                        }
                        LabeledContent("Pocket", value: "\(r.pocketName(devices.devices)) · \(r.isCall ? "call" : "audio")")
                    }
                    Section("Location") {
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
                            Label(r.meta.place == nil ? "Tag with current location" : "Replace with current location", systemImage: "location")
                        }
                    }
                    Section("File") {
                        LabeledContent("Device file", value: "\(r.day)/\(r.name).mp3")
                        LabeledContent("Size", value: r.size.formatted(.byteCount(style: .file)))
                        if let p = r.meta.pocket {
                            LabeledContent("Pocket ID", value: p.advertised)
                            if let mac = p.mac { LabeledContent("Pocket MAC", value: mac) }
                        }
                        ShareLink(item: r.audioURL) { Label("Share the recording", systemImage: "waveform") }
                        if let t = r.transcriptForModel { ShareLink(item: t) { Label("Share the transcript", systemImage: "text.quote") } }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Brand.ground)
                .navigationTitle("Details")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
        }
        .preferredColorScheme(.dark)
    }
}
