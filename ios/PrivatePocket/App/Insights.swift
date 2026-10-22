import Foundation

/// What a span of moments adds up to, worked out from their readings: the days, the
/// commitments either way, what was decided, asked and counted, the threads, the
/// people, and what needs you now. All counted on the phone; the briefing in
/// `Briefings` is the one part a model writes, from the briefs, never the transcripts.
struct Digest {
    struct Need: Identifiable {
        let recording: Recording
        let item: NextItem
        /// "Overdue", "Soon", "To chase", "Open a week".
        let why: String
        var id: String { recording.id + "/" + item.id }
    }

    struct Thread: Identifiable {
        let term: String
        let moments: [Recording]
        /// The most recent sentence that mentions it.
        let latest: String?
        var id: String { term }
        var dates: [Date] { moments.compactMap(\.startedAt) }
    }

    struct Person: Identifiable {
        let name: String
        var moments: [Recording] = []
        var waitingOn: [NextItem] = []
        var youOwe = 0
        var id: String { name }
        var lastSeen: Date? { moments.compactMap(\.startedAt).max() }
    }

    struct Day: Identifiable {
        let date: Date
        var work = 0
        var life = 0
        var other = 0
        var id: Date { date }
        var total: Int { work + life + other }
    }

    /// A line that came out of a moment: a decision, a question, a figure.
    struct Line: Identifiable {
        let recording: Recording
        let text: String
        var id: String { recording.id + "|" + text }
    }

    let window: DateInterval
    let moments: [Recording]
    let days: [Day]
    let needs: [Need]
    let threads: [Thread]
    let people: [Person]
    let decisions: [Line]
    let questions: [Line]
    let figures: [Line]
    let yours: [(Recording, NextItem)]
    let theirs: [(Recording, NextItem)]
    let calls: Int
    let meetings: Int

    var workSeconds: Int { days.map(\.work).reduce(0, +) }
    var lifeSeconds: Int { days.map(\.life).reduce(0, +) }
    var otherSeconds: Int { days.map(\.other).reduce(0, +) }
    var totalSeconds: Int { workSeconds + lifeSeconds + otherSeconds }
    var busiestDay: Day? { days.max { $0.total < $1.total }.flatMap { $0.total > 0 ? $0 : nil } }
    var unread: [Recording] { moments.filter { $0.meta.transcript != nil && $0.meta.insight?.readByModel != true } }
    var outdated: [Recording] { moments.filter { $0.meta.insight?.readByModel == true && ($0.meta.insight?.version ?? 1) < MomentInsight.readerVersion } }
    var yoursOpen: [(Recording, NextItem)] { yours.filter { !$0.1.isDone } }
    var yoursDone: [(Recording, NextItem)] { yours.filter { $0.1.isDone } }
    var theirsOverdue: [(Recording, NextItem)] { theirs.filter { $0.1.date.map { $0 < Date() } ?? false } }

    /// Changes when the briefing should be written again.
    var stamp: String {
        moments.map { r in
            let items = r.meta.insight?.items ?? []
            return "\(r.id)@\(Int(r.meta.analysedAt?.timeIntervalSince1970 ?? 0))/\(items.filter(\.isDone).count)"
        }.joined(separator: ",")
    }

    static func make(_ all: [Recording], window: DateInterval) -> Digest {
        let cal = Calendar.current
        let moments = all.filter { $0.startedAt.map(window.contains) == true }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
        // One entry per day of the span, so the chart has its quiet days too.
        var days: [Day] = []
        var d = cal.startOfDay(for: window.start)
        while d < window.end, days.count < 62 {
            days.append(Day(date: d))
            d = cal.date(byAdding: .day, value: 1, to: d) ?? window.end
        }
        var calls = 0, meetings = 0
        var yours: [(Recording, NextItem)] = [], theirs: [(Recording, NextItem)] = []
        var decisions: [Line] = [], questions: [Line] = [], figures: [Line] = []
        for r in moments {
            let s = r.meta.seconds ?? 0
            if let at = r.startedAt, let i = days.firstIndex(where: { cal.isDate($0.date, inSameDayAs: at) }) {
                if r.kind.isWork { days[i].work += s } else if r.kind.isLife { days[i].life += s } else { days[i].other += s }
            }
            switch r.kind {
            case .businessCall, .personalCall, .call: calls += 1
            case .businessMeeting, .personalMeeting, .meeting: meetings += 1
            default: break
            }
            let items = (r.meta.insight?.items ?? []).filter { !$0.isDismissed }
            yours += items.filter(\.isAction).map { (r, $0) }
            theirs += items.filter(\.isPromise).map { (r, $0) }
            decisions += (r.meta.insight?.decisions ?? []).map { Line(recording: r, text: $0) }
            questions += (r.meta.insight?.questions ?? []).map { Line(recording: r, text: $0) }
            figures += (r.meta.insight?.figures ?? []).map { Line(recording: r, text: $0) }
        }
        let names = Set(moments.flatMap(\.people))
        return Digest(window: window, moments: moments, days: days,
                      needs: needs(all), threads: threads(moments, people: names), people: people(moments),
                      decisions: decisions, questions: questions, figures: figures,
                      yours: yours, theirs: theirs, calls: calls, meetings: meetings)
    }

