import Foundation
import FoundationModels
import SwiftUI

// MARK: - What is kept

/// A thread kept: found by phrases that recur across moments, held by an id so that the
/// user's corrections (a name, a merge, a moment put in or taken out) outlive the
/// reader's next pass. Saved in `Recordings/threads.json`, out of backups like the
/// moments. Every field added later must be optional, or the file stops decoding.
struct ThreadRecord: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    /// The user gave the name; discovery leaves it alone.
    var named: Bool?
    /// The phrases that find its moments, lowercased.
    var aliases: [String]
    /// Moments put in by hand, or recorded into it.
    var pinned: [String]?
    /// Moments the user said are not part of it.
    var excluded: [String]?
    /// Recorded into it, but the reading says it is about something else.
    var doubted: [String]?
    /// Merged into another thread: its phrases and moments went there.
    var mergedInto: String?
    /// "Not a thread": kept so that discovery does not bring it back.
    var hidden: Bool?
    /// Threads the user said to keep apart from this one.
    var apart: [String]?
    var created: Date = Date()
    var state: ThreadState?

    var isActive: Bool { mergedInto == nil && hidden != true }
}

/// What the reader has made of a thread so far: the story as it stands, and what each
/// conversation did to it.
struct ThreadState: Codable, Hashable {
    var story: String?
    var changes: [ThreadChange] = []
    /// Moments already read into it.
    var read: [String] = []
    var updated: Date = Date()
    /// Read by a language model, rather than put together on the phone without one.
    var byModel: Bool?
}

struct ThreadChange: Codable, Hashable, Identifiable {
    var id: String = UUID().uuidString
    /// new, same, changed, reversed, renewed or settled from a reading; lapsed and done from time and ticks.
    var kind: String
    var text: String
    var recordingID: String?
    var at: Date

    var label: String {
        switch kind {
        case "same": "Same"
        case "changed": "Changed"
        case "reversed": "Reversed"
        case "renewed": "Renewed"
        case "settled": "Settled"
        case "lapsed": "Lapsed"
        case "done": "Done"
        default: "New"
        }
    }
}

/// People as the user has corrected them: names that are one person, and names that are
/// not people at all. Applied wherever a moment says who was there.
struct PeopleBook: Codable, Hashable {
    /// A name as read, lowercased → the name to show.
    var same: [String: String] = [:]
    /// Names, lowercased, that are not people.
    var notPeople: [String] = []
}

/// The people book where `Recording.people` can reach it.
enum PeopleNames {
    private static let lock = NSLock()
    private static var book = PeopleBook()

    static func set(_ b: PeopleBook) {
        lock.lock()
        book = b
        lock.unlock()
    }

    /// The name to show for a name as read, or nil when it is not a person, or is you.
    static func canonical(_ name: String) -> String? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, !You.matches(key) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if book.notPeople.contains(key) { return nil }
        return book.same[key] ?? name
    }
}

/// What the screen in front shows, so that Record can be pressed into it; kept with the
/// recording it started (`RecordingMeta.context`).
struct RecordContext: Codable, Hashable {
    var thread: String?
    var threadName: String?
    var person: String?
    var moment: String?
    var momentTitle: String?
    /// A calendar meeting, recorded from its page: the moment is that meeting's, whatever
    /// the clock says (`AppModel.analyse` takes it as the moment's event).
    var meeting: CalendarEventRef?

    /// For the record bar: "Into Northlight", "With Maya", "In Weekly sync", "Follow-up".
    var label: String {
        if let m = meeting { return m.title.isEmpty ? "In a meeting" : "In \(m.title)" }
        if let n = threadName { return "Into \(n)" }
        if let p = person { return "With \(p)" }
        return "Follow-up"
    }

    /// What the reader is told before it reads the conversation.
    var hint: String {
        var s: [String] = []
        if let n = threadName { s.append("This conversation was recorded as part of the ongoing subject \"\(n)\"; if it fits, use that name in the title.") }
        if let p = person { s.append("It was recorded as a conversation with \(p).") }
        if let t = momentTitle { s.append("It follows on from an earlier conversation, \"\(t)\".") }
        return s.joined(separator: " ")
    }
}

// MARK: - Time

/// Open promises and to-dos age. Open for a week is open; a month past its date, or a
/// season with no date, is lapsed, and said so.
enum Ageing {
    static let pastDueDays = 30.0
    static let undatedDays = 90.0

