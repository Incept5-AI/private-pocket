import SwiftUI

/// Threads: everything you keep talking about. What is back after a long quiet first,
/// then what is live, ranked by how recent, how large and how open, then the quiet ones.
/// A thread is kept (`ThreadStore`): rename it, merge it, split it, add a moment, or say
/// it is not a thread, and the next reading leaves that alone.
struct ThreadsView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var threads: ThreadStore
    @State private var mending = ThreadMending()

    var body: some View {
        let all = library.recordings
        let live = threads.live(all)
        let back = live.filter(\.isBack).sorted { ($0.last ?? .distantPast) > ($1.last ?? .distantPast) }
        let alive = live.filter { !$0.isBack && $0.isLive }.sorted { $0.weight > $1.weight }
        let quiet = live.filter { !$0.isLive }.sorted { ($0.last ?? .distantPast) > ($1.last ?? .distantPast) }
        let hints = threads.mergeHints(live)
        let axis = ThreadAxis(live)
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("What keeps coming up").font(.footnote.weight(.semibold)).foregroundStyle(Brand.muted)
                        Text("Threads").font(.largeTitle.weight(.bold)).tracking(-0.5)
                    }
                    .padding(.top, 8)
                    if live.isEmpty {
                        Text("A thread appears once something comes up in two conversations. Nothing has yet.")
                            .font(.subheadline).foregroundStyle(Brand.muted)
                    }
                    ForEach(back) { t in
                        NavigationLink(value: ThreadLink(id: t.id)) { BackCard(thread: t) }
                            .buttonStyle(.plain)
                            .contextMenu { ThreadMenuItems(thread: t, live: live, mending: $mending) }
                    }
                    if !alive.isEmpty {
                        Text("LIVE").font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(Brand.muted).padding(.top, 6)
                        ForEach(alive) { t in
                            card(t, hint: hints.first { $0.from.id == t.id }, axis: axis)
                                .contextMenu { ThreadMenuItems(thread: t, live: live, mending: $mending) }
                        }
                    }
                    if !quiet.isEmpty {
                        Text("QUIET").font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(Brand.muted).padding(.top, 10)
                        ForEach(quiet.prefix(40)) { t in
                            NavigationLink(value: ThreadLink(id: t.id)) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(t.name).font(.body.weight(.semibold)).foregroundStyle(Brand.textSecondary).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(t.last.map { "quiet since \(ThreadText.month($0))" } ?? "").font(.caption.weight(.semibold)).foregroundStyle(Brand.dim)
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu { ThreadMenuItems(thread: t, live: live, mending: $mending) }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 28)
            }
            .background(Brand.ground)
            .toolbar(.hidden, for: .navigationBar)
            .modifier(ThreadMendingSheets(mending: $mending))
            .task(id: all.map { "\($0.id)@\(Int($0.meta.analysedAt?.timeIntervalSince1970 ?? 0))" }.joined()) { threads.discover(all) }
            .navigationDestination(for: ThreadLink.self) { ThreadView(id: $0.id) }
            .navigationDestination(for: String.self) { id in RecordingDetail(id: id) }
            .navigationDestination(for: MomentsFilter.self) { f in FilteredMoments(filter: f) }
        }
    }

    /// A live thread: its row, and under it the merge it looks like it wants, if any.
    private func card(_ t: LiveThread, hint: ThreadStore.MergeHint?, axis: ThreadAxis) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink(value: ThreadLink(id: t.id)) { ThreadRow(thread: t, axis: axis) }
                .buttonStyle(.plain)
            if let hint {
                Rectangle().fill(Brand.hairline).frame(height: 1).padding(.horizontal, 16)
                HStack(spacing: 8) {
                    Text("Part of \(hint.into.name)?").font(.footnote.weight(.semibold)).foregroundStyle(Brand.notice).lineLimit(1)
                    Spacer(minLength: 6)
                    Button { withAnimation { threads.merge(t.id, into: hint.into.id) } } label: {
                        Text("Merge").font(.footnote.weight(.bold)).padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Brand.act, in: Capsule()).foregroundStyle(Brand.onAct)
                    }
                    .buttonStyle(.plain)
                    Button { withAnimation { threads.keepApart(t.id, hint.into.id) } } label: {
                        Text("Keep apart").font(.footnote.weight(.bold)).padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Brand.raised, in: Capsule()).foregroundStyle(Brand.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

enum ThreadText {
    /// "1 moment", "2 moments".
    static func moments(_ n: Int) -> String { n == 1 ? "1 moment" : "\(n) moments" }

    /// "March", or "March 2025" when it is not this year.
    static func month(_ d: Date) -> String {
        Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year)
            ? d.formatted(.dateTime.month(.wide)) : d.formatted(.dateTime.month(.wide).year())
    }

    /// "today", "14 Mar".
    static func short(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? "today" : d.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// A live thread in the list: name, how open, when it was spoken, and who.
struct ThreadRow: View {
    let thread: LiveThread
    let axis: ThreadAxis

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(thread.name).font(.headline).lineLimit(1)
                Spacer(minLength: 6)
                ThreadPill(thread: thread)
            }
            ThreadStrip(dates: thread.moments.compactMap(\.startedAt), axis: axis, ink: Brand.textSecondary)
                .frame(height: 12)
            Text(meta).font(.footnote).foregroundStyle(Brand.textSecondary).lineLimit(2)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var meta: String {
        var parts = [ThreadText.moments(thread.moments.count)]
        if let f = thread.first { parts.append("since \(ThreadText.month(f))") }
        if !thread.people.isEmpty { parts.append("with " + thread.people.prefix(2).joined(separator: ", ")) }
        if let o = thread.alive.first(where: { $0.item.isAction }) { parts.append("yours: \(o.item.text.lowercased())") }
        return parts.joined(separator: " · ")
    }
}

struct ThreadPill: View {
    let thread: LiveThread

    var body: some View {
        let (text, bg, fg): (String, Color, Color) = {
            if !thread.lapsed.isEmpty { return ("\(thread.lapsed.count) lapsed", Brand.life, Brand.onLife) }
            if !thread.alive.isEmpty { return ("\(thread.alive.count) open", Brand.raised, Brand.textSecondary) }
            return ("settled", Brand.surface, Brand.dim)
        }()
        Text(text).font(.caption.weight(.bold)).padding(.horizontal, 9).padding(.vertical, 4)
            .background(bg, in: Capsule()).foregroundStyle(fg).fixedSize()
    }
}

/// A thread spoken again after a long quiet, at the top of the list.
struct BackCard: View {
    let thread: LiveThread

    var body: some View {
        let latest = thread.last ?? Date()
        let gap = Ageing.span(thread.gapBeforeLast ?? 0)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("BACK · AFTER \(gap.uppercased())").font(.caption2.weight(.bold)).tracking(0.7).opacity(0.75)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).opacity(0.6)
            }
            Text(thread.name).font(.title2.weight(.bold)).tracking(-0.3)
            if let rc = thread.recall(before: latest) {
                Text("Spoken \(Findings.dayName(latest)), after \(gap). Last time, \(rc.date.formatted(.dateTime.day().month(.wide))): \(rc.line)")
                    .font(.subheadline.weight(.medium)).lineSpacing(1).fixedSize(horizontal: false, vertical: true)
            }
            ThreadTimeline(dates: thread.moments.compactMap(\.startedAt), ink: Brand.onNotice)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.notice, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .foregroundStyle(Brand.onNotice)
    }
}

