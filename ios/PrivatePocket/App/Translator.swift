import AVFoundation
import Foundation
import Speech

/// Near-live interpreting, one utterance at a time, from the iPhone's microphone or from
/// the Pocket's live stream (which records the conversation too).
///
/// - **On this iPhone:** Apple's speech recognition (SpeechTranscriber, or
///   DictationTranscriber for languages it lacks, such as Dutch) as you speak, then Apple
///   Translation (`TranslateView` owns its session). Works offline once the languages
///   are downloaded.
/// - **Server:** an utterance is cut at the pause after it, sent to Whisper with the
///   source language, then translated by the language model with the last few lines as
///   context. About a second after each pause, and better at idiom ("Enkele reis
///   alstublieft": "One-way, please", where Apple's offered "Please provide some travel
///   information").
@MainActor
final class LiveTranslator: ObservableObject {
    struct Line: Identifiable, Hashable {
        let id = UUID()
        var time = Date()
        var original: String
        var translation: String?
        var failed: String?
    }

    enum Input: String, CaseIterable, Identifiable {
        case mic, pocket
        var id: String { rawValue }
        var label: String { self == .mic ? "iPhone mic" : "Pocket" }
    }

    enum Mode: String, CaseIterable, Identifiable {
        case device, server
        var id: String { rawValue }
        var label: String { self == .device ? "On this iPhone" : "Server" }
    }

    @Published var lines: [Line] = []
    @Published var partial = ""
    @Published var listening = false
    @Published var level: Float = 0
    @Published var status: String?
    @Published var error: String?

    var source = "nl"
    var target = "en"
    var mode = Mode.device
    var audioIn = Input.mic
    var speak = false

    /// Apple Translation: `TranslateView` reads these and writes the results back.
    let appleQueue: AsyncStream<(UUID, String)>
    private let appleSend: AsyncStream<(UUID, String)>.Continuation

    private let engine = AVAudioEngine()
    private let tap = MicTap()
    private let voice = AVSpeechSynthesizer()
    private var voiceDelegate: VoiceDelegate?
    private var speaking = false

    // The Pocket as microphone
    private weak var model: AppModel?
    private var packetizer: MP3Packetizer?
    private let mp3 = MP3Decoder()
    private var startedRecording = false
    private var micTapped = false

    // Server mode
    private var utterance: [Float] = []
    private var inSpeech = false
    private var quietFrames = 0
    private var floorDB: Float = -50
    private var serverQueue: [(UUID, [Float])] = []
    private var serverBusy = false

    // Device mode
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?

    init() {
        (appleQueue, appleSend) = AsyncStream.makeStream(of: (UUID, String).self)
    }

    static let languages = ["nl", "en", "fr", "de", "es", "it", "pt", "da", "sv", "pl", "cs", "tr", "ja", "zh", "ko", "ar"]

