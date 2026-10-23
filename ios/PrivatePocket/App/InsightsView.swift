import SwiftUI

/// What the week or the month adds up to, across moments: the briefing, then the
/// findings (each a picture, a sentence and something to do), your days, what needs
/// you now, and the record behind it all.
struct InsightsView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var model: AppModel
    @State private var cache = DigestCache()
    @State private var allFindings = false
    @State private var dismissed: Set<String> = Prefs.dismissedFindings
    @State private var span = 0   // this week, this month
    @State private var record: RecordTab?
    @State private var showYours = true
    @State private var showTheirs = false
    @State private var path = NavigationPath()
    @State private var toast: String?
    @State private var toastCount = 0

    private var spanName: String { span == 0 ? "week" : "month" }
    private var unit: Calendar.Component { span == 0 ? .weekOfYear : .month }
    private var window: DateInterval {
        Calendar.current.dateInterval(of: unit, for: Date()) ?? DateInterval(start: .distantPast, end: .distantFuture)
    }
    private func shifted(_ w: DateInterval, by k: Int) -> DateInterval {
        let cal = Calendar.current
        guard let d = cal.date(byAdding: unit, value: k, to: w.start), let i = cal.dateInterval(of: unit, for: d) else { return w }
        return i
    }
    private var key: String { (span == 0 ? "week-" : "month-") + window.start.formatted(.iso8601.year().month().day()) }

    var body: some View {
        let all = library.recordings
        let d = cache.digest(all, window: window)
        let history = (1...3).map { cache.digest(all, window: shifted(window, by: -$0)) }
        let findings = Findings.make(d, previous: history.first, history: history, all: all, spanName: spanName)
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Picker("Span", selection: $span) {
                            Text("This week").tag(0)
                            Text("This month").tag(1)
                        }
                        .pickerStyle(.segmented)
                        if d.moments.isEmpty && d.needs.isEmpty && findings.isEmpty {
                            Text("Nothing recorded \(spanName == "week" ? "this week" : "this month") yet. Press the side button on your Pocket, or add the sample moments in Settings.")
                                .font(.body).foregroundStyle(Brand.muted).padding(.top, 28)
                        } else {
                            header(d)
                            if d.totalSeconds > 0 { daysChart(d, previous: history.first) }
                            findingCards(findings.filter { !dismissed.contains(key + "|" + $0.id) }, proxy)
                            needs(d)
                            recordBlock(d)
                            reading(d)
                        }
                    }
                    .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 32)
                }
                .background(Brand.ground)
                .navigationTitle("Insights")
                .navigationDestination(for: String.self) { id in RecordingDetail(id: id) }
                .navigationDestination(for: MomentsFilter.self) { f in FilteredMoments(filter: f) }
                .overlay(alignment: .bottom) { toastView }
                .sensoryFeedback(.success, trigger: toastCount)
                // While older readings are being redone the id holds still, so the re-reading runs once through.
                .task(id: key + "|" + (d.outdated.isEmpty ? d.stamp : "rereading")) {
                    if !d.outdated.isEmpty { await model.rereadOutdated(d.outdated) }
                }
                .onAppear { model.syncAllPlaced() }
            }
        }
    }

    // MARK: Header and briefing

    @ViewBuilder private func header(_ d: Digest) -> some View {
        Text(spanName == "week" ? "This week" : "This month")
            .font(.title.weight(.bold)).tracking(-0.3).padding(.top, 22)
        HStack(spacing: 0) {
            figure("\(d.moments.count)", d.moments.count == 1 ? "moment" : "moments")
            figure(Digest.hours(d.totalSeconds), "recorded")
            figure("\(d.people.count)", d.people.count == 1 ? "person" : "people")
            figure("\(d.yoursOpen.count + d.theirsOpen.count)", "open")
        }
        .padding(.top, 12)
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(Brand.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Findings

    @ViewBuilder private func findingCards(_ fs: [Finding], _ proxy: ScrollViewProxy) -> some View {
        if !fs.isEmpty {
            let shown = allFindings ? fs : Array(fs.prefix(4))
            SectionTitle("What stands out")
            VStack(spacing: 12) {
                ForEach(shown) { f in
                    FindingCard(finding: f, perform: { perform($0, proxy) }, notRight: {
                        withAnimation(.easeInOut(duration: 0.25)) { dismissed.insert(key + "|" + f.id) }
                        Prefs.dismissedFindings = dismissed
                    })
                }
                if fs.count > shown.count {
                    Button("Show \(fs.count - shown.count) more") { withAnimation(.easeInOut(duration: 0.25)) { allFindings = true } }
                        .font(.footnote.weight(.semibold)).frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 4)
        }
    }

    private func perform(_ a: Finding.Action, _ proxy: ScrollViewProxy) {
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
            Task {
                for (r, i) in pairs { await model.place(r, i) }
                show(pairs.count == 1 ? "Added to Reminders" : "\(pairs.count) added to Reminders")
            }
        case .record(let tab):
            withAnimation(.easeInOut(duration: 0.3)) {
                record = tab
                proxy.scrollTo("record", anchor: .top)
            }
        }
    }

    private func show(_ text: String) {
        withAnimation { toast = text }
        toastCount += 1
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation { if toast == text { toast = nil } }
        }
    }

    @ViewBuilder private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glassEffect(.regular, in: Capsule())
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: The days

    @ViewBuilder private func daysChart(_ d: Digest, previous p: Digest?) -> some View {
        let ghost = p?.days.map(\.total) ?? []
        let top = max(1, (d.days.map(\.total) + ghost).max() ?? 1)
        let cal = Calendar.current
        SectionTitle("Your days") {
            HStack(spacing: 12) {
                legend(Brand.work, "Work \(Digest.hours(d.workSeconds))")
                legend(Brand.life, "Life \(Digest.hours(d.lifeSeconds))")
                if d.otherSeconds > 0 { legend(Brand.hairline, "Unsorted") }
            }
            .font(.caption).foregroundStyle(Brand.muted)
        }
        HStack(alignment: .bottom, spacing: d.days.count > 10 ? 3 : 8) {
            ForEach(d.days.indices, id: \.self) { i in
                let day = d.days[i]
                VStack(spacing: 4) {
                    ZStack(alignment: .bottom) {
                        if i < ghost.count, ghost[i] > 0 {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .stroke(Brand.dim.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                                .frame(height: max(3, 96 * CGFloat(ghost[i]) / CGFloat(top)))
                        }
                        if day.total > 0 {
                            VStack(spacing: 1) {
                                if day.other > 0 { Rectangle().fill(Brand.hairline).frame(height: max(2, 96 * CGFloat(day.other) / CGFloat(top))) }
                                if day.life > 0 { Rectangle().fill(Brand.life).frame(height: max(2, 96 * CGFloat(day.life) / CGFloat(top))) }
                                if day.work > 0 { Rectangle().fill(Brand.work).frame(height: max(2, 96 * CGFloat(day.work) / CGFloat(top))) }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        } else if i >= ghost.count || ghost[i] == 0 {
                            Rectangle().fill(Brand.hairline.opacity(0.5)).frame(height: 2)
                        }
                    }
                    .frame(height: 96, alignment: .bottom)
                    if d.days.count <= 10 || cal.component(.weekday, from: day.date) == 2 {
                        Text(d.days.count <= 10 ? day.date.formatted(.dateTime.weekday(.narrow)) : day.date.formatted(.dateTime.day()))
                            .font(.caption2.weight(cal.isDateInToday(day.date) ? .bold : .medium))
                            .foregroundStyle(cal.isDateInToday(day.date) ? Brand.text : Brand.muted)
                    } else {
                        Text(" ").font(.caption2)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 6)
        VStack(alignment: .leading, spacing: 3) {
            if let p, p.totalSeconds > 0 {
                let ratio = Double(d.totalSeconds) / Double(p.totalSeconds)
                let compare = ratio > 1.25 ? "more than" : ratio < 0.8 ? "less than" : "about the same as"
                Text("\(Digest.hours(d.totalSeconds)) recorded, \(compare) last \(spanName)'s \(Digest.hours(p.totalSeconds)), shown dotted.")
            }
            if let b = d.busiestDay {
                Text("Busiest: \(b.date.formatted(.dateTime.weekday(.wide))), \(Digest.hours(b.total)).")
            }
        }
        .font(.caption).foregroundStyle(Brand.dim).padding(.top, 8)
    }

    private func legend(_ colour: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(colour).frame(width: 8, height: 8)
            Text(text)
        }
    }

    // MARK: Needs you

    @ViewBuilder private func needs(_ d: Digest) -> some View {
        if !d.needs.isEmpty {
            SectionTitle("Needs you")
            ForEach(d.needs) { n in
                HStack(alignment: .top, spacing: 12) {
                    Text(n.why.uppercased())
                        .font(.caption2.weight(.bold)).tracking(0.5)
                        .foregroundStyle(whyColour(n.why))
                        .frame(width: 62, alignment: .leading).padding(.top, 4)
                    NavigationLink(value: n.recording.id) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(n.item.text).font(.body)
                            Text([n.item.who, n.item.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? n.item.when, n.recording.displayTitle]
                                    .compactMap { $0 }.joined(separator: " · "))
                                .font(.footnote).foregroundStyle(Brand.muted).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    control(n.recording, n.item)
                }
                .padding(.vertical, 10)
                Divider().overlay(Brand.hairline)
            }
        }
    }

    private func whyColour(_ why: String) -> Color {
        switch why {
        case "Overdue": Brand.bad
        case "Soon": Brand.record
        case "To chase": Brand.life
        default: Brand.muted
        }
    }

    @ViewBuilder private func control(_ r: Recording, _ item: NextItem) -> some View {
        if item.isAction {
            if item.isDone {
                EmptyView()
            } else if item.reminderID == nil {
                Button("Add") { Task { await model.place(r, item) } }.font(.footnote.weight(.semibold))
            } else {
                Button("Done") { model.setDone(r, item: item, done: true) }.font(.footnote.weight(.semibold))
            }
        } else if item.isPromise {
            Button(item.reminderID == nil ? "Remind me" : "Set") { Task { await model.remindMe(r, item: item) } }
                .font(.footnote.weight(.semibold)).disabled(item.reminderID != nil)
        } else if item.eventID == nil, item.date != nil {
            Button("Add") { Task { await model.place(r, item) } }.font(.footnote.weight(.semibold))
        }
    }

    // MARK: The record

    private func count(_ d: Digest, _ t: RecordTab) -> Int {
        switch t {
        case .commitments: d.yours.count + d.theirs.count
        case .decided: d.decisions.count
        case .open: d.questions.count
        case .figures: d.figures.count
        case .threads: d.threads.count
        case .people: d.people.count
        }
    }

    @ViewBuilder private func recordBlock(_ d: Digest) -> some View {
        let tabs = RecordTab.allCases.filter { count(d, $0) > 0 }
        if let first = tabs.first {
            let current = record.flatMap { tabs.contains($0) ? $0 : nil } ?? first
            SectionTitle("The record").id("record")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tabs) { t in
                        Button { withAnimation(.easeInOut(duration: 0.2)) { record = t } } label: {
                            HStack(spacing: 5) {
                                Text(t.rawValue)
                                Text("\(count(d, t))").foregroundStyle(current == t ? Brand.onAct.opacity(0.7) : Brand.dim)
                            }
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(current == t ? Brand.act : Brand.raised, in: Capsule())
                            .foregroundStyle(current == t ? Brand.onAct : Brand.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            switch current {
            case .commitments: ledger(d)
            case .decided: lines(symbol: "checkmark.seal", d.decisions)
            case .open: lines(symbol: "questionmark.circle", d.questions)
            case .figures: lines(symbol: "number", d.figures)
            case .threads: threads(d)
            case .people: people(d)
            }
        }
    }

    // MARK: Commitments

    @ViewBuilder private func ledger(_ d: Digest) -> some View {
        if !d.yours.isEmpty {
            ledgerRow(title: "You", open: d.yoursOpen.count, done: d.yoursDone.count,
                      overdue: d.yoursOpen.filter { $0.1.date.map { $0 < Date() } ?? false }.count,
                      colour: Brand.act, expanded: $showYours)
            if showYours {
                ForEach(Array(d.yours.enumerated()), id: \.offset) { _, pair in itemRow(pair.0, pair.1) }
            }
        }
        if !d.theirs.isEmpty {
            ledgerRow(title: "Owed to you", open: d.theirsOpen.count, done: d.theirs.filter(\.1.isDone).count, overdue: d.theirsOverdue.count,
                      colour: Brand.life, expanded: $showTheirs)
            if showTheirs {
                ForEach(Array(d.theirs.enumerated()), id: \.offset) { _, pair in itemRow(pair.0, pair.1) }
            }
        }
    }

    private func ledgerRow(title: String, open: Int, done: Int, overdue: Int, colour: Color, expanded: Binding<Bool>) -> some View {
        let total = max(1, open + done)
        return Button { withAnimation(.easeInOut(duration: 0.25)) { expanded.wrappedValue.toggle() } } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.body.weight(.semibold))
                    Text([open > 0 ? "\(open) open" : nil, done > 0 ? "\(done) done" : nil, overdue > 0 ? "\(overdue) overdue" : nil]
                            .compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote).foregroundStyle(Brand.muted)
                    Spacer()
                    Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(Brand.dim)
                }
                GeometryReader { g in
                    HStack(spacing: 2) {
                        if done > 0 { Rectangle().fill(Brand.good).frame(width: g.size.width * CGFloat(done) / CGFloat(total)) }
                        if overdue > 0 { Rectangle().fill(Brand.bad).frame(width: g.size.width * CGFloat(min(overdue, open)) / CGFloat(total)) }
                        if open - overdue > 0 { Rectangle().fill(colour).frame(width: g.size.width * CGFloat(open - min(overdue, open)) / CGFloat(total)) }
                    }
                }
                .frame(height: 6)
                .clipShape(Capsule())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 10)
    }

    private func itemRow(_ r: Recording, _ item: NextItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                if item.isAction { model.setDone(r, item: item, done: !item.isDone) }
            } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isDone ? Brand.good : Brand.dim).padding(.top, 2)
            }
            .buttonStyle(.plain)
            NavigationLink(value: r.id) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text).font(.subheadline).foregroundStyle(item.isDone ? Brand.muted : Brand.text)
                    Text([item.isDone ? "Done" : nil, item.who, item.when, r.displayTitle].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(item.isDone ? Brand.good : Brand.muted).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            control(r, item)
        }
        .padding(.vertical, 6)
        .padding(.leading, 8)
    }

    // MARK: Decided, still open, figures

    @ViewBuilder private func lines(symbol: String, _ items: [Digest.Line]) -> some View {
        ForEach(items.prefix(12)) { line in
            NavigationLink(value: line.recording.id) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol).font(.caption).foregroundStyle(Brand.muted).frame(width: 18).padding(.top, 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.text).font(.body)
                        Text([line.recording.startedAt?.formatted(.dateTime.weekday(.abbreviated)), line.recording.displayTitle].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(Brand.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)
            Divider().overlay(Brand.hairline)
        }
        if items.count > 12 { Text("and \(items.count - 12) more").font(.caption).foregroundStyle(Brand.dim).padding(.top, 4) }
    }

    // MARK: Threads

    @ViewBuilder private func threads(_ d: Digest) -> some View {
        Text("What keeps coming up, and where it got to.").font(.caption).foregroundStyle(Brand.dim).padding(.vertical, 4)
        ForEach(d.threads) { t in
            NavigationLink(value: MomentsFilter(title: t.term, ids: t.moments.map(\.id))) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(t.term).font(.body.weight(.semibold))
                        Text("\(t.moments.count) moments").font(.footnote).foregroundStyle(Brand.muted)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Brand.dim)
                    }
                    TimelineStrip(dates: t.dates, window: d.window, settledAt: nil, labelled: false)
                    if let l = t.latest { Text(l).font(.subheadline).foregroundStyle(Brand.textSecondary).lineLimit(2) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 10)
            Divider().overlay(Brand.hairline)
        }
    }

    // MARK: People

    @ViewBuilder private func people(_ d: Digest) -> some View {
        ForEach(Array(d.people.enumerated()), id: \.element.id) { i, p in
            NavigationLink(value: MomentsFilter(title: p.name, ids: p.moments.map(\.id))) {
                HStack(spacing: 12) {
                    Text(String(p.name.prefix(1)).uppercased())
                        .font(.caption.weight(.bold))
                        .frame(width: 30, height: 30)
                        .background(Brand.speakers[i % Brand.speakers.count].opacity(0.22), in: Circle())
                        .foregroundStyle(Brand.speakers[i % Brand.speakers.count])
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).font(.body.weight(.semibold))
                        Text(standing(p)).font(.footnote).foregroundStyle(Brand.muted).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Brand.dim)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)
            Divider().overlay(Brand.hairline)
        }
    }

    private func standing(_ p: Digest.Person) -> String {
        var parts = ["\(p.moments.count) \(p.moments.count == 1 ? "moment" : "moments")"]
        if let l = p.lastSeen { parts.append("last \(Calendar.current.isDateInToday(l) ? "today" : l.formatted(.dateTime.weekday(.abbreviated)))") }
        let open = p.waitingOn.filter { !$0.isDone }
        if !open.isEmpty { parts.append("waiting on \(open.count == 1 ? "one thing" : "\(open.count) things")") }
        if p.youOwe > 0 { parts.append("you owe \(p.youOwe == 1 ? "one" : "\(p.youOwe)")") }
        return parts.joined(separator: " · ")
    }

    // MARK: Reading state

    @ViewBuilder private func reading(_ d: Digest) -> some View {
        let busy = (d.unread + d.outdated).contains { model.working.contains($0.id) }
        if !d.unread.isEmpty || !d.outdated.isEmpty {
            HStack(spacing: 10) {
                if busy { ProgressView().controlSize(.small) }
                Text(!d.unread.isEmpty
                     ? "\(d.unread.count) \(d.unread.count == 1 ? "moment hasn't" : "moments haven't") been read yet, so \(d.unread.count == 1 ? "it isn't" : "they aren't") counted here."
                     : "Reading \(d.outdated.count) \(d.outdated.count == 1 ? "moment" : "moments") again for decisions, questions and figures.")
                    .font(.footnote).foregroundStyle(Brand.muted)
                Spacer()
                if !busy, !d.unread.isEmpty, Summariser.availability == nil {
                    Button("Read") { Task { await model.analyseMissing(d.unread) } }.font(.footnote.weight(.semibold))
                }
            }
            .padding(.top, 28)
        }
    }
}