    /// Open items across every moment, not just the span: what needs you now.
    static func needs(_ all: [Recording]) -> [Need] {
        let now = Date()
        var out: [Need] = []
        for r in all {
            for item in r.meta.insight?.items ?? [] where !item.isDismissed && !item.isDone {
                if item.isAction {
                    if let d = item.date, d < now { out.append(Need(recording: r, item: item, why: "Overdue")) }
                    else if item.date == nil, let s = r.startedAt, now.timeIntervalSince(s) > 7 * 86_400 { out.append(Need(recording: r, item: item, why: "Open a week")) }
                } else if item.isPromise {
                    if let d = item.date, d < now { out.append(Need(recording: r, item: item, why: "To chase")) }
                } else if item.isDate, let d = item.date, d > now, d < now.addingTimeInterval(48 * 3600) {
                    out.append(Need(recording: r, item: item, why: "Soon"))
                }
            }
        }
        let order = ["Overdue": 0, "Soon": 1, "To chase": 2, "Open a week": 3]
        return Array(out.sorted { (order[$0.why] ?? 9, $0.item.date ?? .distantFuture) < (order[$1.why] ?? 9, $1.item.date ?? .distantFuture) }.prefix(8))
    }

    private static let stop: Set<String> = [
        "I", "I'm", "I'll", "I've", "The", "A", "An", "You", "You're", "You've", "You'll", "We", "We're", "We'll", "They", "He", "She", "It", "It's",
        "This", "That", "These", "Those", "Then", "So", "And", "But", "Or", "Next", "Last", "Also", "Yes", "No", "Not", "Okay", "Right", "Back",
        "There", "Here", "When", "What", "Who", "How", "Why", "Which", "If", "In", "On", "At", "For", "With", "By", "From", "To", "Of", "As",
        "Both", "All", "Some", "One", "Two", "Three", "Four", "Five", "Six", "Ten", "Your", "Our", "Their", "His", "Her", "My", "Its",
        "Today", "Tomorrow", "Yesterday", "Tonight", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
        "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December",
        "Speaker", "Call", "Meeting", "Note", "Business", "Personal", "Conversation", "After", "Before", "Once", "While", "Because",
    ]

    /// Capitalised terms, joined into phrases, that run through two or more moments.
    static func threads(_ moments: [Recording], people: Set<String>) -> [Thread] {
        var byTerm: [String: [Recording]] = [:]
        var latest: [String: (Date, String)] = [:]
        for r in moments {
            guard let i = r.meta.insight else { continue }
            let sentences = [i.title ?? ""] + (i.brief ?? []).map(\.text) + (i.keyLines ?? []).map(\.text) + (i.decisions ?? [])
            var terms = Set<String>()
            for s in sentences {
                let words = s.split { !($0.isLetter || $0 == "'" || $0 == "-") }.map(String.init)
                var k = 0
                while k < words.count {
                    let w = words[k]
                    guard w.first?.isUppercase == true, w.count > 2, !stop.contains(w), !people.contains(w) else { k += 1; continue }
                    var phrase = w
                    var j = k + 1
                    while j < words.count, words[j].first?.isUppercase == true, !stop.contains(words[j]), !people.contains(words[j]) {
                        phrase += " " + words[j]
                        j += 1
                    }
                    terms.insert(phrase)
                    k = j
                }
            }
            for t in terms {
                byTerm[t, default: []].append(r)
                if let d = r.startedAt, (latest[t]?.0 ?? .distantPast) < d,
                   let sentence = sentences.dropFirst().first(where: { $0.contains(t) }) ?? sentences.first(where: { $0.contains(t) }) {
                    latest[t] = (d, sentence)
                }
            }
        }
        return byTerm.filter { $0.value.count >= 2 }
            .map { Thread(term: $0.key, moments: $0.value, latest: latest[$0.key]?.1) }
            .sorted { ($0.moments.count, $0.term) > ($1.moments.count, $1.term) }
            .prefix(6).map { $0 }
    }