    /// When an open item lapsed, or nil while it is still alive.
    static func lapse(_ item: NextItem, said: Date?, now: Date = Date()) -> Date? {
        guard !item.isDone, !item.isDismissed, item.isAction || item.isPromise else { return nil }
        let at = item.date.map { $0.addingTimeInterval(pastDueDays * 86_400) } ?? said.map { $0.addingTimeInterval(undatedDays * 86_400) }
        guard let at, at <= now else { return nil }
        return at
    }

    /// "7 months", "5 weeks", "12 days".
    static func span(_ days: Int) -> String {
        if days >= 60 { let m = Int((Double(days) / 30.4).rounded()); return "\(m) month\(m == 1 ? "" : "s")" }
        if days >= 14 { let w = days / 7; return "\(w) week\(w == 1 ? "" : "s")" }
        return "\(days) day\(days == 1 ? "" : "s")"
    }

    private static let common: Set<String> = ["the", "and", "for", "with", "will", "you", "your", "our", "this", "that", "from", "about",
                                              "next", "into", "onto", "over", "them", "they", "him", "her", "his", "its", "all", "can", "has", "have"]

    /// The same thing said again: most of the shorter one's own words are in the longer.
    static func similar(_ a: String, _ b: String) -> Bool {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 && !common.contains($0) })
        }
        let wa = words(a), wb = words(b)
        guard !wa.isEmpty, !wb.isEmpty else { return false }
        return Double(wa.intersection(wb).count) / Double(min(wa.count, wb.count)) >= 0.6
    }
}

extension NextItem {
    /// What was promised, without the name: "Maya will send the quote" → "send the quote".
    var promisedAct: String {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let who, t.lowercased().hasPrefix(who.lowercased() + " will ") { return String(t.dropFirst(who.count + 6)) }
        if let r = t.range(of: #"^[A-Z][\w'’-]*( [A-Z][\w'’-]*)? will "#, options: .regularExpression) { return String(t[r.upperBound...]) }
        return t.prefix(1).lowercased() + t.dropFirst()
    }
}

// MARK: - A thread as it stands

/// Something open in a thread, with its age.
struct OpenItem: Identifiable {
    let recording: Recording
    let item: NextItem
    /// When it was first said, carried over when it was promised again.
    let since: Date
    /// When it lapsed, if it has.
    let lapsedAt: Date?
    /// It was promised before and is promised again.
    let renewed: Bool
    var id: String { recording.id + "/" + item.id }

    var label: String {
        item.isPromise ? (item.who.map { "\($0): " } ?? "") + item.promisedAct : item.text
    }
}

/// A thread with its moments, worked out from the record and the library each time.
struct LiveThread: Identifiable {
    let record: ThreadRecord
    /// Oldest first.
    let moments: [Recording]
    let open: [OpenItem]
    let settled: Int
    let now: Date

    var id: String { record.id }
    var name: String { record.name }
    var first: Date? { moments.first?.startedAt }
    var last: Date? { moments.last?.startedAt }
    var daysSinceLast: Int { last.map { max(0, Int(now.timeIntervalSince($0) / 86_400)) } ?? 9_999 }
    /// The quiet before the latest moment, in days.
    var gapBeforeLast: Int? {
        guard moments.count >= 2, let a = moments[moments.count - 2].startedAt, let b = moments.last?.startedAt else { return nil }
        return Int(b.timeIntervalSince(a) / 86_400)
    }
    /// Spoken in the last three days after a month or more of quiet.
    var isBack: Bool { daysSinceLast <= 3 && (gapBeforeLast ?? 0) >= 30 }
    var isLive: Bool { daysSinceLast <= 30 }
    var isWork: Bool { moments.filter { $0.kind.isWork }.count >= moments.filter { $0.kind.isLife }.count }
    var lapsed: [OpenItem] { open.filter { $0.lapsedAt != nil } }
    var alive: [OpenItem] { open.filter { $0.lapsedAt == nil } }
    var people: [String] {
        var seen = Set<String>(), out: [String] = []
        for p in moments.reversed().flatMap({ $0.people }) where seen.insert(p.lowercased()).inserted { out.append(p) }
        return out
    }
    var unread: [Recording] {
        let read = Set(record.state?.read ?? [])
        return moments.filter { !read.contains($0.id) && $0.meta.insight != nil }
    }
    /// The ranking: recent, large and open first, and back above everything.
    var weight: Double {
        let recency: Double = 10.0 / (1.0 + Double(daysSinceLast) / 7.0)
        let size = Double(min(moments.count, 10))
        let opened = Double(alive.count) * 2.0
        let back: Double = isBack ? 100.0 : 0.0
        return recency + size + opened + back
    }

