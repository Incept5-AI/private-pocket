import SwiftUI

/// Threads: everything you keep talking about, most alive first. A thread is a subject
/// that runs through two or more moments; its page tells the state of it from talk.
struct ThreadsView: View {
    @EnvironmentObject var library: Library

    var body: some View {
        let all = library.recordings
        let threads = Digest.threads(all, people: Set(all.flatMap(\.people)), limit: 40)
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Text("Threads").font(.largeTitle.weight(.bold)).tracking(-0.5).padding(.top, 8)
                    if threads.isEmpty {
                        Text("A thread appears once something comes up in two conversations. Nothing has yet.")
                            .font(.subheadline).foregroundStyle(Brand.muted)
                    }
                    ForEach(threads) { t in
                        NavigationLink(value: t.term) { ThreadRow(thread: t) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 28)
            }
            .background(Brand.ground)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { term in
                if let t = Digest.threads(all, people: Set(all.flatMap(\.people)), limit: 200).first(where: { $0.term == term }) {
                    ThreadView(thread: t)
                } else {
                    RecordingDetail(id: term)
                }
            }
            .navigationDestination(for: MomentsFilter.self) { f in FilteredMoments(filter: f) }
        }
    }
}

struct ThreadRow: View {
    let thread: Digest.Thread

    var body: some View {
        let work = thread.moments.filter { $0.kind.isWork }.count >= thread.moments.count / 2
        let decided = thread.moments.contains { r in (r.meta.insight?.decisions ?? []).contains { $0.range(of: thread.term, options: .caseInsensitive) != nil } }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(thread.term).font(.title3.weight(.bold))
                Spacer()
                Text("\(thread.moments.count) moments").font(.caption.weight(.semibold)).opacity(0.8)
            }
            if let l = thread.latest { Text(l).font(.subheadline).lineLimit(2).opacity(0.9) }
            HStack(spacing: 8) {
                ThreadStrip(dates: thread.dates, ink: work ? Brand.onWork : Brand.onLife)
                Text(decided ? "settled" : "open").font(.caption2.weight(.bold)).padding(.horizontal, 8).padding(.vertical, 3)
                    .background((work ? Brand.onWork : Brand.onLife).opacity(0.18), in: Capsule())
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(work ? Brand.work : Brand.life, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .foregroundStyle(work ? Brand.onWork : Brand.onLife)
    }
}

/// The moments of a thread as dots along the last eight weeks.
struct ThreadStrip: View {
    let dates: [Date]
    let ink: Color

    var body: some View {
        let now = Date(), span = 8 * 7 * 86_400.0
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(ink.opacity(0.25)).frame(height: 2)
                ForEach(Array(dates.enumerated()), id: \.offset) { _, d in
                    let f = max(0, min(1, 1 - now.timeIntervalSince(d) / span))
                    Circle().fill(ink).frame(width: 7, height: 7).offset(x: g.size.width * CGFloat(f) - 3.5)
                }
            }
            .frame(height: 7)
        }
        .frame(height: 7)
    }
}

