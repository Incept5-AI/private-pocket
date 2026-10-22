import EventKit
import Foundation
import FoundationModels
import SwiftUI

/// What kind of conversation a recording was. A language model picks one of the first
/// four when it can tell work from life; `call`, `meeting` and `note` come from the
/// card's switch and the speaker count when it cannot, or when no model has read it.
enum MomentKind: String, Codable, CaseIterable {
    case businessCall = "business_call", personalCall = "personal_call"
    case businessMeeting = "business_meeting", personalMeeting = "personal_meeting"
    case call, meeting, note, other

    var label: String {
        switch self {
        case .businessCall: "Business call"
        case .personalCall: "Personal call"
        case .businessMeeting: "Business meeting"
        case .personalMeeting: "Personal meeting"
        case .call: "Call"
        case .meeting: "Meeting"
        case .note: "Note"
        case .other: "Conversation"
        }
    }

    var symbol: String {
        switch self {
        case .businessCall, .personalCall, .call: "phone.fill"
        case .businessMeeting, .personalMeeting, .meeting: "person.2.fill"
        case .note: "waveform"
        case .other: "bubble.left.and.bubble.right.fill"
        }
    }

    var isWork: Bool { self == .businessCall || self == .businessMeeting }
    var isLife: Bool { self == .personalCall || self == .personalMeeting }
    var colour: Color { isWork ? Brand.work : isLife ? Brand.life : Brand.textSecondary }
    /// The kinds a person can correct a moment to.
    static let choices: [MomentKind] = [.businessCall, .personalCall, .businessMeeting, .personalMeeting, .note]
}

/// A sentence of the brief, or a line of the conversation, with where in the audio it
/// comes from, so it can be heard.
struct Anchored: Codable, Hashable, Identifiable {
    var text: String
    var at: Double?
    var id: String { text }
}

/// One thing that follows from a conversation: something to do, a date, or a promise
/// someone made to the user. Placed in Reminders or Calendar by the app, ticked off in
/// either place.
struct NextItem: Codable, Hashable, Identifiable {
    var id: String = UUID().uuidString
    /// "action", "date" or "promise".
    var kind: String
    var text: String
    var who: String?
    /// When, in the words used ("by Friday").
    var when: String?
    var date: Date?
    /// Where in the audio it was said, and the words it rests on.
    var at: Double?
    var quote: String?
    /// For a date: where it happens, and how long, when either was said.
    var location: String?
    var duration: Double?
    var reminderID: String?
    var eventID: String?
    var done: Bool?
    /// When it was ticked, here or in Reminders, for the week's shape.
    var doneAt: Date?
    var dismissed: Bool?

    var isAction: Bool { kind == "action" }
    var isDate: Bool { kind == "date" }
    var isPromise: Bool { kind == "promise" }
    var isDone: Bool { done == true }
    var isDismissed: Bool { dismissed == true }
}

/// What came out of a conversation, kept in the recording's sidecar.
struct MomentInsight: Codable, Hashable {
    var kind: String
    var title: String?
    var actions: [String] = []
    var promises: [String] = []
    var upcoming: [String] = []
    var people: [String] = []
    var added: [String]?
    /// "model" when a language model read it; "switch" when only the switch, the speakers and the dates did.
    var source: String?
    /// What happened, in two or three sentences addressed to the user, each anchored.
    var brief: [Anchored]?
    var next: [NextItem]?
    /// The lines that mattered most, marked on the waveform.
    var keyLines: [Anchored]?
    /// Speaker names the conversation revealed, keyed like `speakerNames` ("0", "1"…).
    var inferredSpeakers: [String: String]?
    /// What was decided, what was asked and left open, and the figures that came up.
    var decisions: [String]?
    var questions: [String]?
    var figures: [String]?
    /// Which reader wrote it; older readings are redone when a moment opens.
    var version: Int?
    static let readerVersion = 5

    var momentKind: MomentKind { MomentKind(rawValue: kind) ?? .other }
    var readByModel: Bool { source == "model" }
    func isAdded(_ item: String) -> Bool { added?.contains(item) == true }

