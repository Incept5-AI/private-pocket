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
                .fullScreenCover(item: $brief) { BriefView(brief: $0) }
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
            liveBlock.cardGestures(primary: "Open", act: { withAnimation(.spring(duration: 0.6)) { model.takeover = true } }, dismiss: nil)
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
                withAnimation { _ = dismissed.insert("week|" + f.id) }
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