    init(record: ThreadRecord, moments: [Recording], now: Date = Date()) {
        self.record = record
        self.moments = moments
        self.now = now
        var open: [OpenItem] = []
        var settled = 0
        for r in moments {
            let said = r.startedAt ?? now
            settled += (r.meta.insight?.decisions ?? []).count
            for item in r.meta.insight?.items ?? [] where !item.isDismissed && (item.isAction || item.isPromise) {
                if item.isDone { settled += 1; continue }
                // Said again by the same person: the earlier one is carried into this one.
                if let k = open.lastIndex(where: { $0.item.kind == item.kind && ($0.item.who ?? "") == (item.who ?? "") && Ageing.similar($0.item.promisedAct, item.promisedAct) }) {
                    let earlier = open.remove(at: k)
                    open.append(OpenItem(recording: r, item: item, since: earlier.since, lapsedAt: Ageing.lapse(item, said: said, now: now), renewed: true))
                } else {
                    open.append(OpenItem(recording: r, item: item, since: said, lapsedAt: Ageing.lapse(item, said: said, now: now), renewed: false))
                }
            }
        }
        self.open = open.sorted { $0.since < $1.since }
        self.settled = settled
    }

    /// What changed, newest first: the readings' changes, with lapses from time and ticks from the user.
    var changes: [ThreadChange] {
        var out = record.state?.changes ?? []
        for o in open {
            guard let l = o.lapsedAt else { continue }
            let why = o.item.date != nil ? "a month past its date" : "three months with no word"
            out.append(ThreadChange(id: "lapse-" + o.id, kind: "lapsed", text: o.label + ", " + why, recordingID: o.recording.id, at: l))
        }
        for r in moments {
            for item in r.meta.insight?.items ?? [] where item.isDone && !item.isDismissed && (item.isAction || item.isPromise) {
                guard let d = item.doneAt else { continue }
                out.append(ThreadChange(id: "done-" + item.id, kind: "done", text: item.isPromise ? (item.who.map { "\($0): " } ?? "") + item.promisedAct : item.text, recordingID: r.id, at: d))
            }
        }
        return out.sorted { $0.at > $1.at }
    }

    /// Last time, before a moment: when, and what it came to, with what was still owed
    /// as it stood then.
    func recall(before cutoff: Date) -> (date: Date, line: String)? {
        let earlier = moments.filter { ($0.startedAt ?? .distantFuture) < cutoff }
        guard let prev = earlier.last, let at = prev.startedAt else { return nil }
        var line = prev.meta.insight?.brief?.first?.text ?? prev.quote
        if !line.hasSuffix(".") && !line.hasSuffix("”") { line += "." }
        let owed: [(Recording, NextItem)] = earlier.reversed().flatMap { r in
            (r.meta.insight?.items ?? []).filter { !$0.isDone && !$0.isDismissed && ($0.isPromise || $0.isAction) }.map { (r, $0) }
        }
        if let pair = owed.first(where: { $0.1.isPromise && $0.1.who != nil }), let who = pair.1.who {
            let lapsed = Ageing.lapse(pair.1, said: pair.0.startedAt, now: cutoff) != nil
            line += " \(who) was to \(pair.1.promisedAct)" + (lapsed ? ", and it never came." : ".")
        } else if let pair = owed.first(where: { $0.1.isAction }) {
            line += " Still yours: \(pair.1.text.prefix(1).lowercased() + pair.1.text.dropFirst())."
        }
        return (at, line)
    }

    /// The story without a model: when it started, how often, and the latest.
    var plainStory: String {
        var s: [String] = []
        if let f = first { s.append("Since \(f.formatted(.dateTime.day().month(.wide))), \(moments.count) conversation\(moments.count == 1 ? "" : "s").") }
        if let l = moments.last, let at = l.startedAt, let b = l.meta.insight?.brief?.first?.text {
            s.append("Latest, \(Findings.dayName(at)): \(b)")
        }
        if let o = lapsed.first { s.append("Lapsed: \(o.label).") }
        return s.joined(separator: " ")
    }
}

/// A link to a thread's page, for navigation stacks.
struct ThreadLink: Hashable {
    let id: String
}

/// A thread named in the room, with what was said last time.
struct ThreadHint: Equatable {
    let id: String
    let name: String
    let last: Date?
    let line: String
}

// MARK: - The store

@MainActor
final class ThreadStore: ObservableObject {
    @Published private(set) var records: [ThreadRecord] = []
    @Published private(set) var book = PeopleBook()
    /// Threads being read against their state now.
    @Published private(set) var reading: Set<String> = []
    private let url: URL
    private var termCache: [String: (stamp: Double, names: Int, terms: [String: String])] = [:]
    private var namesCache: (stamp: Int, names: Set<String>)?
    private var queue: Task<Void, Never>?

