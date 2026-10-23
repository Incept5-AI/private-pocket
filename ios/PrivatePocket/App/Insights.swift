import NaturalLanguage
import SwiftUI

/// What a span of moments adds up to, worked out from their readings: the days, the
/// commitments either way, what was decided, asked and counted, the threads, the
/// people, and what needs you now. All counted on the phone; the findings in
/// `Findings` are drawn from it, and the briefing in `Briefings` is the one part a
/// model writes, from the findings and the readings, never the transcripts.
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
    let callCount: Int
    let meetingCount: Int

    var workSeconds: Int { days.map(\.work).reduce(0, +) }
    var lifeSeconds: Int { days.map(\.life).reduce(0, +) }
    var otherSeconds: Int { days.map(\.other).reduce(0, +) }
    var totalSeconds: Int { workSeconds + lifeSeconds + otherSeconds }
    var busiestDay: Day? { days.max { $0.total < $1.total }.flatMap { $0.total > 0 ? $0 : nil } }
    var meetings: [Recording] { moments.filter { [.businessMeeting, .personalMeeting, .meeting].contains($0.kind) } }
    var unread: [Recording] { moments.filter { $0.meta.transcript != nil && $0.meta.insight?.readByModel != true } }
    var outdated: [Recording] { moments.filter { $0.meta.insight?.readByModel == true && ($0.meta.insight?.version ?? 1) < MomentInsight.readerVersion } }
    var yoursOpen: [(Recording, NextItem)] { yours.filter { !$0.1.isDone } }
    var yoursDone: [(Recording, NextItem)] { yours.filter { $0.1.isDone } }
    var theirsOpen: [(Recording, NextItem)] { theirs.filter { !$0.1.isDone } }
    var theirsOverdue: [(Recording, NextItem)] { theirs.filter { $0.1.date.map { $0 < Date() } ?? false } }

    /// Changes when the briefing should be written again.
    var stamp: String {
        moments.map { r in
            let items = r.meta.insight?.items ?? []
            return "\(r.id)@\(Int(r.meta.analysedAt?.timeIntervalSince1970 ?? 0))/\(items.filter(\.isDone).count)"
        }.joined(separator: ",")
    }

    static func hours(_ s: Int) -> String {
        s >= 3600 ? "\(s / 3600) h \((s % 3600) / 60)" : "\(max(1, s / 60)) min"
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
                      yours: yours, theirs: theirs, callCount: calls, meetingCount: meetings)
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
        "Venue", "Date", "Dates", "Time", "Location", "Agenda",
        "We've", "They're", "They've", "There's", "That's", "Let's", "Don't", "Can't", "Won't", "Didn't", "Isn't", "Wasn't", "What's",
        "Okay", "Hello", "Thanks", "Thank", "Please", "Sure", "Yeah", "Well", "Just", "Maybe", "Still", "Now", "Every", "Each",
    ]

    /// Words split the way phrases are read, with a trailing possessive dropped.
    static func tokens(_ s: String) -> [String] {
        s.split { !($0.isLetter || $0 == "'" || $0 == "-") }.map { w in
            let t = String(w)
            return t.hasSuffix("'s") ? String(t.dropLast(2)) : t
        }
    }

    /// Words a reading writes with a capital in the middle of a sentence: names, by the
    /// evidence of the moment itself.
    static func midNames(_ r: Recording) -> Set<String> {
        guard let i = r.meta.insight else { return [] }
        var out = Set<String>()
        for text in (i.brief ?? []).map(\.text) + (i.keyLines ?? []).map(\.text) + (i.decisions ?? []) {
            for sentence in text.components(separatedBy: CharacterSet(charactersIn: ".!?…;:")) {
                for (k, w) in tokens(sentence).enumerated() where k > 0 && w.first?.isUppercase == true { out.insert(w) }
            }
        }
        return out
    }

    /// Names in a moment's reading, joined into phrases: from its title, brief, key lines and
    /// decisions. A capital in the middle of a sentence of the reading marks a name. At the
    /// start of a sentence, or in the title, a capital proves nothing ("Book the room",
    /// "Meet at the cafe"), so there a word counts only when the moment never writes it in
    /// lower case and either some reading writes it with a capital mid-sentence (`names`,
    /// gathered across the library) or the language tagger knows it for a person, a place or
    /// an organisation. People are left out.
    static func phrases(_ r: Recording, people: Set<String>, names: Set<String> = []) -> [String] {
        guard let i = r.meta.insight else { return [] }
        let title = i.title ?? ""
        let body = (i.brief ?? []).map(\.text) + (i.keyLines ?? []).map(\.text) + (i.decisions ?? [])
        var lower = Set<String>()
        for text in [r.meta.transcript ?? "", title] + body {
            for w in tokens(text) where w.first?.isLowercase == true { lower.insert(w) }
        }
        let nameWords = Set(people.flatMap { $0.split(separator: " ").map(String.init) })
        func usable(_ w: String) -> Bool {
            w.first?.isUppercase == true && w.count > 2 && !stop.contains(w) && !nameWords.contains(w) && !people.contains(w)
        }
        let tagger = NLTagger(tagSchemes: [.nameType])
        func taggedName(_ word: String, in sentence: String) -> Bool {
            tagger.string = sentence
            var found = false
            tagger.enumerateTags(in: sentence.startIndex..<sentence.endIndex, unit: .word, scheme: .nameType,
                                 options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
                if let tag, tag == .organizationName || tag == .placeName || tag == .personalName, sentence[range].contains(word) {
                    found = true
                    return false
                }
                return true
            }
            return found
        }
        var out: [String] = []
        var seen = Set<String>()
        for (n, text) in ([title] + body).enumerated() {
            for sentence in text.components(separatedBy: CharacterSet(charactersIn: ".!?…;:")) {
                let words = tokens(sentence)
                var k = 0
                while k < words.count {
                    let w = words[k]
                    let midSentence = n > 0 && k > 0
                    guard usable(w), midSentence || (!lower.contains(w.lowercased()) && (names.contains(w) || taggedName(w, in: sentence))) else {
                        k += 1
                        continue
                    }
                    var phrase = w
                    var j = k + 1
                    while j < words.count, usable(words[j]) {
                        phrase += " " + words[j]
                        j += 1
                    }
                    if seen.insert(phrase).inserted { out.append(phrase) }
                    k = j
                }
            }
        }
        return out
    }

    /// The phrases, lowercased, each with the way it was first written.
    static func terms(_ r: Recording, people: Set<String>, names: Set<String> = []) -> [String: String] {
        var out: [String: String] = [:]
        for p in phrases(r, people: people, names: names) where out[p.lowercased()] == nil { out[p.lowercased()] = p }
        return out
    }

    /// Capitalised terms, joined into phrases, that run through two or more moments.
    static func threads(_ moments: [Recording], people: Set<String>, limit: Int = 6) -> [Thread] {
        var byTerm: [String: [Recording]] = [:]
        var latest: [String: (Date, String)] = [:]
        for r in moments {
            guard let i = r.meta.insight else { continue }
            let sentences = [i.title ?? ""] + (i.brief ?? []).map(\.text) + (i.keyLines ?? []).map(\.text) + (i.decisions ?? [])
            let terms = Set(phrases(r, people: people))
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
            .prefix(limit).map { $0 }
    }

    static func people(_ moments: [Recording], limit: Int = 10) -> [Person] {
        var map: [String: Person] = [:]
        for r in moments {
            let items = (r.meta.insight?.items ?? []).filter { !$0.isDismissed }
            for name in r.people {
                map[name, default: Person(name: name)].moments.append(r)
                map[name]?.youOwe += items.filter { $0.isAction && !$0.isDone && $0.text.mentions(name) }.count
            }
            for item in items where item.isPromise {
                // "Maya and Ravi" is a promise from each of them, not from a third person.
                for raw in (item.who ?? "").components(separatedBy: " and ") {
                    guard let who = PeopleNames.canonical(raw.trimmingCharacters(in: .whitespaces)) else { continue }
                    map[who, default: Person(name: who)].waitingOn.append(item)
                }
            }
        }
        return map.values.sorted { ($0.moments.count, $0.name) > ($1.moments.count, $1.name) }.prefix(limit).map { $0 }
    }

    /// What the model reads to write the briefing: one block per moment, from the readings.
    var text: String {
        moments.reversed().map { Digest.reading($0) }.joined(separator: "\n\n")
    }

    /// One moment as a model reads it, in a digest or a thread: when, what, who, and what came of it.
    static func reading(_ r: Recording) -> String {
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
    }
}

