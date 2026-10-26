import EventKit
import SwiftUI

/// Now: the right thing for the hour, then what is coming, then the tape. Setting up or
/// pairing when that is what matters, and the recording; then at most three blocks, ranked
/// (`nowCards`): what was just read, what needs you, the day at six or yesterday, set, in
/// the morning, what the app noticed. Under them, quietly, the meetings and dates to the end
/// of tomorrow (`AheadList`), and the tape of everything said.
struct NowView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: Library
    @EnvironmentObject var devices: DeviceStore
    @EnvironmentObject var link: PocketLink
    @EnvironmentObject var threads: ThreadStore
    @State private var path = NavigationPath()
    @State private var showPocket = false
    @State private var showSettings = false
    @State private var scale: TapeScale = .day
    @State private var focus = Date()
    @State private var cache = DigestCache()
    @State private var visible: Set<String> = []
    @State private var scrolling = false
    @State private var hideHandle: Task<Void, Never>?
    @State private var dismissed: Set<String> = Prefs.dismissedFindings
    @State private var hidden: Set<String> = Prefs.hiddenBlocks
    @State private var toast: String?
    /// The briefs to the end of tomorrow; the one within the hour is a block, the rest wait in Coming up.
    @State private var briefs: [Brief] = []
    /// The calendar's meetings to the end of tomorrow, for Coming up.
    @State private var meetings: [Ahead] = []
    /// The blocks past the first three, unfolded.
    @State private var allBlocks = false
    @State private var briefsAsked = Prefs.askedBriefs
    @State private var deleting: Recording?
    /// Choosing moments to delete together: entered from a moment's menu.
    @State private var selecting = false
    @State private var picked: Set<String> = []
    @State private var confirmMany = false
    @StateObject private var replay = Replay()

    private var recording: Bool { link.status.recordingSince != nil }

    var body: some View {
        let all = library.recordings
        let days = TapeDays.grouped(all)
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                // A list, styled as the page, so swiping a row is the system's own and never fights the scroll.
                List {
                    Group {
                        header
                        blocks(all)
                        tapeHeader
                        switch scale {
                        case .day:
                            ForEach(days, id: \.day) { group in
                                dayHeader(group.day, moments: group.moments)
                                    .id(TapeDays.id(group.day))
                                ForEach(group.moments) { r in band(r) }
                            }
                            if days.isEmpty { emptyTape }
                        case .week: TapeWeek(all: all, focus: focus) { land($0, proxy) }
                        case .month: TapeMonth(all: all, focus: focus) { land($0, proxy) }
                        case .year: TapeYear(all: all, focus: focus) { land($0, proxy) }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 7, leading: 20, bottom: 7, trailing: 20))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 1)
                .contentMargins(.bottom, 28, for: .scrollContent)
                .background(Brand.ground)
                .scrollIndicators(.hidden)
                .safeAreaInset(edge: .bottom) { selectionBar }
                .overlay(alignment: .trailing) {
                    if scale == .day, all.count >= 2, !selecting {
                        DateFinder(moments: all.compactMap { r in r.startedAt.map { (id: r.id, at: $0) } }.sorted { $0.at > $1.at },
                                   topDate: all.filter { visible.contains($0.id) }.compactMap(\.startedAt).max(),
                                   active: scrolling) { id in
                            withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .top) }
                        }
                        .padding(.vertical, 6).padding(.trailing, 2)
                        .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .bottom) { toastView }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: String.self) { id in RecordingDetail(id: id) }
                .navigationDestination(for: MomentsFilter.self) { f in FilteredMoments(filter: f) }
                .navigationDestination(for: ThreadLink.self) { ThreadView(id: $0.id) }
                .sheet(isPresented: $showPocket) { PocketView() }
                .navigationDestination(for: MeetingLink.self) { MeetingView(event: $0.event) }
                .navigationDestination(for: PersonLink.self) { l in
                    if let p = Digest.people(library.recordings, limit: 200).first(where: { $0.name == l.name }) { PersonView(person: p) }
                }
                .sheet(isPresented: $showSettings) { SettingsView(onDone: { showSettings = false }) }
                .confirmationDialog("Delete this moment?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                    titleVisibility: .visible, presenting: deleting) { r in
                    Button("Delete", role: .destructive) {
                        withAnimation { library.delete(r) }
                        deleting = nil
                    }
                } message: { _ in
                    Text("The recording and everything read from it. Reminders and Calendar keep what was sent to them.")
                }
                .onChange(of: model.openMomentID, initial: true) {
                    guard let id = model.openMomentID else { return }
                    model.openMomentID = nil
                    path.append(id)
                }
                .task(id: all.count) {
                    while !Task.isCancelled {
                        refreshAhead()
                        try? await Task.sleep(for: .seconds(60))
                    }
                }
                // Listen back stops when a moment opens, the page is left, or a recording starts.
                .onChange(of: path.count) { replay.stop() }
                .onChange(of: recording) { _, now in if now { replay.stop() } }
                .onAppear { dismissed = Prefs.dismissedFindings }
                .onDisappear { replay.stop() }
            }
        }
    }

    // MARK: Header

    /// The day and the Pocket's state above the greeting, Settings beside them, and Record
    /// as an amber shutter beside the greeting.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.footnote.weight(.semibold)).foregroundStyle(Brand.muted)
                Spacer(minLength: 8)
                if !devices.devices.isEmpty { PocketPill { showPocket = true } }
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape").font(.body.weight(.semibold)).foregroundStyle(Brand.textSecondary)
                        .frame(width: 36, height: 36).background(Brand.surface, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
            HStack(alignment: .center) {
                Text(greeting).font(.largeTitle.weight(.bold)).tracking(-0.5).lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 8)
                if !devices.devices.isEmpty { RecordButton() }
            }
        }
        .padding(.top, 8)
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        if recording { return "Recording." }
        return h < 12 ? "Good morning." : h < 18 ? "Good afternoon." : "Good evening."
    }

    // MARK: The blocks

    private func hide(_ key: String) {
        withAnimation(.easeInOut(duration: 0.25)) { _ = hidden.insert(key) }
        Prefs.hiddenBlocks = hidden
    }

    /// What may stand above the tape, besides the Pocket's own state: three, in the order
    /// they matter, and the rest folded to one line that names them.
    static let blockLimit = 3

    /// The Pocket's state (set up, pairing, recording) always shows and is not counted. Then
    /// the blocks that tell or ask something, ranked, at most three; then what is coming,
    /// quietly; then the tape.
    @ViewBuilder private func blocks(_ all: [Recording]) -> some View {
        if devices.devices.isEmpty {
            NowBlock(tint: Brand.paper, ink: Brand.onPaper, tag: "Your Pocket", title: "Press once. Hear everything.",
                     line: "Have your Pocket nearby and switched on. No account, no cloud.",
                     action: "Find my Pocket") { showPocket = true }
                .cardGestures(primary: "Find my Pocket", act: { showPocket = true }, dismiss: nil)
        } else if !model.canCommand {
            NowBlock(tint: Brand.record, ink: Brand.onRecord, tag: "Needs pairing", title: "Hold the side button for five seconds, until the light blinks blue.",
                     line: "The app pairs by itself while it blinks. Recordings started with the button still stream here meanwhile.",
                     action: "Show me") { showPocket = true }
                .cardGestures(primary: "Show me", act: { showPocket = true }, dismiss: nil)
        }
        if recording || !model.saving.isEmpty {
            liveBlock.cardGestures(primary: "Open", act: { withAnimation(.spring(duration: 0.6)) { model.takeover = true } }, dismiss: nil)
        }
        let cards = nowCards(all)
        ForEach(allBlocks ? cards : Array(cards.prefix(Self.blockLimit))) { card in
            cardView(card, all: all)
        }
        if cards.count > Self.blockLimit {
            foldRow(Array(cards.dropFirst(Self.blockLimit)))
        }
        let soonBrief = cards.compactMap { if case .brief(let b) = $0 { b } else { nil } }.first
        let ahead = (meetings.filter { m in
            guard let b = soonBrief, case .meeting(let e) = m.opens else { return true }
            return !(e.eventIdentifier == b.event.eventIdentifier && e.startDate == b.start)
        } + Ahead.said(all, meetings: meetings)).sorted { $0.at < $1.at }
        if !ahead.isEmpty {
            AheadList(rows: ahead) { a in
                switch a.opens {
                case .meeting(let e): path.append(MeetingLink(event: e))
                case .moment(let id): path.append(id)
                }
            }
        }
    }

    /// The blocks that tell or ask something, in the order they matter. An answer you asked
    /// the card for, while fresh; the meeting within the hour; the moment just read; what is
    /// late or owed; the day's summary (yesterday's in the morning, today's from six); a
    /// thread back after a quiet; the calendar ask; what the app noticed. Whatever was put
    /// away is left out.
    private func nowCards(_ all: [Recording]) -> [NowCard] {
        let hour = Calendar.current.component(.hour, from: Date())
        let cal = Calendar.current
        let today = Self.localDay()
        var out: [NowCard] = []
        if let a = model.cardAnswers.last, Date().timeIntervalSince(a.at) < 2 * 3600 { out.append(.answer(a)) }
        if !recording, let b = briefs.first(where: { $0.start.timeIntervalSinceNow < 3600 }) { out.append(.brief(b)) }
        if let r = justRead(all) { out.append(.read(r)) }
        let needs = Digest.needs(all)
        if !needs.isEmpty { out.append(.needs(needs, day: today)) }
        if hour < 12, let y = yesterday(all, cal: cal) { out.append(.yesterday(y.moments, headline: y.headline, line: y.line, day: today)) }
        if hour >= 17, let t = todayLine(all, cal: cal) { out.append(.evening(t.title, line: t.line, action: t.action, id: t.id, day: today)) }
        if !recording, let t = threads.live(all).filter(\.isBack).max(by: { ($0.last ?? .distantPast) < ($1.last ?? .distantPast) }),
           let latest = t.moments.last {
            out.append(.back(t, latest: latest.id))
        }
        if !recording, !Briefs.calendarAllowed, !briefsAsked, !all.isEmpty { out.append(.askCalendar) }
        if let f = topFinding(all) { out.append(.finding(f)) }
        return out.filter { !hidden.contains($0.id) }
    }

    @ViewBuilder private func cardView(_ card: NowCard, all: [Recording]) -> some View {
        switch card {
        case .answer(let a):
            NowBlock(tint: Brand.record, ink: Brand.onRecord, tag: "Said to the card", title: a.answer, line: "“Pocket, \(a.question)”")
                .cardGestures(primary: nil, act: nil, dismiss: { hide(card.id) })
        case .brief(let b):
            NowBlock(tint: Brand.act, ink: Brand.onAct,
                     tag: "At \(b.start.formatted(date: .omitted, time: .shortened)) · \(b.person.name)" + (b.minutesAway > 0 ? " · in \(b.minutesAway) min" : ""),
                     title: b.count == 0 ? "Nothing open with \(b.person.name)." : "\(b.count) thing\(b.count == 1 ? "" : "s") open with \(b.person.name).",
                     line: Briefs.line(b), action: "Get ready") { path.append(MeetingLink(event: b.event)) }
                .cardGestures(primary: "Get ready", act: { path.append(MeetingLink(event: b.event)) }, dismiss: { hide(card.id) })
        case .askCalendar:
            VStack(alignment: .leading, spacing: 8) {
                Text("BRIEFS BEFORE MEETINGS").font(.caption2.weight(.bold)).tracking(0.7).foregroundStyle(Brand.paperMuted)
                Text("Ten minutes before a meeting with someone you've recorded, see what's open between you. And name who spoke from who was invited.").font(.callout.weight(.semibold)).foregroundStyle(Brand.onPaper)
                Text("Tap to allow Calendar · swipe away for not now").font(.footnote.weight(.bold)).foregroundStyle(Brand.onPaper.opacity(0.7))
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.paper, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .onTapGesture { allowCalendar(all) }
            .cardGestures(primary: "Allow Calendar", act: { allowCalendar(all) },
                          dismiss: { Prefs.askedBriefs = true; withAnimation { briefsAsked = true } })
        case .back(let t, _):
            ReturnBlock(thread: t) { path.append(ThreadLink(id: t.id)) }
                .cardGestures(primary: "Open the thread", act: { path.append(ThreadLink(id: t.id)) }, dismiss: { hide(card.id) })
        case .read(let r):
            NowBlock(tint: r.kind.isLife ? Brand.life : Brand.work, ink: r.kind.isLife ? Brand.onLife : Brand.onWork,
                     tag: "Just read · \(r.kind.label)", title: r.quote,
                     line: readLine(r), action: "Open it") { path.append(r.id) }
                .cardGestures(primary: "Open it", act: { path.append(r.id) }, dismiss: { hide(card.id) })
        case .yesterday(let moments, let headline, let line, _):
            let lines = Replay.lines(from: moments)
            let tape = { path.append(MomentsFilter(title: "Yesterday", ids: moments.map(\.id))) }
            VStack(alignment: .leading, spacing: 8) {
                Text("YESTERDAY, SET · \(moments.count) CONVERSATION\(moments.count == 1 ? "" : "S")").font(.caption2.weight(.bold)).tracking(0.7).foregroundStyle(Brand.paperMuted)
                Text(headline).font(.title3.weight(.bold)).foregroundStyle(Brand.onPaper).fixedSize(horizontal: false, vertical: true)
                Text(line).font(.subheadline).foregroundStyle(Brand.onPaper.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                if !lines.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: replay.playing ? "stop.fill" : "play.fill").foregroundStyle(Brand.record)
                        Text(replay.playing ? "Playing \(replay.index + 1) of \(lines.count) · tap to stop" : "Listen back · \(lines.count) lines, \(max(1, lines.count * 8 / 60)) min · tap to play")
                            .font(.footnote.weight(.bold)).foregroundStyle(Brand.onPaper.opacity(0.8))
                    }
                    .padding(.top, 2)
                }
                if let c = replay.current { Text("“\(c.text)”").font(.footnote.weight(.medium)).foregroundStyle(Brand.onPaper.opacity(0.8)).lineLimit(2) }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.paper, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .onTapGesture {
                if lines.isEmpty { tape() }
                else if replay.playing { replay.stop() } else { replay.play(lines) }
            }
            .cardGestures(primary: lines.isEmpty ? "Yesterday's tape" : "Listen back",
                          act: { if lines.isEmpty { tape() } else if !replay.playing { replay.play(lines) } },
                          dismiss: { replay.stop(); hide(card.id) })
        case .evening(let title, let line, let action, let id, _):
            NowBlock(tint: Brand.work, ink: Brand.onWork, tag: "Six o'clock", title: title, line: line, action: action) {
                if let id { path.append(id) }
            }
            .cardGestures(primary: id == nil ? nil : action, act: id.map { id in { path.append(id) } }, dismiss: { hide(card.id) })
        case .needs(let needs, _):
            NeedsBlock(needs: needs, open: { path.append($0) }, openAll: { openNeeds(needs) })
                .cardGestures(primary: "Open the first", act: { if let n = needs.first { path.append(n.recording.id) } }, dismiss: { hide(card.id) })
        case .finding(let f):
            let notRight = {
                // Read and written against what is stored: You keeps its own copy, and neither undoes the other.
                var stored = Prefs.dismissedFindings
                stored.insert("week|" + f.id)
                Prefs.dismissedFindings = stored
                withAnimation { dismissed = stored }
            }
            FindingBlock(finding: f, perform: { perform($0) }, notRight: notRight)
                .cardGestures(primary: f.choices.first?.label, act: f.choices.first.map { c in { perform(c.action) } }, dismiss: notRight)
        }
    }

    /// The blocks past the first three, as one quiet line naming them; a tap shows them all.
    private func foldRow(_ rest: [NowCard]) -> some View {
        Button { withAnimation(.spring(duration: 0.35)) { allBlocks.toggle() } } label: {
            HStack(spacing: 8) {
                Text(allBlocks ? "Show fewer" : "\(rest.count) more · " + rest.map(\.name).joined(separator: ", "))
                    .font(.footnote.weight(.semibold)).foregroundStyle(Brand.muted).lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: allBlocks ? "chevron.up" : "chevron.down").font(.caption.weight(.bold)).foregroundStyle(Brand.dim)
            }
            .padding(.horizontal, 18).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(allBlocks ? "Folds the blocks past the first three" : "Shows every block")
    }

    private func allowCalendar(_ all: [Recording]) {
        Task {
            if await Planner.allowEvents() { await Briefs.allowNotifications(); Briefs.schedule(all); refreshAhead() }
            Prefs.askedBriefs = true; briefsAsked = true
        }
    }

    /// The briefs and the meetings to the end of tomorrow, read from the calendar once a
    /// minute rather than on every redraw.
    private func refreshAhead() {
        let hours = max(1, Ahead.horizon.timeIntervalSinceNow / 3600)
        briefs = Briefs.calendarAllowed ? Briefs.upcoming(library.recordings, hours: hours) : []
        meetings = Ahead.meetings(briefs: briefs)
    }

    /// Every moment with something late or owed, most pressing first.
    private func openNeeds(_ needs: [Digest.Need]) {
        var seen = Set<String>()
        path.append(MomentsFilter(title: "Needs you", ids: needs.map(\.recording.id).filter { seen.insert($0).inserted }))
    }

    private var liveBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                if let since = link.status.recordingSince {
                    Text(timerInterval: since...Date.distantFuture, countsDown: false)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold)).monospacedDigit()
                } else {
                    Text("Saving…").font(.title2.weight(.bold))
                }
                Spacer()
                Text(model.recordingContext.map { $0.label.uppercased() } ?? "LIVE").font(.caption.weight(.bold)).tracking(1).lineLimit(1)
            }
            NowLiveWords()
            if let h = model.liveThread {
                ThreadHintBox(hint: h).onTapGesture { path.append(ThreadLink(id: h.id)) }
            }
            let caught = model.liveShown(3)
            if !caught.items.isEmpty || !model.liveDecisions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(caught.items) { item in
                        let confirmed = model.liveConfirmed.contains(item.id)
                        HStack(spacing: 10) {
                            Text(item.isAction ? "TO DO" : item.isDate ? "DATE" : "PROMISE").font(.caption2.weight(.bold)).tracking(0.6).foregroundStyle(Brand.record).frame(width: 56, alignment: .leading)
                            Text((item.isPromise ? (item.who.map { "\($0): " } ?? "") : "") + item.text).font(.subheadline.weight(.semibold)).foregroundStyle(Color(hex: 0xFFF7E8)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            Button { model.confirmLive(item) } label: { Image(systemName: "checkmark").font(.caption.weight(.bold)).frame(width: 30, height: 30).background(confirmed ? Brand.act : Color(hex: 0x4A3410), in: Circle()).foregroundStyle(confirmed ? Brand.onAct : Color(hex: 0xFFF7E8)) }.buttonStyle(.plain).accessibilityLabel("Keep it")
                            Button { model.dismissLive(item) } label: { Image(systemName: "xmark").font(.caption.weight(.bold)).frame(width: 30, height: 30).background(Color(hex: 0x4A3410), in: Circle()).foregroundStyle(Color(hex: 0xFFF7E8)) }.buttonStyle(.plain).accessibilityLabel("Drop it")
                        }
                        .padding(10)
                        .background(Brand.onRecord, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    if caught.earlier > 0 {
                        Text("\(caught.earlier) earlier" + (caught.earlierKept > 0 ? ", \(caught.earlierKept) kept" : "")).font(.caption.weight(.bold)).opacity(0.7)
                    }
                    ForEach(model.liveDecisions.prefix(3), id: \.self) { d in
                        HStack(spacing: 10) {
                            Text("DECIDED").font(.caption2.weight(.bold)).tracking(0.6).frame(width: 56, alignment: .leading).opacity(0.7)
                            Text(d).font(.subheadline.weight(.semibold)).lineLimit(2)
                        }
                    }
                    Text("Read in the room. A tick keeps it; a cross drops it; the rest is read again at the stop.").font(.caption2).opacity(0.7)
                }
                .padding(.top, 4)
            }
            Text("Tap to open the recording").font(.footnote.weight(.bold)).opacity(0.7)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.record, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .foregroundStyle(Brand.onRecord)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture { withAnimation(.spring(duration: 0.6)) { model.takeover = true } }
    }

    private func justRead(_ all: [Recording]) -> Recording? {
        let cutoff = Date().addingTimeInterval(-3 * 3600)
        return all.filter { ($0.meta.analysedAt ?? .distantPast) > cutoff && $0.meta.insight?.readByModel == true }
            .max { ($0.meta.analysedAt ?? .distantPast) < ($1.meta.analysedAt ?? .distantPast) }
    }

    private func readLine(_ r: Recording) -> String {
        let items = (r.meta.insight?.items ?? []).filter { !$0.isDismissed }
        var parts: [String] = []
        let todo = items.filter(\.isAction).count
        if todo > 0 { parts.append("\(todo) to do") }
        let dates = items.filter(\.isDate).count
        if dates > 0 { parts.append("\(dates) date\(dates == 1 ? "" : "s")") }
        if let d = r.meta.insight?.decisions?.count, d > 0 { parts.append("\(d) decided") }
        if !r.people.isEmpty { parts.append("with " + r.people.prefix(3).joined(separator: ", ")) }
        return parts.isEmpty ? "Read a moment ago." : parts.joined(separator: " · ") + "."
    }

    private func yesterday(_ all: [Recording], cal: Calendar) -> (moments: [Recording], headline: String, line: String)? {
        let moments = all.filter { $0.startedAt.map { cal.isDateInYesterday($0) } == true }
        guard !moments.isEmpty else { return nil }
        let decisions = moments.flatMap { $0.meta.insight?.decisions ?? [] }
        let longest = moments.max { ($0.meta.seconds ?? 0) < ($1.meta.seconds ?? 0) }
        let headline = decisions.first ?? longest?.quote ?? "A quiet day."
        let items = moments.flatMap { ($0.meta.insight?.items ?? []).filter { !$0.isDismissed } }
        let todo = items.filter { $0.isAction && !$0.isDone }.count
        let promised = items.filter { $0.isPromise && !$0.isDone }
        var line = "\(Digest.hours(moments.map { $0.meta.seconds ?? 0 }.reduce(0, +))) of talk"
        if !decisions.isEmpty { line += ", \(decisions.count) decided" }
        if todo > 0 { line += ", \(todo) to do" }
        if let p = promised.first, let who = p.who { line += ". \(who) owes you: \(p.text.lowercased())" }
        return (moments, headline, line + ".")
    }

    private func todayLine(_ all: [Recording], cal: Calendar) -> (title: String, line: String, action: String, id: String?)? {
        let moments = all.filter { $0.startedAt.map { cal.isDateInToday($0) } == true }
        guard !moments.isEmpty else { return nil }
        let decided = moments.flatMap { $0.meta.insight?.decisions ?? [] }.count
        let items: [(Recording, NextItem)] = moments.flatMap { r in
            (r.meta.insight?.items ?? []).filter { !$0.isDismissed && $0.isAction && !$0.isDone }.map { (r, $0) }
        }
        let opened = items.count
        let title = "Today decided \(decided == 0 ? "nothing yet" : "\(decided) thing\(decided == 1 ? "" : "s")") and opened \(opened)."
        if let pair = items.first(where: { $0.1.isSolid }) ?? items.first {
            return (title, "Before you stop: \(pair.1.text). It's open in \(pair.0.displayTitle).", "Open it", pair.0.id)
        }
        return (title, "Nothing waiting on you tonight.", "Today's tape", nil)
    }

    private func topFinding(_ all: [Recording]) -> Finding? {
        let window = Calendar.current.dateInterval(of: .weekOfYear, for: Date()) ?? DateInterval(start: .distantPast, end: .distantFuture)
        let d = cache.digest(all, window: window)
        let history = (1...3).map { k -> Digest in
            let cal = Calendar.current
            let start = cal.date(byAdding: .weekOfYear, value: -k, to: window.start) ?? window.start
            return cache.digest(all, window: cal.dateInterval(of: .weekOfYear, for: start) ?? window)
        }
        return Findings.make(d, previous: history.first, history: history, all: all, spanName: "week")
            .first { !dismissed.contains("week|" + $0.id) && $0.id != "early" }
    }

    private func perform(_ a: Finding.Action) {
        switch a {
        case .open(let ids, let title):
            if ids.count == 1, let id = ids.first { path.append(id) } else { path.append(MomentsFilter(title: title, ids: ids)) }
        case .remind(let title, let due, let note):
            Task { if await model.quickReminder(title, due: due, note: note) { show("Added to Reminders") } }
        case .chase(let r, let item):
            Task { if await model.remindMe(r, item: item) { show("Reminder set") } }
        case .place(let r, let item):
            Task { if await model.place(r, item) { show("Added to Reminders") } }
        case .placeAll(let pairs):
            Task {
                // Said only for what went in: a refusal shows its own notice, and stops the rest.
                var added = 0
                for (r, i) in pairs {
                    guard await model.place(r, i) else { break }
                    added += 1
                }
                if added > 0 { show("\(added) added to Reminders") }
            }
        }
    }

    /// Today in the person's own time zone, for what is put away for the day (the ISO style
    /// counts days in UTC, so a card put away in the morning came back before noon in Sydney).
    private static func localDay() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func show(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation { if toast == text { toast = nil } }
        }
    }

    @ViewBuilder private var toastView: some View {
        if let toast {
            Text(toast).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glassEffect(.regular, in: Capsule())
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: The tape

    private var tapeHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("The tape").font(.title2.weight(.bold))
                Spacer()
                Text(scale == .day ? "newest first" : scale == .year ? "every day" : "tap a day").font(.caption).foregroundStyle(Brand.dim)
            }
            TapeScaleControl(scale: $scale)
        }
        .padding(.top, 14)
    }

    private var emptyTape: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing on the tape yet.").font(.headline)
            Text("Press the side button on your Pocket. Moments stream in as they are made, and ones recorded while the phone was away arrive when it reconnects.")
                .font(.subheadline).foregroundStyle(Brand.muted)
            Button("Add sample moments") { Task { await model.addSamples() } }.font(.subheadline.weight(.semibold))
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func land(_ day: Date, _ proxy: ScrollViewProxy) {
        focus = day
        withAnimation(.easeInOut(duration: 0.2)) { scale = .day }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation { proxy.scrollTo(TapeDays.id(Calendar.current.startOfDay(for: day)), anchor: .top) }
        }
    }

    private func noteScrolling() {
        hideHandle?.cancel()
        if !scrolling { withAnimation(.spring(duration: 0.35)) { scrolling = true } }
        hideHandle = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) { scrolling = false }
        }
    }

    // MARK: Bands, and choosing several

    /// A moment on the tape: tap to open it, swipe left to delete it, hold for its menu.
    /// While choosing, a tap ticks it instead.
    @ViewBuilder private func band(_ r: Recording) -> some View {
        let chosen = picked.contains(r.id)
        Button {
            if selecting {
                if chosen { picked.remove(r.id) } else { picked.insert(r.id) }
            } else {
                path.append(r.id)
            }
        } label: {
            HStack(spacing: 10) {
                if selecting {
                    Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(chosen ? Brand.act : Brand.dim)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                TapeBand(recording: r)
                    .opacity(selecting && !chosen ? 0.75 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(r.id)
        .onAppear { visible.insert(r.id); noteScrolling() }
        .onDisappear { visible.remove(r.id); noteScrolling() }
        .contextMenu { momentMenu(r) }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !selecting {
                Button { deleting = r } label: { Label("Delete", systemImage: "trash") }
                    .tint(Brand.bad)
            }
        }
        .accessibilityAddTraits(selecting && chosen ? .isSelected : [])
    }

    /// A day's name on the tape; while choosing, a way to take the whole day.
    private func dayHeader(_ day: Date, moments: [Recording]) -> some View {
        let ids = Set(moments.map(\.id))
        let all = !ids.isEmpty && ids.isSubset(of: picked)
        return HStack(alignment: .firstTextBaseline) {
            Text(TapeDays.label(day)).font(.title3.weight(.bold))
            Spacer()
            if selecting {
                Button(all ? "Deselect" : "Select all") {
                    if all { picked.subtract(ids) } else { picked.formUnion(ids) }
                }
                .font(.subheadline.weight(.semibold))
                .tint(Brand.act)
                .buttonStyle(.borderless)
            }
        }
        .padding(.top, 10)
    }

    /// While choosing: how many, Delete, and Done.
    @ViewBuilder private var selectionBar: some View {
        if selecting {
            HStack(spacing: 12) {
                Button("Done") { withAnimation(.spring(duration: 0.3)) { selecting = false; picked = [] } }
                    .font(.body.weight(.semibold))
                    .tint(Brand.act)
                Spacer()
                Text(picked.isEmpty ? "Tap moments to choose them" : "\(picked.count) chosen")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Brand.textSecondary)
                Spacer()
                Button(role: .destructive) { confirmMany = true } label: {
                    Label("Delete", systemImage: "trash").font(.body.weight(.semibold))
                }
                .tint(Brand.bad)
                .disabled(picked.isEmpty)
                .confirmationDialog(picked.count == 1 ? "Delete this moment?" : "Delete \(picked.count) moments?",
                                    isPresented: $confirmMany, titleVisibility: .visible) {
                    Button(picked.count == 1 ? "Delete" : "Delete \(picked.count)", role: .destructive) {
                        let gone = library.recordings.filter { picked.contains($0.id) }
                        withAnimation { library.delete(gone) }
                        picked = []
                        selecting = false
                    }
                } message: {
                    Text("The recordings and everything read from them. Reminders and Calendar keep what was sent to them.")
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .glassEffect(.regular, in: Capsule())
            .padding(.horizontal, 16).padding(.bottom, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder private func momentMenu(_ r: Recording) -> some View {
        Button { withAnimation(.spring(duration: 0.3)) { selecting = true; picked.insert(r.id) } } label: {
            Label("Select", systemImage: "checkmark.circle")
        }
        Button { path.append(r.id) } label: { Label("Open", systemImage: "arrow.up.right") }
        ShareLink(item: model.notes(for: r)) { Label("Share as notes", systemImage: "square.and.arrow.up") }
        if !r.people.isEmpty, let p = r.people.first {
            Button { path.append(MomentsFilter(title: p, ids: library.recordings.filter { $0.people.contains(p) }.map(\.id))) } label: { Label("Everything with \(p)", systemImage: "person") }
        }
        Divider()
        Button(role: .destructive) { deleting = r } label: { Label("Delete", systemImage: "trash") }
    }
}

/// A block on Now that tells or asks something. Its id is the key it is put away under.
private enum NowCard: Identifiable {
    case answer(AppModel.CardAnswer)
    case brief(Brief)
    case read(Recording)
    case needs([Digest.Need], day: String)
    case yesterday([Recording], headline: String, line: String, day: String)
    case evening(String, line: String, action: String, id: String?, day: String)
    case back(LiveThread, latest: String)
    case askCalendar
    case finding(Finding)

    var id: String {
        switch self {
        case .answer(let a): "card|" + a.id.uuidString
        case .brief(let b): "brief|" + b.id
        case .read(let r): "read|" + r.id
        case .needs(_, let day): "needs|" + day
        case .yesterday(_, _, _, let day): "yesterday|" + day
        case .evening(_, _, _, _, let day): "evening|" + day
        case .back(let t, let latest): "return|" + t.id + "|" + latest
        case .askCalendar: "ask-calendar"
        case .finding(let f): "week|" + f.id
        }
    }

    /// Its name in the folded line.
    var name: String {
        switch self {
        case .answer: "The card's answer"
        case .brief(let b): "Brief for " + b.person.name
        case .read: "Just read"
        case .needs(let n, _): "Needs you (\(n.count))"
        case .yesterday: "Yesterday"
        case .evening: "Six o'clock"
        case .back(let t, _): t.name + " is back"
        case .askCalendar: "Briefs"
        case .finding(let f): f.tag
        }
    }
}

/// What is coming, quietly: no colour field and nothing to tick, the time and what it is,
/// with the time column of the tape below it. Four rows, then a line for the rest. A meeting
/// opens its page, ready to record (`MeetingView`); a thing said opens its moment.
struct AheadList: View {
    let rows: [Ahead]
    let open: (Ahead) -> Void
    @State private var all = false

    var body: some View {
        let cal = Calendar.current
        let shown = all ? rows : Array(rows.prefix(4))
        VStack(alignment: .leading, spacing: 2) {
            Text("COMING UP").font(.caption2.weight(.bold)).tracking(0.7).foregroundStyle(Brand.dim).padding(.bottom, 4)
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, a in
                if !cal.isDateInToday(a.at), i == 0 || cal.isDateInToday(shown[i - 1].at) {
                    Text("TOMORROW").font(.caption2.weight(.bold)).tracking(0.7).foregroundStyle(Brand.dim).padding(.top, 6).padding(.bottom, 2)
                }
                Button { open(a) } label: { row(a) }.buttonStyle(.plain)
            }
            if rows.count > 4 {
                Button { withAnimation(.easeInOut(duration: 0.25)) { all.toggle() } } label: {
                    Text(all ? "Show fewer" : "\(rows.count - 4) more to the end of tomorrow")
                        .font(.caption.weight(.semibold)).foregroundStyle(Brand.muted)
                        .padding(.leading, 58).padding(.top, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 6)
    }

    private func row(_ a: Ahead) -> some View {
        let now = a.at <= Date()
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(now ? "now" : a.timed ? a.at.formatted(date: .omitted, time: .shortened) : "–")
                .font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(Brand.dim)
                .frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.title).font(.subheadline.weight(.medium)).foregroundStyle(Brand.textSecondary).lineLimit(1)
                if let d = a.detail, !d.isEmpty { Text(d).font(.caption).foregroundStyle(Brand.dim).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A block on Now: a colour field, a tag, a line that matters, and the one thing to do.
struct NowBlock: View {
    let tint: Color
    let ink: Color
    let tag: String
    let title: String
    let line: String
    var action: String? = nil
    var run: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(tag.uppercased()).font(.caption2.weight(.bold)).tracking(0.7).foregroundStyle(ink.opacity(0.75))
                Spacer(minLength: 8)
                if action != nil { Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(ink.opacity(0.6)) }
            }
            Text(title).font(.title3.weight(.bold)).lineSpacing(1).fixedSize(horizontal: false, vertical: true)
            Text(line).font(.subheadline).lineSpacing(2).foregroundStyle(ink.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .foregroundStyle(ink)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture { if action != nil { run() } }
    }
}

/// What is late or owed, as a teal block: the true count, the first three, each opening
/// its moment, and the rest as one line that opens them all.
struct NeedsBlock: View {
    let needs: [Digest.Need]
    let open: (String) -> Void
    let openAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("NEEDS YOU · \(needs.count)").font(.caption2.weight(.bold)).tracking(0.7).foregroundStyle(Brand.onAct.opacity(0.75))
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Brand.onAct.opacity(0.6))
            }
            ForEach(needs.prefix(3)) { n in
                Button { open(n.recording.id) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Text(n.why.uppercased()).font(.caption2.weight(.bold)).frame(width: 60, alignment: .leading).padding(.top, 3).opacity(0.75)
                        Text(n.item.text).font(.callout.weight(.semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)
            }
            if needs.count > 3 {
                Button(action: openAll) {
                    Text("\(needs.count - 3) more").font(.footnote.weight(.bold)).opacity(0.75)
                        .padding(.leading, 70)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.act, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .foregroundStyle(Brand.onAct)
    }
}

/// What the app noticed, as a lilac block with its own button and Not right.
struct FindingBlock: View {
    let finding: Finding
    let perform: (Finding.Action) -> Void
    let notRight: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("NOTICED · \(finding.tag.uppercased())").font(.caption2.weight(.bold)).tracking(0.7).foregroundStyle(Brand.onNotice.opacity(0.75))
                Spacer(minLength: 8)
                if finding.choices.first != nil { Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Brand.onNotice.opacity(0.6)) }
            }
            Text(finding.text).font(.title3.weight(.bold)).lineSpacing(1).fixedSize(horizontal: false, vertical: true)
            if let c = finding.choices.first {
                Text(c.label).font(.footnote.weight(.bold)).foregroundStyle(Brand.onNotice.opacity(0.7))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.notice, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .foregroundStyle(Brand.onNotice)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture { if let c = finding.choices.first { perform(c.action) } }
    }
}

/// The live waveform: the stream's loudness as it arrives, ten times a second, newest at
/// the right; faint dots when nothing has reached this iPhone for a moment.
struct LiveWave: View {
    @ObservedObject var levels: LiveLevels
    let ink: Color
    var bar: CGFloat = 2.5
    var gap: CGFloat = 2

    var body: some View {
        LevelBars(levels: levels.stalled ? [] : levels.values, ink: ink, bar: bar, gap: gap)
    }
}

/// A block on Now answers to the hand: tap for its one thing, swipe right for it too,
/// swipe left to put it away for today, hold for the menu. The swipes are the system's own
/// list swipes, so they never fight the scroll.
struct CardGestures: ViewModifier {
    let primary: String?
    let act: (() -> Void)?
    let dismiss: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if let primary, let act {
                    Button { act() } label: { Label(primary, systemImage: "arrow.up.right") }
                        .tint(Brand.act)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if let dismiss {
                    Button { withAnimation { dismiss() } } label: { Label("Put away", systemImage: "eye.slash") }
                        .tint(Brand.raised)
                }
            }
            .contextMenu {
                if let primary, let act { Button { act() } label: { Label(primary, systemImage: "arrow.up.right") } }
                if let dismiss { Button(role: .destructive) { dismiss() } label: { Label("Put away for today", systemImage: "eye.slash") } }
            }
    }
}

extension View {
    func cardGestures(primary: String?, act: (() -> Void)?, dismiss: (() -> Void)?) -> some View {
        modifier(CardGestures(primary: primary, act: act, dismiss: dismiss))
    }
}

/// The words as they come, on Now's live block: its own view, so only it redraws with them.
private struct NowLiveWords: View {
    @EnvironmentObject var live: LiveSession

    var body: some View {
        if !live.text.isEmpty {
            Text(live.text.tail(160)).font(.callout.weight(.medium)).lineLimit(3)
        } else {
            Text(live.isActive ? "Listening…" : "Started before the phone connected; it's fetched when it stops.").font(.callout.weight(.medium))
        }
    }
}