// MARK: - A finding

struct FindingCard: View {
    let finding: Finding
    let perform: (Finding.Action) -> Void
    /// A wrong guess goes away for this span, before it costs trust.
    let notRight: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(finding.tag.uppercased())
                .font(.caption2.weight(.bold)).tracking(0.7)
                .foregroundStyle(finding.tint)
            if let v = finding.visual { FindingVisual(visual: v).accessibilityHidden(true) }
            Text(finding.text)
                .font(.body.weight(.medium)).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(finding.choices) { c in
                    Button(c.label) { perform(c.action) }
                        .buttonStyle(.glass)
                        .font(.footnote.weight(.semibold))
                }
                Spacer(minLength: 0)
                Button("Not right", action: notRight)
                    .font(.footnote.weight(.semibold)).foregroundStyle(Brand.muted)
                    .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// The picture a finding rests on, one small chart each, all in the brand's colours.
struct FindingVisual: View {
    let visual: Finding.Visual

    var body: some View {
        switch visual {
        case .balance(let before, let after, let bl, let al): BalanceBars(before: before, after: after, beforeLabel: bl, afterLabel: al)
        case .ring(let done, let total, let previous): RingView(done: done, total: total, previous: previous)
        case .growth(let open, let labels): GrowthView(open: open, labels: labels)
        case .spike(let intake, let labels, let peak): SpikeView(intake: intake, labels: labels, peak: peak)
        case .timeline(let dates, let window, let settledAt): TimelineStrip(dates: dates, window: window, settledAt: settledAt, labelled: true)
        case .waiting(let rows): WaitingRows(rows: rows)
        case .lapse(let said, let due, let now): LapseView(said: said, due: due, now: now)
        case .pair(let a, let b, let al, let bl): PairBars(a: a, b: b, aLabel: al, bLabel: bl)
        case .step(let fv, let fl, let tv, let tl, let up): StepView(fromValue: fv, fromLabel: fl, toValue: tv, toLabel: tl, up: up)
        case .presence(let present, let labels): PresenceDots(present: present, labels: labels)
        case .hours(let seconds, let decisions): HoursBar(seconds: seconds, decisions: decisions)
        }
    }
}

struct BalanceBars: View {
    let before: Double?
    let after: Double
    let beforeLabel: String
    let afterLabel: String