/// The lists under the findings, one at a time.
enum RecordTab: String, CaseIterable, Identifiable {
    case commitments = "Commitments", decided = "Decided", open = "Still open", figures = "Figures", threads = "Threads", people = "People"
    var id: String { rawValue }
}

/// Something only adding up many conversations shows: a sentence the user would not
/// have arrived at alone, a picture of it, and what to do about it.
struct Finding: Identifiable {
    enum Visual {
        /// Work's share of recorded time, this span against the last.
        case balance(before: Double?, after: Double, beforeLabel: String, afterLabel: String)
        case ring(done: Int, total: Int, previous: (done: Int, total: Int)?)
        /// Open commitments per day, so far.
        case growth(open: [Int], labels: [String])
        /// Commitments taken on per day, with the day that stands out.
        case spike(intake: [Int], labels: [String], peak: Int)
        case timeline(dates: [Date], window: DateInterval, settledAt: Date?)
        case waiting([(name: String, days: Int)])
        case lapse(said: Date, due: Date?, now: Date)
        case pair(a: Int, b: Int, aLabel: String, bLabel: String)
        case step(fromValue: String, fromLabel: String, toValue: String, toLabel: String, up: Bool)
        case presence([Bool], labels: [String])
        case hours(seconds: Int, decisions: Int)
    }