/// The return, as a block on Now: the thread is back, and what was said last time.
struct ReturnBlock: View {
    let thread: LiveThread
    let open: () -> Void

    var body: some View {
        let latest = thread.last ?? Date()
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("NOTICED · BACK AFTER \(Ageing.span(thread.gapBeforeLast ?? 0).uppercased())").font(.caption2.weight(.bold)).tracking(0.7).foregroundStyle(Brand.onNotice.opacity(0.75))
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Brand.onNotice.opacity(0.6))
            }
            Text("\(thread.name) again.").font(.title3.weight(.bold))
            if let rc = thread.recall(before: latest) {
                Text("Last time, \(rc.date.formatted(.dateTime.day().month(.wide))): \(rc.line)")
                    .font(.subheadline).lineSpacing(2).foregroundStyle(Brand.onNotice.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
            }
            ThreadTimeline(dates: thread.moments.compactMap(\.startedAt), ink: Brand.onNotice)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.notice, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .foregroundStyle(Brand.onNotice)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture(perform: open)
    }
}

/// A thread named in the room: what was said last time, in the live block and the table.
struct ThreadHintBox: View {
    let hint: ThreadHint
    var large = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text((hint.name + (hint.last.map { " · last spoken \(Findings.dayName($0))" } ?? "")).uppercased())
                .font((large ? Font.caption : .caption2).weight(.bold)).tracking(0.6).foregroundStyle(Brand.notice)
            Text(hint.line).font((large ? Font.title3 : .subheadline).weight(.semibold))
                .foregroundStyle(Color(hex: 0xFFF7E8)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(large ? 14 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.onRecord, in: RoundedRectangle(cornerRadius: large ? 18 : 14, style: .continuous))
    }
}

