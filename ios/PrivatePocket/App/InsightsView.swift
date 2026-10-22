import SwiftUI

/// What the week or the month adds up to, across moments: the briefing, the days,
/// the commitments either way, what needs you now, what was decided, asked and
/// counted, the threads, and the people.
struct InsightsView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var model: AppModel
    @StateObject private var briefings = Briefings()
    @State private var span = 0   // this week, this month
    @State private var showYours = false
    @State private var showTheirs = false

    private var window: DateInterval {
        Calendar.current.dateInterval(of: span == 0 ? .weekOfYear : .month, for: Date())
            ?? DateInterval(start: .distantPast, end: .distantFuture)
    }
    private var key: String { (span == 0 ? "week-" : "month-") + window.start.formatted(.iso8601.year().month().day()) }

    var body: some View {
        let d = Digest.make(library.recordings, window: window)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Picker("Span", selection: $span) {
                        Text("This week").tag(0)
                        Text("This month").tag(1)
                    }
                    .pickerStyle(.segmented)
                    if d.moments.isEmpty && d.needs.isEmpty {
                        Text("Nothing recorded \(span == 0 ? "this week" : "this month") yet. Press the side button on your Pocket, or add the sample moments in Settings.")
                            .font(.body).foregroundStyle(Brand.muted).padding(.top, 28)
                    } else {
                        header(d)
                        briefing(d)
                        if d.totalSeconds > 0 { daysChart(d) }
                        ledger(d)
                        needs(d)
                        lines("Decided", symbol: "checkmark.seal", d.decisions)
                        lines("Still open", symbol: "questionmark.circle", d.questions)
                        lines("Figures", symbol: "number", d.figures)
                        threads(d)
                        people(d)
                        reading(d)
                    }
                }
                .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 32)
            }
            .background(Brand.ground)
            .navigationTitle("Insights")
            .navigationDestination(for: String.self) { id in RecordingDetail(id: id) }
            .navigationDestination(for: MomentsFilter.self) { f in FilteredMoments(filter: f) }
            // While older readings are being redone the id holds still, so the re-reading runs
            // once through; the briefing is written when the readings have settled.
            .task(id: key + "|" + (d.outdated.isEmpty ? d.stamp : "rereading")) {
                if !d.outdated.isEmpty { await model.rereadOutdated(d.outdated); return }
                await briefings.ensure(key: key, digest: d)
            }
        }
    }

    // MARK: Header and briefing

    @ViewBuilder private func header(_ d: Digest) -> some View {
        Text(span == 0 ? "This week" : "This month")
            .font(.system(size: 30, weight: .bold)).tracking(-0.3).padding(.top, 22)
        HStack(spacing: 0) {
            figure("\(d.moments.count)", d.moments.count == 1 ? "moment" : "moments")
            figure(Self.hours(d.totalSeconds), "recorded")
            figure("\(d.people.count)", d.people.count == 1 ? "person" : "people")
            figure("\(d.yoursOpen.count + d.theirs.filter { !$0.1.isDone }.count)", "open")
        }
        .padding(.top, 12)
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(Brand.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func briefing(_ d: Digest) -> some View {
        if let b = briefings.texts[key], !b.text.isEmpty {
            Text(b.text).font(.system(size: 19, weight: .medium)).lineSpacing(4).padding(.top, 20)
            Text("Written from the moments' summaries, \(b.remote ? "on your server" : "on this iPhone").")
                .font(.caption).foregroundStyle(Brand.dim).padding(.top, 8)
        } else if briefings.writing.contains(key) {
            HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Writing the briefing…").font(.subheadline).foregroundStyle(Brand.muted) }
                .padding(.top, 20)
        } else if let why = Summariser.availability {
            Text(why).font(.subheadline).foregroundStyle(Brand.muted).padding(.top, 20)
        }
    }

    // MARK: The days

    @ViewBuilder private func daysChart(_ d: Digest) -> some View {
        let top = max(1, d.days.map(\.total).max() ?? 1)
        let cal = Calendar.current
        SectionTitle("Your days") {
            HStack(spacing: 12) {
                legend(Brand.work, "Work \(Self.hours(d.workSeconds))")
                legend(Brand.life, "Life \(Self.hours(d.lifeSeconds))")
                if d.otherSeconds > 0 { legend(Brand.hairline, "Unsorted") }
            }
            .font(.caption).foregroundStyle(Brand.muted)
        }
        HStack(alignment: .bottom, spacing: d.days.count > 10 ? 3 : 8) {
            ForEach(d.days) { day in
                VStack(spacing: 4) {
                    VStack(spacing: 1) {
                        Spacer(minLength: 0)
                        if day.other > 0 { Rectangle().fill(Brand.hairline).frame(height: max(2, 90 * CGFloat(day.other) / CGFloat(top))) }
                        if day.life > 0 { Rectangle().fill(Brand.life).frame(height: max(2, 90 * CGFloat(day.life) / CGFloat(top))) }
                        if day.work > 0 { Rectangle().fill(Brand.work).frame(height: max(2, 90 * CGFloat(day.work) / CGFloat(top))) }
                        if day.total == 0 { Rectangle().fill(Brand.hairline.opacity(0.5)).frame(height: 2) }
                    }
                    .frame(height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    if d.days.count <= 10 || cal.component(.weekday, from: day.date) == 2 {
                        Text(d.days.count <= 10 ? day.date.formatted(.dateTime.weekday(.narrow)) : day.date.formatted(.dateTime.day()))
                            .font(.system(size: 10, weight: cal.isDateInToday(day.date) ? .bold : .medium))
                            .foregroundStyle(cal.isDateInToday(day.date) ? Brand.text : Brand.muted)
                    } else {
                        Text(" ").font(.system(size: 10))
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 6)
        if let b = d.busiestDay {
            Text("Busiest: \(b.date.formatted(.dateTime.weekday(.wide))), \(Self.hours(b.total)).")
                .font(.caption).foregroundStyle(Brand.dim).padding(.top, 8)
        }
    }

    private func legend(_ colour: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(colour).frame(width: 8, height: 8)
            Text(text)
        }
    }

    // MARK: Commitments

    @ViewBuilder private func ledger(_ d: Digest) -> some View {
        if !d.yours.isEmpty || !d.theirs.isEmpty {
            SectionTitle("Commitments")
            ledgerRow(title: "You", open: d.yoursOpen.count, done: d.yoursDone.count,
                      overdue: d.yoursOpen.filter { $0.1.date.map { $0 < Date() } ?? false }.count,
                      colour: Brand.act, expanded: $showYours)
            if showYours {
                ForEach(Array(d.yours.enumerated()), id: \.offset) { _, pair in itemRow(pair.0, pair.1) }
            }
            ledgerRow(title: "Owed to you", open: d.theirs.filter { !$0.1.isDone }.count, done: d.theirs.filter(\.1.isDone).count, overdue: d.theirsOverdue.count,
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
            Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(item.isDone ? Brand.good : Brand.dim).padding(.top, 2)
            NavigationLink(value: r.id) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text).font(.subheadline).strikethrough(item.isDone).foregroundStyle(item.isDone ? Brand.dim : Brand.text)
                    Text([item.who, item.when, r.displayTitle].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(Brand.muted).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            control(r, item)
        }
        .padding(.vertical, 6)
        .padding(.leading, 8)
    }

    // MARK: Needs you

    @ViewBuilder private func needs(_ d: Digest) -> some View {
        if !d.needs.isEmpty {
            SectionTitle("Needs you")
            ForEach(d.needs) { n in
                HStack(alignment: .top, spacing: 12) {
                    Text(n.why.uppercased())
                        .font(.system(size: 9, weight: .bold)).tracking(0.5)
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

    // MARK: Decided, still open, figures

    @ViewBuilder private func lines(_ title: String, symbol: String, _ items: [Digest.Line]) -> some View {
        if !items.isEmpty {
            SectionTitle(title)
            ForEach(items.prefix(8)) { line in
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
            if items.count > 8 { Text("and \(items.count - 8) more").font(.caption).foregroundStyle(Brand.dim).padding(.top, 4) }
        }
    }

    // MARK: Threads

    @ViewBuilder private func threads(_ d: Digest) -> some View {
        if !d.threads.isEmpty {
            SectionTitle("Threads")
            Text("What keeps coming up, and where it got to.").font(.caption).foregroundStyle(Brand.dim).padding(.bottom, 4)
            ForEach(d.threads) { t in
                NavigationLink(value: MomentsFilter(title: t.term, ids: t.moments.map(\.id))) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(t.term).font(.body.weight(.semibold))
                            Text("\(t.moments.count) moments").font(.footnote).foregroundStyle(Brand.muted)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Brand.dim)
                        }
                        timeline(t.dates, in: d.window)
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
    }

    /// The moments of a thread as dots along the span.
    private func timeline(_ dates: [Date], in window: DateInterval) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.hairline).frame(height: 2)
                ForEach(Array(dates.enumerated()), id: \.offset) { _, d in
                    let f = max(0, min(1, d.timeIntervalSince(window.start) / max(1, window.duration)))
                    Circle().fill(Brand.act).frame(width: 7, height: 7).offset(x: g.size.width * CGFloat(f) - 3.5)
                }
            }
            .frame(height: 7)
        }
        .frame(height: 7)
        .padding(.vertical, 3)
    }

    // MARK: People

    @ViewBuilder private func people(_ d: Digest) -> some View {
        if !d.people.isEmpty {
            SectionTitle("People")
            ForEach(Array(d.people.enumerated()), id: \.element.id) { i, p in
                NavigationLink(value: MomentsFilter(title: p.name, ids: p.moments.map(\.id))) {
                    HStack(spacing: 12) {
                        Text(String(p.name.prefix(1)).uppercased())
                            .font(.system(size: 12, weight: .bold))
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

    private static func hours(_ s: Int) -> String {
        s >= 3600 ? "\(s / 3600) h \((s % 3600) / 60)" : "\(max(1, s / 60)) min"
    }
}

/// A set of moments opened from a thread or a person.
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
