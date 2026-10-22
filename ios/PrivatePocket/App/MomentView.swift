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
    @State private var behind: Behind?
    @State private var showDetails = false
    @State private var showAll = false
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var renamingSpeaker: Int?
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var confirmRedo = false

    private var recording: Recording? { library.recordings.first { $0.id == id } }

    var body: some View {
        if let r = recording {
            let blocks = TranscriptBlock.make(r)
            let current = blocks.last { $0.start <= player.position }?.id
            ZStack(alignment: .top) {
                Brand.ground.ignoresSafeArea()
                RadialGradient(colors: [r.kind.colour.opacity(0.2), .clear],
                               center: UnitPoint(x: 0.5, y: 0), startRadius: 0, endRadius: 420)
                    .ignoresSafeArea()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            MomentHeader(recording: r, rename: {
                                newTitle = r.meta.title ?? ""
                                renaming = true
                            }, renameSpeaker: { i in
                                newName = r.meta.speakerNames?[String(i)] ?? ""
                                renamingSpeaker = i
                            })
                            stage(r)
                            if let brief = r.meta.insight?.brief, !brief.isEmpty {
                                SectionTitle("Summary")
                                BriefText(sentences: brief) { behind = Behind(sentence: $0) }
                                if brief.contains(where: { $0.at != nil }) {
                                    Text("Tap a sentence to hear where it came from.")
                                        .font(.caption).foregroundStyle(Brand.dim).padding(.top, 8)
                                }
                            }
                            TodoSection(recording: r) { behind = Behind(item: $0) }
                            EventSection(recording: r) { behind = Behind(item: $0) }
                            TranscriptSection(recording: r, blocks: blocks, current: current, player: player, showAll: $showAll) { i in
                                newName = r.meta.speakerNames?[String(i)] ?? ""
                                renamingSpeaker = i
                            }
                            AskSection(recording: r)
                            footer(r)
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                    }
                    .onChange(of: current) {
                        guard player.playing, showAll, let c = current else { return }
                        withAnimation { proxy.scrollTo(c, anchor: .center) }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { PlayerBar(player: player, envelope: envelope) }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: model.notes(for: r)) { Image(systemName: "square.and.arrow.up") }
                }
            }
            .sheet(item: $behind) { b in BehindSheet(id: r.id, behind: b, player: player).presentationDetents([.medium]) }
            .sheet(isPresented: $showDetails) { MomentDetailsSheet(id: r.id) }
            .alert("Name this moment", isPresented: $renaming) {
                TextField(r.displayTitle, text: $newTitle)
                Button("Save") { model.rename(r, to: newTitle) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Leave it empty to go back to the title it was given.")
            }
            .alert("Name this speaker", isPresented: Binding(get: { renamingSpeaker != nil }, set: { if !$0 { renamingSpeaker = nil } })) {
                TextField(renamingSpeaker.map { "Speaker \($0 + 1)" } ?? "", text: $newName)
                Button("Save") { if let i = renamingSpeaker { model.renameSpeaker(r, speaker: i, to: newName) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Used wherever this moment names them.")
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
            .onChange(of: player.playing) { if player.playing { showAll = true } }
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

    /// What is happening, by itself, until the moment is ready.
    @ViewBuilder private func stage(_ r: Recording) -> some View {
        let working = model.working.contains(r.id)
        if r.meta.transcript == nil {
            StageRow(title: working ? "Transcribing \(Prefs.sttRemoteNow ? "on your server" : "on this iPhone")…" : "Waiting to be transcribed",
                     detail: working ? "Then it is read for its speakers, a summary, to-dos and events. Nothing for you to do." : nil,
                     spinning: working, action: working ? nil : "Transcribe now") { Task { await model.transcribe(r) } }
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

/// A section's name, in the page's quiet grey.
struct SectionTitle: View {
    let title: String
    var trailing: AnyView? = nil
    init(_ title: String) { self.title = title }
    init<T: View>(_ title: String, @ViewBuilder trailing: () -> T) { self.title = title; self.trailing = AnyView(trailing()) }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Brand.muted)
            Spacer()
            trailing
        }
        .padding(.top, 26).padding(.bottom, 4)
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

/// Kind, title, when, where, and the speakers, identified where they named themselves.
struct MomentHeader: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    let rename: () -> Void
    let renameSpeaker: (Int) -> Void

    /// Speakers by number with their names (or "Speaker N"), then anyone else named.
    private var faces: [(index: Int?, name: String)] {
        let r = recording
        var out: [(Int?, String)] = []
        if let t = r.meta.turns, Speakers.count(t) > 1 {
            for i in Set(t.map(\.speaker)).sorted() { out.append((i, Speakers.name(i, r.meta.speakerNames))) }
        }
        for p in r.meta.insight?.people ?? [] where !out.contains(where: { $0.1.caseInsensitiveCompare(p) == .orderedSame }) {
            out.append((nil, p))
        }
        return out
    }

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
            if !faces.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(faces.enumerated()), id: \.offset) { i, f in
                            let colour = Brand.speakers[(f.index ?? i) % Brand.speakers.count]
                            let unnamed = f.index != nil && (r.meta.speakerNames?[String(f.index!)] ?? "").isEmpty
                            Button {
                                if let idx = f.index { renameSpeaker(idx) }
                            } label: {
                                HStack(spacing: 6) {
                                    Text(String(f.name.prefix(1)).uppercased())
                                        .font(.system(size: 11, weight: .bold))
                                        .frame(width: 24, height: 24)
                                        .background(colour.opacity(0.22), in: Circle())
                                        .foregroundStyle(colour)
                                    Text(f.name).font(.subheadline.weight(.medium)).foregroundStyle(unnamed ? Brand.muted : Brand.text)
                                    if unnamed { Image(systemName: "pencil").font(.caption2).foregroundStyle(Brand.dim) }
                                }
                                .padding(.trailing, 10).padding(.leading, 4).padding(.vertical, 4)
                                .background(Brand.surface, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(f.index == nil)
                        }
                    }
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

/// What the user has to do, each addable to Reminders, and what others promised.
struct TodoSection: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    let open: (NextItem) -> Void

    var body: some View {
        let r = recording
        let items = NextList.ordered(r.meta.insight?.items ?? []).filter { $0.isAction || $0.isPromise }
        if !items.isEmpty {
            let unplaced = items.filter { $0.isAction && $0.reminderID == nil && !$0.isDone }
            SectionTitle("To do") {
                if unplaced.count > 1 {
                    Button("Add all to Reminders") { Task { for i in unplaced { await model.place(r, i) } } }
                        .font(.caption.weight(.semibold))
                }
            }
            ForEach(items) { item in
                NextRow(recording: r, item: item) { open(item) }
                Divider().overlay(Brand.hairline)
            }
        }
    }
}

/// Meetings, deadlines and dates, each addable to Calendar.
struct EventSection: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    let open: (NextItem) -> Void

    var body: some View {
        let r = recording
        let items = NextList.ordered(r.meta.insight?.items ?? []).filter(\.isDate)
        if !items.isEmpty {
            SectionTitle("Events")
            ForEach(items) { item in
                NextRow(recording: r, item: item) { open(item) }
                Divider().overlay(Brand.hairline)
            }
        }
    }
}

/// Ordering shared by the sections and the notes.
enum NextList {
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
            trailing
        }
        .padding(.vertical, 11)
    }

    @ViewBuilder private var trailing: some View {
        if item.isAction {
            if item.reminderID != nil {
                Text("Added").font(.footnote.weight(.semibold)).foregroundStyle(Brand.good)
            } else if !item.isDone {
                Button("Add") { Task { await model.place(recording, item) } }.font(.footnote.weight(.semibold))
            }
        } else if item.isDate {
            if item.eventID != nil {
                Text("Added").font(.footnote.weight(.semibold)).foregroundStyle(Brand.good)
            } else if item.date != nil {
                Button("Add") { Task { await model.place(recording, item) } }.font(.footnote.weight(.semibold))
            }
        } else {
            Button(item.reminderID == nil ? "Remind me" : "Set") { Task { await model.remindMe(recording, item: item) } }
                .font(.footnote.weight(.semibold)).disabled(item.reminderID != nil)
        }
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
        if item.isPromise, let who = item.who { return [who, item.when].compactMap { $0 }.joined(separator: " · ") }
        return item.when
    }
}

// MARK: - The recording

/// Play, and the shape of the audio: grey until played, amber once played; drag to seek.
struct PlayerBar: View {
    @ObservedObject var player: Player
    let envelope: [Float]

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
                WaveformView(envelope: envelope, progress: player.position / total) { player.seek($0 * total) }
                    .frame(height: 26)
                HStack {
                    Text(Speakers.stamp(player.position))
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
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                // Fixed 3-point bars with 2-point gaps, as many as fit; the envelope is
                // resampled to that count, so a bar is never thinner than its corners.
                let bw: CGFloat = 3, gap: CGFloat = 2
                let n = max(8, Int((size.width + gap) / (bw + gap)))
                let lit = Int((progress * Double(n)).rounded(.down))
                for i in 0..<n {
                    let v: CGFloat
                    if envelope.isEmpty {
                        v = 0.22
                    } else {
                        let j = min(envelope.count - 1, i * envelope.count / n)
                        v = CGFloat(max(envelope[j], 0.06))
                    }
                    let h = max(4, v * (size.height - 4))
                    let x = CGFloat(i) * (bw + gap)
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: (size.height - h) / 2, width: bw, height: h), cornerRadius: bw / 2),
                             with: .color(i < lit ? Brand.record : Color.white.opacity(0.3)))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in seek(max(0, min(1, g.location.x / geo.size.width))) })
        }
    }
}