    private struct File: Codable {
        var threads: [ThreadRecord]
        var people: PeopleBook?
    }

    init(root: URL) {
        url = root.appendingPathComponent("threads.json")
        load()
    }

    func load() {
        if let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: d) {
            records = f.threads
            book = f.people ?? PeopleBook()
        } else {
            // A file that no longer decodes is kept aside before the next save writes over it.
            if let d = try? Data(contentsOf: url) {
                let bad = url.appendingPathExtension("bad")
                if !FileManager.default.fileExists(atPath: bad.path) { try? d.write(to: bad) }
            }
            records = []
            book = PeopleBook()
        }
        PeopleNames.set(book)
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try? enc.encode(File(threads: records, people: book)).write(to: url, options: .atomic)
    }

    /// Start over: nothing kept.
    func clear() {
        records = []
        book = PeopleBook()
        termCache = [:]
        PeopleNames.set(book)
        try? FileManager.default.removeItem(at: url)
    }

    private func index(_ id: String) -> Int? { records.firstIndex { $0.id == id } }

    /// The thread an id now stands for, following merges.
    func resolve(_ id: String) -> ThreadRecord? {
        var cur = records.first { $0.id == id }
        var hops = 0
        while let c = cur, let next = c.mergedInto, hops < 10 {
            cur = records.first { $0.id == next }
            hops += 1
        }
        return cur
    }

    // MARK: Finding threads

    /// Words the library writes with a capital mid-sentence, worked out again only when a reading changes.
    private func names(_ all: [Recording]) -> (names: Set<String>, stamp: Int) {
        let stamp = all.reduce(all.count) { $0 &+ Int($1.meta.analysedAt?.timeIntervalSince1970 ?? 0) }
        if let c = namesCache, c.stamp == stamp { return (c.names, stamp) }
        var out = Set<String>()
        for r in all { out.formUnion(Digest.midNames(r)) }
        namesCache = (stamp, out)
        return (out, stamp)
    }

    private func terms(_ r: Recording, people: Set<String>, names: (names: Set<String>, stamp: Int)) -> [String: String] {
        let stamp = r.meta.analysedAt?.timeIntervalSince1970 ?? 0
        if let c = termCache[r.id], c.stamp == stamp, c.names == names.stamp { return c.terms }
        let t = Digest.terms(r, people: people, names: names.names)
        termCache[r.id] = (stamp, names.stamp, t)
        return t
    }

    /// A new thread for each phrase that now runs through two or more moments.
    func discover(_ all: [Recording]) {
        let people = Set(all.flatMap(\.people))
        let evidence = names(all)
        var ids: [String: Int] = [:]
        var display: [String: String] = [:]
        for r in all {
            for (key, shown) in terms(r, people: people, names: evidence) {
                ids[key, default: 0] += 1
                if display[key] == nil { display[key] = shown }
            }
        }
        var changed = false
        // A thread found by a phrase no reading uses any more, that the user never touched, goes;
        // it comes back if the phrase does.
        if !all.isEmpty {
            let targets = Set(records.compactMap(\.mergedInto))
            let before = records.count
            records.removeAll { rec in
                rec.named != true && rec.mergedInto == nil && rec.hidden != true
                    && (rec.pinned ?? []).isEmpty && (rec.excluded ?? []).isEmpty && (rec.apart ?? []).isEmpty
                    && !targets.contains(rec.id) && !rec.aliases.contains { (ids[$0] ?? 0) > 0 }
            }
            changed = records.count != before
        }
        let known = Set(records.flatMap(\.aliases))
        for (key, n) in ids where n >= 2 && !known.contains(key) {
            records.append(ThreadRecord(name: display[key] ?? key, aliases: [key]))
            changed = true
        }
        if changed { save() }
    }