    var body: some View {
        VStack(spacing: 8) {
            if let before { row(beforeLabel, before, dim: true) }
            row(afterLabel, after, dim: false)
        }
    }

    private func row(_ label: String, _ work: Double, dim: Bool) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.caption).foregroundStyle(Brand.muted).frame(width: 76, alignment: .leading)
            GeometryReader { g in
                HStack(spacing: 2) {
                    Rectangle().fill(dim ? Brand.work.opacity(0.4) : Brand.work).frame(width: max(0, g.size.width * work))
                    Rectangle().fill(dim ? Brand.life.opacity(0.4) : Brand.life)
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())
            Text(Findings.pct(work)).font(.caption.monospacedDigit()).foregroundStyle(dim ? Brand.dim : Brand.text).frame(width: 38, alignment: .trailing)
        }
    }
}

struct RingView: View {
    let done: Int
    let total: Int
    let previous: (done: Int, total: Int)?

    private var frac: Double { total > 0 ? Double(done) / Double(total) : 0 }
    private var prevFrac: Double? { previous.flatMap { $0.total > 0 ? Double($0.done) / Double($0.total) : nil } }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Brand.hairline, lineWidth: 7)
                Circle().trim(from: 0, to: frac)
                    .stroke(Brand.good, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if let prevFrac {
                    Circle().inset(by: 9).stroke(Brand.hairline, lineWidth: 3)
                    Circle().inset(by: 9).trim(from: 0, to: prevFrac)
                        .stroke(Brand.dim, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text("\(done)/\(total)").font(.system(.footnote, design: .rounded, weight: .semibold)).monospacedDigit()
            }
            .frame(width: 66, height: 66)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) { Circle().fill(Brand.good).frame(width: 8, height: 8); Text("done, \(Findings.pct(frac))") }
                if let prevFrac { HStack(spacing: 6) { Circle().fill(Brand.dim).frame(width: 8, height: 8); Text("last time, \(Findings.pct(prevFrac))") } }
            }
            .font(.caption).foregroundStyle(Brand.muted)
            Spacer(minLength: 0)
        }
    }
}

