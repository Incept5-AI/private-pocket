import AVFoundation
import Foundation
import FoundationModels
import Speech

/// On-device speech-to-text with SpeechAnalyzer / SpeechTranscriber. The model
/// assets are downloaded once by the OS; audio never leaves the phone.
enum Transcriber {
    static func transcribe(_ url: URL, localeID: String) async throws -> TimedTranscript {
        if await Prefs.sttRemote { return try await RemoteSTT.transcribe(url, localeID: localeID) }
        let transcriber = try await prepare(localeID: localeID, reporting: [])
        let file = try AVAudioFile(forReading: url)
        async let collected = transcriber.results.reduce(into: TimedTranscript(text: "", words: [])) { acc, result in
            let piece = String(result.text.characters).trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { return }
            acc.text += acc.text.isEmpty ? piece : " " + piece
            acc.words += words(in: result.text)
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collected
    }

    /// Word times from a result's audio-time-range runs, offset by `offset` seconds.
    static func words(in text: AttributedString, offset: Double = 0) -> [TimedWord] {
        text.runs.compactMap { run in
            guard let r = run.audioTimeRange else { return nil }
            let w = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !w.isEmpty else { return nil }
            return TimedWord(word: w, start: r.start.seconds + offset, end: r.end.seconds + offset)
        }
    }

    /// A transcriber for `localeID` with its model reserved and installed.
    static func prepare(localeID: String, reporting: Set<SpeechTranscriber.ReportingOption>) async throws -> SpeechTranscriber {
        guard localeID != Languages.auto else { throw AIError.autoNeedsServer }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
            throw AIError.unsupportedLocale(localeID)
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: reporting,
                                            attributeOptions: [.audioTimeRange])
        try await reserve(locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        return transcriber
    }

    /// The OS keeps speech models for a limited number of languages per app. Free
    /// a slot (the language least likely to be wanted again) when they are all taken.
    private static func reserve(_ locale: Locale) async throws {
        let reserved = await AssetInventory.reservedLocales
        let tag = { (l: Locale) in l.identifier(.bcp47) }
        guard !reserved.contains(where: { tag($0) == tag(locale) }) else { return }
        if reserved.count >= AssetInventory.maximumReservedLocales {
            let keep = await MainActor.run { Set([Prefs.transcriptionLocale] + Prefs.favouriteLocales) }
            if let drop = reserved.first(where: { !keep.contains(tag($0)) }) ?? reserved.first {
                await AssetInventory.release(reservedLocale: drop)
            }
        }
        try await AssetInventory.reserve(locale: locale)
    }
}

/// Languages on-device transcription supports, named in the phone's language.
enum Languages {
    /// Let the server's Whisper detect the language (on-device cannot).
    static let auto = "auto"

    static func supported() async -> [String] {
        await SpeechTranscriber.supportedLocales
            .map { $0.identifier(.bcp47) }
            .sorted { name($0).localizedCompare(name($1)) == .orderedAscending }
    }

    static func name(_ id: String) -> String {
        id == auto ? "Detect automatically" : Locale.current.localizedString(forIdentifier: id) ?? id
    }
}

/// Summaries from the configured language model (see `LLM`). Long transcripts
/// are summarised in chunks and the chunk summaries are then summarised together,
/// so a long meeting does not overflow the model's context window.
enum Summariser {
    /// Why summaries and questions cannot run now, or nil if they can.
    @MainActor static var availability: String? { LLM.availability }

    static func summarise(_ transcript: String, instructions: String, localeID: String?) async throws -> String {
        let c = await LLM.config
        if let why = await LLM.availability { throw AIError.modelUnavailable(why) }
        var instructions = instructions
        // Answer in the language of the recording if the model speaks it.
        if let id = localeID, c.remote || SystemLanguageModel.default.supportsLocale(Locale(identifier: id)),
           let language = Locale(identifier: "en").localizedString(forLanguageCode: Locale(identifier: id).language.languageCode?.identifier ?? "") {
            instructions += "\nThe transcript is in \(language). Write the whole summary, including the headings, in \(language)."
        }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIError.emptyTranscript }