    /// Every thread with its moments, as things stand: phrases matched, plus pinned, minus excluded.
    func live(_ all: [Recording], now: Date = Date()) -> [LiveThread] {
        let people = Set(all.flatMap(\.people))
        let evidence = names(all)
        var byID: [String: Recording] = [:]
        var byTerm: [String: [Recording]] = [:]
        for r in all {
            byID[r.id] = r
            for key in terms(r, people: people, names: evidence).keys { byTerm[key, default: []].append(r) }
        }
        var out: [LiveThread] = []
        for rec in records where rec.isActive {
            var set: [String: Recording] = [:]
            for a in rec.aliases { for r in byTerm[a] ?? [] { set[r.id] = r } }
            for id in rec.pinned ?? [] { if let r = byID[id] { set[id] = r } }
            for id in rec.excluded ?? [] { set[id] = nil }
            guard set.count >= 2 || (rec.named == true && !set.isEmpty) else { continue }
            let moments = set.values.sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
            out.append(LiveThread(record: rec, moments: moments, now: now))
        }
        return out
    }

    /// The threads a moment is in.
    func threads(of id: String, in live: [LiveThread]) -> [LiveThread] {
        live.filter { $0.moments.contains { $0.id == id } }
    }

    struct MergeHint: Identifiable {
        let into: LiveThread
        let from: LiveThread
        var id: String { from.id + ">" + into.id }
    }

    /// Two threads that look like one: they share most moments, or one's name holds the other's.
    func mergeHints(_ live: [LiveThread]) -> [MergeHint] {
        var out: [MergeHint] = []
        let sorted = live.sorted { ($0.moments.count, $0.weight) > ($1.moments.count, $1.weight) }
        for (i, a) in sorted.enumerated() {
            let mine = Set(a.moments.map(\.id))
            for b in sorted.dropFirst(i + 1) {
                guard !(a.record.apart ?? []).contains(b.id), !(b.record.apart ?? []).contains(a.id) else { continue }
                let shared = Set(b.moments.map(\.id)).intersection(mine).count
                let nested = a.record.aliases.contains { x in b.record.aliases.contains { y in (" " + y + " ").contains(" " + x + " ") || (" " + x + " ").contains(" " + y + " ") } }
                if shared >= 2, nested || Double(shared) >= 0.75 * Double(b.moments.count) {
                    out.append(MergeHint(into: a, from: b))
                }
            }
        }
        return Array(out.prefix(3))
    }

    // MARK: Mending

    func rename(_ id: String, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = index(id) else { return }
        records[i].name = n
        records[i].named = true
        let key = n.lowercased()
        let taken = records.contains { $0.id != id && $0.isActive && $0.aliases.contains(key) }
        if !taken, !records[i].aliases.contains(key) { records[i].aliases.append(key) }
        save()
    }

    func merge(_ from: String, into: String) {
        guard let f = index(from), let t = index(into), f != t else { return }
        records[t].aliases = Self.unique(records[t].aliases + records[f].aliases)
        records[t].pinned = Self.unique((records[t].pinned ?? []) + (records[f].pinned ?? []))
        records[t].excluded = Self.unique((records[t].excluded ?? []) + (records[f].excluded ?? []))
            .filter { !(records[t].pinned ?? []).contains($0) }
        records[f].mergedInto = into
        save()
    }

    func keepApart(_ a: String, _ b: String) {
        guard let i = index(a), let j = index(b) else { return }
        records[i].apart = Self.unique((records[i].apart ?? []) + [b])
        records[j].apart = Self.unique((records[j].apart ?? []) + [a])
        save()
    }

    func hide(_ id: String) {
        guard let i = index(id) else { return }
        records[i].hidden = true
        save()
    }

    func pin(_ moment: String, to id: String) {
        guard let rec = resolve(id), let i = index(rec.id) else { return }
        records[i].pinned = Self.unique((records[i].pinned ?? []) + [moment])
        records[i].excluded = (records[i].excluded ?? []).filter { $0 != moment }
        save()
    }

    func exclude(_ moment: String, from id: String) {
        guard let rec = resolve(id), let i = index(rec.id) else { return }
        records[i].excluded = Self.unique((records[i].excluded ?? []) + [moment])
        records[i].pinned = (records[i].pinned ?? []).filter { $0 != moment }
        records[i].doubted = (records[i].doubted ?? []).filter { $0 != moment }
        records[i].state?.changes.removeAll { $0.recordingID == moment }
        records[i].state?.read.removeAll { $0 == moment }
        save()
    }

    /// Recorded into it after all: keep it there, and stop asking.
    func keep(_ moment: String, in id: String) {
        guard let i = index(id) else { return }
        records[i].doubted = (records[i].doubted ?? []).filter { $0 != moment }
        save()
    }

