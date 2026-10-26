import EventKit
import SwiftUI

/// A calendar meeting, pushed by value from Coming up or the brief block.
struct MeetingLink: Hashable {
    let event: EKEvent
}

/// A person, pushed by name from a page outside People.
struct PersonLink: Hashable {
    let name: String
}

/// A meeting before it happens, ready to record: when and where, Record into it (the moment
/// is that meeting's whatever the clock says, `RecordContext.meeting`; the card's own button
/// does the same while the page is open around the meeting's time), who is coming and what
/// is open with each, what was recorded in it, and what was said the last time.
struct MeetingView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: Library
    @EnvironmentObject var link: PocketLink
    @EnvironmentObject var devices: DeviceStore
    let event: EKEvent
    @State private var details = false

    var body: some View {
        let all = library.recordings
        let ref = Briefs.ref(event)
        let people = Digest.people(all, limit: 200)
        let coming = ref.others.map { n in (name: n, person: Meeting.person(n, in: people)) }
        let known = coming.compactMap(\.person)
        let briefs = known.map { Briefs.make($0, event: event) }.filter { !$0.theirs.isEmpty || !$0.yours.isEmpty }
        let here = all.filter { Meeting.isIn($0, ref) }
        let before = Meeting.before(ref, all, with: known)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(ref)
                VStack(alignment: .leading, spacing: 24) {
                    if !here.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionTitle("Recorded in it")
                            ForEach(here) { r in NavigationLink(value: r.id) { TapeBand(recording: r) }.buttonStyle(.plain) }
                        }
                    }
                    if !coming.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle("Who's coming")
                            ForEach(coming, id: \.name) { c in invitee(c.name, c.person) }
                        }
                    }
                    if !briefs.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle("Open between you")
                            ForEach(briefs) { b in open(b) }
                        }
                    }
                    if !before.moments.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionTitle(before.title) {
                                if before.moments.count > 3 {
                                    NavigationLink("All \(before.moments.count)", value: MomentsFilter(title: before.title, ids: before.moments.map(\.id)))
                                        .font(.subheadline.weight(.semibold)).tint(Brand.act)
                                }
                            }
                            ForEach(before.moments.prefix(3)) { r in NavigationLink(value: r.id) { TapeBand(recording: r) }.buttonStyle(.plain) }
                        }
                    }
                    if coming.isEmpty && here.isEmpty && before.moments.isEmpty {
                        Text("Nothing said in it yet, and no one invited the app knows. Record it, and the moment keeps this meeting and who was invited.")
                            .font(.subheadline).foregroundStyle(Brand.muted)
                    }
                }
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 28)
            }
        }
        .background(Brand.ground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { details = true } label: { Image(systemName: "calendar") }
                    .accessibilityLabel("The event in your calendar")
            }
        }
        .sheet(isPresented: $details) {
            EventSheet(event: event) { details = false }
                .ignoresSafeArea()
                .presentationDragIndicator(.visible)
        }
        .onAppear { model.pageContext = RecordContext(meeting: ref) }
        .onDisappear { if let m = model.pageContext?.meeting, Meeting.same(m, ref) { model.pageContext = nil } }
    }

    // MARK: Header and Record

    private func header(_ ref: CalendarEventRef) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.everyMinute) { t in
                Text(Meeting.when(ref.start, ref.end, now: t.date).uppercased())
                    .font(.caption2.weight(.bold)).tracking(0.7).opacity(0.75)
            }
            Text(ref.title.isEmpty ? "A meeting" : ref.title).font(.largeTitle.weight(.bold)).tracking(-0.6)
                .fixedSize(horizontal: false, vertical: true)
            if let place = ref.location?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty {
                Label(place, systemImage: "mappin.and.ellipse").font(.callout.weight(.semibold)).lineLimit(2)
            }
            recordBar(ref).padding(.top, 10)
        }
        .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.work).foregroundStyle(Brand.onWork)
    }

    /// The one thing the page is for. Recording into this meeting shows the timer and brings
    /// the recording back; anything else in the way says what it is.
    @ViewBuilder private func recordBar(_ ref: CalendarEventRef) -> some View {
        let connected = link.connectedDeviceID != nil && link.connectedDeviceID == devices.selectedID
        let since = link.status.recordingSince
        let intoThis = since != nil && model.recordingContext?.meeting.map { Meeting.same($0, ref) } == true
        let ready = model.canCommand && connected
        Button {
            if since != nil { withAnimation(.spring(duration: 0.6)) { model.takeover = true } }
            else { Task { await model.toggleRecording() } }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Brand.onRecord).frame(width: 26, height: 26)
                    if since != nil {
                        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Brand.record).frame(width: 9, height: 9)
                    } else {
                        Circle().fill(Brand.record).frame(width: 10, height: 10)
                    }
                }
                if let since, intoThis {
                    Text("Recording it · ").font(.headline) + Text(timerInterval: since...Date.distantFuture, countsDown: false).font(.headline.monospacedDigit())
                } else {
                    Text(since != nil ? "Recording something else" : !model.canCommand ? "Pair your Pocket to record from here"
                         : !connected ? "Your Pocket is away" : "Record this meeting").font(.headline)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.record, in: Capsule())
            .foregroundStyle(Brand.onRecord)
            .shadow(color: Brand.record.opacity(ready || since != nil ? 0.4 : 0), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(since == nil && (!ready || model.toggling))
        .opacity(since == nil && !ready ? 0.45 : model.toggling ? 0.7 : 1)
        if since == nil, Meeting.near(ref) {
            Text("Or press the button on your Pocket while this page is open.").font(.footnote.weight(.semibold)).opacity(0.75)
        }
    }

    // MARK: People

    @ViewBuilder private func invitee(_ name: String, _ person: Digest.Person?) -> some View {
        let row = HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(person?.name ?? name).font(.callout.weight(.semibold)).foregroundStyle(person == nil ? Brand.textSecondary : Brand.text)
                Text(person.map { PersonCard.standing($0) } ?? "Not in your moments yet").font(.caption).foregroundStyle(Brand.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            if person != nil { Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Brand.dim) }
        }
        .contentShape(Rectangle())
        if let p = person {
            NavigationLink(value: PersonLink(name: p.name)) { row }.buttonStyle(.plain)
        } else {
            row
        }
    }

    /// What one person promised and what you owe them, three of each at most.
    private func open(_ b: Brief) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(b.theirs.prefix(3)) { t in
                line("\(b.person.name) said they'd \(t.text.lowercased())", t.when)
            }
            ForEach(Array(b.yours.prefix(3).enumerated()), id: \.offset) { _, pair in
                NavigationLink(value: pair.0.id) { line("You owe \(b.person.name): \(pair.1.text.lowercased())", pair.1.when) }.buttonStyle(.plain)
            }
            if let f = b.figure { line("Last figure with \(b.person.name): \(f)", nil) }
        }
    }

    private func line(_ text: String, _ when: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(text).font(.callout.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
            if let when { Text(when).font(.caption).foregroundStyle(Brand.muted) }
        }
        .contentShape(Rectangle())
    }
}