    enum Action {
        case open(ids: [String], title: String)
        case remind(title: String, due: Date?, note: String)
        case chase(Recording, NextItem)
        case place(Recording, NextItem)
        case placeAll([(Recording, NextItem)])
        case record(RecordTab)
    }

    struct Choice: Identifiable {
        let label: String
        let action: Action
        var id: String { label }
    }

    let id: String
    let tag: String
    let tint: Color
    let text: String
    let visual: Visual?
    let choices: [Choice]
    let weight: Int
}

enum Findings {
    typealias Choice = Finding.Choice

    /// The findings for a span, strongest first, at most six.
    static func make(_ d: Digest, previous: Digest?, history: [Digest], all: [Recording], spanName: String) -> [Finding] {
        let now = Date()
        let cal = Calendar.current
        let thisSpan = "this \(spanName)", lastSpan = "last \(spanName)"
        var out: [Finding] = []
        let recent = all.filter { ($0.startedAt ?? .distantPast) > now.addingTimeInterval(-30 * 86_400) }
        let names = Set(all.flatMap(\.people))

        out += goneQuiet(recent, all: all, now: now, cal: cal)
        if let f = waitingOnYou(recent, names: names, now: now) { out.append(f) }
        out += threads(d, now: now)
        if let f = meetings(d, thisSpan: thisSpan) { out.append(f) }
        if let f = followThrough(d, previous: previous, thisSpan: thisSpan, lastSpan: lastSpan) { out.append(f) }
        if let f = load(d, thisSpan: thisSpan, cal: cal) { out.append(f) }
        if let f = questions(d, thisSpan: thisSpan) { out.append(f) }
        if let f = figureMoved(d, previous: previous) { out.append(f) }
        if let f = balance(d, previous: previous, thisSpan: thisSpan, lastSpan: lastSpan) { out.append(f) }
        out += outOfTouch(d, history: history, all: all, spanName: spanName, thisSpan: thisSpan, now: now)

        if out.isEmpty, d.moments.count < 3, all.count < 5 {
            out.append(Finding(id: "early", tag: "Early days", tint: Brand.muted,
                               text: "Insights builds up as the Pocket records. Within a week or so there is enough here to show your balance of work and life, your follow-through, what has stalled, and who is waiting on you.",
                               visual: nil, choices: [], weight: 1))
        }
        return Array(out.sorted { $0.weight > $1.weight }.prefix(6))
    }

    // MARK: The rules