    /// The Next list; readings made before it existed are folded in.
    var items: [NextItem] {
        if let next { return next }
        return actions.enumerated().map { NextItem(id: "action-\($0.offset)", kind: "action", text: $0.element) }
            + upcoming.enumerated().map { NextItem(id: "date-\($0.offset)", kind: "date", text: $0.element, date: Planner.date(in: $0.element)) }
            + promises.enumerated().map { NextItem(id: "promise-\($0.offset)", kind: "promise", text: $0.element) }
    }
}

extension Recording {
    var kind: MomentKind {
        if let l = meta.labelKind.flatMap(MomentKind.init(rawValue:)) { return l }
        if let k = meta.insight?.momentKind, k != .other { return k }
        if isCall { return .call }
        if let t = meta.turns, Speakers.count(t) > 1 { return .meeting }
        return meta.transcript == nil ? .other : .note
    }

    /// The line that stands for the moment: the user's title, the model's, else the
    /// first thing that was said.
    var quote: String {
        if let t = meta.title, !t.isEmpty { return t }
        if let t = meta.insight?.title, !t.isEmpty { return t }
        if let s = firstSentence { return "“\(s)”" }
        return meta.transcript == nil ? "Not transcribed yet" : (meta.place?.name ?? "Untitled")
    }

    var firstSentence: String? {
        guard let text = meta.transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        var first: String?
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, stop in
            first = s?.trimmingCharacters(in: .whitespacesAndNewlines)
            stop = true
        }
        guard var s = first, !s.isEmpty else { return nil }
        if s.count > 120 { s = String(s.prefix(117)).trimmingCharacters(in: .whitespaces) + "…" }
        return s
    }

    /// Who was there, by name: the reading's people, else the names given to speakers.
    var people: [String] {
        if let p = meta.insight?.people, !p.isEmpty { return p }
        return (meta.speakerNames ?? [:]).values.filter { !$0.isEmpty }.sorted()
    }

    /// Who, and where: the second line of a card.
    var subline: String? {
        var parts: [String] = []
        if !people.isEmpty { parts.append(people.prefix(3).joined(separator: ", ")) }
        if let p = meta.place?.name { parts.append(p) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The kind as a small chip, in the kind's colour. Built from an icon and a text rather
/// than a Label, which drops its title when given a fixed size inside a list row.
struct KindChip: View {
    let kind: MomentKind

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: kind.symbol).font(.caption2.weight(.semibold))
            Text(kind.label).font(.caption.weight(.semibold))
        }
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(kind.colour)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(kind.colour.opacity(0.14), in: Capsule())
    }
}

// MARK: - Reading a conversation

@Generable
struct DraftSentence {
    @Guide(description: "One sentence of the brief, addressed to the user as 'you', in the transcript's language")
    var text: String
    @Guide(description: "The exact words from the transcript this sentence rests on, verbatim, ten words or fewer")
    var quote: String
}

@Generable
struct DraftItem {
    @Guide(description: "action if the user has to do it; promise if someone else said they would do something for the user; date if it is a meeting, deadline or event")
    var kind: String
    @Guide(description: "For an action, a short imperative. For a promise, 'Name will …'. For a date, the title as it should appear in a calendar, specific to this conversation: what it is and with whom or where, like 'Workshop at the Garden Room' or 'Call with Ravi about the launch'; never the date or time itself")
    var text: String
    @Guide(description: "Who made the promise; empty otherwise")
    var who: String
    @Guide(description: "For a date, where it happens, if said; empty otherwise")
    var place: String
    @Guide(description: "When, in the words used, like 'by Friday' or 'Tuesday the 12th at 9'; empty if none was said")
    var when: String
    @Guide(description: "The exact words from the transcript it rests on, verbatim, ten words or fewer")
    var quote: String
}

