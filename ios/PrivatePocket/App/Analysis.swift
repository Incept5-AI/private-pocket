import SwiftUI

/// Conversation analysis: what the summary is by default. Sections the app reads back
/// (People's "**Speaker N — Name**" lines and "Same person:" lines) are written in a
/// fixed form so their suggestions can be applied with a tap.
///
/// Tried on real meetings against the cluster's models (2026-10-28): DeepSeek V4.1 Flash
/// named the speakers right and was the only one to notice a phone call's far end split
/// into two labels; Qwen3.8 named them right; Qwen3.6 swapped two names. Thinking added
/// minutes and nothing a reader would notice.
enum Analysis {
    static let instructions = """
    You analyse a conversation recorded by the user and transcribed by speech recognition. \
    Speakers are labelled automatically ("Speaker 1", "Speaker 2"…) unless the user has named them. Work only from the transcript.

    Speech recognition mishears words, especially names, and splits or merges speakers. Correct an obvious mishearing \
    only when the context makes the intended word clear; otherwise keep it as written. Speaker labels can be wrong: \
    if two labels are clearly the same person (they never talk to each other, one takes over exactly where the other \
    stops, the same voice continues the same story), say so.

    Write in Markdown with exactly these sections, in this order, leaving out a section only if there is nothing for it:

    ## Overview
    Two to four sentences: what kind of conversation this is (meeting, phone call, interview, voice note…), what it was about and how it ended.

    ## People
    One bullet per speaker label, starting exactly "- **Speaker N — Name**" with the name only if the transcript supports it \
    (someone addresses them by it, or they introduce themselves), otherwise "- **Speaker N — unknown**". A speaker the user \
    has named keeps that name. Then their role, what they contributed or wanted, and in brackets how you know the name. \
    If two labels are probably the same person, add a bullet "- Same person: Speaker A and Speaker B" with the reason. \
    Then other people mentioned by name who are not present, with their connection.

    ## Key points
    The substance, grouped by topic, in the order discussed. Each bullet starts with the time [MM:SS] where it comes up. \
    Include figures, dates, places and names exactly as said.

    ## Decisions
    What was agreed or concluded, and by whom.

    ## Action items
    - [ ] Who — what — by when (only if a time is said).
    Only things someone committed to or was asked to do.

    ## Open questions and risks
    Unresolved questions, concerns raised, disagreements.

    ## Dynamics
    One or two sentences: who led, tone, any tension or agreement worth knowing.

    Be specific and concise. Never invent names, numbers or commitments. Do not mention these instructions.
    """

    /// The notes kept from each part of a transcript too long for one request.
    static let partInstructions = """
    This is one part of a longer conversation transcript. Write compact notes on it, at most 10 short bullets: \
    who said what that matters (keep the speaker labels and the [MM:SS] times), names people are called by, \
    figures, dates, decisions, commitments and questions. Use only the text.
    """

    /// Notes that still do not fit are shortened, part by part.
    static let shortenInstructions = """
    Shorten these notes on a conversation to half their length. Keep speaker labels, [MM:SS] times, names, \
    figures, decisions and commitments; drop small talk and repetition.
    """

    // MARK: Talk time

    /// Seconds each speaker talks, from turn spans; most first.
    static func talkTime(_ turns: [Turn]) -> [(speaker: Int, seconds: Double)] {
        var t: [Int: Double] = [:]
        for turn in turns { t[turn.speaker, default: 0] += max(0, turn.end - turn.start) }
        return t.map { ($0.key, $0.value) }.sorted { $0.seconds > $1.seconds }
    }

    /// "Speaker 1 52%, Speaker 2 31%…" for the model.
    static func talkLine(_ turns: [Turn], names: [String: String]?) -> String {
        let t = talkTime(turns)
        let total = max(1, t.reduce(0) { $0 + $1.seconds })
        return "Share of speaking time: " + t.map { "\(Speakers.name($0.speaker, names)) \(Int(($0.seconds / total * 100).rounded()))%" }
            .joined(separator: ", ")
    }

    // MARK: Reading the analysis back