    /// A promise that fell due, or is a week old, with nothing recorded with that person since.
    private static func goneQuiet(_ recent: [Recording], all: [Recording], now: Date, cal: Calendar) -> [Finding] {
        var lapsed: [(who: String, days: Int, said: Date, r: Recording, item: NextItem)] = []
        for r in recent {
            guard let said = r.startedAt else { continue }
            for item in r.meta.insight?.items ?? [] where item.isPromise && !item.isDone && !item.isDismissed {
                guard let who = item.who, !who.isEmpty else { continue }
                let overdue = item.date.map { $0 < now } ?? false
                let old = item.date == nil && now.timeIntervalSince(said) > 5 * 86_400
                guard overdue || old else { continue }
                let after = max(said, item.date ?? said)
                let since = all.contains { ($0.startedAt ?? .distantPast) > after && $0.people.contains { $0.caseInsensitiveCompare(who) == .orderedSame } }
                guard !since else { continue }
                lapsed.append((who, Int(now.timeIntervalSince(item.date ?? said) / 86_400), said, r, item))
            }
        }
        // One card per person: the oldest lapse leads, the rest are counted.
        var out: [Finding] = []
        let byWho = Dictionary(grouping: lapsed) { $0.who.lowercased() }
        for group in byWho.values {
            guard let lead = group.max(by: { $0.days < $1.days }) else { continue }
            let more = group.count > 1 ? ", with \(group.count - 1) more promise\(group.count == 2 ? "" : "s") open" : ""
            let text: String
            if let due = lead.item.date {
                let past = lead.days == 0 ? "due today" : "\(lead.days) day\(lead.days == 1 ? "" : "s") past due"
                text = "\(lead.who) said “\(lead.item.text)”, due \(dayName(due, cal)). It is \(past)\(more), and nothing with \(lead.who) has been recorded since."
            } else {
                text = "\(lead.who) said “\(lead.item.text)” \(lead.days) days ago\(more), and nothing with \(lead.who) has been recorded since."
            }
            out.append(Finding(id: "quiet/\(lead.who.lowercased())", tag: "Gone quiet", tint: Brand.record, text: text,
                               visual: .lapse(said: lead.said, due: lead.item.date, now: now),
                               choices: [Choice(label: lead.item.reminderID == nil ? "Remind me to chase" : "Reminder set", action: .chase(lead.r, lead.item)),
                                         Choice(label: "Open", action: .open(ids: [lead.r.id], title: lead.r.displayTitle))],
                               weight: 100 - min(lead.days, 20)))
        }
        return Array(out.sorted { $0.weight > $1.weight }.prefix(2))
    }

    /// Open commitments that name someone, two days old or more, oldest first.
    private static func waitingOnYou(_ recent: [Recording], names: Set<String>, now: Date) -> Finding? {
        var waiting: [(name: String, days: Int, r: Recording, item: NextItem)] = []
        for r in recent {
            guard let said = r.startedAt else { continue }
            for item in r.meta.insight?.items ?? [] where item.isAction && !item.isDone && !item.isDismissed {
                let named = item.who ?? names.first { item.text.mentions($0) }
                guard let who = named, !who.isEmpty else { continue }
                let days = Int(now.timeIntervalSince(said) / 86_400)
                guard days >= 2 else { continue }
                if let i = waiting.firstIndex(where: { $0.name == who }) {
                    if days > waiting[i].days { waiting[i] = (who, days, r, item) }
                } else {
                    waiting.append((who, days, r, item))
                }
            }
        }
        guard let longest = waiting.max(by: { $0.days < $1.days }) else { return nil }
        let text = waiting.count == 1
            ? "Your oldest open commitment involving someone else is \(longest.days) days old: “\(longest.item.text)”, with \(longest.name)."
            : "\(waiting.count) of your open commitments involve other people. The oldest, \(longest.days) days: “\(longest.item.text)”, with \(longest.name)."
        let rows = waiting.sorted { $0.days > $1.days }.prefix(5).map { (name: $0.name, days: $0.days) }
        return Finding(id: "waiting", tag: "Owed to others", tint: Brand.record, text: text, visual: .waiting(rows),
                       choices: [Choice(label: longest.item.reminderID == nil ? "Add to Reminders" : "In Reminders", action: .place(longest.r, longest.item)),
                                 Choice(label: "Open", action: .open(ids: [longest.r.id], title: longest.r.displayTitle))],
                       weight: 95)
    }