    /// A new thread, named, holding these moments; the old one lets them go.
    @discardableResult
    func split(_ id: String, moments: [String], name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !moments.isEmpty, let i = index(id) else { return nil }
        let new = ThreadRecord(name: n, named: true, aliases: [n.lowercased()], pinned: moments)
        records[i].excluded = Self.unique((records[i].excluded ?? []) + moments)
        records[i].pinned = (records[i].pinned ?? []).filter { !moments.contains($0) }
        records[i].state?.changes.removeAll { moments.contains($0.recordingID ?? "") }
        records[i].state?.read.removeAll { moments.contains($0) }
        records.append(new)
        save()
        return new.id
    }

    /// A thread started by hand from one moment.
    @discardableResult
    func create(_ name: String, with moment: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        if let existing = records.first(where: { $0.isActive && $0.aliases.contains(n.lowercased()) }) {
            pin(moment, to: existing.id)
            return existing.id
        }
        let new = ThreadRecord(name: n, named: true, aliases: [n.lowercased()], pinned: [moment])
        records.append(new)
        save()
        return new.id
    }

    private func doubt(_ moment: String, in id: String) {
        guard let i = index(id) else { return }
        records[i].doubted = Self.unique((records[i].doubted ?? []) + [moment])
        save()
    }

    // MARK: People

    /// Show this name as another, everywhere.
    func renamePerson(_ name: String, to new: String) {
        let n = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        let old = name.lowercased()
        for (k, v) in book.same where v.lowercased() == old { book.same[k] = n }
        book.same[old] = n
        if n.lowercased() != old { book.same[n.lowercased()] = nil }
        book.notPeople.removeAll { $0 == n.lowercased() }
        PeopleNames.set(book)
        save()
    }

    /// Two names, one person.
    func samePerson(_ name: String, as other: String) {
        renamePerson(name, to: PeopleNames.canonical(other) ?? other)
    }

    func notAPerson(_ name: String) {
        let key = name.lowercased()
        if !book.notPeople.contains(key) { book.notPeople.append(key) }
        for (k, v) in book.same where v.lowercased() == key { book.notPeople.append(k) }
        PeopleNames.set(book)
        save()
    }

    // MARK: Reading against the state

    /// Runs thread reading one job at a time, so two readings of one thread never cross.
    func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = queue
        queue = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    /// Reads the moments of a thread not yet read into its state, oldest first, a few at a time.
    func catchUp(_ t: LiveThread) async {
        let unread = t.unread
        guard !unread.isEmpty, !reading.contains(t.id) else { return }
        reading.insert(t.id)
        defer { reading.remove(t.id) }
        var s = t.record.state ?? ThreadState()
        let useModel = LLM.availability == nil
        var stride = 0
        while stride < unread.count {
            let batch = Array(unread[stride..<min(stride + 4, unread.count)])
            stride += batch.count
            var result: ThreadReader.Result?
            if useModel {
                result = try? await ThreadReader.read(name: t.name, state: s, open: t.open, moments: batch, config: LLM.config)
                // The model failed (the server away, say): these stay unread, to be read properly next time.
                if result == nil { break }
            }
            let r = result ?? ThreadReader.plain(t, state: s, moments: batch)
            if let story = r.story { s.story = story }
            s.changes += r.changes
            s.read = Self.unique(s.read + batch.map(\.id))
            s.byModel = result != nil && (s.byModel ?? true)
            for id in r.notAbout where (t.record.pinned ?? []).contains(id) { doubt(id, in: t.id) }
        }
        s.updated = Date()
        guard let i = index(t.id) else { return }
        // Merged into the state as it is now: a moment taken out while this read stays out.
        let out = Set(records[i].excluded ?? [])
        var now = records[i].state ?? ThreadState()
        let known = Set(now.changes.map(\.id))
        now.story = s.story ?? now.story
        now.changes += s.changes.filter { !known.contains($0.id) && !out.contains($0.recordingID ?? "") }
        now.read = Self.unique(now.read + s.read).filter { !out.contains($0) }
        now.byModel = s.byModel
        now.updated = s.updated
        records[i].state = now
        save()
    }

    private static func unique(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        return xs.filter { seen.insert($0).inserted }
    }
}

// MARK: - The reader, for threads

