import SwiftUI

/// One recording: the player, then the analysis, the speaker-labelled transcript (tap a
/// time to hear it) and the details, a tab each.
struct RecordingDetail: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: Library
    @EnvironmentObject var devices: DeviceStore
    let id: String
    @StateObject private var player = Player()
    @State private var title = ""
    @State var language = Prefs.transcriptionLocale
    @State private var renaming: Int?
    @State private var newName = ""
    @AppStorage("recordingTab") private var tab = Pane.analysis

    enum Pane: String, CaseIterable, Identifiable {
        case analysis = "Analysis", transcript = "Transcript", details = "Details"
        var id: String { rawValue }
    }

    private var recording: Recording? { library.recordings.first { $0.id == id } }

    var body: some View {
        if let r = recording {
            List {
                Section {
                    PlayerControls(player: player, url: r.audioURL)
                    Picker("Show", selection: $tab) {
                        ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                }
                if model.working.contains(r.id) {
                    Section {
                        HStack {
                            ProgressView()
                            Text(model.progress[r.id] ?? "Working…").foregroundStyle(.secondary)
                        }
                    }
                }
                switch tab {
                case .analysis: analysis(r)
                case .transcript: transcript(r)
                case .details: details(r)
                }
            }
            .navigationTitle(r.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ShareLink(item: r.audioURL) { Label("Audio", systemImage: "waveform") }
                        if let t = r.transcriptForModel { ShareLink(item: t) { Label("Transcript", systemImage: "text.quote") } }
                        if let s = r.meta.summary { ShareLink(item: s) { Label("Analysis", systemImage: "sparkles") } }
                        if let both = shareBoth(r) { ShareLink(item: both) { Label("Analysis and transcript", systemImage: "doc.text") } }
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .alert("Name this speaker", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField(renaming.map { "Speaker \($0 + 1)" } ?? "", text: $newName)
                Button("Save") { if let s = renaming { model.renameSpeaker(r, speaker: s, to: newName) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Used in the transcript, the analysis and answers. Give two speakers the same name to treat them as one.")
            }
            .onAppear {
                title = r.meta.title ?? ""
                language = r.meta.locale ?? Prefs.transcriptionLocale
            }
            .onDisappear {
                player.stop()
                if title != (r.meta.title ?? "") { model.rename(r, to: title) }
            }
        } else {
            ContentUnavailableView("Recording deleted", systemImage: "trash")
        }
    }

    private func rename(_ r: Recording, _ speaker: Int) {
        newName = r.meta.speakerNames?[String(speaker)] ?? ""
        renaming = speaker
    }

    private func shareBoth(_ r: Recording) -> String? {
        guard let s = r.meta.summary, let t = r.transcriptForModel else { return nil }
        return "\(r.sourceLabel)\n\n\(s)\n\n## Transcript\n\n\(t)"
    }

    // MARK: Analysis

    @ViewBuilder private func analysis(_ r: Recording) -> some View {
        if let turns = r.meta.turns, Speakers.count(turns) > 1 {
            Section {
                SpeakerBar(turns: turns, names: r.meta.speakerNames) { rename(r, $0) }
            } header: { Text("Who spoke") } footer: { Text("Tap a speaker to name them.") }
            suggestions(r, turns: turns)
        }
        Section {
            if let s = r.meta.summary {
                MarkdownView(text: s)
            } else if r.meta.transcript == nil {
                Text("Transcribe the recording first, on the Transcript tab.").foregroundStyle(.secondary)
            }
            Button {
                Task { await model.summarise(r) }
            } label: {
                Label(r.meta.summary == nil ? "Analyse" : "Analyse again", systemImage: "sparkles")
            }
            .disabled(r.meta.transcript == nil || model.working.contains(r.id) || Summariser.availability != nil)
        } header: { Text("Analysis") } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let at = r.meta.summarisedAt {
                    let by = r.meta.summaryModel.map { $0 == "on-device" ? " by Apple's on-device model" : " by \($0)" } ?? ""
                    Text("Made\(by), \(at.formatted(date: .abbreviated, time: .shortened)).")
                }
                Text(Summariser.availability ?? "Uses \(LLM.whereLabel)")
            }
        }
        Section {
            NavigationLink {
                AskView(fixedRecording: r.id)
            } label: {
                Label("Ask about this recording", systemImage: "questionmark.bubble")
            }
            .disabled(r.meta.transcript == nil)
        } footer: {
            Text("For example: what did Daniel want, or which restaurant was it?")
        }
    }

    /// Names and merges the analysis proposes, offered once each.
    @ViewBuilder private func suggestions(_ r: Recording, turns: [Turn]) -> some View {
        let s = r.meta.summary ?? ""
        let present = Set(turns.map(\.speaker))
        let names = Analysis.suggestedNames(s, existing: r.meta.speakerNames).filter { present.contains($0.key) }
        // Apple's on-device model proposes merges that are not there; only a server model's are offered.
        let merges = r.meta.summaryModel == "on-device" ? []
            : Analysis.samePerson(s).filter { present.contains($0.keep) && present.contains($0.merge) }
        if !names.isEmpty || !merges.isEmpty {
            Section {
                if !names.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(names.sorted { $0.key < $1.key }, id: \.key) { k, v in
                            Text("Speaker \(k + 1) → **\(v)**")
                        }
                    }
                    Button { model.applySuggestedNames(r, names) } label: { Label("Use these names", systemImage: "person.text.rectangle") }
                }
                ForEach(merges, id: \.merge) { m in
                    Button {
                        model.mergeSpeakers(r, speaker: m.merge, into: m.keep)
                    } label: {
                        Label("Merge \(Speakers.name(m.merge, r.meta.speakerNames)) into \(Speakers.name(m.keep, r.meta.speakerNames))",
                              systemImage: "arrow.triangle.merge")
                    }
                }
            } header: { Text("Suggested by the analysis") } footer: {
                Text("From what was said. Check before using: speech recognition mishears names.")
            }
        }
    }

    // MARK: Transcript

    @ViewBuilder private func transcript(_ r: Recording) -> some View {
        Section {
            if let turns = r.meta.turns, Speakers.count(turns) > 1 {
                ForEach(turns) { t in
                    TranscriptTurn(turn: t, names: r.meta.speakerNames,
                                   onRename: { rename(r, $0) }, onPlay: { player.play(from: t.start) })
                }
            } else if let t = r.meta.transcript {
                Text(t).textSelection(.enabled)
            } else {
                Text("No transcript yet.").foregroundStyle(.secondary)
            }
        } footer: {
            if let turns = r.meta.turns, Speakers.count(turns) > 1 { Text("Tap a time to listen from there, a name to rename.") }
        }
        Section {
            Picker("Language", selection: $language) {
                ForEach(languageChoices(r), id: \.self) { Text(Languages.name($0)).tag($0) }
            }
            Button {
                Task { await model.transcribe(r, localeID: language) }
            } label: {
                Label(r.meta.transcript == nil ? "Transcribe in \(Languages.name(language))"
                                               : "Transcribe again in \(Languages.name(language))",
                      systemImage: "text.quote")
            }
            .disabled(model.working.contains(r.id))
            if r.meta.words != nil, Prefs.diarize {
                Button {
                    Task { await model.findSpeakers(r) }
                } label: {
                    Label(r.meta.turns == nil ? "Find speakers" : "Find speakers again", systemImage: "person.2")
                }
                .disabled(model.working.contains(r.id))
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if r.meta.liveTranscript == true {
                    Text("Made live while recording. Transcribe again for the most accurate version.")
                }
                if let e = r.meta.speakersError { Text("Speakers: \(e)") }
                Text(Self.engineNote)
            }
        }
    }

    static var engineNote: String {
        let words = Prefs.sttRemote
            ? "Words: \(Prefs.sttModel) on \(URL(string: Prefs.sttURL)?.host() ?? "the server"), in short pieces; the audio is uploaded to it."
            : Prefs.localEngine == .parakeet ? "Words: Parakeet on this iPhone; the audio does not leave it."
                                              : "Words: Apple's speech recognition on this iPhone; the audio does not leave it."
        let who = !Prefs.diarize ? "" : Prefs.diarizeOnDevice ? " Speakers: found on this iPhone." : " Speakers: found by the diarisation server."
        return words + who
    }

    // MARK: Details

    @ViewBuilder private func details(_ r: Recording) -> some View {
        Section("Details") {
            TextField(r.meta.place?.name ?? r.startedAt?.formatted(date: .omitted, time: .shortened) ?? "Title", text: $title)
                .onSubmit { model.rename(r, to: title) }
                .submitLabel(.done)
            if let t = r.startedAt {
                LabeledContent("Recorded", value: t.formatted(date: .abbreviated, time: .shortened))
            }
            if let s = r.meta.seconds {
                LabeledContent("Length", value: Duration.seconds(s).formatted(.time(pattern: .hourMinuteSecond)))
            }
            LabeledContent("Pocket", value: r.pocketName(devices.devices))
            if r.isCall { LabeledContent("Mode", value: "Phone call") }
            if r.meta.partial == true {
                Text("Only part of this recording was saved. A sync replaces it with the Pocket's copy if that holds more.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let place = r.meta.place {
                Link(destination: place.mapsURL) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(place.label, systemImage: "mappin.and.ellipse")
                        Text(place.approximate ? "Approximate: where the phone was when it downloaded" : place.coordinateText)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Remove location", role: .destructive) { model.clearPlace(r) }
            }
            Button {
                Task { await model.tagHere(r) }
            } label: {
                Label(r.meta.place == nil ? "Tag with current location" : "Replace with current location", systemImage: "location")
            }
        }
        Section("File") {
            LabeledContent("Device file", value: "\(r.day)/\(r.name).mp3")
            if let p = r.meta.pocket {
                LabeledContent("Pocket ID", value: p.advertised)
                if let mac = p.mac { LabeledContent("Pocket MAC", value: mac) }
            }
            LabeledContent("Size", value: r.size.formatted(.byteCount(style: .file)))
        }
    }
}