    /// Threads that keep coming up without a decision, and one that got settled.
    private static func threads(_ d: Digest, now: Date) -> [Finding] {
        var stalled: [Finding] = [], settled: [Finding] = []
        for t in d.threads {
            let dates = t.dates.sorted()
            guard let first = dates.first, let last = dates.last else { continue }
            let days = Int(last.timeIntervalSince(first) / 86_400)
            let decidedAt = t.moments.compactMap { r -> Date? in
                (r.meta.insight?.decisions ?? []).contains { $0.range(of: t.term, options: .caseInsensitive) != nil } ? r.startedAt : nil
            }.max()
            let open = Choice(label: "Open", action: .open(ids: t.moments.map(\.id), title: t.term))
            if decidedAt == nil, t.moments.count >= 3 || (t.moments.count >= 2 && days >= 5) {
                let span = days == 0 ? "today" : "over \(days) days"
                stalled.append(Finding(id: "stalled/\(t.term)", tag: "Stalled", tint: Brand.record,
                                       text: "“\(t.term)” has come up in \(t.moments.count) conversations \(span) without a decision.",
                                       visual: .timeline(dates: dates, window: d.window, settledAt: nil),
                                       choices: [Choice(label: "Settle it", action: .remind(title: "Decide: \(t.term)", due: tomorrowMorning(now),
                                                                                             note: "Came up in \(t.moments.count) conversations without a decision. From Private Pocket.")), open],
                                       weight: 88 + min(t.moments.count, 5)))
            } else if let decidedAt, t.moments.count >= 3 {
                settled.append(Finding(id: "settled/\(t.term)", tag: "Settled", tint: Brand.good,
                                       text: "“\(t.term)” ran through \(t.moments.count) conversations and was settled \(dayName(decidedAt)).",
                                       visual: .timeline(dates: dates, window: d.window, settledAt: decidedAt), choices: [open], weight: 40))
            }
        }
        return Array(stalled.prefix(2)) + Array(settled.prefix(1))
    }

    /// Meetings that produced no decision.
    private static func meetings(_ d: Digest, thisSpan: String) -> Finding? {
        let ms = d.meetings
        let seconds = ms.map { $0.meta.seconds ?? 0 }.reduce(0, +)
        let decided = ms.map { ($0.meta.insight?.decisions ?? []).count }.reduce(0, +)
        guard ms.allSatisfy({ $0.meta.insight?.readByModel == true }) else { return nil }
        if ms.count >= 2, decided == 0 {
            return Finding(id: "meetings", tag: "Meetings", tint: Brand.work,
                           text: "\(ms.count) meetings \(thisSpan), \(Digest.hours(seconds)) between them, and not one decision recorded in any of them.",
                           visual: .hours(seconds: seconds, decisions: 0),
                           choices: [Choice(label: "Open them", action: .open(ids: ms.map(\.id), title: "Meetings"))], weight: 85)
        }
        if seconds >= 2 * 3600, decided <= 1 {
            return Finding(id: "meetings", tag: "Meetings", tint: Brand.work,
                           text: "\(Digest.hours(seconds)) of meetings \(thisSpan) produced \(decided == 0 ? "no decision" : "one decision").",
                           visual: .hours(seconds: seconds, decisions: decided),
                           choices: [Choice(label: "Open them", action: .open(ids: ms.map(\.id), title: "Meetings"))], weight: 85)
        }
        return nil
    }

    private static func followThrough(_ d: Digest, previous: Digest?, thisSpan: String, lastSpan: String) -> Finding? {
        let total = d.yours.count, done = d.yoursDone.count
        guard total >= 3 else { return nil }
        let prev: (done: Int, total: Int)? = previous.flatMap { $0.yours.count >= 2 ? ($0.yoursDone.count, $0.yours.count) : nil }
        var text = "You have done \(done) of the \(total) things you took on \(thisSpan)."
        if let prev { text += " \(lastSpan.capitalizedFirst): \(prev.done) of \(prev.total)." }
        if done * 3 < total, let oldest = d.yoursOpen.compactMap({ $0.0.startedAt }).min(), !Calendar.current.isDateInToday(oldest) {
            text += " The oldest still open is from \(dayName(oldest))."
        }
        let open = d.yoursOpen.filter { $0.1.reminderID == nil }
        var choices = [Choice(label: "See them", action: .record(.commitments))]
        if !open.isEmpty { choices.insert(Choice(label: open.count == 1 ? "Add it to Reminders" : "Add the open ones to Reminders", action: .placeAll(open)), at: 0) }
        return Finding(id: "follow", tag: "Follow-through", tint: Brand.act, text: text,
                       visual: .ring(done: done, total: total, previous: prev), choices: choices, weight: 80)
    }