/// The state of a thread, told from talk: the story so far, decided in order, the
/// figures as they moved, who owes what, and what to raise next time.
struct ThreadView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: Library
    let thread: Digest.Thread

    private var moments: [Recording] { thread.moments.sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) } }
    private var work: Bool { moments.filter { $0.kind.isWork }.count >= moments.count / 2 }

    var body: some View {
        let decisions = moments.flatMap { r in (r.meta.insight?.decisions ?? []).map { (r, $0) } }
        let figures = moments.flatMap { r in (r.meta.insight?.figures ?? []).map { (r, $0) } }
        let items = moments.flatMap { r in (r.meta.insight?.items ?? []).filter { !$0.isDismissed }.map { (r, $0) } }
        let promises = items.filter { $0.1.isPromise && !$0.1.isDone }
        let yours = items.filter { $0.1.isAction && !$0.1.isDone }
        let questions = moments.flatMap { $0.meta.insight?.questions ?? [] }
        let people = Array(Set(moments.flatMap(\.people))).sorted()
        let first = moments.first?.startedAt, last = moments.last?.startedAt
        let days = (first != nil && last != nil) ? Int(last!.timeIntervalSince(first!) / 86_400) : 0
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(moments.count) moments · \(days == 0 ? "one day" : "\(days) days") · \(work ? "work" : "life")".uppercased())
                        .font(.caption2.weight(.bold)).tracking(0.7).opacity(0.75)
                    Text(thread.term).font(.system(.largeTitle, design: .default, weight: .bold)).tracking(-0.6)
                    Text(story(decisions: decisions.map(\.1), promises: promises, yours: yours, questions: questions, people: people))
                        .font(.callout.weight(.semibold)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    let total = decisions.count + questions.count
                    if total > 0 {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill((work ? Brand.onWork : Brand.onLife).opacity(0.25))
                                Capsule().fill(work ? Brand.onWork : Brand.onLife).frame(width: g.size.width * CGFloat(decisions.count) / CGFloat(total))
                            }
                        }
                        .frame(height: 8)
                        Text("\(decisions.count) of \(total) things decided").font(.caption.weight(.semibold)).opacity(0.85)
                    }
                }
                .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(work ? Brand.work : Brand.life)
                .foregroundStyle(work ? Brand.onWork : Brand.onLife)

                VStack(alignment: .leading, spacing: 20) {
                    if !decisions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionTitle("Decided, in order")
                            ForEach(Array(decisions.enumerated()), id: \.offset) { _, pair in
                                NavigationLink(value: pair.0.id) {
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Text(pair.0.startedAt?.formatted(.dateTime.day().month(.abbreviated)) ?? "").font(.caption.weight(.bold)).foregroundStyle(Brand.muted).frame(width: 46, alignment: .leading)
                                        Text(pair.1).font(.callout.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !figures.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionTitle("Figures, as said")
                            ForEach(Array(figures.enumerated()), id: \.offset) { _, pair in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(pair.0.startedAt?.formatted(.dateTime.day().month(.abbreviated)) ?? "").font(.caption.weight(.bold)).foregroundStyle(Brand.muted).frame(width: 46, alignment: .leading)
                                    Text(pair.1).font(.callout.weight(.semibold))
                                }
                            }
                        }
                    }
                    if !promises.isEmpty || !yours.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle("Who owes what")
                            ForEach(Array(promises.enumerated()), id: \.offset) { _, pair in
                                owes(pair.0, pair.1, who: pair.1.who ?? "Someone", theirs: true)
                            }
                            ForEach(Array(yours.enumerated()), id: \.offset) { _, pair in
                                owes(pair.0, pair.1, who: "You", theirs: false)
                            }
                        }
                    }
                    if !questions.isEmpty || !promises.isEmpty || !yours.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("NEXT TIME IT COMES UP").font(.caption2.weight(.bold)).tracking(0.7).foregroundStyle(Brand.onAct.opacity(0.7))
                            Text(nextTime(promises: promises, yours: yours, questions: questions)).font(.callout.weight(.semibold)).foregroundStyle(Brand.onAct).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Brand.act, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    HStack(spacing: 8) {
                        NavigationLink(value: MomentsFilter(title: thread.term, ids: moments.map(\.id))) {
                            Text("Its \(moments.count) moments").font(.footnote.weight(.bold)).padding(.horizontal, 12).padding(.vertical, 8).background(Brand.surface, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        if !people.isEmpty {
                            Text(people.prefix(4).joined(separator: ", ")).font(.footnote.weight(.semibold)).foregroundStyle(Brand.muted).padding(.horizontal, 12).padding(.vertical, 8).background(Brand.surface, in: Capsule())
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 28)
            }
        }
        .background(Brand.ground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private func owes(_ r: Recording, _ item: NextItem, who: String, theirs: Bool) -> some View {
        NavigationLink(value: r.id) {
            HStack(spacing: 10) {
                Text(String(who.prefix(1)).uppercased()).font(.caption.weight(.bold))
                    .frame(width: 30, height: 30)
                    .background(theirs ? Brand.work : Brand.act, in: Circle())
                    .foregroundStyle(theirs ? Brand.onWork : Brand.onAct)
                VStack(alignment: .leading, spacing: 1) {
                    Text(theirs ? "\(who): \(item.text)" : item.text).font(.callout.weight(.semibold)).lineLimit(2)
                    if let w = item.when { Text(w).font(.caption).foregroundStyle(Brand.muted) }
                }
                Spacer()
                Text(theirs ? "open" : "yours").font(.caption2.weight(.bold)).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(theirs ? Brand.life : Brand.act, in: Capsule()).foregroundStyle(theirs ? Brand.onLife : Brand.onAct)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func story(decisions: [String], promises: [(Recording, NextItem)], yours: [(Recording, NextItem)], questions: [String], people: [String]) -> String {
        var s: [String] = []
        if let l = thread.latest { s.append(l) }
        if !decisions.isEmpty { s.append("Decided so far: " + decisions.prefix(2).joined(separator: "; ").lowercased() + (decisions.count > 2 ? ", and \(decisions.count - 2) more." : ".")) }
        if !promises.isEmpty || !yours.isEmpty {
            var owed: [String] = []
            if let p = promises.first, let who = p.1.who { owed.append("\(who) owes \(p.1.text.lowercased())") }
            if let y = yours.first { owed.append("you owe \(y.1.text.lowercased())") }
            s.append(owed.joined(separator: "; ").capitalizedFirst + ".")
        }
        if !questions.isEmpty { s.append("Still open: \(questions.first!.lowercased())" + (questions.count > 1 ? ", and \(questions.count - 1) more." : ".")) }
        if s.isEmpty { s.append("It has come up \(thread.moments.count) times" + (people.isEmpty ? "." : ", with \(people.prefix(3).joined(separator: ", ")).")) }
        return s.joined(separator: " ")
    }

    private func nextTime(promises: [(Recording, NextItem)], yours: [(Recording, NextItem)], questions: [String]) -> String {
        var parts: [String] = []
        for p in promises.prefix(2) { if let who = p.1.who { parts.append("ask \(who) about \(p.1.text.lowercased())") } }
        for q in questions.prefix(1) { parts.append("settle \(q.lowercased())") }
        for y in yours.prefix(1) { parts.append("bring \(y.1.text.lowercased())") }
        return parts.isEmpty ? "Nothing open." : (parts.joined(separator: ", ") + ".").capitalizedFirst
    }
}