// MARK: - Time, drawn

/// The span the list's strips share, so threads can be compared by eye: a year at most.
struct ThreadAxis {
    let start: Date
    let end: Date

    init(_ live: [LiveThread], now: Date = Date()) {
        let earliest = live.compactMap(\.first).min() ?? now.addingTimeInterval(-60 * 86_400)
        start = max(earliest, now.addingTimeInterval(-365 * 86_400))
        end = now
    }

    func fraction(_ d: Date) -> CGFloat {
        let span = max(1, end.timeIntervalSince(start))
        return CGFloat(min(1, max(0, d.timeIntervalSince(start) / span)))
    }
}

/// A thread's moments as dots on the shared span; a long quiet is dashed.
struct ThreadStrip: View {
    let dates: [Date]
    let axis: ThreadAxis
    let ink: Color

    var body: some View {
        Canvas { ctx, size in
            let y = size.height / 2, pad: CGFloat = 4, w = size.width - 2 * pad
            let ds = dates.sorted()
            func x(_ d: Date) -> CGFloat { pad + w * axis.fraction(d) }
            var base = Path()
            base.move(to: CGPoint(x: pad, y: y))
            base.addLine(to: CGPoint(x: pad + w, y: y))
            ctx.stroke(base, with: .color(ink.opacity(0.14)), lineWidth: 1.5)
            for (a, b) in zip(ds, ds.dropFirst()) {
                var p = Path()
                p.move(to: CGPoint(x: x(a), y: y))
                p.addLine(to: CGPoint(x: x(b), y: y))
                let quiet = b.timeIntervalSince(a) >= 30 * 86_400
                ctx.stroke(p, with: .color(ink.opacity(quiet ? 0.6 : 0.45)), style: StrokeStyle(lineWidth: 1.5, dash: quiet ? [2, 3] : []))
            }
            for d in ds {
                let r: CGFloat = 3.2
                ctx.fill(Path(ellipseIn: CGRect(x: x(d) - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(ink))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A thread's own span, from its first moment to now, with the months over it: the
/// moments as dots, a quiet of a month or more dashed, the latest larger.
struct ThreadTimeline: View {
    let dates: [Date]
    let ink: Color

    var body: some View {
        Canvas { ctx, size in
            let ds = dates.sorted()
            guard let first = ds.first else { return }
            let now = Date()
            let start = first.addingTimeInterval(-86_400), end = max(now, ds.last ?? now)
            let span = max(86_400, end.timeIntervalSince(start))
            let pad: CGFloat = 7, w = size.width - 2 * pad, y = size.height - 8
            func x(_ d: Date) -> CGFloat { pad + w * CGFloat(d.timeIntervalSince(start) / span) }
            let cal = Calendar.current
            if span > 45 * 86_400 {
                var labels: [(CGFloat, String)] = []
                var m = cal.date(from: cal.dateComponents([.year, .month], from: start)) ?? start
                while m <= end, labels.count < 20 {
                    let mid = cal.date(byAdding: .day, value: 14, to: m) ?? m
                    if mid >= start, mid <= end { labels.append((x(mid), m.formatted(.dateTime.month(.narrow)))) }
                    m = cal.date(byAdding: .month, value: 1, to: m) ?? end.addingTimeInterval(1)
                }
                if labels.count <= 13 {
                    for (lx, t) in labels {
                        ctx.draw(Text(t).font(.caption2.weight(.heavy)).foregroundStyle(ink.opacity(0.7)), at: CGPoint(x: lx, y: 7))
                    }
                }
            }
            for (a, b) in zip(ds, ds.dropFirst()) {
                var p = Path()
                p.move(to: CGPoint(x: x(a), y: y))
                p.addLine(to: CGPoint(x: x(b), y: y))
                let quiet = b.timeIntervalSince(a) >= 30 * 86_400
                ctx.stroke(p, with: .color(ink.opacity(quiet ? 0.6 : 0.4)), style: StrokeStyle(lineWidth: 1.5, dash: quiet ? [2, 4] : []))
            }
            if let last = ds.last, now.timeIntervalSince(last) > 86_400 {
                var p = Path()
                p.move(to: CGPoint(x: x(last), y: y))
                p.addLine(to: CGPoint(x: pad + w, y: y))
                ctx.stroke(p, with: .color(ink.opacity(0.25)), style: StrokeStyle(lineWidth: 1.5, dash: [1, 3]))
            }
            for (i, d) in ds.enumerated() {
                let r: CGFloat = i == ds.count - 1 ? 5 : 3.5
                ctx.fill(Path(ellipseIn: CGRect(x: x(d) - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(ink))
            }
        }
        .frame(height: 30)
        .accessibilityHidden(true)
    }
}

// MARK: - A thread's page

/// A thread as history: the story rewritten as each moment joins, what changed and when,
/// what is open by its age, what to raise next time, and its moments with the quiets
/// between them.
struct ThreadView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: Library
    @EnvironmentObject var threads: ThreadStore
    @EnvironmentObject var link: PocketLink
    @EnvironmentObject var live: LiveSession
    let id: String
    @State private var mending = ThreadMending()
    @State private var allChanges = false

    var body: some View {
        let all = library.recordings
        let threadsNow = threads.live(all)
        let target = threads.resolve(id)?.id ?? id
        if let t = threadsNow.first(where: { $0.id == target }) {
            page(t, live: threadsNow)
                .modifier(ThreadMendingSheets(mending: $mending))
                .task(id: t.moments.map(\.id).joined(separator: ",")) { await threads.catchUp(t) }
                .onAppear { model.pageContext = RecordContext(thread: t.id, threadName: t.name) }
                .onDisappear { if model.pageContext?.thread == t.id { model.pageContext = nil } }
        } else {
            ContentUnavailableView("This thread has gone", systemImage: "line.3.horizontal",
                                   description: Text("It was merged, split away, or marked as not a thread."))
                .background(Brand.ground)
        }
    }

    private func page(_ t: LiveThread, live all: [LiveThread]) -> some View {
        let work = t.isWork
        let into = model.recordingContext?.thread.flatMap { threads.resolve($0)?.id }
        let recordingInto = link.status.recordingSince != nil && into == t.id
        let doubted = (t.record.doubted ?? []).compactMap { d in t.moments.first { $0.id == d } }
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(t, tint: work ? Brand.work : Brand.life, ink: work ? Brand.onWork : Brand.onLife)
                if recordingInto { recordingBand(t) }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(doubted) { r in doubtCard(r, t) }
                    story(t)
                    changesSection(t)
                    openSection(t)
                    nextTime(t)
                    momentsSection(t)
                }
                .padding(.horizontal, 24).padding(.bottom, 28)
            }
        }
        .background(Brand.ground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { RecordButton(size: 30) }
            ToolbarItem(placement: .topBarTrailing) {
                Menu { ThreadMenuItems(thread: t, live: all, mending: $mending) } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("Mend this thread")
            }
        }
    }

    private func header(_ t: LiveThread, tint: Color, ink: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ThreadText.moments(t.moments.count) + (t.first.map { " · since \(ThreadText.month($0))" } ?? ""))
                    .font(.caption2.weight(.bold)).tracking(0.7).textCase(.uppercase).opacity(0.75)
                Spacer(minLength: 6)
                if t.isBack, let g = t.gapBeforeLast {
                    Text("Back · \(Ageing.span(g))").font(.caption2.weight(.bold)).tracking(0.5).textCase(.uppercase)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Brand.notice, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .foregroundStyle(Brand.onNotice)
                }
            }
            Text(t.name).font(.largeTitle.weight(.bold)).tracking(-0.6)
                .onTapGesture { mending.name = t.name; mending.renaming = t }
            let others = t.record.aliases.filter { $0 != t.name.lowercased() }
            if !others.isEmpty {
                Text("also " + others.prefix(3).map { "“\($0)”" }.joined(separator: ", ")).font(.caption.weight(.semibold)).opacity(0.8)
            }
            ThreadTimeline(dates: t.moments.compactMap(\.startedAt), ink: ink)
            Text(summary(t)).font(.caption.weight(.semibold)).opacity(0.85)
        }
        .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint)
        .foregroundStyle(ink)
    }

