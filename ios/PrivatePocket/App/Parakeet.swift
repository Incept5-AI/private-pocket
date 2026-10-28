import AVFoundation
import FluidAudio
import Foundation

/// On-device speech to text with NVIDIA's Parakeet TDT v3 (25 European languages) and
/// speaker diarisation (pyannote segmentation, WeSpeaker embeddings, VBx clustering),
/// both on the Neural Engine through FluidAudio. The models are downloaded once from
/// Hugging Face (about 470 MB and 20 MB); audio never leaves the phone.
///
/// Measured on the Pocket's own MP3s against phone recordings of the same meetings:
/// Parakeet matches Whisper large-v3 on the server and is clearly better than Apple's
/// SpeechTranscriber on overlapping meeting speech, and it cannot fall into Whisper's
/// repetition loops. The diarizer split a phone call into its two speakers where the
/// server's split the far end in two.
actor OnDeviceSpeech {
    static let shared = OnDeviceSpeech()

    private var asr: AsrManager?
    private var diarizer: OfflineDiarizerManager?

    /// Languages Parakeet v3 transcribes (it detects which by itself).
    static let languages: Set<String> = Set(Language.allCases.map(\.rawValue)).union(["en"])

    static func supports(_ localeID: String) -> Bool {
        localeID == Languages.auto || languages.contains(Locale(identifier: localeID).language.languageCode?.identifier ?? "")
    }

    func transcribe(_ url: URL, localeID: String, status: @escaping @Sendable (String) -> Void) async throws -> TimedTranscript {
        guard Self.supports(localeID) else { throw AIError.unsupportedLocale(localeID) }
        let asr = try await loadASR(status)
        status("Transcribing on this iPhone…")
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let code = Locale(identifier: localeID).language.languageCode?.identifier
        let result = try await asr.transcribe(url, decoderState: &state, language: code.flatMap(Language.init(rawValue:)))
        let words = Self.words(result.tokenTimings ?? [])
        return TimedTranscript(text: result.text.trimmingCharacters(in: .whitespacesAndNewlines), words: words)
    }

    /// One phrase (16 kHz mono), e.g. from the Translate tab.
    func transcribe(samples: [Float], localeID: String, status: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        let asr = try await loadASR(status)
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let code = Locale(identifier: localeID).language.languageCode?.identifier
        // Parakeet wants at least a second; pad a shorter phrase with silence.
        let padded = samples.count >= 16_000 ? samples : samples + [Float](repeating: 0, count: 16_000 - samples.count)
        return try await asr.transcribe(padded, decoderState: &state, language: code.flatMap(Language.init(rawValue:)))
            .text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Downloads and loads the speech model now (before going offline).
    func prepare(status: @escaping @Sendable (String) -> Void) async throws {
        _ = try await loadASR(status)
    }

    /// Who spoke when. Speaker ids are local to this recording, as with the server.
    func diarize(_ url: URL, status: @escaping @Sendable (String) -> Void) async throws -> [SpeakerSegment] {
        let d = try await loadDiarizer(status)
        status("Finding speakers on this iPhone…")
        let source = try AudioSourceFactory().makeDiskBackedSource(from: url, targetSampleRate: 16_000)
        defer { source.source.cleanup() }
        let result = try await d.process(audioSource: source.source, audioLoadingSeconds: source.loadDuration) { _, _ in }
        var ids: [String: Int] = [:]
        return result.segments
            .sorted { $0.startTimeSeconds < $1.startTimeSeconds }
            .map { s in
                let n = ids[s.speakerId] ?? ids.count
                ids[s.speakerId] = n
                return SpeakerSegment(start: Double(s.startTimeSeconds), end: Double(s.endTimeSeconds), speaker: n)
            }
    }

    private func loadASR(_ status: @Sendable (String) -> Void) async throws -> AsrManager {
        if let asr { return asr }
        status("Getting the speech model ready (a 470 MB download the first time)…")
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let m = AsrManager(config: .default)
        try await m.loadModels(models)
        asr = m
        return m
    }

    private func loadDiarizer(_ status: @Sendable (String) -> Void) async throws -> OfflineDiarizerManager {
        if let diarizer { return diarizer }
        status("Getting the speaker model ready (a 20 MB download the first time)…")
        let m = OfflineDiarizerManager(config: .default)
        try await m.prepareModels()
        diarizer = m
        return m
    }

    /// Tokens that start with a space start a word; the rest join the one before.
    static func words(_ tokens: [TokenTiming]) -> [TimedWord] {
        var out: [TimedWord] = []
        for t in tokens {
            let piece = t.token.replacingOccurrences(of: "▁", with: " ")
            let w = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !w.isEmpty else { continue }
            if piece.hasPrefix(" ") || out.isEmpty {
                out.append(TimedWord(word: w, start: t.startTime, end: t.endTime))
            } else {
                out[out.count - 1].word += w
                out[out.count - 1].end = t.endTime
            }
        }
        return out
    }
}