@Generable
struct ThreadDraftChange {
    @Guide(description: "The number of the new conversation it came from")
    var moment: Int
    @Guide(description: "new, same, changed, reversed, renewed or settled")
    var kind: String
    @Guide(description: "One short line saying what it did, like 'Budget £12,000 to £15,000' or 'Launch moved to after the workshop'")
    var text: String
}

@Generable
struct ThreadDraft {
    @Guide(description: "The story of the subject as it stands now, three or four sentences, addressed to the user as 'you'")
    var story: String
    @Guide(description: "What each new conversation did to the subject; empty if nothing")
    var changes: [ThreadDraftChange]
    @Guide(description: "The numbers of new conversations that are not about this subject at all; empty if none")
    var notAbout: [Int]
}

/// Reads new conversations against a thread's state: the story rewritten, and what each
/// one did to it. From the readings, never the transcripts.
enum ThreadReader {
    struct Result {
        var story: String?
        var changes: [ThreadChange]
        var notAbout: [String]
    }

    static let instructions = """
    You keep the record of one subject that runs through several recorded conversations. You are given the story so far, \
    what is still open, and one or more new conversations about it, numbered, with what was said, decided and promised. \
    Rewrite the story in three or four sentences, addressed to the user as "you", in the conversations' language, so that it \
    reads as the state of the subject now, the new conversations included. \
    Then list what each new conversation did to the subject, each in one short line, with its kind: new (raised for the first time), \
    same (said again, unchanged), changed (a figure, date or plan moved: say from what to what), reversed (an earlier decision undone), \
    renewed (something still open promised again), or settled (an open question or task resolved). Leave out small talk. \
    Use only what you are given; never invent. If a new conversation is not about this subject at all, give its number under notAbout.
    """

