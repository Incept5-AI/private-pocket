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
}

/// What came out of a conversation, kept in the recording's sidecar.
struct MomentInsight: Codable, Hashable {
    var kind: String
    var title: String?
    var actions: [String] = []
    var promises: [String] = []
    var upcoming: [String] = []
    var people: [String] = []
    /// Items already added to Reminders or Calendar.
    var added: [String]?
    /// "model" when a language model read it; "switch" when only the switch, the speakers and the dates did.
    var source: String?

    var momentKind: MomentKind { MomentKind(rawValue: kind) ?? .other }
    var readByModel: Bool { source == "model" }
    func isAdded(_ item: String) -> Bool { added?.contains(item) == true }
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

    /// Who, and where: the second line of a card.
    var subline: String? {
        var parts: [String] = []
        let people = meta.insight?.people ?? Array((meta.speakerNames ?? [:]).values.sorted())
        if !people.isEmpty { parts.append(people.prefix(3).joined(separator: ", ")) }
        if let p = meta.place?.name { parts.append(p) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The kind as a small chip, in the kind's colour.
struct KindChip: View {
    let kind: MomentKind

    var body: some View {
        Label(kind.label, systemImage: kind.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(kind.colour)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(kind.colour.opacity(0.14), in: Capsule())
    }
}

// MARK: - Reading a conversation

@Generable
struct InsightDraft {
    @Guide(description: "What it was: business_call, personal_call, business_meeting, personal_meeting, note (one person thinking aloud) or other")
    var kind: String
    @Guide(description: "A title of at most six words, in the language of the transcript")
    var title: String
    @Guide(description: "Things the user agreed to do, each a short imperative sentence; empty if none")
    var actions: [String]
    @Guide(description: "Things other people said they would do for the user; empty if none")
    var promises: [String]
    @Guide(description: "Future meetings, deadlines or events mentioned, each as what and when in the words used; empty if none")
    var upcoming: [String]
    @Guide(description: "Names of the people who took part or were talked about; empty if none")
    var people: [String]
}

/// A plain copy of the draft, so a server's JSON and the on-device model meet in one place.
private struct Draft: Decodable {
    var kind: String?
    var title: String?
    var actions: [String]?
    var promises: [String]?
    var upcoming: [String]?
    var people: [String]?

    init(_ d: InsightDraft) {
        kind = d.kind
        title = d.title
        actions = d.actions
        promises = d.promises
        upcoming = d.upcoming
        people = d.people
    }
}

/// Reads a transcript for what the conversation was and what came out of it, with the
/// same language model that writes summaries: on the phone or on the user's server.
enum Analyst {
    static let instructions = """
    You read the transcript of one recorded conversation, phone call or voice note, and say what it was and what came out of it. \
    The transcript may be in any language; write the title and the items in that language. \
    Use only what is in the text. Do not invent names, dates or tasks. Keep every item short. \
    People are real names only: never list labels like Speaker 1 or Speaker 2 as people. \
    Write each action as a short imperative without naming who does it; things other people said they would do go under promises, not actions.
    """

    /// The whole transcript, in parts if it is long, merged into one reading.
    static func analyse(_ r: Recording, config c: LLMConfig) async throws -> MomentInsight {
        guard let text = r.transcriptForModel?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw AIError.emptyTranscript
        }
        let hint = r.isCall ? "The recorder's switch was on call, so this is a phone call. " : ""
        var drafts: [Draft] = []
        for chunk in Summariser.split(text, max: c.chunkChars).prefix(8) {
            drafts.append(try await draft(c, prompt: "\(hint)Transcript:\n\n\(chunk)"))
        }
        return merge(drafts, into: heuristic(r))
    }

    private static func draft(_ c: LLMConfig, prompt: String) async throws -> Draft {
        guard c.remote else {
            let session = LanguageModelSession(model: .default, instructions: instructions)
            return Draft(try await session.respond(to: prompt, generating: InsightDraft.self).content)
        }
        let json = instructions + "\nReply with JSON only, no prose and no code fence, with exactly these keys: " +
            "\"kind\" (one of business_call, personal_call, business_meeting, personal_meeting, note, other), " +
            "\"title\" (a string), \"actions\", \"promises\", \"upcoming\", \"people\" (each an array of strings)."
        let reply = try await LLM.complete(c, instructions: json, prompt: prompt)
        guard let open = reply.firstIndex(of: "{"), let close = reply.lastIndex(of: "}"), open < close else { throw LLMError.empty }
        return try JSONDecoder().decode(Draft.self, from: Data(reply[open...close].utf8))
    }

    /// The kind by majority, the first title, the lists joined without repeats.
    private static func merge(_ drafts: [Draft], into base: MomentInsight) -> MomentInsight {
        var out = base
        let kinds = drafts.compactMap { $0.kind.flatMap(MomentKind.init(rawValue:)) }.filter { $0 != .other }
        var tally: [MomentKind: Int] = [:]
        for k in kinds { tally[k, default: 0] += 1 }
        if let k = tally.max(by: { $0.value < $1.value })?.key { out.kind = k.rawValue }
        out.title = drafts.compactMap { $0.title?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        out.actions = unique(drafts.flatMap { $0.actions ?? [] }.map(unlabelled), cap: 10)
        out.promises = unique(drafts.flatMap { $0.promises ?? [] }.map(unlabelled), cap: 8)
        // The model's own dates when it found any; the date detector's only as a fallback.
        let upcoming = unique(drafts.flatMap { $0.upcoming ?? [] }, cap: 8)
        out.upcoming = upcoming.isEmpty ? base.upcoming : upcoming
        out.people = unique((drafts.flatMap { $0.people ?? [] } + base.people).filter { !isLabel($0) }, cap: 10)
        out.source = "model"
        return out
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
        out.people = Array((r.meta.speakerNames ?? [:]).values.sorted())
        if let text = r.meta.transcript {
            out.upcoming = Planner.dates(in: text, after: r.startedAt ?? Date())
                .map { "\($0.text) · \($0.date.formatted(date: .abbreviated, time: .shortened))" }
        }
        out.source = "switch"
        return out
    }
}

// MARK: - Reminders and Calendar

/// Reminders and Calendar, touched only when the user taps Add.
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
            guard let d = m.date, d > after else { continue }
            let from = max(0, m.range.location - 36)
            let range = NSRange(location: from, length: min(ns.length - from, m.range.length + (m.range.location - from)))
            let words = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(Found(text: (from > 0 ? "…" : "") + words, date: d))
            if out.count == 6 { break }
        }
        return out
    }

    /// The first date in a short line like "Demo, Thursday 10am".
    static func date(in line: String) -> Date? {
        guard let detector else { return nil }
        return detector.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length))
            .compactMap(\.date).first
    }

    static func addReminder(_ title: String, note: String) async throws {
        guard try await store.requestFullAccessToReminders() else { throw PlannerError.denied("Reminders") }
        let item = EKReminder(eventStore: store)
        item.title = title
        item.notes = note
        item.calendar = store.defaultCalendarForNewReminders()
        try store.save(item, commit: true)
    }

    static func addEvent(_ title: String, at date: Date, note: String) async throws {
        guard try await store.requestFullAccessToEvents() else { throw PlannerError.denied("Calendar") }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = date
        event.endDate = date.addingTimeInterval(3600)
        event.notes = note
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent, commit: true)
    }
}

enum PlannerError: LocalizedError {
    case denied(String)

    var errorDescription: String? {
        switch self {
        case .denied(let app): "Allow \(app) access for Private Pocket in iOS Settings."
        }
    }
}