@Generable
struct DraftSpeaker {
    @Guide(description: "The label as it appears in the transcript, like Speaker 2")
    var label: String
    @Guide(description: "That person's name, if the conversation reveals it; empty if not")
    var name: String
}

@Generable
struct InsightDraft {
    @Guide(description: "What it was: business_call, personal_call, business_meeting, personal_meeting, note (one person thinking aloud) or other")
    var kind: String
    @Guide(description: "A title of at most six words, in the transcript's language")
    var title: String
    @Guide(description: "Two or three sentences saying what happened and what was decided, addressed to the user as 'you'")
    var brief: [DraftSentence]
    @Guide(description: "Everything that follows from the conversation: things the user must do, dates, and promises others made; empty if none")
    var next: [DraftItem]
    @Guide(description: "Up to three lines of the conversation that mattered most, verbatim; empty if none")
    var keyLines: [String]
    @Guide(description: "Names of the people who took part or were talked about; never labels like Speaker 1")
    var people: [String]
    @Guide(description: "For each Speaker label whose name the conversation reveals, the label and the name; empty if none")
    var speakers: [DraftSpeaker]
    @Guide(description: "Decisions made, each one short sentence; empty if none")
    var decisions: [String]
    @Guide(description: "Questions that still had no answer when the conversation ended, each one short sentence; never a question that was answered later in it; empty if none")
    var questions: [String]
    @Guide(description: "Amounts that matter, money, quantities or counts, each written as the amount and what it is for, like '£3,000 for the offsite' or '30 people at the workshop'; never a date, a day of the month or a clock time; empty if none")
    var figures: [String]
}

/// A plain copy of the draft, so a server's JSON and the on-device model meet in one place.
private struct Draft: Decodable {
    struct Sentence: Decodable { var text: String?; var quote: String? }
    struct Item: Decodable { var kind: String?; var text: String?; var who: String?; var place: String?; var when: String?; var quote: String? }
    struct Speaker: Decodable { var label: String?; var name: String? }
    var kind: String?
    var title: String?
    var brief: [Sentence]?
    var next: [Item]?
    var keyLines: [String]?
    var people: [String]?
    var speakers: [Speaker]?
    var decisions: [String]?
    var questions: [String]?
    var figures: [String]?

    init(_ d: InsightDraft) {
        kind = d.kind
        title = d.title
        brief = d.brief.map { Sentence(text: $0.text, quote: $0.quote) }
        next = d.next.map { Item(kind: $0.kind, text: $0.text, who: $0.who, place: $0.place, when: $0.when, quote: $0.quote) }
        keyLines = d.keyLines
        people = d.people
        speakers = d.speakers.map { Speaker(label: $0.label, name: $0.name) }
        decisions = d.decisions
        questions = d.questions
        figures = d.figures
    }
}

/// Reads a transcript for what the conversation was and what came out of it, with the
/// same language model that writes summaries: on the phone or on the user's server.
/// Every sentence and item comes back with the words it rests on, which `Anchor` turns
/// into a place in the audio.
enum Analyst {
    static let instructions = """
    You read the transcript of one recorded conversation, phone call or voice note, and give back what a good assistant would after sitting in the room. \
    Use only what is in the text; never invent names, dates or tasks. Write in the transcript's language, except the kind. \
    The user is the person who made the recording: address them as "you". \
    Speaker labels like Speaker 1 are not names and are never people; if the conversation reveals a label's name, give it under speakers. \
    Write each action as a short imperative without naming who does it; things other people said they would do are promises, not actions. \
    Title each date the way it should appear in a calendar: what it is and with whom or where, specific to this conversation, with the date and time kept out of the title and given under when. \
    Note what was decided. List only the questions still unanswered when the conversation ended. \
    Give figures as the amount and what it is for, never dates, days of the month or clock times. \
    For every item and every sentence of the brief, quote the exact words from the transcript it rests on, verbatim, ten words or fewer.
    """