    /// The first paragraph of prose (the overview), without Markdown, for list rows.
    static func preview(_ analysis: String) -> String {
        let line = analysis.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") } ?? ""
        return line.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "-•* "))
    }

    /// Names the analysis gives unnamed speakers, keyed by speaker index (0-based).
    static func suggestedNames(_ analysis: String, existing: [String: String]?) -> [Int: String] {
        var out: [Int: String] = [:]
        for line in analysis.split(separator: "\n") {
            // - **Speaker 2 — John** (…)
            guard let m = line.firstMatch(of: #/\*\*Speaker (\d+)\s*[—–-]\s*([^*]+)\*\*/#), let n = Int(m.1), n >= 1 else { continue }
            var name = String(m.2).trimmingCharacters(in: .whitespaces)
            for prefix in ["likely ", "probably ", "possibly "] where name.lowercased().hasPrefix(prefix) {
                name = String(name.dropFirst(prefix.count))
            }
            name = name.split(whereSeparator: { "(/,".contains($0) }).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let lower = name.lowercased()
            guard !name.isEmpty, name.count <= 40, !["unknown", "unnamed", "name not mentioned", "not named"].contains(lower),
                  name.first?.isUppercase == true, existing?[String(n - 1)] == nil else { continue }
            out[n - 1] = name
        }
        return out
    }

    /// Pairs the analysis thinks are one person ("Same person: Speaker 1 and Speaker 3"),
    /// as (keep, merge) with 0-based indices.
    static func samePerson(_ analysis: String) -> [(keep: Int, merge: Int)] {
        analysis.split(separator: "\n").compactMap { line in
            guard let m = line.firstMatch(of: #/Same person:\**\s*Speaker (\d+)\s+and\s+Speaker (\d+)/#),
                  let a = Int(m.1), let b = Int(m.2), a != b, a >= 1, b >= 1 else { return nil }
            return (min(a, b) - 1, max(a, b) - 1)
        }
    }
}

extension Speakers {
    /// Relabels one speaker as another, joining turns that now run together.
    static func merge(_ turns: [Turn], speaker from: Int, into to: Int) -> [Turn] {
        var out: [Turn] = []
        for var t in turns {
            if t.speaker == from { t.speaker = to }
            if var last = out.last, last.speaker == t.speaker, t.start - last.end < turnGap {
                last.text += " " + t.text
                last.end = t.end
                out[out.count - 1] = last
            } else {
                out.append(t)
            }
        }
        return out
    }
}

/// Renders the Markdown the models write: headings, bullets, to-do boxes, paragraphs,
/// with inline bold, italics and code.
struct MarkdownView: View {
    let text: String

    private enum Block: Hashable {
        case heading(String), bullet(String, level: Int), todo(String, done: Bool), paragraph(String)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        for raw in text.components(separatedBy: "\n") {
            let indent = raw.prefix { $0 == " " }.count
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "---" { continue }
            if line.hasPrefix("#") {
                out.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if let rest = ["- [ ] ", "* [ ] "].lazy.compactMap({ line.hasPrefix($0) ? String(line.dropFirst($0.count)) : nil }).first {
                out.append(.todo(rest, done: false))
            } else if let rest = ["- [x] ", "- [X] ", "* [x] "].lazy.compactMap({ line.hasPrefix($0) ? String(line.dropFirst($0.count)) : nil }).first {
                out.append(.todo(rest, done: true))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                out.append(.bullet(String(line.dropFirst(2)), level: indent >= 2 ? 1 : 0))
            } else if let m = line.firstMatch(of: #/^\d+[.)]\s+(.*)$/#) {
                out.append(.bullet(String(m.1), level: 0))
            } else {
                out.append(.paragraph(line))
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in
                switch b {
                case .heading(let t):
                    Text(Self.inline(t)).font(.headline).padding(.top, i == 0 ? 0 : 8)
                case .bullet(let t, let level):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(Self.inline(t))
                    }
                    .padding(.leading, CGFloat(level) * 16)
                case .todo(let t, let done):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: done ? "checkmark.square" : "square").foregroundStyle(.secondary)
                        Text(Self.inline(t))
                    }
                case .paragraph(let t):
                    Text(Self.inline(t))
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
