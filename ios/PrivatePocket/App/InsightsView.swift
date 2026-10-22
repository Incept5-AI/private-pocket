import SwiftUI

/// What the week or the month adds up to, across moments: the briefing, what needs you
/// now, the threads running through the conversations, the people, and the numbers.
struct InsightsView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var model: AppModel
    @StateObject private var briefings = Briefings()
    @State private var span = 0   // this week, this month

    private var window: DateInterval {
        Calendar.current.dateInterval(of: span == 0 ? .weekOfYear : .month, for: Date())
            ?? DateInterval(start: .distantPast, end: .distantFuture)
    }
    private var key: String { (span == 0 ? "week-" : "month-") + window.start.formatted(.iso8601.year().month().day()) }

    var body: some View {
        let digest = Digest.make(library.recordings, window: window)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Picker("Span", selection: $span) {
                        Text("This week").tag(0)
                        Text("This month").tag(1)
                    }
                    .pickerStyle(.segmented)
                    if digest.moments.isEmpty && digest.needs.isEmpty {
                        Text("Nothing recorded \(span == 0 ? "this week" : "this month") yet. Press the side button on your Pocket, or add the sample moments in Settings.")
                            .font(.body).foregroundStyle(Brand.muted).padding(.top, 28)
                    } else {
                        briefing(digest)
                        needs(digest)
                        threads(digest)
                        people(digest)
                        numbers(digest)
                        if !digest.unread.isEmpty { unread(digest) }
                    }
                }
                .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 32)
            }
            .background(Brand.ground)
            .navigationTitle("Insights")
            .navigationDestination(for: String.self) { id in RecordingDetail(id: id) }
            .navigationDestination(for: MomentsFilter.self) { f in FilteredMoments(filter: f) }
            .task(id: key + "|" + digest.stamp) { await briefings.ensure(key: key, digest: digest) }
        }
    }

    // MARK: The briefing

    @ViewBuilder private func briefing(_ d: Digest) -> some View {
        Text(span == 0 ? "This week" : "This month")
            .font(.system(size: 30, weight: .bold)).tracking(-0.3).padding(.top, 22)
        Text(numbersLine(d)).font(.subheadline).foregroundStyle(Brand.muted).padding(.top, 4)
        if let b = briefings.texts[key], !b.text.isEmpty {
            Text(b.text).font(.system(size: 19, weight: .medium)).lineSpacing(4).padding(.top, 18)
            Text("Written from the moments' summaries, \(b.remote ? "on your server" : "on this iPhone").")
                .font(.caption).foregroundStyle(Brand.dim).padding(.top, 8)
        } else if briefings.writing.contains(key) {
            HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Writing the briefing…").font(.subheadline).foregroundStyle(Brand.muted) }
                .padding(.top, 18)
        } else if let why = Summariser.availability {
            Text(why).font(.subheadline).foregroundStyle(Brand.muted).padding(.top, 18)
        } else if d.moments.isEmpty {
            Text("Nothing in this span yet.").font(.subheadline).foregroundStyle(Brand.muted).padding(.top, 18)
        }
    }

    private func numbersLine(_ d: Digest) -> String {
        var parts = ["\(d.moments.count) \(d.moments.count == 1 ? "moment" : "moments")"]
        if d.totalSeconds > 0 { parts.append(Self.hours(d.totalSeconds)) }
        if d.calls > 0 { parts.append("\(d.calls) \(d.calls == 1 ? "call" : "calls")") }
        if d.meetings > 0 { parts.append("\(d.meetings) \(d.meetings == 1 ? "meeting" : "meetings")") }
        return parts.joined(separator: " · ")
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
                    control(n)
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

    @ViewBuilder private func control(_ n: Digest.Need) -> some View {
        let r = n.recording, item = n.item
        if item.isAction {
            if item.reminderID == nil {
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

    // MARK: Threads

    @ViewBuilder private func threads(_ d: Digest) -> some View {
        if !d.threads.isEmpty {
            SectionTitle("Threads")
            Text("What keeps coming up, and where it got to.").font(.caption).foregroundStyle(Brand.dim).padding(.bottom, 4)
            ForEach(d.threads) { t in
                NavigationLink(value: MomentsFilter(title: t.term, ids: t.moments.map(\.id))) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(t.term).font(.body.weight(.semibold))
                            Text("\(t.moments.count) moments").font(.footnote).foregroundStyle(Brand.muted)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Brand.dim)
                        }
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
        let open = p.waitingOn.filter { !$0.isDone }
        if !open.isEmpty { parts.append("waiting on \(open.count == 1 ? "one thing" : "\(open.count) things")") }
        if p.youOwe > 0 { parts.append("you owe \(p.youOwe == 1 ? "one" : "\(p.youOwe)")") }
        return parts.joined(separator: " · ")
    }

    // MARK: Numbers

    @ViewBuilder private func numbers(_ d: Digest) -> some View {
        if d.totalSeconds > 0 {
            SectionTitle("Time")
            GeometryReader { g in
                HStack(spacing: 2) {
                    Rectangle().fill(Brand.work).frame(width: g.size.width * CGFloat(d.workSeconds) / CGFloat(d.totalSeconds))
                    Rectangle().fill(Brand.life).frame(width: g.size.width * CGFloat(d.lifeSeconds) / CGFloat(d.totalSeconds))
                    Rectangle().fill(Brand.hairline)
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())
            .padding(.top, 6)
            HStack(spacing: 14) {
                legend(Brand.work, "Work \(Self.hours(d.workSeconds))")
                legend(Brand.life, "Life \(Self.hours(d.lifeSeconds))")
                if d.otherSeconds > 0 { legend(Brand.hairline, "Unsorted \(Self.hours(d.otherSeconds))") }
            }
            .font(.caption).foregroundStyle(Brand.muted).padding(.top, 8)
            if let b = d.busiestDay { Text("Busiest day: \(b).").font(.caption).foregroundStyle(Brand.dim).padding(.top, 4) }
        }
    }

    private func legend(_ colour: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(colour).frame(width: 8, height: 8)
            Text(text)
        }
    }

    private static func hours(_ s: Int) -> String {
        s >= 3600 ? "\(s / 3600) h \((s % 3600) / 60)" : "\(max(1, s / 60)) min"
    }

    // MARK: Unread

    @ViewBuilder private func unread(_ d: Digest) -> some View {
        let busy = d.unread.contains { model.working.contains($0.id) }
        HStack(spacing: 10) {
            if busy { ProgressView().controlSize(.small) }
            Text("\(d.unread.count) \(d.unread.count == 1 ? "moment hasn't" : "moments haven't") been read yet, so \(d.unread.count == 1 ? "it isn't" : "they aren't") counted here.")
                .font(.footnote).foregroundStyle(Brand.muted)
            Spacer()
            if !busy, Summariser.availability == nil {
                Button("Read") { Task { await model.analyseMissing(d.unread) } }.font(.footnote.weight(.semibold))
            }
        }
        .padding(.top, 28)
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