    /// The whole transcript, in parts if it is long, merged into one reading.
    static func analyse(_ r: Recording, config c: LLMConfig) async throws -> MomentInsight {
        guard let text = r.transcriptForModel?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw AIError.emptyTranscript
        }
        let hint = r.isCall ? "The recorder's switch was on call, so this is a phone call. " : ""
        var drafts: [Draft] = []
        for chunk in Summariser.split(text, max: c.chunkChars).prefix(6) {
            drafts.append(try await draft(c, prompt: "\(hint)Transcript:\n\n\(chunk)"))
        }
        return merge(drafts, for: r)
    }

    private static func draft(_ c: LLMConfig, prompt: String) async throws -> Draft {
        guard c.remote else {
            let session = LanguageModelSession(model: .default, instructions: instructions)
            return Draft(try await session.respond(to: prompt, generating: InsightDraft.self).content)
        }
        let json = instructions + "\nReply with JSON only, no prose and no code fence, with exactly these keys: " +
            "\"kind\" (one of business_call, personal_call, business_meeting, personal_meeting, note, other); \"title\" (a string); " +
            "\"brief\" (an array of {\"text\", \"quote\"}); \"next\" (an array of {\"kind\": action|date|promise, \"text\", \"who\", \"place\", \"when\", \"quote\"}); " +
            "\"keyLines\" (an array of strings); \"people\" (an array of strings); \"speakers\" (an array of {\"label\", \"name\"}); " +
            "\"decisions\" (an array of strings: what was decided); " +
            "\"questions\" (an array of strings: questions that still had no answer when the conversation ended, never ones answered later in it); " +
            "\"figures\" (an array of strings: amounts that matter, money, quantities or counts, each as the amount and what it is for, " +
            "like '£3,000 for the offsite' or '30 people at the workshop', never a date, a day of the month or a clock time)."
        let reply = try await LLM.complete(c, instructions: json, prompt: prompt)
        guard let open = reply.firstIndex(of: "{"), let close = reply.lastIndex(of: "}"), open < close else { throw LLMError.empty }
        return try JSONDecoder().decode(Draft.self, from: Data(reply[open...close].utf8))
    }

    /// The kind by majority, the first title, the brief from the first part (and the
    /// end of the last), the lists joined without repeats, everything anchored.
    private static func merge(_ drafts: [Draft], for r: Recording) -> MomentInsight {
        let words = r.meta.words ?? []
        func anchor(_ q: String?) -> Double? { q.flatMap { Anchor.find($0, in: words) } }
        func clean(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

        var out = heuristic(r)
        let kinds = drafts.compactMap { $0.kind.flatMap(MomentKind.init(rawValue:)) }.filter { $0 != .other }
        var tally: [MomentKind: Int] = [:]
        for k in kinds { tally[k, default: 0] += 1 }
        if let k = tally.max(by: { $0.value < $1.value })?.key { out.kind = k.rawValue }
        out.title = drafts.compactMap { $0.title.map(clean) }.first { !$0.isEmpty }

        let sentences: [Draft.Sentence] = drafts.count == 1
            ? Array((drafts[0].brief ?? []).prefix(3))
            : Array((drafts.first?.brief ?? []).prefix(2)) + Array((drafts.last?.brief ?? []).suffix(1))
        out.brief = sentences.map { Anchored(text: clean($0.text), at: anchor($0.quote)) }.filter { !$0.text.isEmpty }

        var items: [NextItem] = []
        var seen = Set<String>()
        for d in drafts {
            for it in d.next ?? [] {
                let text = unlabelled(clean(it.text))
                guard !text.isEmpty, let kind = it.kind?.lowercased().trimmingCharacters(in: .whitespaces),
                      ["action", "date", "promise"].contains(kind) else { continue }
                let key = kind + "|" + text.lowercased().trimmingCharacters(in: .punctuationCharacters)
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                let when = clean(it.when).isEmpty ? nil : clean(it.when)
                let who = cleanWho(it.who)
                let place = clean(it.place).isEmpty ? nil : clean(it.place)
                let said = r.startedAt
                let found = when.flatMap { Planner.dateAndDuration(in: $0, said: said) } ?? (kind == "date" ? Planner.dateAndDuration(in: text, said: said) : nil)
                let title = kind == "date" ? eventTitle(text, place: place) : text
                let quote = clean(it.quote).isEmpty ? nil : clean(it.quote)
                items.append(NextItem(kind: kind, text: title, who: who, when: when, date: found?.date, at: anchor(quote), quote: quote,
                                      location: place, duration: found?.duration))
            }
        }
        out.next = Array(items.prefix(16))
        out.actions = items.filter(\.isAction).map(\.text)
        out.promises = items.filter(\.isPromise).map(\.text)
        out.upcoming = items.filter(\.isDate).map { [$0.text, $0.when].compactMap { $0 }.joined(separator: ", ") }
        out.keyLines = unique(drafts.flatMap { $0.keyLines ?? [] }, cap: 3).map { Anchored(text: $0, at: anchor($0)) }
        out.decisions = unique(drafts.flatMap { $0.decisions ?? [] }, cap: 6)
        out.questions = unique(drafts.flatMap { $0.questions ?? [] }, cap: 5)
        out.figures = unique(drafts.flatMap { $0.figures ?? [] }, cap: 8)
        out.people = unique((drafts.flatMap { $0.people ?? [] } + out.people).filter(isPerson), cap: 10)

        var inferred: [String: String] = [:]
        for d in drafts {
            for s in d.speakers ?? [] {
                let name = clean(s.name)
                guard !name.isEmpty, !isLabel(name), let i = speakerIndex(clean(s.label)) else { continue }
                inferred[String(i)] = inferred[String(i)] ?? name
            }
        }
        out.inferredSpeakers = inferred.isEmpty ? nil : inferred
        out.source = "model"
        out.version = MomentInsight.readerVersion
        return out
    }

    /// A calendar title: the date and time words stripped from the end, the place added
    /// when the title does not already say where.
    static func eventTitle(_ text: String, place: String?) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let days = "monday|tuesday|wednesday|thursday|friday|saturday|sunday|tomorrow|today|tonight|next week|next month|this week"
        let patterns = [
            #"[,\s]+(on|next|this|by|from|for)?\s*(\#(days))\b.*$"#,
            #"[,\s]+at\s+(half\s+|quarter\s+)?\d[\d:.]*\s*(am|pm|o'clock)?.*$"#,
            #"[,\s]+(on|by)\s+the\s+\d+(st|nd|rd|th)?\b.*$"#,
        ]
        for p in patterns {
            if let r = t.range(of: p, options: [.regularExpression, .caseInsensitive]), r.lowerBound > t.startIndex {
                t = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:-– "))
        if t.isEmpty { t = text }
        if let place, !t.localizedCaseInsensitiveContains(place), t.count + place.count < 48 {
            t += " at " + place
        }
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    /// "Speaker 2" → 1, the index `speakerNames` is keyed by.
    static func speakerIndex(_ label: String) -> Int? {
        let digits = label.drop { !$0.isNumber }.prefix { $0.isNumber }
        guard let n = Int(digits), n >= 1 else { return nil }
        return n - 1
    }

    /// "Speaker 2 to bring a tube" → "Bring a tube".
    static func unlabelled(_ s: String) -> String {
        let pattern = #"^\s*speaker\s+\w+\s+(to|will|should|is to|needs to|has to)\s+"#
        guard let r = s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return s }
        let rest = String(s[r.upperBound...])
        return rest.prefix(1).uppercased() + rest.dropFirst()
    }

    /// "Speaker 2", "speaker one": a transcript label, not a person.
    static func isLabel(_ s: String) -> Bool {
        let t = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("speaker ") || t == "speaker" || t.hasPrefix("unknown speaker")
    }

    private static let selfWords: Set<String> = ["you", "me", "i", "myself", "recorder", "the recorder", "user", "the user", "speaker", "everyone", "everybody", "team", "the team", "the board", "all"]

    /// A name: capitalised, not a label, not the user, not a group.
    static func isPerson(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let f = t.first, f.isUppercase, !isLabel(t) else { return false }
        return !selfWords.contains(t.lowercased())
    }

    /// Who an item names, with the user and labels taken out: "Ravi and Recorder" is Ravi.
    static func cleanWho(_ raw: String?) -> String? {
        let parts = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " & ", with: " and ").components(separatedBy: " and ")
            .flatMap { $0.components(separatedBy: ", ") }
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces) }
            .filter(isPerson)
        return parts.isEmpty ? nil : parts.joined(separator: " and ")
    }

    private static func unique(_ items: [String], cap: Int) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in items {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = s.lowercased().trimmingCharacters(in: .punctuationCharacters)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(s)
            if out.count == cap { break }
        }
        return out
    }

    /// Without a model: the kind from the switch and the speakers, the dates in the
    /// text, the names given to the speakers.
    static func heuristic(_ r: Recording) -> MomentInsight {
        let meeting = r.meta.turns.map { Speakers.count($0) > 1 } == true
        var out = MomentInsight(kind: (r.isCall ? MomentKind.call : meeting ? .meeting : .note).rawValue)
        out.people = Array((r.meta.speakerNames ?? [:]).values.filter { !$0.isEmpty }.sorted())
        if let text = r.meta.transcript {
            out.upcoming = Planner.dates(in: text, after: r.startedAt ?? Date())
                .map { "\($0.text) · \($0.date.formatted(date: .abbreviated, time: .shortened))" }
        }
        out.source = "switch"
        return out
    }
}