    private func summary(_ t: LiveThread) -> String {
        var s = "\(t.alive.count) open · \(t.settled) settled"
        if !t.lapsed.isEmpty { s += " · \(t.lapsed.count) lapsed" }
        return s
    }

    private func recordingBand(_ t: LiveThread) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recording into \(t.name)").font(.caption2.weight(.bold)).tracking(0.7).textCase(.uppercase).opacity(0.75)
            LiveLine().font(.callout.weight(.semibold)).lineLimit(2)
            Text("The reader is told it is probably \(t.name).").font(.caption2.weight(.semibold)).opacity(0.7)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.record)
        .foregroundStyle(Brand.onRecord)
    }

    private func doubtCard(_ r: Recording, _ t: LiveThread) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("“\(r.displayTitle)” was recorded into \(t.name), but it reads as something else.").font(.callout.weight(.semibold))
            HStack(spacing: 10) {
                Button { threads.keep(r.id, in: t.id) } label: { capsule("Keep it here", Brand.act, Brand.onAct) }.buttonStyle(.plain)
                Button { threads.exclude(r.id, from: t.id) } label: { capsule("Take it out", Brand.raised, Brand.textSecondary) }.buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.top, 18)
    }

    private func capsule(_ text: String, _ bg: Color, _ fg: Color) -> some View {
        Text(text).font(.subheadline.weight(.bold)).padding(.horizontal, 14).padding(.vertical, 8)
            .background(bg, in: Capsule()).foregroundStyle(fg)
    }

    private func story(_ t: LiveThread) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("The story so far") {
                if threads.reading.contains(t.id) {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Reading").font(.caption) }.foregroundStyle(Brand.muted)
                } else if let u = t.record.state?.updated {
                    Text("rewritten \(Findings.dayName(u))").font(.caption).foregroundStyle(Brand.dim)
                }
            }
            Text(t.record.state?.story ?? t.plainStory)
                .font(.body.weight(.medium)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func changesSection(_ t: LiveThread) -> some View {
        let changes = t.changes
        if !changes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("What changed")
                ForEach(allChanges ? changes : Array(changes.prefix(5))) { c in
                    NavigationLink(value: c.recordingID ?? "") {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(ThreadText.short(c.at)).font(.caption.weight(.bold)).foregroundStyle(Brand.muted).frame(width: 50, alignment: .leading)
                            ChangeTag(kind: c.kind, label: c.label)
                            Text(c.text).font(.callout.weight(.semibold)).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(c.recordingID == nil)
                }
                if changes.count > 5 {
                    Button(allChanges ? "Fewer" : "All \(changes.count) changes") { withAnimation { allChanges.toggle() } }
                        .font(.footnote.weight(.bold)).tint(Brand.act)
                }
            }
        }
    }

    @ViewBuilder private func openSection(_ t: LiveThread) -> some View {
        if !t.open.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Open, by age")
                ForEach(t.open) { o in
                    NavigationLink(value: o.recording.id) { OpenRow(open: o) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { model.setDone(o.recording, item: o.item, done: true) } label: { Label("Done", systemImage: "checkmark.circle") }
                            Button(role: .destructive) { model.dismiss(o.recording, item: o.item) } label: { Label("Not mine", systemImage: "xmark") }
                        }
                }
            }
        }
    }

    @ViewBuilder private func nextTime(_ t: LiveThread) -> some View {
        let parts = Self.nextTimeParts(t)
        if !parts.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("NEXT TIME IT COMES UP").font(.caption2.weight(.bold)).tracking(0.7).foregroundStyle(Brand.onAct.opacity(0.7))
                Text((parts.joined(separator: ", ") + ".").capitalizedFirst).font(.callout.weight(.semibold)).foregroundStyle(Brand.onAct)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.act, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.top, 24)
        }
    }

    static func nextTimeParts(_ t: LiveThread) -> [String] {
        var parts: [String] = []
        func small(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }
        for p in t.alive.filter({ $0.item.isPromise }).prefix(2) {
            if let who = p.item.who { parts.append("ask \(who) about the promise to \(p.item.promisedAct)") }
        }
        for q in t.moments.suffix(3).flatMap({ $0.meta.insight?.questions ?? [] }).prefix(1) { parts.append("settle \(small(q))") }
        for y in t.alive.filter({ $0.item.isAction }).prefix(1) { parts.append("bring \(small(y.item.text))") }
        if parts.count < 3, let l = t.lapsed.first {
            if l.item.isPromise, let who = l.item.who { parts.append("ask \(who) whether the promise to \(l.item.promisedAct) still stands") }
            else { parts.append("decide whether to \(small(l.item.text)) or let it go") }
        }
        return parts
    }

    private func momentsSection(_ t: LiveThread) -> some View {
        let ms = Array(t.moments.reversed())
        return VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Its " + ThreadText.moments(ms.count))
            ForEach(Array(ms.enumerated()), id: \.element.id) { i, r in
                NavigationLink(value: r.id) { TapeBand(recording: r) }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) { threads.exclude(r.id, from: t.id) } label: { Label("Not part of this", systemImage: "minus.circle") }
                    }
                if i + 1 < ms.count, let a = r.startedAt, let b = ms[i + 1].startedAt, a.timeIntervalSince(b) >= 30 * 86_400 {
                    QuietGap(days: Int(a.timeIntervalSince(b) / 86_400))
                }
            }
        }
    }
}