struct GrowthView: View {
    let open: [Int]
    let labels: [String]

    var body: some View {
        VStack(spacing: 4) {
            Canvas { ctx, size in
                let n = open.count
                guard n > 1 else { return }
                let top = max(1, open.max() ?? 1)
                let w = size.width - 16, h = size.height - 16
                func pt(_ i: Int) -> CGPoint { CGPoint(x: w * CGFloat(i) / CGFloat(n - 1), y: 12 + h - h * CGFloat(open[i]) / CGFloat(top)) }
                var line = Path()
                line.move(to: pt(0))
                for i in 1..<n { line.addLine(to: pt(i)) }
                var area = line
                area.addLine(to: CGPoint(x: pt(n - 1).x, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()
                ctx.fill(area, with: .color(Brand.act.opacity(0.16)))
                ctx.stroke(line, with: .color(Brand.act), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                let last = pt(n - 1)
                ctx.fill(Path(ellipseIn: CGRect(x: last.x - 4, y: last.y - 4, width: 8, height: 8)), with: .color(Brand.act))
                ctx.draw(Text("\(open[n - 1])").font(.caption.weight(.bold)).foregroundStyle(Brand.text), at: CGPoint(x: last.x + 4, y: last.y - 10), anchor: .bottom)
                if let f = open.firstIndex(where: { $0 > 0 }) {
                    let p = pt(f)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(Brand.act))
                    ctx.draw(Text("\(open[f])").font(.caption2).foregroundStyle(Brand.muted), at: CGPoint(x: p.x, y: p.y - 8), anchor: .bottom)
                }
            }
            .frame(height: 64)
            HStack {
                ForEach(labels.indices, id: \.self) { i in
                    Text(labels[i]).font(.caption2).foregroundStyle(Brand.muted)
                    if i < labels.count - 1 { Spacer(minLength: 0) }
                }
            }
            .padding(.trailing, 16)
        }
    }
}

struct SpikeView: View {
    let intake: [Int]
    let labels: [String]
    let peak: Int

    var body: some View {
        let top = max(1, intake.max() ?? 1)
        HStack(alignment: .bottom, spacing: intake.count > 10 ? 3 : 8) {
            ForEach(intake.indices, id: \.self) { i in
                VStack(spacing: 3) {
                    if i == peak { Text("\(intake[i])").font(.caption.weight(.bold)).foregroundStyle(Brand.record) }
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(i == peak ? Brand.record : Brand.raised)
                        .frame(height: max(3, 48 * CGFloat(intake[i]) / CGFloat(top)))
                    if i < labels.count { Text(labels[i]).font(.caption2).foregroundStyle(i == peak ? Brand.text : Brand.muted) }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// The moments of a thread as dots along the span; a settled one gets a green dot.
struct TimelineStrip: View {
    let dates: [Date]
    let window: DateInterval
    let settledAt: Date?
    let labelled: Bool

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Brand.hairline).frame(height: 2)
                    ForEach(Array(dates.enumerated()), id: \.offset) { _, d in
                        let f = max(0, min(1, d.timeIntervalSince(window.start) / max(1, window.duration)))
                        let settled = settledAt.map { Calendar.current.isDate($0, inSameDayAs: d) } ?? false
                        Circle()
                            .fill(settled ? Brand.good : (settledAt == nil && labelled ? Brand.record : Brand.act))
                            .frame(width: settled ? 11 : 8, height: settled ? 11 : 8)
                            .offset(x: g.size.width * CGFloat(f) - (settled ? 5.5 : 4))
                    }
                }
                .frame(height: 11)
            }
            .frame(height: 11)
            if labelled {
                HStack {
                    Text(window.start.formatted(.dateTime.day().month(.abbreviated)))
                    Spacer()
                    Text(settledAt == nil ? "no decision yet" : "settled")
                        .foregroundStyle(settledAt == nil ? Brand.record : Brand.good)
                    Spacer()
                    Text(window.end.addingTimeInterval(-1).formatted(.dateTime.day().month(.abbreviated)))
                }
                .font(.caption).foregroundStyle(Brand.muted)
            }
        }
        .padding(.vertical, 3)
    }
}

struct WaitingRows: View {
    let rows: [(name: String, days: Int)]

    var body: some View {
        let top = max(1, rows.map(\.days).max() ?? 1)
        VStack(spacing: 7) {
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: 10) {
                    Text(rows[i].name).font(.caption).foregroundStyle(Brand.textSecondary).frame(width: 76, alignment: .leading).lineLimit(1)
                    GeometryReader { g in
                        Capsule().fill(rows[i].days >= 5 ? Brand.record : Brand.act)
                            .frame(width: max(6, g.size.width * CGFloat(rows[i].days) / CGFloat(top)))
                    }
                    .frame(height: 8)
                    Text("\(rows[i].days) d").font(.caption.monospacedDigit()).foregroundStyle(Brand.muted).frame(width: 36, alignment: .trailing)
                }
            }
        }
    }
}