/// A meeting's ties to the moments: which were recorded in it, which came before in the same
/// series or with the same people, and who of the people it invites the readings know.
enum Meeting {
    /// The same occurrence: the same event at the same start (a series shares its id).
    static func same(_ a: CalendarEventRef, _ b: CalendarEventRef) -> Bool {
        a.id == b.id && abs(a.start.timeIntervalSince(b.start)) < 60
    }

    /// Recorded in this meeting: its event, or before it is read, the meeting it was recorded into.
    static func isIn(_ r: Recording, _ ref: CalendarEventRef) -> Bool {
        guard let e = r.meta.event ?? r.meta.context?.meeting else { return false }
        return same(e, ref)
    }

    /// From half an hour before until it ends: when the card's own button records into it.
    static func near(_ ref: CalendarEventRef, now: Date = Date()) -> Bool {
        now > ref.start.addingTimeInterval(-30 * 60) && now < ref.end
    }

    /// Earlier times of the same meeting (the same series, or the same title with someone
    /// invited both times), else the latest moments with the people coming; newest first.
    static func before(_ ref: CalendarEventRef, _ all: [Recording], with people: [Digest.Person]) -> (title: String, moments: [Recording]) {
        let title = ref.title.trimmingCharacters(in: .whitespaces).lowercased()
        let invited = Set(ref.others.map { $0.lowercased() })
        let series = all.filter { r in
            guard let e = r.meta.event, !same(e, ref), e.start < ref.start else { return false }
            if let id = ref.id, e.id == id { return true }
            return !title.isEmpty && e.title.trimmingCharacters(in: .whitespaces).lowercased() == title
                && (invited.isEmpty || !invited.isDisjoint(with: e.others.map { $0.lowercased() }))
        }
        let newest: (Recording, Recording) -> Bool = { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
        if !series.isEmpty { return ("Last time", series.sorted(by: newest)) }
        var seen = Set<String>()
        let with = people.flatMap(\.moments).filter { !isIn($0, ref) && seen.insert($0.id).inserted }
        return (people.count == 1 ? "Last with \(people[0].name)" : "Last with them", with.sorted(by: newest))
    }

    /// The person the readings know by an invitee's name: the same name, or the same first
    /// name where the surnames do not differ and no one else shares it.
    static func person(_ invitee: String, in people: [Digest.Person]) -> Digest.Person? {
        if let p = people.first(where: { $0.name.caseInsensitiveCompare(invitee) == .orderedSame }) { return p }
        let parts = invitee.lowercased().split(separator: " ")
        let same = people.filter { p in
            let q = p.name.lowercased().split(separator: " ")
            guard let first = q.first, first == parts.first else { return false }
            return q.count == 1 || parts.count == 1 || q.last == parts.last
        }
        return same.count == 1 ? same[0] : nil
    }

    /// "Today · 14:00–15:00 · in 25 min", "Now · until 15:00", "Tomorrow · 09:30–10:00".
    static func when(_ start: Date, _ end: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        func t(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
        if start <= now { return "Now · until \(t(end))" }
        let day = cal.isDateInToday(start) ? "Today" : cal.isDateInTomorrow(start) ? "Tomorrow" : start.formatted(.dateTime.weekday(.wide))
        let minutes = Int(start.timeIntervalSince(now) / 60)
        return "\(day) · \(t(start))–\(t(end))" + (minutes < 120 ? " · in \(max(1, minutes)) min" : "")
    }
}