    static func name(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    // MARK: Start and stop

    func start(model: AppModel) async {
        guard !listening else { return }
        error = nil
        do {
            let session = AVAudioSession.sharedInstance()
            if audioIn == .pocket {
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
                if mode == .device { try await startDevice() }
                try await startPocket(model)
                return
            }
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            guard await AVAudioApplication.requestRecordPermission() else {
                error = "Allow the microphone in iOS Settings → Private Pocket."
                return
            }
            if mode == .device { try await startDevice() }
            let inFormat = engine.inputNode.outputFormat(forBus: 0)
            tap.prepare(from: inFormat, analyzer: mode == .device ? analyzerFormat : nil)
            tap.onSamples = { [weak self] samples, db, analyzerBuffer in
                Task { @MainActor in self?.received(samples, db: db, analyzerBuffer: analyzerBuffer) }
            }
            engine.inputNode.removeTap(onBus: 0)
            engine.inputNode.installTap(onBus: 0, bufferSize: 4_096, format: inFormat) { [tap] buf, _ in tap.process(buf) }
            micTapped = true
            engine.prepare()
            try engine.start()
            listening = true
            status = mode == .device ? "Listening on this iPhone" : "Listening; each phrase is sent after a pause"
        } catch {
            self.error = error.localizedDescription
            stop()
        }
    }

    func stop() {
        if audioIn == .pocket || packetizer != nil {
            model?.liveListener = nil
            packetizer = nil
            if startedRecording, let model, model.pocketRecording { Task { await model.toggleRecording() } }
            startedRecording = false
        }
        if micTapped {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            micTapped = false
        }
        listening = false
        level = 0
        status = nil
        if mode == .server, inSpeech { endUtterance() }
        input?.finish()
        input = nil
        let a = analyzer
        analyzer = nil
        Task { try? await a?.finalizeAndFinishThroughEndOfInput() }
        if !partial.isEmpty { commit(partial) }
        partial = ""
        voice.stopSpeaking(at: .immediate)
    }

    func clear() {
        lines = []
        partial = ""
    }

    /// The conversation as text, for sharing.
    var transcript: String {
        lines.map { l in
            "[\(l.time.formatted(date: .omitted, time: .shortened))] \(l.original)\n→ \(l.translation ?? l.failed ?? "…")"
        }.joined(separator: "\n\n")
    }

    // MARK: Audio in

    /// Listens to the Pocket's live MP3 (16 kHz mono), starting a recording if none is running.
    private func startPocket(_ model: AppModel) async throws {
        guard model.pocketCanStream else { throw TranslateError.noPocket }
        self.model = model
        let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        tap.prepare(from: pcm, analyzer: mode == .device ? analyzerFormat : nil)
        tap.onSamples = { [weak self] samples, db, analyzerBuffer in
            Task { @MainActor in self?.received(samples, db: db, analyzerBuffer: analyzerBuffer) }
        }
        let p = MP3Packetizer()
        p.onPackets = { [mp3, tap] data, descs, fmt in
            if let b = mp3.decode(data, packets: descs, format: fmt) { tap.process(b) }
        }
        packetizer = p
        model.liveListener = { [weak p] data in p?.parse(data) }
        listening = true
        if !model.pocketRecording {
            status = "Starting a recording on the Pocket…"
            await model.toggleRecording()
            guard model.pocketRecording else {
                stop()
                throw TranslateError.noPocket
            }
            startedRecording = true
        }
        status = "Listening through the Pocket; the conversation is also recorded"
    }

    private var analyzerFormat: AVAudioFormat?

    private func received(_ samples: [Float], db: Float, analyzerBuffer: AVAudioPCMBuffer?) {
        level = max(0, min(1, (db + 60) / 50))
        guard listening, !speaking else { return }
        switch mode {
        case .device:
            if let b = analyzerBuffer { input?.yield(AnalyzerInput(buffer: b)) }
        case .server:
            segment(samples, db: db)
        }
    }

    /// Server mode: a phrase starts 12 dB above the room's quiet level and ends after
    /// 0.7 s back near it, or at 12 s.
    private func segment(_ samples: [Float], db: Float) {
        let frameSeconds = Double(samples.count) / 16_000
        // The room's quiet level: falls at once to anything quieter, creeps back up slowly.
        if db < floorDB { floorDB = db } else if !inSpeech { floorDB = min(-20, floorDB + 0.02) }
        floorDB = max(-80, floorDB)
        if !inSpeech, db > floorDB + 12 {
            inSpeech = true
            quietFrames = 0
            // Keep a little audio from before the start, so the first word is whole.
            utterance = Array(utterance.suffix(4_800))
        }
        utterance += samples
        if !inSpeech {
            if utterance.count > 4_800 { utterance.removeFirst(utterance.count - 4_800) }
            return
        }
        quietFrames = db < floorDB + 6 ? quietFrames + 1 : 0
        let quiet = Double(quietFrames) * frameSeconds
        if quiet >= 0.7 || Double(utterance.count) / 16_000 >= 12 { endUtterance() }
    }

    private func endUtterance() {
        inSpeech = false
        quietFrames = 0
        let audio = utterance
        utterance = []
        guard Double(audio.count) / 16_000 >= 0.6 else { return }
        let line = Line(original: "…")
        lines.append(line)
        serverQueue.append((line.id, audio))
        if !serverBusy { Task { await drainServer() } }
    }

    private func drainServer() async {
        serverBusy = true
        defer { serverBusy = false }
        while !serverQueue.isEmpty {
            let (id, audio) = serverQueue.removeFirst()
            do {
                let wav = ChunkedSTT.wav(audio[...])
                let r = try await RemoteSTT.request(wav, filename: "phrase.wav", type: "audio/wav", localeID: source, timeout: 30)
                let words = Cleanup.words(r.transcript.words)
                let text = (words.isEmpty ? r.transcript.text : words.map(\.word).joined(separator: " "))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !Cleanup.isNoise(text) else { lines.removeAll { $0.id == id }; continue }
                update(id) { $0.original = text }
                let translated = try await translateWithModel(text, before: id)
                update(id) { $0.translation = translated }
                say(translated)
            } catch {
                update(id) { $0.failed = error.localizedDescription }
            }
        }
    }

    private func translateWithModel(_ text: String, before id: UUID) async throws -> String {
        let earlier = lines.prefix { $0.id != id }.suffix(3)
            .compactMap { l in l.translation.map { "\(l.original) → \($0)" } }
            .joined(separator: "\n")
        let instructions = """
        You are a live interpreter. Translate what was said from \(Self.englishName(source)) into natural \(Self.englishName(target)). \
        It comes from speech recognition, one phrase at a time: fix obvious mishearings from context, keep names and numbers. \
        Earlier lines are only context. Reply with the translation of the new phrase only.
        """
        let prompt = (earlier.isEmpty ? "" : "Earlier:\n\(earlier)\n\n") + "New phrase:\n\(text)"
        return try await LLM.complete(LLM.config, instructions: instructions, prompt: prompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func englishName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    // MARK: On this iPhone

    private func startDevice() async throws {
        let locale = Locale(identifier: source)
        let module: any SpeechModule
        if let l = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let t = SpeechTranscriber(locale: l, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
            module = t
            results = Task { [weak self] in
                do { for try await r in t.results { self?.result(String(r.text.characters), final: r.isFinal) } } catch {}
            }
            try await Transcriber.reserve(l)
        } else if let l = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let t = DictationTranscriber(locale: l, contentHints: [], transcriptionOptions: [.punctuation],
                                         reportingOptions: [.volatileResults], attributeOptions: [])
            module = t
            results = Task { [weak self] in
                do { for try await r in t.results { self?.result(String(r.text.characters), final: r.isFinal) } } catch {}
            }
            try await Transcriber.reserve(l)
        } else {
            throw TranslateError.noRecogniser(Self.name(source))
        }
        status = "Getting \(Self.name(source)) speech recognition ready…"
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [module]) { try await req.downloadAndInstall() }
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self)
        input = cont
        let a = SpeechAnalyzer(modules: [module])
        analyzer = a
        try await a.start(inputSequence: stream)
    }

