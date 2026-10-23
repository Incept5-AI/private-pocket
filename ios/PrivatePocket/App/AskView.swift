import SwiftUI

enum AskRange: String, CaseIterable, Identifiable {
    case today = "Today", week = "7 days", month = "30 days", all = "All time"
    var id: String { rawValue }

    func contains(_ date: Date?) -> Bool {
        guard let date else { return self == .all }
        switch self {
        case .today: return Calendar.current.isDateInToday(date)
        case .week: return date > Date().addingTimeInterval(-7 * 86_400)
        case .month: return date > Date().addingTimeInterval(-30 * 86_400)
        case .all: return true
        }
    }

    var phrase: String {
        switch self {
        case .today: "today"
        case .week: "the last 7 days"
        case .month: "the last 30 days"
        case .all: "every moment"
        }
    }
}

/// Ask across moments: a question at the top, the span and the people as chips
/// under it, and each answer as a card with the moments it was read from.
struct AskView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: Library
    @State private var range = AskRange.week
    @State private var person: String?
    @State private var question = ""
    @FocusState private var typing: Bool

    private static let thread = "ask"

    private var inRange: [Recording] { library.recordings.filter { range.contains($0.startedAt) } }
    private var inScope: [Recording] {
        guard let person else { return inRange }
        return inRange.filter { $0.people.contains { $0.caseInsensitiveCompare(person) == .orderedSame } }
    }
    private var transcribed: [Recording] { inScope.filter { $0.meta.transcript != nil } }
    private var pending: Int { inScope.filter { $0.meta.transcript == nil }.count }
    private var conversation: [QA] { model.conversations[Self.thread] ?? [] }
    private var busy: Bool { conversation.last.map { $0.answer == nil && $0.error == nil } ?? false }
    private var canAsk: Bool { !transcribed.isEmpty && Summariser.availability == nil && !busy }

    /// The people in the span, most often first.
    private var people: [String] {
        var counts: [String: Int] = [:]
        for r in inRange { for p in r.people { counts[p, default: 0] += 1 } }
        var top = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(6).map(\.key)
        // The chosen person stays after the span changes, so the choice can always be undone.
        if let person, !top.contains(person) { top.insert(person, at: 0) }
        return top
    }

    private var suggestions: [String] {
        var out = ["What's still open?"]
        if let p = person ?? people.first { out.append("What did \(p) agree to?") }
        out += ["What was decided?", "Which dates are coming up?", "Who owes me something?"]
        return Array(out.prefix(4))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    field
                    chips
                    status
                    ForEach(conversation.reversed()) { qa in
                        AnswerCard(qa: qa).padding(.top, 12)
                    }
                    if !conversation.isEmpty {
                        Button("Clear") { model.conversations[Self.thread] = nil }
                            .font(.footnote.weight(.semibold)).foregroundStyle(Brand.muted)
                            .disabled(busy)
                            .padding(.top, 16)
                    }
                }
                .padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 32)
            }
            .background(Brand.ground)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Ask the tape")
            .navigationDestination(for: String.self) { id in RecordingDetail(id: id) }
            .navigationDestination(for: MomentsFilter.self) { f in FilteredMoments(filter: f) }
            .navigationDestination(for: ThreadLink.self) { ThreadView(id: $0.id) }
        }
    }

    // MARK: The question

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Brand.muted)
            TextField("Ask about your days", text: $question, axis: .vertical)
                .lineLimit(1...3)
                .focused($typing)
                .submitLabel(.send)
                .onSubmit { send(question) }
            if !question.trimmingCharacters(in: .whitespaces).isEmpty {
                Button { send(question) } label: {
                    Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(Brand.onAct)
                        .frame(width: 30, height: 30).background(Brand.act, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canAsk)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(typing ? Brand.act.opacity(0.6) : Brand.hairline, lineWidth: 1))
        .animation(.easeInOut(duration: 0.2), value: typing)
        .padding(.top, 8)
    }

    // MARK: Span, people, and things to try

    private var chips: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AskRange.allCases) { r in
                        chip(r.rawValue, selected: range == r) { withAnimation(.easeInOut(duration: 0.2)) { range = r } }
                    }
                    ForEach(people, id: \.self) { p in
                        chip("With \(p)", selected: person == p) { withAnimation(.easeInOut(duration: 0.2)) { person = person == p ? nil : p } }
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions, id: \.self) { s in
                        Button { send(s) } label: {
                            Text(s).font(.footnote.weight(.medium))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .foregroundStyle(canAsk ? Brand.act : Brand.dim)
                                .background(Brand.surface, in: Capsule())
                                .overlay(Capsule().stroke(Brand.hairline, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canAsk)
                    }
                }
            }
        }
        .padding(.top, 12)
    }

    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.footnote.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(selected ? Brand.act : Brand.raised, in: Capsule())
                .foregroundStyle(selected ? Brand.onAct : Brand.textSecondary)
        }
        .buttonStyle(.plain)
    }

    private var status: some View {
        let scope = (person.map { "with \($0) " } ?? "") + (range == .all ? "across every moment" : "in \(range.phrase)")
        let text: String
        if let why = Summariser.availability {
            text = why
        } else if transcribed.isEmpty {
            text = pending > 0 ? "\(pending) \(pending == 1 ? "moment is" : "moments are") still being transcribed \(scope)." : "Nothing recorded \(scope) yet."
        } else {
            text = "Answered from \(transcribed.count) \(transcribed.count == 1 ? "moment" : "moments") \(scope), \(Prefs.llmRemoteNow ? "on your server" : "on this iPhone")."
                + (pending > 0 ? " \(pending) more still being transcribed." : "")
        }
        return Text(text).font(.caption).foregroundStyle(Brand.dim).padding(.top, 10)
    }

    private func send(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, canAsk else { return }
        question = ""
        typing = false
        let rs = transcribed
        Task { await model.ask(q, scope: Self.thread, recordings: rs) }
    }
}