/// From the day it was said, past the day it was due, to now.
struct LapseView: View {
    let said: Date
    let due: Date?
    let now: Date

    var body: some View {
        let total = max(1, now.timeIntervalSince(said))
        VStack(spacing: 5) {
            GeometryReader { g in
                let dueX = due.map { g.size.width * CGFloat(max(0, min(1, $0.timeIntervalSince(said) / total))) }
                ZStack(alignment: .leading) {
                    Capsule().fill(Brand.hairline).frame(height: 3)
                    if let dueX {
                        Rectangle().fill(Brand.bad).frame(width: max(0, g.size.width - dueX), height: 3).offset(x: dueX)
                        Rectangle().fill(Brand.record).frame(width: 2, height: 14).offset(x: dueX - 1)
                    }
                    Circle().fill(Brand.dim).frame(width: 8, height: 8)
                    Circle().fill(due == nil ? Brand.record : Brand.bad).frame(width: 8, height: 8).offset(x: g.size.width - 8)
                }
                .frame(height: 14)
            }
            .frame(height: 14)
            HStack {
                Text("said \(Findings.dayName(said))")
                Spacer()
                if let due { Text("due \(Findings.dayName(due))").foregroundStyle(Brand.record); Spacer() }
                Text("now")
            }
            .font(.caption).foregroundStyle(Brand.muted)
        }
    }
}