/// Something open in a thread, with who owes it and how old it is.
struct OpenRow: View {
    let open: OpenItem

    var body: some View {
        let o = open
        HStack(spacing: 10) {
            let theirs = o.item.isPromise
            Text(theirs ? String((o.item.who ?? "?").prefix(1)).uppercased() : "You").font(.caption2.weight(.bold))
                .frame(width: 32, height: 32)
                .background(theirs ? Brand.work : Brand.act, in: Circle())
                .foregroundStyle(theirs ? Brand.onWork : Brand.onAct)
            VStack(alignment: .leading, spacing: 1) {
                Text(o.label).font(.callout.weight(.semibold)).lineLimit(2)
                Text(age).font(.caption).foregroundStyle(Brand.muted)
            }
            Spacer(minLength: 6)
            let (text, bg, fg): (String, Color, Color) = o.renewed ? ("again", Brand.life, Brand.onLife)
                : o.lapsedAt != nil ? ("lapsed", Brand.life, Brand.onLife)
                : theirs ? ("open", Brand.raised, Brand.textSecondary) : ("yours", Brand.act, Brand.onAct)
            Text(text).font(.caption2.weight(.bold)).padding(.horizontal, 8).padding(.vertical, 4)
                .background(bg, in: Capsule()).foregroundStyle(fg).fixedSize()
        }
        .contentShape(Rectangle())
    }

