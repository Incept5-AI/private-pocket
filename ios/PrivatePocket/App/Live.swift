import AVFoundation
import AudioToolbox
import Foundation
import Speech

/// The audio a Pocket streams over Bluetooth while it records (the same MP3 bytes
/// it writes to its file). Saved as it arrives, transcribed live, and used as the
/// recording at stop when it covers the whole recording, so no download is needed.
@MainActor
final class LiveSession: ObservableObject {
    struct Result {
        let name: String
        let audio: Data
        /// Streamed from the first byte with no disconnection in between.
        let complete: Bool
        let transcript: String?
        let words: [TimedWord]
        let locale: String?
    }

    @Published private(set) var name: String?
    @Published private(set) var bytes = 0
    @Published private(set) var finalText = ""
    @Published private(set) var volatileText = ""
    /// Where the live transcript comes from, or why there is none.
    @Published private(set) var engineNote: String?
    @Published private(set) var gap = false
    /// Speaker turns so far, refreshed every `diarizeEvery` seconds of audio.
    @Published private(set) var turns: [Turn] = []
    @Published private(set) var speakersNote: String?

    static let diarizeEvery: Double = 45
    private var diarizing = false
    private var lastDiarizedBytes = 0

    private var deviceID: UUID?
    private var file: FileHandle?
    private var url: URL?
    private var parser: MP3Packetizer?
    private var local: LocalLiveTranscriber?
    private var remote: RemoteLiveTranscriber?
    private var localeID: String?

    var isActive: Bool { name != nil }
    var text: String { [finalText, volatileText].filter { !$0.isEmpty }.joined(separator: " ") }

    func begin(name: String, device: UUID) {
        if isActive { _ = abandon() }
        self.name = name
        deviceID = device
        bytes = 0
        finalText = ""
        volatileText = ""
        gap = false
        engineNote = nil
        turns = []
        speakersNote = nil
        diarizing = false
        lastDiarizedBytes = 0

        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Live", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent("\(name).mp3")
        FileManager.default.createFile(atPath: u.path, contents: nil)
        url = u
        file = try? FileHandle(forWritingTo: u)

        guard Prefs.liveTranscript else { engineNote = "Live transcript is off (Settings → Processing)."; return }
        let p = MP3Packetizer()
        parser = p
        localeID = Self.liveLocale()
        if Prefs.sttRemote {
            let r = RemoteLiveTranscriber(localeID: localeID ?? Languages.auto)
            r.onText = { [weak self] t in self?.finalText = t }
            r.onError = { [weak self] e in self?.engineNote = "Live transcript paused: \(e)" }
            remote = r
            engineNote = "Live transcript: \(Prefs.sttModel) on the server, every \(Int(RemoteLiveTranscriber.chunkSeconds)) s"
            p.onPackets = { [weak r] data, descs, fmt in r?.add(data, packets: descs, format: fmt) }
        } else {
            let l = LocalLiveTranscriber()
            l.onText = { [weak self] f, v in self?.finalText = f; self?.volatileText = v }
            local = l
            let id = localeID ?? Locale.current.identifier(.bcp47)
            engineNote = "Live transcript on this iPhone (\(Languages.name(id)))"
            Task {
                do { try await l.start(localeID: id) } catch { self.engineNote = "No live transcript: \(error.localizedDescription)" }
            }
            p.onPackets = { [weak l] data, descs, fmt in l?.add(data, packets: descs, format: fmt) }
        }
    }

    func append(_ d: Data) {
        guard isActive else { return }
        file?.write(d)
        bytes += d.count
        parser?.parse(d)
        // ~4 KB per second at the Pocket's 32 kbps.
        if Prefs.diarize, !diarizing, bytes - lastDiarizedBytes >= Int(Self.diarizeEvery * 4_000) { refreshSpeakers() }
    }

    private var words: [TimedWord] { local?.words ?? remote?.words ?? [] }

    /// Diarises everything streamed so far (ids only hold within one request).
    private func refreshSpeakers() {
        guard let url, let name else { return }
        diarizing = true
        lastDiarizedBytes = bytes
        Task {
            defer { if self.name == name { self.diarizing = false } }
            do {
                let segments = try await Diarizer.diarize(try Data(contentsOf: url), filename: "\(name).mp3")
                guard self.name == name else { return }
                turns = Speakers.align(words, segments)
                speakersNote = nil
            } catch {
                guard self.name == name else { return }
                speakersNote = "Speakers: \(error.localizedDescription)"
            }
        }
    }

    /// The link dropped: the stream now has a hole, so the device file is needed.
    func markGap() { if isActive { gap = true } }