struct PairBars: View {
    let a: Int
    let b: Int
    let aLabel: String
    let bLabel: String

    var body: some View {
        let top = max(1, a, b)
        VStack(spacing: 7) {
            bar(aLabel, a, Brand.record, top)
            bar(bLabel, b, Brand.good, top)
        }
    }

    private func bar(_ label: String, _ v: Int, _ colour: Color, _ top: Int) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.caption).foregroundStyle(Brand.muted).frame(width: 56, alignment: .leading)
            GeometryReader { g in
                Capsule().fill(colour).frame(width: max(6, g.size.width * CGFloat(v) / CGFloat(top)))
            }
            .frame(height: 10)
            Text("\(v)").font(.caption.monospacedDigit().weight(.semibold)).frame(width: 28, alignment: .trailing)
        }
    }
}

struct StepView: View {
    let fromValue: String
    let fromLabel: String
    let toValue: String
    let toLabel: String
    let up: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(fromValue).font(.system(.title2, design: .rounded, weight: .semibold)).foregroundStyle(Brand.textSecondary)
                Text(fromLabel).font(.caption).foregroundStyle(Brand.muted)
            }
            StepShape(up: up).stroke(Brand.act, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 44, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(toValue).font(.system(.title2, design: .rounded, weight: .semibold)).foregroundStyle(Brand.act)
                Text(toLabel).font(.caption).foregroundStyle(Brand.muted)
            }
            Spacer(minLength: 0)
        }
    }
}