/// Each speaker's share of the talking, as one bar and a legend.
struct SpeakerBar: View {
    let turns: [Turn]
    let names: [String: String]?
    var onTap: (Int) -> Void

    var body: some View {
        let shares = Analysis.talkTime(turns)
        let total = max(1, shares.reduce(0) { $0 + $1.seconds })
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(shares, id: \.speaker) { s in
                        TurnRow.colours[s.speaker % TurnRow.colours.count]
                            .frame(width: max(2, (g.size.width - CGFloat(shares.count * 2)) * s.seconds / total))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
            ForEach(shares, id: \.speaker) { s in
                Button { onTap(s.speaker) } label: {
                    HStack {
                        Circle().fill(TurnRow.colours[s.speaker % TurnRow.colours.count]).frame(width: 10, height: 10)
                        Text(Speakers.name(s.speaker, names))
                        Spacer()
                        Text("\(Int((s.seconds / total * 100).rounded()))%  ·  \(Duration.seconds(Int(s.seconds)).formatted(.time(pattern: .minuteSecond)))")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A turn in the transcript: the speaker in their colour, the time as a play button.
struct TranscriptTurn: View {
    let turn: Turn
    let names: [String: String]?
    var onRename: (Int) -> Void
    var onPlay: () -> Void

    var body: some View {
        let colour = TurnRow.colours[turn.speaker % TurnRow.colours.count]
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(colour).frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Button { onRename(turn.speaker) } label: {
                        Text(Speakers.name(turn.speaker, names)).font(.subheadline.weight(.semibold)).foregroundStyle(colour)
                    }
                    .buttonStyle(.borderless)
                    Button(action: onPlay) {
                        Label(Speakers.stamp(turn.start), systemImage: "play.fill")
                            .font(.caption.monospacedDigit())
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                Text(turn.text).textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}