    /// Ends the session for recording `name`; nil if it was for another one.
    func end(name: String) async -> Result? {
        guard self.name == name else { return nil }
        try? file?.close()
        file = nil
        var transcript: String?
        if let l = local { transcript = await l.finish() }
        if let r = remote { transcript = await r.finish() }
        let words = self.words
        let audio = url.flatMap { try? Data(contentsOf: $0) } ?? Data()
        if let url { try? FileManager.default.removeItem(at: url) }
        let result = Result(name: name, audio: audio, complete: !gap && !audio.isEmpty,
                            transcript: transcript.flatMap { $0.isEmpty ? nil : $0 },
                            words: words,
                            locale: remote != nil && localeID == Languages.auto ? nil : localeID)
        reset()
        return result
    }

    @discardableResult
    func abandon() -> String? {
        let n = name
        try? file?.close()
        if let url { try? FileManager.default.removeItem(at: url) }
        local?.cancel()
        remote?.cancel()
        reset()
        return n
    }

    private func reset() {
        name = nil
        file = nil
        url = nil
        parser = nil
        local = nil
        remote = nil
    }

    /// Live recognition needs a named language on the phone; the server can detect it.
    private static func liveLocale() -> String? {
        let def = Prefs.transcriptionLocale
        if def != Languages.auto { return def }
        if Prefs.sttRemote { return Languages.auto }
        return Prefs.favouriteLocales.first { $0 != Languages.auto }
    }
}

/// Splits a byte stream of MP3 into whole frames (packets) with AudioFileStream.
final class MP3Packetizer {
    /// Frame bytes, their descriptions (offsets into the bytes) and the stream format.
    var onPackets: ((Data, [AudioStreamPacketDescription], AudioStreamBasicDescription) -> Void)?
    private var stream: AudioFileStreamID?
    fileprivate var format: AudioStreamBasicDescription?

    init() {
        AudioFileStreamOpen(Unmanaged.passUnretained(self).toOpaque(), { client, stream, property, _ in
            let me = Unmanaged<MP3Packetizer>.fromOpaque(client).takeUnretainedValue()
            guard property == kAudioFileStreamProperty_DataFormat else { return }
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            if AudioFileStreamGetProperty(stream, property, &size, &asbd) == noErr { me.format = asbd }
        }, { client, numberBytes, numberPackets, input, descs in
            let me = Unmanaged<MP3Packetizer>.fromOpaque(client).takeUnretainedValue()
            guard let fmt = me.format, numberPackets > 0 else { return }
            let data = Data(bytes: input, count: Int(numberBytes))
            let list = Array(UnsafeBufferPointer(start: descs, count: Int(numberPackets)))
            me.onPackets?(data, list, fmt)
        }, kAudioFileMP3Type, &stream)
    }

    deinit { if let stream { AudioFileStreamClose(stream) } }

    func parse(_ d: Data) {
        guard let stream else { return }
        d.withUnsafeBytes { raw in
            _ = AudioFileStreamParseBytes(stream, UInt32(d.count), raw.baseAddress, [])
        }
    }
}

/// Apple's on-device recogniser fed with decoded stream audio, reporting volatile
/// (in-progress) and final text as it goes.
@MainActor
final class LocalLiveTranscriber {
    var onText: ((String, String) -> Void)?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var target: AVAudioFormat?
    private var pending: [AVAudioPCMBuffer] = []
    private var decoder: AVAudioConverter?
    private var resampler: AVAudioConverter?
    private var pcmFormat: AVAudioFormat?
    private var finalText = ""
    private(set) var words: [TimedWord] = []