struct StepShape: Shape {
    let up: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        let y0 = up ? r.maxY - 1 : r.minY + 1, y1 = up ? r.minY + 1 : r.maxY - 1
        p.move(to: CGPoint(x: r.minX, y: y0))
        p.addLine(to: CGPoint(x: r.midX, y: y0))
        p.addLine(to: CGPoint(x: r.midX, y: y1))
        p.addLine(to: CGPoint(x: r.maxX, y: y1))
        return p
    }
}

struct PresenceDots: View {
    let present: [Bool]
    let labels: [String]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(present.indices, id: \.self) { i in
                VStack(spacing: 5) {
                    Circle()
                        .fill(present[i] ? Brand.act : Color.clear)
                        .overlay(Circle().stroke(present[i] ? Brand.act : Brand.dim, lineWidth: 1.5))
                        .frame(width: 14, height: 14)
                    if i < labels.count { Text(labels[i]).font(.caption2).foregroundStyle(Brand.muted) }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct HoursBar: View {
    let seconds: Int
    let decisions: Int

    var body: some View {
        let scale = max(seconds, 4 * 3600)
        VStack(spacing: 5) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Brand.hairline).frame(height: 10)
                    Capsule().fill(Brand.work.opacity(0.75)).frame(width: max(8, g.size.width * CGFloat(seconds) / CGFloat(scale)), height: 10)
                    ForEach(1..<max(2, scale / 3600 + 1), id: \.self) { h in
                        Rectangle().fill(Brand.ground).frame(width: 1, height: 10).offset(x: g.size.width * CGFloat(h * 3600) / CGFloat(scale))
                    }
                }
            }
            .frame(height: 10)
            HStack {
                Text("\(Digest.hours(seconds)) in meetings")
                Spacer()
                Text(decisions == 0 ? "no decision" : "\(decisions) decision\(decisions == 1 ? "" : "s")").foregroundStyle(decisions == 0 ? Brand.bad : Brand.good)
            }
            .font(.caption).foregroundStyle(Brand.muted)
        }
    }
}

