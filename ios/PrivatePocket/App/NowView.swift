import SwiftUI

/// Now: the right thing for the hour, then the tape. Setting up or pairing when that is
/// what matters; what was just read; what needs you; what the app noticed; the day at
/// six; yesterday, set, in the morning. Under it, the tape of everything said.
struct NowView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: Library
    @EnvironmentObject var devices: DeviceStore
    @EnvironmentObject var link: PocketLink
    @EnvironmentObject var live: LiveSession
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
    @State private var brief: Brief?
    @State private var tableMode = false
    @State private var briefsAsked = Prefs.askedBriefs
    @StateObject private var replay = Replay()

    private var recording: Bool { link.status.recordingSince != nil }

    var body: some View {
        let all = library.recordings
        let days = TapeDays.grouped(all)
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14, pinnedViews: []) {
                        header
                        blocks(all)
                        tapeHeader
                        switch scale {
                        case .day:
                            ForEach(days, id: \.day) { group in
                                Text(TapeDays.label(group.day))
                                    .font(.title3.weight(.bold)).padding(.top, 10)
                                    .id(TapeDays.id(group.day))
                                ForEach(group.moments) { r in
                                    NavigationLink(value: r.id) { TapeBand(recording: r) }
                                        .buttonStyle(.plain)
                                        .id(r.id)
                                        .onAppear { visible.insert(r.id); noteScrolling() }
                                        .onDisappear { visible.remove(r.id); noteScrolling() }
                                        .contextMenu { momentMenu(r) }
                                }
                            }
                            if days.isEmpty { emptyTape }
                        case .week: TapeWeek(all: all, focus: focus) { land($0, proxy) }
                        case .month: TapeMonth(all: all, focus: focus) { land($0, proxy) }
                        case .year: TapeYear(all: all, focus: focus) { land($0, proxy) }
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 28)
                }
                .background(Brand.ground)
                .scrollIndicators(.hidden)
                .overlay(alignment: .trailing) {
                    if scale == .day, all.count >= 2 {
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
                .fullScreenCover(item: $brief) { BriefView(brief: $0) }
                .fullScreenCover(isPresented: $tableMode) { LiveView() }
                .sheet(isPresented: $showSettings) { SettingsView(onDone: { showSettings = false }) }
                .onChange(of: model.openMomentID, initial: true) {
                    guard let id = model.openMomentID else { return }
                    model.openMomentID = nil
                    path.append(id)
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.footnote.weight(.semibold)).foregroundStyle(Brand.muted)
                Text(greeting).font(.largeTitle.weight(.bold)).tracking(-0.5)
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape").font(.body.weight(.semibold)).foregroundStyle(Brand.textSecondary)
                    .frame(width: 36, height: 36).background(Brand.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
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
        withAnimation(.easeInOut(duration: 0.25)) { hidden.insert(key) }
        Prefs.hiddenBlocks = hidden
    }

    @ViewBuilder private func blocks(_ all: [Recording]) -> some View {
        let hour = Calendar.current.component(.hour, from: Date())
        let cal = Calendar.current
        let today = Date().formatted(.iso8601.year().month().day())
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
        if recording || live.isActive {
            liveBlock.cardGestures(primary: "Table mode", act: { tableMode = true }, dismiss: nil)
        }
        if let a = model.cardAnswers.last, !hidden.contains("card|" + a.id.uuidString) {
            NowBlock(tint: Brand.record, ink: Brand.onRecord, tag: "Said to the card", title: a.answer, line: "“Pocket, \(a.question)”")
                .cardGestures(primary: nil, act: nil, dismiss: { hide("card|" + a.id.uuidString) })
        }
        if !recording, Briefs.calendarAllowed, let b = Briefs.upcoming(all).first, !hidden.contains("brief|" + b.id) {
            NowBlock(tint: Brand.act, ink: Brand.onAct,
                     tag: "At \(b.start.formatted(date: .omitted, time: .shortened)) · \(b.person.name)" + (b.minutesAway > 0 ? " · in \(b.minutesAway) min" : ""),
                     title: b.count == 0 ? "Nothing open with \(b.person.name)." : "\(b.count) thing\(b.count == 1 ? "" : "s") open with \(b.person.name).",
                     line: Briefs.line(b), action: "Read the brief") { brief = b }
                .cardGestures(primary: "Read the brief", act: { brief = b }, dismiss: { hide("brief|" + b.id) })
        } else if !recording, !Briefs.calendarAllowed, !briefsAsked, !all.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("BRIEFS BEFORE MEETINGS").font(.caption2.weight(.bold)).tracking(0.7).foregroundStyle(Brand.paperMuted)
                Text("Ten minutes before a meeting with someone you've recorded, see what's open between you. And name who spoke from who was invited.").font(.callout.weight(.semibold)).foregroundStyle(Brand.onPaper)
                Text("Tap to allow Calendar · swipe away for not now").font(.footnote.weight(.bold)).foregroundStyle(Brand.onPaper.opacity(0.7))
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.paper, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .onTapGesture {
                Task {
                    if await Planner.allowEvents() { await Briefs.allowNotifications(); Briefs.schedule(all) }
                    Prefs.askedBriefs = true; briefsAsked = true
                }
            }
            .cardGestures(primary: "Allow Calendar", act: {
                Task {
                    if await Planner.allowEvents() { await Briefs.allowNotifications(); Briefs.schedule(all) }
                    Prefs.askedBriefs = true; briefsAsked = true
                }
            }, dismiss: { Prefs.askedBriefs = true; withAnimation { briefsAsked = true } })
        }
        let back = threads.live(all).filter(\.isBack).max { ($0.last ?? .distantPast) < ($1.last ?? .distantPast) }
        if !recording, let t = back, let latest = t.moments.last, !hidden.contains("return|" + t.id + "|" + latest.id) {
            ReturnBlock(thread: t) { path.append(ThreadLink(id: t.id)) }
                .cardGestures(primary: "Open the thread", act: { path.append(ThreadLink(id: t.id)) }, dismiss: { hide("return|" + t.id + "|" + latest.id) })
        }
        if let r = justRead(all), !hidden.contains("read|" + r.id) {
            NowBlock(tint: r.kind.isLife ? Brand.life : Brand.work, ink: r.kind.isLife ? Brand.onLife : Brand.onWork,
                     tag: "Just read · \(r.kind.label)", title: r.quote,
                     line: readLine(r), action: "Open it") { path.append(r.id) }
                .cardGestures(primary: "Open it", act: { path.append(r.id) }, dismiss: { hide("read|" + r.id) })
        }
        if hour < 12, let y = yesterday(all, cal: cal), !hidden.contains("yesterday|" + today) {
            let lines = Replay.lines(from: y.moments)
            VStack(alignment: .leading, spacing: 8) {
                Text("YESTERDAY, SET · \(y.moments.count) CONVERSATION\(y.moments.count == 1 ? "" : "S")").font(.caption2.weight(.bold)).tracking(0.7).foregroundStyle(Brand.paperMuted)
                Text(y.headline).font(.title3.weight(.bold)).foregroundStyle(Brand.onPaper).fixedSize(horizontal: false, vertical: true)
                Text(y.line).font(.subheadline).foregroundStyle(Brand.onPaper.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
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
                if lines.isEmpty { path.append(MomentsFilter(title: "Yesterday", ids: y.moments.map(\.id))) }
                else if replay.playing { replay.stop() } else { replay.play(lines) }
            }
            .cardGestures(primary: lines.isEmpty ? "Yesterday's tape" : "Listen back",
                          act: { if lines.isEmpty { path.append(MomentsFilter(title: "Yesterday", ids: y.moments.map(\.id))) } else if !replay.playing { replay.play(lines) } },
                          dismiss: { replay.stop(); hide("yesterday|" + today) })
        }
        if hour >= 17, let t = todayLine(all, cal: cal), !hidden.contains("evening|" + today) {
            NowBlock(tint: Brand.work, ink: Brand.onWork, tag: "Six o'clock", title: t.title, line: t.line, action: t.action) {
                if let id = t.id { path.append(id) }
            }
            .cardGestures(primary: t.id == nil ? nil : t.action, act: t.id.map { id in { path.append(id) } }, dismiss: { hide("evening|" + today) })
        }
        let needs = Digest.needs(all)
        if !needs.isEmpty, !hidden.contains("needs|" + today) {
            NeedsBlock(needs: needs) { path.append($0) }
                .cardGestures(primary: "Open the first", act: { if let n = needs.first { path.append(n.recording.id) } }, dismiss: { hide("needs|" + today) })
        }
        if let f = topFinding(all) {
            let notRight = {
                withAnimation { dismissed.insert("week|" + f.id) }
                Prefs.dismissedFindings = dismissed
            }
            FindingBlock(finding: f, perform: { perform($0) }, notRight: notRight)
                .cardGestures(primary: f.choices.first?.label, act: f.choices.first.map { c in { perform(c.action) } }, dismiss: notRight)
        }
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
            if !live.text.isEmpty {
                Text(String(live.text.suffix(160))).font(.callout.weight(.medium)).lineLimit(3)
            } else {
                Text(live.isActive ? "Listening…" : "Started before the phone connected; it's fetched when it stops.").font(.callout.weight(.medium))
            }
            if let h = model.liveThread {
                ThreadHintBox(hint: h).onTapGesture { path.append(ThreadLink(id: h.id)) }
            }
            if !model.liveItems.isEmpty || !model.liveDecisions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.liveItems) { item in
                        let confirmed = model.liveConfirmed.contains(item.id), gone = model.liveDismissed.contains(item.id)
                        HStack(spacing: 10) {
                            Text(item.isAction ? "TO DO" : item.isDate ? "DATE" : "PROMISE").font(.caption2.weight(.bold)).tracking(0.6).foregroundStyle(Brand.record).frame(width: 56, alignment: .leading)
                            Text((item.isPromise ? (item.who.map { "\($0): " } ?? "") : "") + item.text).font(.subheadline.weight(.semibold)).foregroundStyle(Color(hex: 0xFFF7E8)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            Button { model.confirmLive(item) } label: { Image(systemName: "checkmark").font(.caption.weight(.bold)).frame(width: 30, height: 30).background(confirmed ? Brand.act : Color(hex: 0x4A3410), in: Circle()).foregroundStyle(confirmed ? Brand.onAct : Color(hex: 0xFFF7E8)) }.buttonStyle(.plain)
                            Button { model.dismissLive(item) } label: { Image(systemName: "xmark").font(.caption.weight(.bold)).frame(width: 30, height: 30).background(Color(hex: 0x4A3410), in: Circle()).foregroundStyle(Color(hex: 0xFFF7E8)) }.buttonStyle(.plain)
                        }
                        .padding(10)
                        .background(Brand.onRecord, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .opacity(gone ? 0.45 : 1)
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
            Text("Tap for the table · stop from the bar below").font(.footnote.weight(.bold)).opacity(0.7)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.record, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .foregroundStyle(Brand.onRecord)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture { tableMode = true }
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

    @ViewBuilder private func momentMenu(_ r: Recording) -> some View {
        Button { path.append(r.id) } label: { Label("Open", systemImage: "arrow.up.right") }
        ShareLink(item: model.notes(for: r)) { Label("Share as notes", systemImage: "square.and.arrow.up") }
        if !r.people.isEmpty, let p = r.people.first {
            Button { path.append(MomentsFilter(title: p, ids: library.recordings.filter { $0.people.contains(p) }.map(\.id))) } label: { Label("Everything with \(p)", systemImage: "person") }
        }
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

/// What needs you now, as a teal block: the first three, each opening its moment.
struct NeedsBlock: View {
    let needs: [Digest.Need]
    let open: (String) -> Void

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

/// The record control, in the bottom accessory above the tabs: Record or Stop, the time
/// while it records, and the Pocket's state, which opens the Pocket's own screen.
struct RecordAccessory: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var link: PocketLink
    @EnvironmentObject var live: LiveSession
    @EnvironmentObject var devices: DeviceStore
    @State private var showPocket = false

    private var recording: Bool { link.status.recordingSince != nil }
    private var connected: Bool { link.connectedDeviceID != nil && link.connectedDeviceID == devices.selectedID }

    private var state: String {
        if recording { return model.recordingContext?.label ?? (live.isActive ? "Streaming" : "On the card") }
        if !model.canCommand { return "Needs pairing" }
        if !connected { return "Away" }
        if let c = model.pageContext { return c.label }
        if let b = link.status.battery { return "Ready · \(b)%" }
        return "Ready"
    }

    /// Inline, beside a collapsed tab bar, there is room for the dot and a word; expanded,
    /// for the state as well.
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        let inline = placement == .inline
        HStack(spacing: 10) {
            Button { Task { await model.toggleRecording() } } label: {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(Brand.onRecord).frame(width: 28, height: 28)
                        RoundedRectangle(cornerRadius: recording ? 3 : 6, style: .continuous).fill(Brand.record).frame(width: 12, height: 12)
                    }
                    if let since = link.status.recordingSince, recording {
                        Text(timerInterval: since...Date.distantFuture, countsDown: false)
                            .font(.subheadline.weight(.bold)).monospacedDigit().lineLimit(1).fixedSize()
                    } else {
                        Text(inline && !model.canCommand ? "Pair" : "Record").font(.subheadline.weight(.bold)).lineLimit(1).fixedSize()
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!model.canCommand || (!connected && !recording))
            .accessibilityLabel(recording ? "Stop recording" : "Record")
            if recording {
                if live.isActive {
                    LiveWave(levels: live.levels, ink: Brand.onRecord)
                        .frame(maxWidth: .infinity)
                        .frame(height: inline ? 14 : 22)
                        .contentShape(Rectangle())
                        .onTapGesture { showPocket = true }
                        .accessibilityLabel("Streaming to this iPhone")
                } else if !inline {
                    Text("On the card").font(.footnote.weight(.semibold)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !inline, !recording || model.recordingContext != nil {
                if !recording { Spacer(minLength: 6) }
                Button { showPocket = true } label: {
                    HStack(spacing: 6) {
                        LightDot(state: recording ? .recording : model.canCommand && connected ? .on : .off).frame(width: 8, height: 8)
                        Text(state).font(.footnote.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Your Pocket")
            }
        }
        .padding(.horizontal, inline ? 10 : 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(Brand.onRecord)
        .background(Brand.record, in: Capsule())
        .clipShape(Capsule())
        .padding(3)
        .contentShape(Capsule())
        .onTapGesture { if inline { showPocket = true } }
        .animation(.easeInOut(duration: 0.25), value: recording)
        .sheet(isPresented: $showPocket) { PocketView() }
    }
}

/// The record bar's waveform: the stream's loudness as it arrives, ten times a second,
/// newest at the right; faint dots when nothing has reached this iPhone for a moment.
struct LiveWave: View {
    @ObservedObject var levels: LiveLevels
    let ink: Color

    var body: some View {
        LevelBars(levels: levels.stalled ? [] : levels.values, ink: ink, bar: 2.5, gap: 2)
    }
}

/// Live, in the room, in large type: the timer, the words as they come, and what the
/// reader has caught so far with a tick and a cross on each. For the table.
struct LiveView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var link: PocketLink
    @EnvironmentObject var live: LiveSession
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .largeTitle) private var timerSize = 64.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    if let since = link.status.recordingSince {
                        Text(timerInterval: since...Date.distantFuture, countsDown: false)
                            .font(.system(size: timerSize, weight: .bold, design: .rounded)).monospacedDigit()
                    } else {
                        Text("Saving…").font(.largeTitle.weight(.bold))
                    }
                    Spacer()
                    Button("Done") { dismiss() }.font(.subheadline.weight(.bold)).padding(.horizontal, 14).padding(.vertical, 8).background(Brand.onRecord, in: Capsule()).foregroundStyle(Brand.record).buttonStyle(.plain)
                }
                let text = live.text
                if !text.isEmpty {
                    let tail = String(text.suffix(600))
                    Text(tail).font(.title2.weight(.semibold)).lineSpacing(3)
                } else {
                    Text(live.isActive ? "Listening…" : "Not streaming to this iPhone. It's read when it stops.").font(.title2.weight(.semibold))
                }
                if let h = model.liveThread { ThreadHintBox(hint: h, large: true) }
                if !model.liveItems.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.liveItems) { item in
                            let confirmed = model.liveConfirmed.contains(item.id), gone = model.liveDismissed.contains(item.id)
                            HStack(spacing: 12) {
                                Text(item.isAction ? "TO DO" : item.isDate ? "DATE" : "PROMISE").font(.caption.weight(.bold)).tracking(0.8).foregroundStyle(Brand.record).frame(width: 72, alignment: .leading)
                                Text((item.isPromise ? (item.who.map { "\($0): " } ?? "") : "") + item.text).font(.title3.weight(.bold)).foregroundStyle(Color(hex: 0xFFF7E8)).frame(maxWidth: .infinity, alignment: .leading)
                                Button { model.confirmLive(item) } label: { Image(systemName: "checkmark").font(.title3.weight(.bold)).frame(width: 44, height: 44).background(confirmed ? Brand.act : Color(hex: 0x4A3410), in: Circle()).foregroundStyle(confirmed ? Brand.onAct : Color(hex: 0xFFF7E8)) }.buttonStyle(.plain)
                                Button { model.dismissLive(item) } label: { Image(systemName: "xmark").font(.title3.weight(.bold)).frame(width: 44, height: 44).background(Color(hex: 0x4A3410), in: Circle()).foregroundStyle(Color(hex: 0xFFF7E8)) }.buttonStyle(.plain)
                            }
                            .padding(14)
                            .background(Brand.onRecord, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .opacity(gone ? 0.45 : 1)
                        }
                    }
                }
                ForEach(model.liveDecisions.prefix(4), id: \.self) { d in
                    HStack(spacing: 12) {
                        Text("DECIDED").font(.caption.weight(.bold)).tracking(0.8).frame(width: 72, alignment: .leading).opacity(0.7)
                        Text(d).font(.title3.weight(.bold))
                    }
                }
                if let a = model.cardAnswers.last {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("“Pocket, \(a.question)”").font(.subheadline.weight(.semibold)).opacity(0.75)
                        Text(a.answer).font(.title3.weight(.bold))
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.onRecord.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                Spacer(minLength: 40)
                if model.canCommand, link.status.recordingSince != nil {
                    HStack { Spacer()
                        Button { Task { await model.toggleRecording() }; dismiss() } label: {
                            ZStack { Circle().strokeBorder(Brand.onRecord, lineWidth: 3).frame(width: 76, height: 76); RoundedRectangle(cornerRadius: 8).fill(Brand.onRecord).frame(width: 30, height: 30) }
                        }
                        .buttonStyle(.plain).accessibilityLabel("Stop recording")
                        Spacer() }
                }
            }
            .padding(24).padding(.top, 10)
        }
        .background(Brand.record.ignoresSafeArea())
        .foregroundStyle(Brand.onRecord)
        .statusBarHidden()
    }
}

/// A block on Now answers to the hand: tap for its one thing, swipe right to do it,
/// swipe left to put it away for today, hold for the menu. A vertical drag is left
/// to the scroll.
struct CardGestures: ViewModifier {
    let primary: String?
    let act: (() -> Void)?
    let dismiss: (() -> Void)?
    @State private var offset: CGFloat = 0
    @State private var gone = false
    @State private var pulse = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .opacity(gone ? 0 : 1 - min(0.35, abs(offset) / 500))
            .background(alignment: .leading) {
                if offset > 24, let primary {
                    Text(primary.uppercased()).font(.caption.weight(.bold)).tracking(0.8).foregroundStyle(Brand.act)
                        .padding(.leading, 6).opacity(min(1, (offset - 24) / 60))
                }
            }
            .background(alignment: .trailing) {
                if offset < -24, dismiss != nil {
                    Text("PUT AWAY").font(.caption.weight(.bold)).tracking(0.8).foregroundStyle(Brand.muted)
                        .padding(.trailing, 6).opacity(min(1, (-offset - 24) / 60))
                }
            }
            .gesture(
                DragGesture(minimumDistance: 24, coordinateSpace: .local)
                    .onChanged { v in
                        guard abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
                        let w = v.translation.width
                        let allowed = (w > 0 && act != nil) || (w < 0 && dismiss != nil)
                        offset = allowed ? w : w * 0.18
                    }
                    .onEnded { v in
                        let w = v.translation.width
                        if w > 96, let act {
                            pulse += 1
                            withAnimation(.spring(duration: 0.35)) { offset = 0 }
                            act()
                        } else if w < -96, let dismiss {
                            pulse += 1
                            if reduceMotion { gone = true; dismiss() }
                            else {
                                withAnimation(.easeOut(duration: 0.22)) { offset = -520; gone = true }
                                Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(230))
                                    dismiss()
                                }
                            }
                        } else {
                            withAnimation(.spring(duration: 0.35)) { offset = 0 }
                        }
                    }
            )
            .contextMenu {
                if let primary, let act { Button { act() } label: { Label(primary, systemImage: "arrow.up.right") } }
                if let dismiss { Button(role: .destructive) { dismiss() } label: { Label("Put away for today", systemImage: "eye.slash") } }
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: pulse)
    }
}

extension View {
    func cardGestures(primary: String?, act: (() -> Void)?, dismiss: (() -> Void)?) -> some View {
        modifier(CardGestures(primary: primary, act: act, dismiss: dismiss))
    }
}