    private func result(_ text: String, final: Bool) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if final {
            partial = ""
            if !t.isEmpty { commit(t) }
        } else {
            partial = t
        }
    }

    /// A finished phrase from the phone's recogniser, handed to Apple Translation.
    private func commit(_ text: String) {
        let line = Line(original: text)
        lines.append(line)
        appleSend.yield((line.id, text))
    }

    /// From `TranslateView`'s translation session.
    func translated(_ id: UUID, _ result: Result<String, Error>) {
        switch result {
        case .success(let t):
            update(id) { $0.translation = t }
            say(t)
        case .failure(let e):
            update(id) { $0.failed = e.localizedDescription }
        }
    }

    private func update(_ id: UUID, _ change: (inout Line) -> Void) {
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
        change(&lines[i])
    }

    // MARK: Speaking

    /// Reads the translation aloud; the microphone is ignored meanwhile so it is not
    /// translated back.
    private func say(_ text: String) {
        guard speak, !text.isEmpty else { return }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: target)
        if voiceDelegate == nil {
            let d = VoiceDelegate { [weak self] in Task { @MainActor in self?.speaking = false } }
            voiceDelegate = d
            voice.delegate = d
        }
        speaking = true
        voice.speak(u)
    }
}

/// Converts microphone buffers on the audio thread: 16 kHz mono floats with their level
/// for server mode, and the recogniser's own format for device mode.
final class MicTap: @unchecked Sendable {
    var onSamples: (([Float], Float, AVAudioPCMBuffer?) -> Void)?
    private var toMono: AVAudioConverter?
    private var mono: AVAudioFormat?
    private var toAnalyzer: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?

    func prepare(from input: AVAudioFormat, analyzer: AVAudioFormat?) {
        mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        toMono = mono.flatMap { AVAudioConverter(from: input, to: $0) }
        analyzerFormat = analyzer
        toAnalyzer = analyzer.flatMap { AVAudioConverter(from: input, to: $0) }
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let mono, let toMono else { return }
        let samples = convert(buffer, with: toMono, to: mono).map { b in
            Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
        } ?? []
        var e: Float = 0
        for s in samples { e += s * s }
        let db = 10 * log10(e / Float(max(1, samples.count)) + 1e-10)
        let forAnalyzer = toAnalyzer.flatMap { c in analyzerFormat.flatMap { convert(buffer, with: c, to: $0) } }
        onSamples?(samples, db, forAnalyzer)
    }

    private func convert(_ buffer: AVAudioPCMBuffer, with c: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32)
        else { return nil }
        var used = false
        var err: NSError?
        c.convert(to: out, error: &err) { _, status in
            if used { status.pointee = .noDataNow; return nil }
            used = true
            status.pointee = .haveData
            return buffer
        }
        return err == nil && out.frameLength > 0 ? out : nil
    }
}

private final class VoiceDelegate: NSObject, AVSpeechSynthesizerDelegate {
    let done: () -> Void
    init(_ done: @escaping () -> Void) { self.done = done }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { done() }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { done() }
}

enum TranslateError: LocalizedError {
    case noRecogniser(String), noPocket
    var errorDescription: String? {
        switch self {
        case .noRecogniser(let l): "This iPhone cannot recognise \(l) speech. Use the server for it."
        case .noPocket: "Connect the Pocket on the Recorder tab first (or press its button to record), or listen with the iPhone's microphone."
        }
    }
}