    /// Open commitments growing through the span, or one day that brought most of them.
    private static func load(_ d: Digest, thisSpan: String, cal: Calendar) -> Finding? {
        guard !d.days.isEmpty else { return nil }
        var taken = [Int](repeating: 0, count: d.days.count), closed = taken
        for (r, item) in d.yours {
            guard let s = r.startedAt, let i = d.days.firstIndex(where: { cal.isDate($0.date, inSameDayAs: s) }) else { continue }
            taken[i] += 1
            if item.isDone {
                let c = item.doneAt ?? s
                let j = d.days.firstIndex { cal.isDate($0.date, inSameDayAs: c) } ?? i
                closed[min(max(i, j), d.days.count - 1)] += 1
            }
        }
        let today = d.days.firstIndex { cal.isDateInToday($0.date) } ?? d.days.count - 1
        var open: [Int] = [], run = 0
        for i in 0...today { run += taken[i] - closed[i]; open.append(run) }
        let labels = d.days.prefix(today + 1).map { d.days.count <= 10 ? $0.date.formatted(.dateTime.weekday(.narrow)) : $0.date.formatted(.dateTime.day()) }
        let total = taken.reduce(0, +)
        if let firstNZ = open.firstIndex(where: { $0 > 0 }), let last = open.last, last >= 4, open.count - firstNZ >= 3, last >= 2 * max(1, open[firstNZ]) {
            let closedTotal = closed.reduce(0, +)
            let tail = closedTotal == 0 ? "and none has been closed yet" : "with \(closedTotal) closed along the way"
            return Finding(id: "load", tag: "Load", tint: Brand.act,
                           text: "Open commitments have grown from \(open[firstNZ]) on \(dayName(d.days[firstNZ].date)) to \(last) now, \(tail).",
                           visual: .growth(open: open, labels: Array(labels)),
                           choices: [Choice(label: "See them", action: .record(.commitments))], weight: 75)
        }
        let busyDays = taken.filter { $0 > 0 }.count
        if total >= 4, busyDays >= 2, let peak = (0...today).max(by: { taken[$0] < taken[$1] }), taken[peak] * 2 >= total, taken[peak] >= 3 {
            return Finding(id: "spike", tag: "Load", tint: Brand.act,
                           text: "\(d.days[peak].date.formatted(.dateTime.weekday(.wide))) alone added \(taken[peak]) of the \(total) things you took on \(thisSpan).",
                           visual: .spike(intake: Array(taken.prefix(today + 1)), labels: Array(labels), peak: peak),
                           choices: [Choice(label: "See them", action: .record(.commitments))], weight: 72)
        }
        return nil
    }

    private static func questions(_ d: Digest, thisSpan: String) -> Finding? {
        let q = d.questions.count, dec = d.decisions.count
        if q >= 4, q * 2 > dec * 3 {
            var text = "\(thisSpan.capitalizedFirst) raised \(q) questions and settled \(dec)."
            let by = Dictionary(grouping: d.questions, by: { $0.recording.id })
            if let top = by.max(by: { $0.value.count < $1.value.count }), top.value.count >= 2, let r = top.value.first?.recording {
                text += " \(top.value.count) of them are from \(r.displayTitle)."
            }
            return Finding(id: "questions", tag: "Open questions", tint: Brand.act, text: text,
                           visual: .pair(a: q, b: dec, aLabel: "raised", bLabel: "settled"),
                           choices: [Choice(label: "See what is open", action: .record(.open))], weight: 70)
        }
        if dec >= 4, dec >= q {
            return Finding(id: "decided", tag: "Decided", tint: Brand.good,
                           text: "\(thisSpan.capitalizedFirst) settled \(dec) things and left \(q) open.",
                           visual: .pair(a: dec, b: q, aLabel: "settled", bLabel: "open"),
                           choices: [Choice(label: "See them", action: .record(.decided))], weight: 35)
        }
        return nil
    }