/// The shape of a recording: the loudness of each of a hundred or so slices, on a
/// gentle curve, scaled so one loud moment does not flatten the rest.
enum Waveform {
    nonisolated static func envelope(url: URL, slices: Int = 120) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let frames = Int(file.length)
        guard frames > 0 else { return [] }
        let per = max(1, frames / slices)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(per)) else { return [] }
        var out: [Float] = []
        for _ in 0..<slices {
            do { try file.read(into: buf, frameCount: AVAudioFrameCount(per)) } catch { break }
            let n = Int(buf.frameLength)
            guard n > 0, let ch = buf.floatChannelData?[0] else { break }
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            out.append(pow((sum / Float(n)).squareRoot(), 0.6))
        }
        guard !out.isEmpty else { return [] }
        let sorted = out.sorted()
        let top = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        return top > 0 ? out.map { min(1, $0 / top) } : out
    }
}

/// The transcript, inline: a few turns, or all of them; follows the audio while playing.
struct TranscriptSection: View {
    let recording: Recording
    let blocks: [TranscriptBlock]
    let current: Int?
    @ObservedObject var player: Player
    @Binding var showAll: Bool
    let renameSpeaker: (Int) -> Void

    var body: some View {
        let r = recording
        if !blocks.isEmpty {
            let speakers = r.meta.turns.map { Speakers.count($0) } ?? 1
            SectionTitle("Transcript") {
                HStack(spacing: 10) {
                    Text([speakers > 1 ? "\(speakers) speakers" : nil, r.meta.locale.map { Languages.name($0) }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(Brand.dim)
                    if blocks.count > 3 {
                        Button(showAll ? "Less" : "Show all") { withAnimation { showAll.toggle() } }.font(.caption.weight(.semibold))
                    }
                }
            }
            ForEach(showAll ? blocks : Array(blocks.prefix(3))) { b in
                TranscriptBlockRow(block: b, names: r.meta.speakerNames, position: b.id == current ? player.position : nil, onRename: renameSpeaker)
                    .id(b.id)
                    .padding(.horizontal, 8)
                    .background(b.id == current && player.playing ? Brand.record.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onTapGesture { player.play(from: b.start) }
            }
            Text(blocks.count > 3 && !showAll ? "Tap a line to play from there. Play, and the rest follows." : "Tap a line to play from there.")
                .font(.caption).foregroundStyle(Brand.dim).padding(.top, 6)
        }
    }
}

/// Questions about this moment, answered from its transcript, in place.
struct AskSection: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    @State private var question = ""
    @FocusState private var typing: Bool

    var body: some View {
        let r = recording
        let conversation = model.conversations[r.id] ?? []
        let busy = conversation.last.map { $0.answer == nil && $0.error == nil } ?? false
        SectionTitle("Ask")
        ForEach(conversation) { qa in
            VStack(alignment: .leading, spacing: 6) {
                Text(qa.question).font(.subheadline.weight(.semibold))
                if let a = qa.answer {
                    Text(a).font(.body).foregroundStyle(Brand.textSecondary).textSelection(.enabled)
                } else if let e = qa.error {
                    Text(e).font(.subheadline).foregroundStyle(Brand.muted)
                } else {
                    HStack { ProgressView().controlSize(.small); Text(qa.progress ?? "Thinking…").font(.subheadline).foregroundStyle(Brand.muted) }
                }
            }
            .padding(.vertical, 10)
            Divider().overlay(Brand.hairline)
        }
        HStack(spacing: 10) {
            TextField("Anything about this moment…", text: $question, axis: .vertical)
                .lineLimit(1...3).focused($typing).submitLabel(.send).onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(Brand.onAct)
                    .frame(width: 30, height: 30).background(Brand.act, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || busy || r.meta.transcript == nil || Summariser.availability != nil)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.top, 8)
        Text(Summariser.availability ?? (r.meta.transcript == nil ? "Once it is transcribed." : "Answered from this conversation only, \(Prefs.llmRemoteNow ? "on your server" : "on this iPhone")."))
            .font(.caption).foregroundStyle(Brand.dim).padding(.top, 6)
    }

    private func send() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        question = ""
        typing = false
        let r = recording
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