/// Finds where a quoted phrase was said, by matching its words in order against the
/// timed words of the transcript. Tolerant of a few mis-heard words.
enum Anchor {
    static func find(_ quote: String, in words: [TimedWord]) -> Double? {
        let q = tokens(quote)
        guard q.count >= 2, !words.isEmpty else { return nil }
        let w = words.map { tokens($0.word).first ?? "" }
        let span = q.count + 4
        var best = (score: 0, index: 0)
        for i in 0..<w.count {
            let end = min(w.count, i + span)
            var score = 0, j = i
            for t in q {
                while j < end, w[j] != t { j += 1 }
                if j < end { score += 1; j += 1 }
            }
            if score > best.score { best = (score, i) }
            if score == q.count { break }
        }
        guard Double(best.score) >= Double(q.count) * 0.5 else { return nil }
        return words[best.index].start
    }

    static func tokens(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
    }
}

// MARK: - Reminders and Calendar

/// Reminders and Calendar. Actions go into a Pocket list in Reminders with their due
/// date, dates become hour-long events; both only once the user has allowed it, and
/// never twice for the same item.
enum Planner {
    private static let store = EKEventStore()
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    struct Found: Hashable {
        let text: String
        let date: Date
    }

    /// Dates mentioned in a text that fall after `after`, with the words around them.
    static func dates(in text: String, after: Date) -> [Found] {
        guard let detector else { return [] }
        let ns = text as NSString
        var out: [Found] = []
        for m in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let raw = m.date else { continue }
            let d = rebase(raw, phrase: ns.substring(with: m.range), said: after)
            guard d > after else { continue }
            let from = max(0, m.range.location - 36)
            let range = NSRange(location: from, length: min(ns.length - from, m.range.length + (m.range.location - from)))
            let words = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(Found(text: (from > 0 ? "…" : "") + words, date: d))
            if out.count == 6 { break }
        }
        return out
    }

    /// The first date in a short line like "Demo, Thursday 10am".
    static func date(in line: String) -> Date? { dateAndDuration(in: line)?.date }

    /// The first date in a line, and how long when a span like "nine till four" was said.
    static func dateAndDuration(in line: String, said: Date? = nil) -> (date: Date, duration: Double?)? {
        guard let detector else { return nil }
        for m in detector.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
            if let d = m.date { return (rebase(d, phrase: line, said: said), m.duration > 0 ? m.duration : nil) }
        }
        return nil
    }

    private static let absoluteDate = try? NSRegularExpression(
        pattern: #"\b\d{1,2}(st|nd|rd|th)\b|\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}\b|\b\d{1,2}\s+(of\s+)?(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)|\b20\d{2}\b|\b\d{1,2}/\d{1,2}"#,
        options: .caseInsensitive)
    private static let weekdayNames = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    /// The detector reads a phrase from today. One said on another day is moved back to
    /// it: "tomorrow" in a call ten days ago was the day after the call. A phrase with a
    /// day of the month, a month or a year stands as it is; a weekday keeps its weekday.
    static func rebase(_ d: Date, phrase: String, said: Date?) -> Date {
        guard let said else { return d }
        let cal = Calendar.current
        let delta = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: said)).day ?? 0
        guard delta != 0 else { return d }
        let lower = phrase.lowercased()
        if let re = absoluteDate, re.firstMatch(in: lower, range: NSRange(location: 0, length: (lower as NSString).length)) != nil { return d }
        guard var moved = cal.date(byAdding: .day, value: delta, to: d) else { return d }
        if weekdayNames.contains(where: { lower.contains($0) }) {
            let want = cal.component(.weekday, from: d)
            var k = 0
            while cal.component(.weekday, from: moved) != want, k < 7 {
                moved = cal.date(byAdding: .day, value: 1, to: moved) ?? moved
                k += 1
            }
        }
        return moved
    }

    // Reminders

    static func addReminder(_ title: String, due: Date?, note: String) async throws -> String {
        guard try await store.requestFullAccessToReminders() else { throw PlannerError.denied("Reminders") }
        let item = EKReminder(eventStore: store)
        item.title = title
        item.notes = note
        item.calendar = try pocketList()
        if let due {
            item.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            item.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(item, commit: true)
        return item.calendarItemIdentifier
    }

    static func setReminder(_ id: String, completed: Bool) {
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        r.isCompleted = completed
        try? store.save(r, commit: true)
    }

    static func reminderCompleted(_ id: String) -> Bool? {
        (store.calendarItem(withIdentifier: id) as? EKReminder)?.isCompleted
    }

    static func removeReminder(_ id: String) {
        if let r = store.calendarItem(withIdentifier: id) as? EKReminder { try? store.remove(r, commit: true) }
    }

    static func reminderURL(_ id: String) -> URL? { URL(string: "x-apple-reminderkit://REMCDReminder/\(id)") }

    /// The app's own list in Reminders, made on first use.
    private static func pocketList() throws -> EKCalendar {
        if let c = store.calendars(for: .reminder).first(where: { $0.title == "Pocket" }) { return c }
        let c = EKCalendar(for: .reminder, eventStore: store)
        c.title = "Pocket"
        guard let source = store.defaultCalendarForNewReminders()?.source
                ?? store.sources.first(where: { $0.sourceType == .calDAV })
                ?? store.sources.first(where: { $0.sourceType == .local }) else { throw PlannerError.denied("Reminders") }
        c.source = source
        try store.saveCalendar(c, commit: true)
        return c
    }

    // Calendar

    static func addEvent(_ title: String, at date: Date, duration: Double? = nil, location: String? = nil, note: String) async throws -> String {
        guard try await store.requestFullAccessToEvents() else { throw PlannerError.denied("Calendar") }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = date
        event.endDate = date.addingTimeInterval(duration ?? 3600)
        event.location = location
        event.notes = note
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent, commit: true)
        return event.eventIdentifier
    }

    static func removeEvent(_ id: String) {
        if let e = store.event(withIdentifier: id) { try? store.remove(e, span: .thisEvent, commit: true) }
    }

    static func calendarURL(at date: Date) -> URL? { URL(string: "calshow:\(Int(date.timeIntervalSinceReferenceDate))") }
}

enum PlannerError: LocalizedError {
    case denied(String)

    var errorDescription: String? {
        switch self {
        case .denied(let app): "Allow \(app) access for Private Pocket in iOS Settings."
        }
    }
}