    // MARK: Figures

    private struct Fig {
        let amount: Double
        let shown: String
        let money: Bool
        let subject: Set<String>
        let about: String
        let recording: Recording
    }

    private static let figureStop: Set<String> = ["the", "and", "for", "with", "per", "about", "around", "roughly", "each", "from", "that", "this", "was", "were", "are", "will", "would", "been", "have", "has", "had", "they", "them", "their", "you", "your", "our", "its", "all", "than", "more", "less", "over", "under", "just", "only", "some", "into", "onto",
                                                  "people", "person", "persons", "hours", "hour", "days", "day", "weeks", "week", "months", "month", "years", "year", "minutes", "minute", "pounds", "dollars", "euros", "percent", "times", "units", "items", "things", "spaces", "seats", "places", "taken", "left"]
    private static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    private static func parse(_ line: Digest.Line) -> Fig? {
        let lower = line.text.lowercased()
        if lower.contains("o'clock") || lower.contains("oclock") { return nil }
        if lower.range(of: #"\b\d{1,2}(:\d{2})?\s?(am|pm)\b"#, options: .regularExpression) != nil { return nil }
        if lower.range(of: #"\b\d{1,2}(st|nd|rd|th)\b"#, options: .regularExpression) != nil { return nil }
        if months.contains(where: { lower.contains($0) }) { return nil }
        guard let m = line.text.range(of: #"([£$€]\s?)?\d[\d,]*(\.\d+)?\s?(k|K|m|M|bn|%)?"#, options: .regularExpression) else { return nil }
        let shown = String(line.text[m]).trimmingCharacters(in: .whitespaces)
        guard var amount = Double(shown.filter { "0123456789.".contains($0) }) else { return nil }
        let tail = shown.lowercased()
        if tail.hasSuffix("bn") { amount *= 1e9 } else if tail.hasSuffix("m") { amount *= 1e6 } else if tail.hasSuffix("k") { amount *= 1e3 }
        let rest = line.text.replacingCharacters(in: m, with: " ")
        let subject = Set(rest.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 && !figureStop.contains($0) })
        guard !subject.isEmpty else { return nil }
        var about = rest.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        for lead in ["for ", "of ", "on ", "at ", "to ", "in "] where about.lowercased().hasPrefix(lead) { about = String(about.dropFirst(lead.count)); break }
        return Fig(amount: amount, shown: shown, money: shown.first.map { "£$€".contains($0) } ?? false, subject: subject, about: about, recording: line.recording)
    }

    /// The same thing counted differently in two conversations.
    private static func figureMoved(_ d: Digest, previous: Digest?) -> Finding? {
        let figs = (d.figures + (previous?.figures ?? [])).compactMap(parse)
        var best: (Fig, Fig, Int)?
        for i in figs.indices {
            for j in figs.indices where j > i {
                let a = figs[i], b = figs[j]
                guard a.recording.id != b.recording.id, a.money == b.money, a.amount != b.amount else { continue }
                let shared = a.subject.intersection(b.subject).count
                let needed = min(a.subject.count, b.subject.count) >= 3 ? 2 : 1
                guard shared >= needed, shared > (best?.2 ?? 0) else { continue }
                best = (a, b, shared)
            }
        }
        guard let (x, y, _) = best else { return nil }
        let (from, to) = (x.recording.startedAt ?? .distantPast) <= (y.recording.startedAt ?? .distantPast) ? (x, y) : (y, x)
        let fromDay = from.recording.startedAt.map { dayName($0) } ?? "earlier", toDay = to.recording.startedAt.map { dayName($0) } ?? "later"
        return Finding(id: "figure/\(to.recording.id)", tag: "A figure moved", tint: Brand.act,
                       text: "\(to.about.capitalizedFirst): \(from.shown) on \(fromDay), \(to.shown) by \(toDay).",
                       visual: .step(fromValue: from.shown, fromLabel: fromDay, toValue: to.shown, toLabel: toDay, up: to.amount > from.amount),
                       choices: [Choice(label: "Open both", action: .open(ids: [from.recording.id, to.recording.id], title: to.about.capitalizedFirst))], weight: 65)
    }

    private static func balance(_ d: Digest, previous: Digest?, thisSpan: String, lastSpan: String) -> Finding? {
        let wl = d.workSeconds + d.lifeSeconds
        guard wl >= 600 else { return nil }
        let w = Double(d.workSeconds) / Double(wl)
        if let p = previous, p.workSeconds + p.lifeSeconds >= 600 {
            let pw = Double(p.workSeconds) / Double(p.workSeconds + p.lifeSeconds)
            guard abs(w - pw) >= 0.15 else { return nil }
            return Finding(id: "balance", tag: "Balance", tint: Brand.life,
                           text: "Work took \(pct(w)) of your recorded time \(thisSpan), \(w > pw ? "up" : "down") from \(pct(pw)) \(lastSpan).",
                           visual: .balance(before: pw, after: w, beforeLabel: lastSpan, afterLabel: thisSpan), choices: [], weight: 60)
        }
        if w >= 0.85 || w <= 0.15 {
            return Finding(id: "balance", tag: "Balance", tint: Brand.life,
                           text: w >= 0.85 ? "Nearly everything you recorded \(thisSpan) was work: \(pct(w))." : "Nearly everything you recorded \(thisSpan) was life: \(pct(1 - w)).",
                           visual: .balance(before: nil, after: w, beforeLabel: lastSpan, afterLabel: thisSpan), choices: [], weight: 50)
        }
        return nil
    }

    /// Someone who was in the last spans and is not in this one.
    private static func outOfTouch(_ d: Digest, history: [Digest], all: [Recording], spanName: String, thisSpan: String, now: Date) -> [Finding] {
        guard history.count >= 2, d.window.start.addingTimeInterval(d.window.duration / 2) < now else { return [] }
        let here = Set(d.people.map(\.name))
        let past = history.reversed().map { Set($0.people.map(\.name)) }   // oldest first
        let names = past.reduce(Set<String>()) { $0.union($1) }
        var out: [Finding] = []
        for name in names.sorted() where !here.contains(name) {
            let presence = past.map { $0.contains(name) }
            guard presence.last == true, presence.filter({ $0 }).count >= 2 else { continue }
            let count = presence.filter { $0 }.count
            let text = count == past.count
                ? "You had spoken with \(name) every \(spanName) for \(count) \(spanName)s; not \(thisSpan)."
                : "You had spoken with \(name) in \(count) of the last \(past.count) \(spanName)s; not \(thisSpan)."
            var labels = (1...past.count).reversed().map { $0 == 1 ? "last" : "\($0) ago" }
            labels.append("this")
            let ids = all.filter { $0.people.contains(name) }.map(\.id)
            out.append(Finding(id: "touch/\(name)", tag: "Out of touch", tint: Brand.life, text: text,
                               visual: .presence(presence + [false], labels: labels),
                               choices: [Choice(label: "Remind me to call \(name)", action: .remind(title: "Call \(name)", due: tomorrowMorning(now), note: "Not spoken \(thisSpan). From Private Pocket.")),
                                         Choice(label: "Open", action: .open(ids: ids, title: name))],
                               weight: 55))
        }
        return Array(out.prefix(2))
    }

    // MARK: Words

    static func dayName(_ d: Date, _ cal: Calendar = .current) -> String {
        if cal.isDateInToday(d) { return "today" }
        if cal.isDateInYesterday(d) { return "yesterday" }
        if cal.isDateInTomorrow(d) { return "tomorrow" }
        if abs(d.timeIntervalSinceNow) < 6 * 86_400 { return d.formatted(.dateTime.weekday(.wide)) }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }

    static func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

    static func tomorrowMorning(_ now: Date) -> Date? {
        let cal = Calendar.current
        guard let t = cal.date(byAdding: .day, value: 1, to: now) else { return nil }
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: t)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }

    /// The name as a word in this text: "Tom" in "call Tom back", not in "tomorrow".
    func mentions(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return false }
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: n) + "(?![\\p{L}\\p{N}])"
        return range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