/// One question and its answer, with the moments it was read from.
struct AnswerCard: View {
    @EnvironmentObject var library: Library
    let qa: QA

    private var sources: [Recording] {
        qa.sources.compactMap { id in library.recordings.first { $0.id == id } }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(qa.question).font(.subheadline.weight(.semibold)).foregroundStyle(Brand.muted)
            if let a = qa.answer {
                Text(a.answerText).font(.title3.weight(.medium)).lineSpacing(4).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !sources.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(sources.prefix(3)) { r in
                            NavigationLink(value: r.id) { sourceRow(r) }.buttonStyle(.plain)
                        }
                        if sources.count > 3 {
                            NavigationLink(value: MomentsFilter(title: qa.question, ids: sources.map(\.id))) {
                                Text("and \(sources.count - 3) more").font(.footnote.weight(.semibold)).foregroundStyle(Brand.act)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4).padding(.top, 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 2)
                }
                Text("Answered \(Prefs.llmRemoteNow ? "on your server" : "on this iPhone") from \(qa.scopeCount) \(qa.scopeCount == 1 ? "moment" : "moments").")
                    .font(.caption).foregroundStyle(Brand.dim)
            } else if let e = qa.error {
                Text(e).font(.subheadline).foregroundStyle(Brand.muted)
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(qa.progress ?? "Reading…").font(.subheadline).foregroundStyle(Brand.muted)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contextMenu {
            if let a = qa.answer { Button("Copy answer") { UIPasteboard.general.string = a } }
        }
    }

    private func sourceRow(_ r: Recording) -> some View {
        HStack(spacing: 10) {
            Image(systemName: r.kind.symbol).font(.caption.weight(.semibold)).foregroundStyle(r.kind.colour)
                .frame(width: 28, height: 28).background(Brand.raised, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(r.displayTitle).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(r.startedAt?.formatted(date: .abbreviated, time: .shortened) ?? r.day).font(.caption).foregroundStyle(Brand.muted)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Brand.dim)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Brand.raised.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }
}

extension String {
    /// A model's answer as it was written: bold, italics and links shown as such, line breaks
    /// and list dashes kept; plain text if it is not markdown at all. Models answer in markdown
    /// more often than not, and the asterisks used to show.
    var answerText: AttributedString {
        (try? AttributedString(markdown: self, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(self)
    }
}