        let chunks = split(text, max: c.chunkChars)
        if chunks.count == 1 {
            return try await LLM.complete(c, instructions: instructions, prompt: "Transcript:\n\n\(text)")
        }
        var partials: [String] = []
        for (i, chunk) in chunks.enumerated() {
            partials.append(try await LLM.complete(c,
                instructions: "Summarise this part of a longer transcript in a few bullet points. Keep any action items, names and decisions. Use only what is in the text.",
                prompt: "Part \(i + 1) of \(chunks.count):\n\n\(chunk)"))
        }
        return try await LLM.complete(c, instructions: instructions,
                                      prompt: "These are notes on consecutive parts of one recording. Combine them into a single summary.\n\n" +
                                          partials.joined(separator: "\n\n"))
    }

    /// Splits on sentence boundaries where possible.
    static func split(_ text: String, max: Int) -> [String] {
        guard text.count > max else { return [text] }
        var chunks: [String] = []
        var current = ""
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            guard let s else { return }
            if current.count + s.count > max, !current.isEmpty { chunks.append(current); current = "" }
            current += s
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

/// Questions about transcripts ("who was mentioned?", "which restaurant?").
/// Everything that fits goes to the model in one prompt. More than that is read
/// part by part, keeping only what bears on the question, and the extracts are
/// then answered together (repeatedly, if even they do not fit).
enum Asker {
    struct Source {
        let label: String
        let text: String
    }

    static let instructions = """
    You answer questions about transcripts of the user's own recordings. Each transcript, \
    or set of notes taken from one, starts with its recording's name and date in square brackets. \
    Use only that text. If the answer is not in it, say so plainly. \
    When there are several recordings, say which recording (by name and date) each part of the answer comes from. \
    The transcripts come from speech recognition, so names may be misspelled: give them as written. \
    Be concise. Reply only in the language of the question, even if the transcripts are in another language.
    """

    static let extractInstructions = """
    You read one part of the transcripts of the user's recordings and pick out everything \
    that helps answer the user's question: names, places, numbers, quotes, each with the name \
    and date of the recording it comes from (given in square brackets). Use only the text. \
    Do not answer the question yet. If nothing in this part is relevant, reply with exactly NONE.
    """

    static func answer(_ question: String, sources: [Source], depth: Int = 0,
                       progress: @escaping @MainActor (Int, Int) -> Void) async throws -> String {
        let c = await LLM.config
        if let why = await LLM.availability { throw AIError.modelUnavailable(why) }
        guard !sources.isEmpty else { throw AIError.noTranscripts }

        var packs = pack(sources, max: c.chunkChars)
        if depth >= 3 { packs = [(String(packs.map(\.text).joined().prefix(c.chunkChars)), [])] }
        if packs.count == 1 {
            return try await LLM.complete(c, instructions: instructions,
                                          prompt: "\(packs[0].text)\nQuestion: \(question)")
        }
        var notes: [Source] = []
        for (i, p) in packs.enumerated() {
            await progress(i + 1, packs.count)
            let n = try await LLM.complete(c, instructions: extractInstructions,
                                           prompt: "\(p.text)\nQuestion: \(question)")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty, !n.uppercased().hasPrefix("NONE") {
                notes.append(Source(label: "Notes from: " + p.labels.joined(separator: "; "), text: n))
            }
        }
        guard !notes.isEmpty else { throw AIError.notFound }
        return try await answer(question, sources: notes, depth: depth + 1, progress: progress)
    }

    /// Labelled blocks, several short recordings to a block, long ones split.
    static func pack(_ sources: [Source], max: Int) -> [(text: String, labels: [String])] {
        var packs: [(text: String, labels: [String])] = []
        var current = ""
        var labels: [String] = []
        for s in sources {
            for (i, piece) in Summariser.split(s.text, max: max - 400).enumerated() {
                let block = "[\(s.label)\(i > 0 ? " (continued)" : "")]\n\(piece)\n\n"
                if current.count + block.count > max, !current.isEmpty {
                    packs.append((current, labels))
                    current = ""
                    labels = []
                }
                current += block
                if !labels.contains(s.label) { labels.append(s.label) }
            }
        }
        if !current.isEmpty { packs.append((current, labels)) }
        return packs
    }
}

enum AIError: LocalizedError {
    case unsupportedLocale(String), modelUnavailable(String), emptyTranscript, noTranscripts, notFound, autoNeedsServer

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let l): "On-device transcription does not support \(l). Change the language in Settings."
        case .modelUnavailable(let why): why
        case .emptyTranscript: "The transcript is empty."
        case .noTranscripts: "None of these recordings has a transcript yet. Transcribe them first."
        case .notFound: "Nothing in the transcripts answers that."
        case .autoNeedsServer: "On-device transcription cannot detect the language. Pick one, or use a server in Settings → Speech to text."
        }
    }
}
