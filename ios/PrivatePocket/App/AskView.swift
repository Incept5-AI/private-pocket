import SwiftUI

enum AskRange: String, CaseIterable, Identifiable {
    case today = "Today", week = "Last 7 days", month = "Last 30 days", all = "All time"
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
}

/// Ask questions about transcripts, answered by the on-device model. Used as a tab
/// (any recording, or all of them in a date range) and from a recording's page.
struct AskView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: Library
    /// Set when opened from a recording: the scope is fixed to it.
    var fixedRecording: String?

    @State private var scope = "all"
    @State private var range = AskRange.week
    @State private var question = ""
    @FocusState private var typing: Bool

    static let suggestions = [
        "Who was mentioned?",
        "Which places, restaurants or businesses were mentioned?",
        "What was decided, and what are the action items?",
        "Which dates, times and numbers came up?",
    ]

    private var scopeID: String { fixedRecording ?? scope }

    private var inScope: [Recording] {
        if scopeID != "all" { return library.recordings.filter { $0.id == scopeID } }
        return library.recordings.filter { range.contains($0.startedAt) }
    }

    private var transcribed: [Recording] { inScope.filter { $0.meta.transcript != nil } }
    private var untranscribed: [Recording] { inScope.filter { $0.meta.transcript == nil } }
    private var conversation: [QA] { model.conversations[scopeID] ?? [] }
    private var busy: Bool { conversation.last.map { $0.answer == nil && $0.error == nil } ?? false }

    var body: some View {
        List {
            if fixedRecording == nil {
                Section {
                    Picker("Ask about", selection: $scope) {
                        Text("All recordings").tag("all")
                        ForEach(library.recordings.filter { $0.meta.transcript != nil }) { r in
                            Text(r.sourceLabel).tag(r.id)
                        }
                    }
                    if scope == "all" {
                        Picker("From", selection: $range) {
                            ForEach(AskRange.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                }
            }
            Section {
                LabeledContent("Transcribed", value: "\(transcribed.count) of \(inScope.count)")
                if !untranscribed.isEmpty {
                    let pending = untranscribed.filter { model.working.contains($0.id) }.count
                    Button {
                        Task { await model.transcribeMissing(untranscribed) }
                    } label: {
                        if pending > 0 {
                            HStack { ProgressView(); Text("Transcribing…") }
                        } else {
                            Label("Transcribe the other \(untranscribed.count)", systemImage: "text.quote")
                        }
                    }
                    .disabled(pending > 0)
                }
            } footer: {
                Text(Summariser.availability
                     ?? "Answered from the transcripts only, by \(LLM.whereLabel) Long or many transcripts are read part by part, which takes longer.")
            }

            if conversation.isEmpty {
                Section("Try") {
                    ForEach(Self.suggestions, id: \.self) { s in
                        Button(s) { send(s) }
                            .disabled(transcribed.isEmpty || Summariser.availability != nil)
                    }
                }
            }

            ForEach(conversation) { qa in
                Section {
                    Text(qa.question).font(.headline)
                    if let a = qa.answer {
                        Text(a).textSelection(.enabled)
                    } else if let e = qa.error {
                        Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    } else {
                        HStack {
                            ProgressView()
                            Text(qa.progress ?? "Thinking…").foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    if qa.scopeCount > 1 { Text("Across \(qa.scopeCount) recordings") }
                }
                .contextMenu {
                    if let a = qa.answer { Button("Copy answer") { UIPasteboard.general.string = a } }
                }
            }

            if !conversation.isEmpty {
                Button("Clear", role: .destructive) { model.conversations[scopeID] = nil }
                    .disabled(busy)
            }
        }
            .scrollContentBackground(.hidden)
            .background(Brand.ground)
        .navigationTitle(fixedRecording == nil ? "Ask" : "Ask about this recording")
        .navigationBarTitleDisplayMode(fixedRecording == nil ? .large : .inline)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            HStack {
                TextField("Ask about your recordings", text: $question, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($typing)
                    .submitLabel(.send)
                    .onSubmit { send(question) }
                Button { send(question) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || busy
                          || transcribed.isEmpty || Summariser.availability != nil)
            }
            .padding(.horizontal).padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func send(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        question = ""
        typing = false
        let id = scopeID, rs = transcribed
        Task { await model.ask(q, scope: id, recordings: rs) }
    }
}

/// The Ask tab.
struct AskTab: View {
    var body: some View {
        NavigationStack { AskView() }
    }
}
