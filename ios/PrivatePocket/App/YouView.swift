import SwiftUI

/// You: the mirror. A few observations a month from your own voice, each a number or a
/// name on a colour field with the evidence behind it, then this week's findings.
struct YouView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: Library
    @State private var cache = DigestCache()
    @State private var dismissed: Set<String> = Prefs.dismissedFindings
    @State private var path = NavigationPath()
    @State private var toast: String?

    var body: some View {
        let all = library.recordings
        let cal = Calendar.current
        let month = cal.dateInterval(of: .month, for: Date()) ?? DateInterval(start: .distantPast, end: .distantFuture)
        let week = cal.dateInterval(of: .weekOfYear, for: Date()) ?? month
        let m = cache.digest(all, window: month)
        let w = cache.digest(all, window: week)
        let history = (1...3).map { k -> Digest in
            let start = cal.date(byAdding: .weekOfYear, value: -k, to: week.start) ?? week.start
            return cache.digest(all, window: cal.dateInterval(of: .weekOfYear, for: start) ?? week)
        }
        let findings = Findings.make(w, previous: history.first, history: history, all: all, spanName: "week").filter { !dismissed.contains("week|" + $0.id) }
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("You").font(.largeTitle.weight(.bold)).tracking(-0.5)
                        Spacer()
                        Text("this month, from \(m.moments.count) conversation\(m.moments.count == 1 ? "" : "s")").font(.caption.weight(.semibold)).foregroundStyle(Brand.muted)
                    }
                    .padding(.top, 8)
                    mirror(m, all: all)
                    if !findings.isEmpty {
                        SectionTitle("This week")
                        ForEach(findings) { f in
                            FindingCard(finding: f, perform: { perform($0) }, notRight: {
                                withAnimation { dismissed.insert("week|" + f.id) }
                                Prefs.dismissedFindings = dismissed
                            })
                        }
                    }
                    if m.moments.isEmpty && findings.isEmpty {
                        Text("The mirror needs a few days of conversations. It fills in by itself.").font(.subheadline).foregroundStyle(Brand.muted)
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 28)
            }
            .background(Brand.ground)
            .overlay(alignment: .bottom) { if let toast { Text(toast).font(.subheadline.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 10).glassEffect(.regular, in: Capsule()).padding(.bottom, 12) } }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { id in RecordingDetail(id: id) }
            .navigationDestination(for: MomentsFilter.self) { f in FilteredMoments(filter: f) }
        }
    }

    // MARK: The observations

    @ViewBuilder private func mirror(_ m: Digest, all: [Recording]) -> some View {
        let yoursTotal = m.yours.count, yoursDone = m.yoursDone.count
        if yoursTotal >= 3 {
            Mirror(tint: Brand.act, ink: Brand.onAct, big: Findings.pct(Double(yoursDone) / Double(yoursTotal)),
                   title: "of your word kept this month.", line: thursdayLine(m) ?? "\(yoursDone) of \(yoursTotal) things you took on, done.",
                   action: "The evidence") { path.append(MomentsFilter(title: "Your word", ids: Array(Set(m.yours.map { $0.0.id })))) }
        }
        let theirsTotal = m.theirs.count, theirsDone = m.theirs.filter { $0.1.isDone }.count
        if theirsTotal >= 3 {
            Mirror(tint: Brand.work, ink: Brand.onWork, big: Findings.pct(Double(theirsDone) / Double(theirsTotal)),
                   title: "of what others promised you, kept.", line: "\(theirsTotal - theirsDone) still open" + (m.theirsOverdue.isEmpty ? "." : ", \(m.theirsOverdue.count) past due."),
                   action: "Who") { path.append(MomentsFilter(title: "Promised to you", ids: Array(Set(m.theirs.map { $0.0.id })))) }
        }
        if let gone = drifting(all) {
            Mirror(tint: Brand.life, ink: Brand.onLife, big: gone.name, title: "every week, until \(gone.weeks) weeks ago.",
                   line: gone.others.isEmpty ? "\(gone.count) conversations before that." : "\(gone.others.joined(separator: " and ")) too.",
                   action: "What you talked about") { path.append(MomentsFilter(title: gone.name, ids: gone.ids)) }
        }
        if let stalled = stalled(all) {
            Mirror(tint: Brand.notice, ink: Brand.onNotice, big: "\(stalled.count)×", title: "\(stalled.term), raised and never decided.",
                   line: "Last \(stalled.last).", action: "The thread") { path.append(MomentsFilter(title: stalled.term, ids: stalled.ids)) }
        }
        if let busy = m.busiestDay, m.days.filter({ $0.total > 0 }).count >= 5 {
            Mirror(tint: Brand.paper, ink: Brand.onPaper, big: busy.date.formatted(.dateTime.weekday(.wide)), title: "is your heaviest day.",
                   line: "\(Digest.hours(busy.total)) of talk, against \(Digest.hours(m.totalSeconds / max(1, m.days.filter { $0.total > 0 }.count))) on an ordinary day.", action: nil) {}
        }
    }

    private func thursdayLine(_ m: Digest) -> String? {
        let cal = Calendar.current
        var byDay: [Int: (done: Int, total: Int)] = [:]
        for (r, item) in m.yours {
            guard let s = r.startedAt else { continue }
            let wd = cal.component(.weekday, from: s)
            byDay[wd, default: (0, 0)].total += 1
            if item.isDone { byDay[wd]!.done += 1 }
        }
        guard let worst = byDay.filter({ $0.value.total >= 3 }).min(by: { Double($0.value.done) / Double($0.value.total) < Double($1.value.done) / Double($1.value.total) }) else { return nil }
        let name = cal.weekdaySymbols[worst.key - 1]
        return "And \(Findings.pct(Double(worst.value.done) / Double(worst.value.total))) of what you promise on a \(name)."
    }

    private func drifting(_ all: [Recording]) -> (name: String, weeks: Int, count: Int, others: [String], ids: [String])? {
        let now = Date()
        var out: [(String, Int, Int, [String])] = []
        for p in Digest.people(all, limit: 60) {
            guard p.moments.count >= 3, let last = p.lastSeen else { continue }
            let weeks = Int(now.timeIntervalSince(last) / (7 * 86_400))
            guard weeks >= 2 else { continue }
            let span = p.moments.compactMap(\.startedAt)
            guard let first = span.min(), last.timeIntervalSince(first) >= 14 * 86_400 else { continue }
            out.append((p.name, weeks, p.moments.count, p.moments.map(\.id)))
        }
        guard let lead = out.max(by: { $0.2 < $1.2 }) else { return nil }
        return (lead.0, lead.1, lead.2, out.filter { $0.0 != lead.0 }.prefix(2).map { $0.0 }, lead.3)
    }

    private func stalled(_ all: [Recording]) -> (term: String, count: Int, last: String, ids: [String])? {
        let threads = Digest.threads(all, people: Set(all.flatMap(\.people)), limit: 30)
        for t in threads where t.moments.count >= 3 {
            let decided = t.moments.contains { r in (r.meta.insight?.decisions ?? []).contains { $0.range(of: t.term, options: .caseInsensitive) != nil } }
            if !decided, let last = t.dates.max() {
                return (t.term, t.moments.count, Findings.dayName(last), t.moments.map(\.id))
            }
        }
        return nil
    }

    private func perform(_ a: Finding.Action) {
        switch a {
        case .open(let ids, let title):
            if ids.count == 1, let id = ids.first { path.append(id) } else { path.append(MomentsFilter(title: title, ids: ids)) }
        case .remind(let title, let due, let note):
            Task { if await model.quickReminder(title, due: due, note: note) { show("Added to Reminders") } }
        case .chase(let r, let item):
            Task { await model.remindMe(r, item: item); show("Reminder set") }
        case .place(let r, let item):
            Task { await model.place(r, item); show("Added to Reminders") }
        case .placeAll(let pairs):
            Task { for (r, i) in pairs { await model.place(r, i) }; show("\(pairs.count) added to Reminders") }
        case .record:
            break
        }
    }

    private func show(_ text: String) {
        withAnimation { toast = text }
        Task { try? await Task.sleep(for: .seconds(2.2)); withAnimation { if toast == text { toast = nil } } }
    }
}

/// One observation: a big number or name on a colour field, a line, and the evidence.
struct Mirror: View {
    let tint: Color
    let ink: Color
    let big: String
    let title: String
    let line: String
    let action: String?
    let run: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(big).font(.system(.largeTitle, design: .default, weight: .bold)).tracking(-1).lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.callout.weight(.bold)).fixedSize(horizontal: false, vertical: true)
            Text(line).font(.footnote).opacity(0.85).fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action: run) { Text(action + " →").font(.footnote.weight(.bold)) }.buttonStyle(.plain).padding(.top, 5)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .foregroundStyle(ink)
    }
}