    private var age: String {
        let o = open
        let days = max(0, Int(Date().timeIntervalSince(o.since) / 86_400))
        if o.renewed { return "first said \(ThreadText.short(o.since)) · said again \(o.recording.startedAt.map { Findings.dayName($0) } ?? "")" }
        if let l = o.lapsedAt { return "since \(ThreadText.short(o.since)) · lapsed \(ThreadText.month(l))" }
        if let w = o.item.when { return "\(w) · said \(Findings.dayName(o.since))" }
        return days == 0 ? "said today" : "\(Ageing.span(days)) open"
    }
}

struct ChangeTag: View {
    let kind: String
    let label: String

    var body: some View {
        let (bg, fg): (Color, Color) = {
            switch kind {
            case "reversed", "changed": return (Brand.notice, Brand.onNotice)
            case "renewed", "settled", "done": return (Brand.act, Brand.onAct)
            case "lapsed": return (Brand.life, Brand.onLife)
            case "same": return (Brand.raised, Brand.textSecondary)
            default: return (Brand.raised, Brand.text)
            }
        }()
        Text(label).font(.caption2.weight(.heavy)).tracking(0.6).textCase(.uppercase)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(bg, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .foregroundStyle(fg)
            .fixedSize()
    }
}

/// "— 7 months quiet —", between a thread's moments.
struct QuietGap: View {
    let days: Int

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Brand.hairline).frame(height: 1)
            Text("\(Ageing.span(days)) quiet").font(.caption2.weight(.bold)).foregroundStyle(Brand.dim).fixedSize()
            Rectangle().fill(Brand.hairline).frame(height: 1)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Mending

struct ThreadMending {
    var renaming: LiveThread?
    var name = ""
    var splitting: LiveThread?
    var pinning: LiveThread?
}

/// Rename, merge, add a moment, split, not a thread: the same menu on a row and a page.
struct ThreadMenuItems: View {
    @EnvironmentObject var threads: ThreadStore
    let thread: LiveThread
    let live: [LiveThread]
    @Binding var mending: ThreadMending