    private struct Draft: Decodable {
        struct Change: Decodable {
            var moment: Int?
            var kind: String?
            var text: String?
            enum K: String, CodingKey { case moment, kind, text }
            init(moment: Int?, kind: String?, text: String?) { self.moment = moment; self.kind = kind; self.text = text }
            init(from d: Decoder) throws {
                let c = try d.container(keyedBy: K.self)
                if let i = try? c.decode(Int.self, forKey: .moment) { moment = i }
                else if let s = try? c.decode(String.self, forKey: .moment) { moment = Int(s.filter(\.isNumber)) }
                kind = try? c.decode(String.self, forKey: .kind)
                text = try? c.decode(String.self, forKey: .text)
            }
        }
        var story: String?
        var changes: [Change]?
        var notAbout: [Int]?
        enum K: String, CodingKey { case story, changes, notAbout }
        init(story: String?, changes: [Change]?, notAbout: [Int]?) { self.story = story; self.changes = changes; self.notAbout = notAbout }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            story = try? c.decode(String.self, forKey: .story)
            changes = try? c.decode([Change].self, forKey: .changes)
            if let ns = try? c.decode([Int].self, forKey: .notAbout) { notAbout = ns }
            else if let ss = try? c.decode([String].self, forKey: .notAbout) { notAbout = ss.compactMap { Int($0.filter(\.isNumber)) } }
        }
    }

    static func read(name: String, state: ThreadState, open: [OpenItem], moments: [Recording], config c: LLMConfig) async throws -> Result {
        let prompt = Self.prompt(name: name, state: state, open: open, moments: moments)
        let draft: Draft
        if c.remote {
            let json = instructions + "\nReply with JSON only, no prose and no code fence, with exactly these keys: \"story\" (a string); " +
                "\"changes\" (an array of {\"moment\": the new conversation's number, \"kind\": one of new, same, changed, reversed, renewed, settled, \"text\": one short line}); " +
                "\"notAbout\" (an array of new conversation numbers, empty if none)."
            let reply = try await LLM.complete(c, instructions: json, prompt: prompt, temperature: 0)
            guard let o = reply.firstIndex(of: "{"), let e = reply.lastIndex(of: "}"), o < e else { throw LLMError.empty }
            draft = try JSONDecoder().decode(Draft.self, from: Data(reply[o...e].utf8))
        } else {
            let session = LanguageModelSession(model: .default, instructions: instructions)
            let g = try await session.respond(to: prompt, generating: ThreadDraft.self).content
            draft = Draft(story: g.story, changes: g.changes.map { .init(moment: $0.moment, kind: $0.kind, text: $0.text) }, notAbout: g.notAbout)
        }
        var changes: [ThreadChange] = []
        for ch in draft.changes ?? [] {
            guard let n = ch.moment, n >= 1, n <= moments.count else { continue }
            let kind = (ch.kind ?? "").lowercased().trimmingCharacters(in: .whitespaces)
            let text = (ch.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard ["new", "same", "changed", "reversed", "renewed", "settled"].contains(kind), !text.isEmpty else { continue }
            let r = moments[n - 1]
            changes.append(ThreadChange(kind: kind, text: text, recordingID: r.id, at: r.startedAt ?? Date()))
        }
        let story = draft.story?.trimmingCharacters(in: .whitespacesAndNewlines)
        let notAbout = (draft.notAbout ?? []).compactMap { n in (1...max(1, moments.count)).contains(n) && n <= moments.count ? moments[n - 1].id : nil }
        return Result(story: (story ?? "").isEmpty ? nil : story, changes: changes, notAbout: notAbout)
    }

    static func prompt(name: String, state: ThreadState, open: [OpenItem], moments: [Recording]) -> String {
        var s = "Subject: \(name)\n\nStory so far: " + (state.story ?? "none yet; these are its first conversations.") + "\n"
        let recent = state.changes.suffix(10)
        if !recent.isEmpty {
            s += "Changes so far:\n" + recent.map { "- \($0.at.formatted(date: .abbreviated, time: .omitted)), \($0.kind): \($0.text)" }.joined(separator: "\n") + "\n"
        }
        let earlier = open.filter { o in !moments.contains { $0.id == o.recording.id } }
        if !earlier.isEmpty {
            s += "Still open:\n" + earlier.prefix(8).map { "- \($0.label) (since \($0.since.formatted(date: .abbreviated, time: .omitted)))" }.joined(separator: "\n") + "\n"
        }
        s += "\nNew conversations:\n"
        for (i, r) in moments.enumerated() {
            s += "\n\(i + 1). " + Digest.reading(r) + "\n"
        }
        return s
    }

    /// Without a model: decisions and promises are new, a figure for the same thing at a
    /// new amount has changed, and the story is put together from the latest brief.
    static func plain(_ t: LiveThread, state: ThreadState, moments: [Recording]) -> Result {
        var figures: [String: String] = [:]
        for r in t.moments where state.read.contains(r.id) {
            for f in r.meta.insight?.figures ?? [] { if let p = figure(f) { figures[p.what] = p.amount } }
        }
        var changes: [ThreadChange] = []
        var promised: [NextItem] = t.moments.filter { state.read.contains($0.id) }.flatMap { ($0.meta.insight?.items ?? []).filter(\.isPromise) }
        for r in moments {
            let at = r.startedAt ?? Date()
            for d in r.meta.insight?.decisions ?? [] { changes.append(ThreadChange(kind: "new", text: d, recordingID: r.id, at: at)) }
            for f in r.meta.insight?.figures ?? [] {
                guard let p = figure(f) else { continue }
                if let old = figures[p.what], old != p.amount {
                    changes.append(ThreadChange(kind: "changed", text: "\(p.what.capitalizedFirst): \(old) to \(p.amount)", recordingID: r.id, at: at))
                } else if figures[p.what] == nil {
                    changes.append(ThreadChange(kind: "new", text: f, recordingID: r.id, at: at))
                }
                figures[p.what] = p.amount
            }
            for item in r.meta.insight?.items ?? [] where item.isPromise && !item.isDismissed {
                let again = promised.contains { ($0.who ?? "") == (item.who ?? "") && Ageing.similar($0.promisedAct, item.promisedAct) }
                changes.append(ThreadChange(kind: again ? "renewed" : "new", text: (item.who.map { "\($0): " } ?? "") + item.promisedAct, recordingID: r.id, at: at))
                promised.append(item)
            }
        }
        return Result(story: t.plainStory, changes: changes, notAbout: [])
    }

    /// "£3,000 for the offsite" → (£3,000, the offsite).
    static func figure(_ s: String) -> (amount: String, what: String)? {
        guard let r = s.range(of: #"[£$€]?\s?\d[\d,.]*\s?(k|m|bn|%|percent|million|thousand)?"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let amount = String(s[r]).trimmingCharacters(in: .whitespaces)
        var rest = (String(s[..<r.lowerBound]) + " " + String(s[r.upperBound...])).trimmingCharacters(in: .whitespacesAndNewlines)
        for lead in ["for ", "of ", "on ", "at ", "in "] where rest.lowercased().hasPrefix(lead) { rest = String(rest.dropFirst(lead.count)) }
        let what = rest.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        return what.isEmpty ? nil : (amount, what)
    }
}