    static func people(_ moments: [Recording]) -> [Person] {
        var map: [String: Person] = [:]
        for r in moments {
            let items = (r.meta.insight?.items ?? []).filter { !$0.isDismissed }
            for name in r.people {
                map[name, default: Person(name: name)].moments.append(r)
                map[name]?.youOwe += items.filter { $0.isAction && !$0.isDone && $0.text.localizedCaseInsensitiveContains(name) }.count
            }
            for item in items where item.isPromise {
                if let who = item.who { map[who, default: Person(name: who)].waitingOn.append(item) }
            }
        }
        return map.values.sorted { ($0.moments.count, $0.name) > ($1.moments.count, $1.name) }.prefix(10).map { $0 }
    }

    /// What the model reads to write the briefing: one block per moment, from the readings.
    var text: String {
        moments.reversed().map { r in
            let i = r.meta.insight
            var lines = ["— \(r.startedAt?.formatted(date: .abbreviated, time: .shortened) ?? r.day) · \(r.kind.label) · \(r.displayTitle)"
                         + (r.people.isEmpty ? "" : " · with \(r.people.joined(separator: ", "))")]
            if let b = i?.brief, !b.isEmpty { lines.append("Brief: " + b.map(\.text).joined(separator: " ")) }
            if let d = i?.decisions, !d.isEmpty { lines.append("Decided: " + d.joined(separator: "; ")) }
            let items = (i?.items ?? []).filter { !$0.isDismissed }
            let todo = items.filter(\.isAction)
            if !todo.isEmpty { lines.append("To do: " + todo.map { $0.text + ($0.isDone ? " (done)" : $0.when.map { " (\($0))" } ?? "") }.joined(separator: "; ")) }
            let promised = items.filter(\.isPromise)
            if !promised.isEmpty { lines.append("Promised: " + promised.map { [$0.who, $0.text, $0.when].compactMap { $0 }.joined(separator: " · ") }.joined(separator: "; ")) }
            let dates = items.filter(\.isDate)
            if !dates.isEmpty { lines.append("Dates: " + dates.map { [$0.text, $0.when].compactMap { $0 }.joined(separator: ", ") }.joined(separator: "; ")) }
            if let q = i?.questions, !q.isEmpty { lines.append("Open questions: " + q.joined(separator: "; ")) }
            if let f = i?.figures, !f.isEmpty { lines.append("Figures: " + f.joined(separator: "; ")) }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

/// The span in a few sentences, written by the configured language model from the
/// moments' briefs, and kept until the moments change.
@MainActor
final class Briefings: ObservableObject {
    struct Briefing: Codable {
        var stamp: String
        var text: String
        var at: Date
        var remote: Bool
    }

    @Published private(set) var texts: [String: Briefing]
    @Published private(set) var writing: Set<String> = []

    init() {
        if let data = UserDefaults.standard.data(forKey: "briefings"), let t = try? JSONDecoder().decode([String: Briefing].self, from: data) {
            texts = t
        } else {
            texts = [:]
        }
    }

    static let instructions = """
    You write a short briefing for the person who made these recordings, from the notes on each one. \
    Four to six sentences, addressed to them as "you", no lists and no headings. \
    Say what dominated the period, what moved forward, what was decided, what is still unresolved, \
    and who is waiting on them or they on others, naming people. Use only the notes. Write in the notes' language.
    """

    /// Writes the briefing for `key` if the moments changed since the last one.
    func ensure(key: String, digest: Digest) async {
        let stamp = digest.stamp
        guard !digest.moments.isEmpty, texts[key]?.stamp != stamp, !writing.contains(key) else { return }
        await ServerStatus.shared.check()
        guard LLM.availability == nil else { return }
        writing.insert(key)
        defer { writing.remove(key) }
        let c = LLM.config
        do {
            let text = try await Self.write(digest, config: c)
            texts[key] = Briefing(stamp: stamp, text: text, at: Date(), remote: c.remote)
            if let data = try? JSONEncoder().encode(texts) { UserDefaults.standard.set(data, forKey: "briefings") }
        } catch {
            // Left for next time; the rest of the tab stands on its own.
        }
    }

    private static func write(_ d: Digest, config c: LLMConfig) async throws -> String {
        let span = "\(d.window.start.formatted(date: .abbreviated, time: .omitted)) to \(d.window.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted))"
        let chunks = Summariser.split(d.text, max: c.chunkChars)
        if chunks.count == 1 {
            return try await LLM.complete(c, instructions: instructions, prompt: "Notes on \(d.moments.count) moments, \(span):\n\n\(d.text)")
        }
        var partials: [String] = []
        for (i, chunk) in chunks.enumerated() {
            partials.append(try await LLM.complete(c, instructions: instructions, prompt: "Notes, part \(i + 1) of \(chunks.count), \(span):\n\n\(chunk)"))
        }
        return try await LLM.complete(c, instructions: instructions,
                                      prompt: "These are briefings on consecutive parts of the same period, \(span). Combine them into one.\n\n" + partials.joined(separator: "\n\n"))
    }
}