    func start(localeID: String) async throws {
        let transcriber = try await Transcriber.prepare(localeID: localeID, reporting: [.volatileResults])
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AIError.unsupportedLocale(localeID)
        }
        target = fmt
        let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self)
        input = cont
        let a = SpeechAnalyzer(modules: [transcriber])
        analyzer = a
        results = Task { [weak self] in
            do {
                for try await r in transcriber.results {
                    let piece = String(r.text.characters).trimmingCharacters(in: .whitespaces)
                    guard let self else { return }
                    if r.isFinal {
                        if !piece.isEmpty { self.finalText += self.finalText.isEmpty ? piece : " " + piece }
                        self.words += Transcriber.words(in: r.text)
                        self.onText?(self.finalText, "")
                    } else {
                        self.onText?(self.finalText, piece)
                    }
                }
            } catch {}
        }
        try await a.start(inputSequence: stream)
        pending.forEach(feed)
        pending = []
    }

    func add(_ data: Data, packets: [AudioStreamPacketDescription], format: AudioStreamBasicDescription) {
        guard let pcm = decode(data, packets: packets, format: format) else { return }
        if input == nil { pending.append(pcm) } else { feed(pcm) }
    }

    func finish() async -> String {
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await results?.value
        return finalText
    }

    func cancel() {
        input?.finish()
        results?.cancel()
        Task { [analyzer] in await analyzer?.cancelAndFinishNow() }
    }

    private func feed(_ pcm: AVAudioPCMBuffer) {
        guard let target, let input else { return }
        if pcm.format == target { input.yield(AnalyzerInput(buffer: pcm)); return }
        if resampler == nil { resampler = AVAudioConverter(from: pcm.format, to: target) }
        guard let resampler else { return }
        let ratio = target.sampleRate / pcm.format.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 64)
        else { return }
        var given = false
        _ = resampler.convert(to: out, error: nil) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return pcm
        }
        if out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
    }

    /// MP3 frames → float PCM at the stream's own rate.
    private func decode(_ data: Data, packets: [AudioStreamPacketDescription],
                        format: AudioStreamBasicDescription) -> AVAudioPCMBuffer? {
        var asbd = format
        guard let mp3 = AVAudioFormat(streamDescription: &asbd) else { return nil }
        if decoder == nil {
            pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: asbd.mSampleRate,
                                      channels: asbd.mChannelsPerFrame, interleaved: false)
            if let pcmFormat { decoder = AVAudioConverter(from: mp3, to: pcmFormat) }
        }
        guard let decoder, let pcmFormat else { return nil }
        let maxPacket = packets.map { Int($0.mDataByteSize) }.max() ?? 0
        let comp = AVAudioCompressedBuffer(format: mp3, packetCapacity: AVAudioPacketCount(packets.count),
                                           maximumPacketSize: maxPacket)
        data.withUnsafeBytes { comp.data.copyMemory(from: $0.baseAddress!, byteCount: data.count) }
        for (i, d) in packets.enumerated() { comp.packetDescriptions?[i] = d }
        comp.packetCount = AVAudioPacketCount(packets.count)
        comp.byteLength = UInt32(data.count)

        let framesPerPacket = max(Int(asbd.mFramesPerPacket), 1152)
        guard let out = AVAudioPCMBuffer(pcmFormat: pcmFormat,
                                         frameCapacity: AVAudioFrameCount(packets.count * framesPerPacket))
        else { return nil }
        var given = false
        _ = decoder.convert(to: out, error: nil) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return comp
        }
        return out.frameLength > 0 ? out : nil
    }
}

/// Server Whisper on consecutive slices of the stream. MP3 frames can be cut
/// between and uploaded as they are, so each slice is a valid MP3 file.
@MainActor
final class RemoteLiveTranscriber {
    static let chunkSeconds: Double = 15

    var onText: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private let localeID: String
    private var buffer = Data()
    private var bufferedSeconds: Double = 0
    /// Where the buffered slice starts in the recording, for word times.
    private var bufferStart: Double = 0
    private var queue: [(data: Data, offset: Double)] = []
    private(set) var words: [TimedWord] = []
    private var worker: Task<Void, Never>?
    private var text = ""
    private var cancelled = false

    init(localeID: String) { self.localeID = localeID }

    func add(_ data: Data, packets: [AudioStreamPacketDescription], format: AudioStreamBasicDescription) {
        for p in packets {
            buffer.append(data.subdata(in: Int(p.mStartOffset)..<Int(p.mStartOffset) + Int(p.mDataByteSize)))
        }
        let frames = Double(max(format.mFramesPerPacket, 1)) * Double(packets.count)
        bufferedSeconds += frames / max(format.mSampleRate, 1)
        if bufferedSeconds >= Self.chunkSeconds { flush() }
    }

    func finish() async -> String {
        flush()
        while worker != nil || !queue.isEmpty {
            if worker == nil { work() }
            await worker?.value
        }
        return text
    }

    func cancel() {
        cancelled = true
        worker?.cancel()
        queue = []
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        queue.append((buffer, bufferStart))
        bufferStart += bufferedSeconds
        buffer = Data()
        bufferedSeconds = 0
        if worker == nil { work() }
    }

    private func work() {
        guard !queue.isEmpty, !cancelled else { return }
        let chunk = queue.removeFirst()
        worker = Task { [weak self, localeID] in
            do {
                let t = try await RemoteSTT.transcribe(chunk.data, filename: "live.mp3", type: "audio/mpeg", localeID: localeID)
                guard let self else { return }
                if !t.text.isEmpty { self.text += self.text.isEmpty ? t.text : " " + t.text }
                self.words += t.words.map { TimedWord(word: $0.word, start: $0.start + chunk.offset, end: $0.end + chunk.offset) }
                self.onText?(self.text)
            } catch {
                self?.onError?(error.localizedDescription)
            }
            guard let self else { return }
            self.worker = nil
            self.work()
        }
    }
}
