import AVFoundation
import Foundation
import NaturalLanguage
import Speech

/// Near-live interpreting, one utterance at a time, from the iPhone's microphone or from
/// the Pocket's live stream (which records the conversation too).
///
/// Each phrase is cut at the pause after it (an energy gate over the room's quiet level).
///
/// - **On this iPhone:** Parakeet transcribes the phrase, then Apple Translation
///   (`TranslateView` owns its session). Offline once the models are downloaded. A language
///   Parakeet lacks falls back to Apple's recognisers as you speak (SpeechTranscriber, or
///   DictationTranscriber, which has Dutch). On real Dutch street interviews Apple's Dutch
///   dictation returned nothing where Parakeet got most of it.
/// - **Server:** Whisper, then the language model with the last few lines as context.
///   About a second after each pause, and better at idiom ("Enkele reis alstublieft":
///   "One-way, please", where Apple Translation offered "Please provide some travel
///   information").
///
/// Neither forces the source language: in Amsterdam people switch to English, and Whisper
/// told "Dutch" translates the English into Dutch. A phrase already in the target language
/// is shown as it is.
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
    private var speechDB: Float = -30
    private var frames: [(Int, Float)] = []   // the phrase's frames: samples, level
    private var serverQueue: [(UUID, [Float])] = []
    private var serverBusy = false

    // Device mode: Parakeet per phrase, or Apple's recogniser as you speak
    private var parakeet = false
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
            status = listeningNote
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
        if inSpeech { endUtterance() }
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
        status = listeningNote
    }

    private var analyzerFormat: AVAudioFormat?

    private func received(_ samples: [Float], db: Float, analyzerBuffer: AVAudioPCMBuffer?) {
        level = max(0, min(1, (db + 60) / 50))
        guard listening, !speaking else { return }
        if mode == .device, !parakeet {
            if let b = analyzerBuffer { input?.yield(AnalyzerInput(buffer: b)) }
        } else {
            segment(samples, db: db)
        }
    }

    /// A phrase starts 12 dB over the room's quiet level and ends at a pause: below halfway
    /// between that level and the speaker's, for 0.7 s in a short phrase, 0.35 s past 3 s,
    /// 0.17 s past 6 s. Over continuous sound (a street, music) there is no such pause, so
    /// at 8 s it is cut at the quietest moment of its last 3 s and the rest starts the next.
    /// On Dutch street interviews this gave phrases of 5 to 8 s; a fixed gate ran to the cap.
    private func segment(_ samples: [Float], db: Float) {
        // The room's quiet level: falls at once to anything quieter, creeps back up slowly.
        if db < floorDB { floorDB = db } else if !inSpeech { floorDB = min(-20, floorDB + 0.02) }
        floorDB = max(-80, floorDB)
        if !inSpeech, db > floorDB + 12 {
            inSpeech = true
            quietFrames = 0
            speechDB = db
            // Keep a little audio from before the start, so the first word is whole.
            let keep = utterance.suffix(4_800)
            utterance = Array(keep)
            frames = [(keep.count, floorDB)]
        }
        utterance += samples
        frames.append((samples.count, db))
        if !inSpeech {
            if utterance.count > 4_800 { utterance.removeFirst(utterance.count - 4_800) }
            frames = []
            return
        }
        let mid = (floorDB + speechDB) / 2
        if db > mid { speechDB = 0.9 * speechDB + 0.1 * db }
        quietFrames = db < mid ? quietFrames + 1 : 0
        let seconds = Double(utterance.count) / 16_000
        let need = seconds < 3 ? 0.7 : seconds < 6 ? 0.35 : 0.17
        if seconds >= 8 {
            cutAtQuietest()
        } else if Double(quietFrames) * Double(samples.count) / 16_000 >= need {
            endUtterance()
        }
    }

    /// Sends what came before the quietest frame of the last 3 s; the rest carries on.
    private func cutAtQuietest() {
        var start = 0, best = 0, bestDB = Float.infinity, cut = utterance.count
        for (n, db) in frames {
            if start >= utterance.count - 48_000, db < bestDB, start > 0 { bestDB = db; best = start }
            start += n
        }
        if best > 0 { cut = best }
        let head = Array(utterance[..<cut])
        utterance = Array(utterance[cut...])
        var acc = 0
        frames = frames.filter { f in defer { acc += f.0 }; return acc >= cut }
        quietFrames = 0
        queuePhrase(head)
    }

    private func endUtterance() {
        inSpeech = false
        quietFrames = 0
        let audio = utterance
        utterance = []
        frames = []
        queuePhrase(audio)
    }

    private func queuePhrase(_ audio: [Float]) {
        guard Double(audio.count) / 16_000 >= 0.6 else { return }
        let line = Line(original: "…")
        lines.append(line)
        serverQueue.append((line.id, audio))
        if !serverBusy { Task { await drainPhrases() } }
    }

    /// Phrases in order: words, then the translation.
    private func drainPhrases() async {
        serverBusy = true
        defer { serverBusy = false }
        while !serverQueue.isEmpty {
            let (id, audio) = serverQueue.removeFirst()
            do {
                let (text, language) = mode == .server ? try await serverWords(audio) : (try await phoneWords(audio), nil)
                guard !text.isEmpty, !Cleanup.isNoise(text), !Cleanup.isStockPhrase(text) else {
                    lines.removeAll { $0.id == id }
                    continue
                }
                update(id) { $0.original = text }
                if Self.isIn(target, text, detected: language) {
                    update(id) { $0.translation = text }   // already in the listener's language
                } else if mode == .server {
                    let translated = try await translateWithModel(text, before: id)
                    update(id) { $0.translation = translated }
                    say(translated)
                } else {
                    appleSend.yield((id, text))
                }
            } catch {
                update(id) { $0.failed = error.localizedDescription }
            }
        }
    }

    /// Whisper detects the language; one it should not have heard (a short Dutch phrase
    /// taken for German, say) is asked again in the source language.
    private func serverWords(_ audio: [Float]) async throws -> (String, String?) {
        let wav = ChunkedSTT.wav(audio[...])
        var r = try await RemoteSTT.request(wav, filename: "phrase.wav", type: "audio/wav", localeID: Languages.auto, timeout: 30)
        if let l = r.language, l != source, l != target {
            r = try await RemoteSTT.request(wav, filename: "phrase.wav", type: "audio/wav", localeID: source, timeout: 30)
            r.language = source
        }
        let words = Cleanup.words(r.transcript.words)
        let text = words.isEmpty ? r.transcript.text : words.map(\.word).joined(separator: " ")
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), r.language)
    }

    private func phoneWords(_ audio: [Float]) async throws -> String {
        let status: @Sendable (String) -> Void = { [weak self] s in Task { @MainActor in self?.status = s } }
        // No language hint: Parakeet follows a switch to English by itself.
        let t = try await OnDeviceSpeech.shared.transcribe(samples: audio, localeID: Languages.auto, status: status)
        if listening { self.status = listeningNote }
        return t
    }

    /// The phrase is already in `code`: Whisper said so, or (failing that) the text reads so.
    static func isIn(_ code: String, _ text: String, detected: String?) -> Bool {
        if let detected { return detected == code }
        guard text.split(separator: " ").count >= 3 else { return false }
        return NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue == code
    }

    private var listeningNote: String {
        audioIn == .pocket ? "Listening through the Pocket; the conversation is also recorded"
            : mode == .server ? "Listening; each phrase is sent after a pause" : "Listening on this iPhone"
    }

    /// Downloads what on-device translation needs (Parakeet; the languages are fetched by
    /// `TranslateView`), so it works without a connection.
    func prepareOffline() async {
        status = "Getting the speech model…"
        do {
            try await OnDeviceSpeech.shared.prepare { [weak self] s in Task { @MainActor in self?.status = s } }
            appleSend.yield((UUID(), ""))   // an empty phrase: TranslateView downloads the languages
            status = "Speech model ready. Allow the language download if asked."
        } catch {
            self.error = error.localizedDescription
            status = nil
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
        parakeet = OnDeviceSpeech.supports(source)
        if parakeet {
            status = "Getting the speech model ready…"
            try await OnDeviceSpeech.shared.prepare { [weak self] s in Task { @MainActor in self?.status = s } }
            return
        }
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