    var body: some View {
        Button { mending.name = thread.name; mending.renaming = thread } label: { Label("Rename", systemImage: "pencil") }
        let mine = Set(thread.moments.map(\.id))
        let others = live.filter { $0.id != thread.id }
            .map { (t: $0, shared: Set($0.moments.map(\.id)).intersection(mine).count) }
            .sorted { ($0.shared, $0.t.weight) > ($1.shared, $1.t.weight) }
            .prefix(8).map(\.t)
        if !others.isEmpty {
            Menu {
                ForEach(others) { o in Button(o.name) { withAnimation { threads.merge(thread.id, into: o.id) } } }
            } label: { Label("Merge into…", systemImage: "arrow.triangle.merge") }
        }
        Button { mending.pinning = thread } label: { Label("Add a moment…", systemImage: "pin") }
        if thread.moments.count > 1 {
            Button { mending.splitting = thread } label: { Label("Split…", systemImage: "arrow.triangle.branch") }
        }
        Button(role: .destructive) { withAnimation { threads.hide(thread.id) } } label: { Label("Not a thread", systemImage: "xmark") }
    }
}

struct ThreadMendingSheets: ViewModifier {
    @EnvironmentObject var threads: ThreadStore
    @Binding var mending: ThreadMending

    func body(content: Content) -> some View {
        content
            .alert("Name this thread", isPresented: Binding(get: { mending.renaming != nil }, set: { if !$0 { mending.renaming = nil } })) {
                TextField("Name", text: $mending.name)
                Button("Save") { if let t = mending.renaming { threads.rename(t.id, to: mending.name) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The new name finds its moments too.")
            }
            .sheet(item: $mending.splitting) { t in SplitSheet(thread: t) }
            .sheet(item: $mending.pinning) { t in PinSheet(thread: t) }
    }
}

/// Pick the moments that are a thread of their own, and name it.
struct SplitSheet: View {
    @EnvironmentObject var threads: ThreadStore
    @Environment(\.dismiss) private var dismiss
    let thread: LiveThread
    @State private var chosen: Set<String> = []
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Name of the new thread", text: $name)
                } footer: {
                    Text("The moments you pick leave \(thread.name) and start a thread of their own.")
                }
                Section("Moments") {
                    ForEach(Array(thread.moments.reversed())) { r in
                        Button {
                            if chosen.contains(r.id) { chosen.remove(r.id) } else { chosen.insert(r.id) }
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.quote).font(.callout.weight(.semibold)).lineLimit(2)
                                    Text(r.startedAt.map { ThreadText.short($0) } ?? r.day).font(.caption).foregroundStyle(Brand.muted)
                                }
                                Spacer()
                                Image(systemName: chosen.contains(r.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(chosen.contains(r.id) ? Brand.act : Brand.dim)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.ground)
            .navigationTitle("Split \(thread.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Split") {
                        threads.split(thread.id, moments: Array(chosen), name: name)
                        dismiss()
                    }
                    .disabled(chosen.isEmpty || chosen.count == thread.moments.count || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// Put a moment into a thread by hand: the recent ones that are not in it yet.
struct PinSheet: View {
    @EnvironmentObject var threads: ThreadStore
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    let thread: LiveThread

    var body: some View {
        let mine = Set(thread.moments.map(\.id))
        let recent = library.recordings.filter { !mine.contains($0.id) && $0.meta.transcript != nil }.prefix(40)
        NavigationStack {
            List {
                Section {
                    ForEach(Array(recent)) { r in
                        Button {
                            threads.pin(r.id, to: thread.id)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.quote).font(.callout.weight(.semibold)).lineLimit(2)
                                Text(r.startedAt.map { ThreadText.short($0) } ?? r.day).font(.caption).foregroundStyle(Brand.muted)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("A moment put in by hand stays in \(thread.name), whatever it says.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.ground)
            .navigationTitle("Add to \(thread.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

// MARK: - On a moment

/// The threads a moment is in, what it continues and what continued it, with a way to
/// add it to a thread or take it out; and the question when it was recorded into a thread
/// it does not seem to be about.
struct MomentThreads: View {
    @EnvironmentObject var threads: ThreadStore
    @EnvironmentObject var library: Library
    let recording: Recording
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        let all = library.recordings
        let live = threads.live(all)
        let mine = threads.threads(of: recording.id, in: live)
        let parent = recording.meta.context?.moment.flatMap { id in all.first { $0.id == id } }
        let children = all.filter { $0.meta.context?.moment == recording.id }
        let doubted = live.filter { ($0.record.doubted ?? []).contains(recording.id) }
        let into = recording.meta.context?.thread.flatMap { threads.resolve($0)?.id }
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let p = parent {
                        NavigationLink(value: p.id) { chip("Continues: \(p.displayTitle)", "arrow.turn.down.right", Brand.surface, Brand.textSecondary) }
                            .buttonStyle(.plain)
                    }
                    ForEach(children) { c in
                        NavigationLink(value: c.id) { chip("Followed by: \(c.displayTitle)", "arrow.turn.down.left", Brand.surface, Brand.textSecondary) }
                            .buttonStyle(.plain)
                    }
                    ForEach(mine) { t in
                        NavigationLink(value: ThreadLink(id: t.id)) {
                            chip((t.id == into ? "Continues " : "") + t.name, "line.3.horizontal", t.isWork ? Brand.work : Brand.life, t.isWork ? Brand.onWork : Brand.onLife)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) { threads.exclude(recording.id, from: t.id) } label: { Label("Not part of \(t.name)", systemImage: "minus.circle") }
                        }
                    }
                    Menu {
                        ForEach(Array(live.filter { t in !mine.contains { $0.id == t.id } }.sorted { $0.weight > $1.weight }.prefix(12))) { t in
                            Button(t.name) { threads.pin(recording.id, to: t.id) }
                        }
                        Divider()
                        Button { name = ""; naming = true } label: { Label("New thread…", systemImage: "plus") }
                    } label: {
                        chip(mine.isEmpty ? "Add to a thread" : "Add", "plus", Brand.surface, Brand.textSecondary)
                    }
                }
            }
            .sideScrollZone()
            ForEach(doubted) { t in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recorded into \(t.name), but it reads as something else.").font(.callout.weight(.semibold))
                    HStack(spacing: 10) {
                        Button { threads.keep(recording.id, in: t.id) } label: {
                            Text("Keep it there").font(.subheadline.weight(.bold)).padding(.horizontal, 14).padding(.vertical, 8)
                                .background(Brand.act, in: Capsule()).foregroundStyle(Brand.onAct)
                        }
                        .buttonStyle(.plain)
                        Button { threads.exclude(recording.id, from: t.id) } label: {
                            Text("Take it out").font(.subheadline.weight(.bold)).padding(.horizontal, 14).padding(.vertical, 8)
                                .background(Brand.raised, in: Capsule()).foregroundStyle(Brand.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(.top, 12)
        .alert("Start a thread", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Start") { _ = threads.create(name, with: recording.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This moment goes in it, and so does anything that names it later.")
        }
    }

    private func chip(_ text: String, _ icon: String, _ bg: Color, _ fg: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2.weight(.bold))
            Text(text).font(.caption.weight(.semibold)).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(bg, in: Capsule())
        .foregroundStyle(fg)
    }
}

/// The last words heard, in a view of its own, so only it redraws as they come.
struct LiveLine: View {
    @EnvironmentObject var live: LiveSession

    var body: some View {
        Text(live.text.isEmpty ? "Listening…" : live.text.tail(140))
    }
}