/// Digests kept until the moments they were made from change, so a render costs a
/// hash of the readings rather than a pass over every moment.
final class DigestCache {
    private var entries: [String: (stamp: Int, digest: Digest)] = [:]

    func digest(_ all: [Recording], window: DateInterval) -> Digest {
        let key = "\(window.start.timeIntervalSince1970)/\(window.end.timeIntervalSince1970)"
        let stamp = Self.stamp(all)
        if let e = entries[key], e.stamp == stamp { return e.digest }
        let d = Digest.make(all, window: window)
        entries[key] = (stamp, d)
        return d
    }

    /// Everything a digest depends on, as one hash; the clock in ten-minute steps, since
    /// what needs you depends on it.
    static func stamp(_ all: [Recording]) -> Int {
        var h = Hasher()
        h.combine(all.count)
        h.combine(Int(Date().timeIntervalSince1970 / 600))
        for r in all {
            h.combine(r.id)
            h.combine(r.meta.analysedAt?.timeIntervalSince1970 ?? 0)
            h.combine(r.meta.transcribedAt?.timeIntervalSince1970 ?? 0)
            h.combine(r.meta.labelKind ?? "")
            for i in r.meta.insight?.items ?? [] {
                h.combine(i.done == true); h.combine(i.dismissed == true); h.combine(i.reminderID != nil); h.combine(i.eventID != nil)
            }
        }
        return h.finalize()
    }
}

/// A set of moments opened from a finding, a thread or a person.
struct MomentsFilter: Hashable {
    let title: String
    let ids: [String]
}

struct FilteredMoments: View {
    @EnvironmentObject var library: Library
    let filter: MomentsFilter

    var body: some View {
        let moments = library.recordings.filter { filter.ids.contains($0.id) }
        ScrollView {
            VStack(spacing: 10) {
                ForEach(moments) { r in
                    NavigationLink(value: r.id) { MomentCard(recording: r) }.buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(Brand.ground)
        .navigationTitle(filter.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
