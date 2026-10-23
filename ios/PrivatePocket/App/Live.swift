@preconcurrency import AVFAudio
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
    /// Bytes streamed so far: not published, as it changes with every Bluetooth packet.
    private(set) var bytes = 0
    /// Whole seconds streamed so far, published once a second.
    @Published private(set) var seconds = 0
    @Published private(set) var finalText = ""
    @Published private(set) var volatileText = ""
    /// Where the live transcript comes from, or why there is none.
    @Published private(set) var engineNote: String?
    @Published private(set) var gap = false
    /// Speaker turns so far, refreshed every `diarizeEvery` seconds of audio.
    @Published private(set) var turns: [Turn] = []
    @Published private(set) var speakersNote: String?
    /// How loud the stream is, for the waveforms; its own object so only they redraw.
    let levels = LiveLevels()

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
        seconds = 0
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

        // The stream is split into MP3 frames and decoded once: the level meter hears every
        // frame, the transcriber on the phone gets the same audio, and the server's slices
        // are cut from the frames themselves.
        let p = MP3Packetizer()
        parser = p
        let decoder = MP3Decoder()
        levels.start()
        p.onPackets = { [weak self] data, descs, fmt in
            guard let self else { return }
            if let pcm = decoder.decode(data, packets: descs, format: fmt) {
                self.levels.add(pcm)
                self.local?.add(pcm)
            }
            self.remote?.add(data, packets: descs, format: fmt)
        }
        guard Prefs.liveTranscript else { engineNote = "Live transcript is off (Settings → Processing)."; return }
        localeID = Self.liveLocale()
        // A transcriber still finishing an earlier recording never writes over this one's words.
        let session = name
        if Prefs.sttRemoteNow {
            let r = RemoteLiveTranscriber(localeID: localeID ?? Languages.auto)
            r.onText = { [weak self] t in
                if let self, self.name == session || self.name == nil { self.finalText = t }
            }
            r.onError = { [weak self] e in
                if let self, self.name == session { self.engineNote = "Live transcript paused: \(e)" }
            }
            remote = r
            engineNote = "Live transcript: \(Prefs.sttModel) on the server, every \(Int(RemoteLiveTranscriber.chunkSeconds)) s"
        } else {
            let l = LocalLiveTranscriber()
            l.onText = { [weak self] f, v in
                if let self, self.name == session || self.name == nil { self.finalText = f; self.volatileText = v }
            }
            local = l
            let id = localeID ?? Locale.current.identifier(.bcp47)
            engineNote = "Live transcript on this iPhone (\(Languages.name(id)))"
            Task {
                do { try await l.start(localeID: id) } catch {
                    // Not started (the language not on the phone, say): it stops collecting audio
                    // for a recogniser that will never take it.
                    l.abandon()
                    guard self.name == session else { return }
                    if self.local === l { self.local = nil }
                    self.engineNote = "No live transcript: \(error.localizedDescription)"
                }
            }
        }
    }

    func append(_ d: Data) {
        guard isActive else { return }
        if let f = file {
            do { try f.write(contentsOf: d) } catch {
                // The phone would not take it (full, say): the stream is no longer whole, so the
                // Pocket's own file is fetched at the stop.
                try? f.close()
                file = nil
                gap = true
            }
        }
        bytes += d.count
        let s = Int(Double(bytes) / PocketFacts.bytesPerSecond)
        if s != seconds { seconds = s }
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
    func end(name: String) async -> Result? { await detach(name: name)?.finish() }

    /// Takes recording `name`'s stream out of the session at once, so another recording can
    /// begin while this one's transcriber finishes and its file is read; nil if the session
    /// was for another one. Before, a recording started during that wait threw the new
    /// session away and read its file as the old one's.
    func detach(name: String) -> Ending? {
        guard self.name == name else { return nil }
        try? file?.close()
        let ending = Ending(name: name, url: url, local: local, remote: remote, gap: gap,
                            locale: remote != nil && localeID == Languages.auto ? nil : localeID)
        reset()
        return ending
    }

    /// A stopped recording's stream, finishing on its own.
    @MainActor
    final class Ending {
        let name: String
        private let url: URL?
        private let local: LocalLiveTranscriber?
        private let remote: RemoteLiveTranscriber?
        private let gap: Bool
        private let locale: String?

        init(name: String, url: URL?, local: LocalLiveTranscriber?, remote: RemoteLiveTranscriber?, gap: Bool, locale: String?) {
            self.name = name
            self.url = url
            self.local = local
            self.remote = remote
            self.gap = gap
            self.locale = locale
        }

        func finish() async -> LiveSession.Result {
            var transcript: String?
            if let l = local { transcript = await l.finish() }
            if let r = remote { transcript = await r.finish() }
            let words = local?.words ?? remote?.words ?? []
            let audio = url.flatMap { try? Data(contentsOf: $0) } ?? Data()
            if let url { try? FileManager.default.removeItem(at: url) }
            return LiveSession.Result(name: name, audio: audio, complete: !gap && !audio.isEmpty,
                                      transcript: transcript.flatMap { $0.isEmpty ? nil : $0 }, words: words, locale: locale)
        }
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
        levels.stop()
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
        if Prefs.sttRemoteNow { return Languages.auto }
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
    private var resampler: AVAudioConverter?
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

    private var abandoned = false

    /// Decoded stream audio, at the stream's own rate. While the recogniser starts (it may
    /// fetch its model first) about a minute is kept; older audio goes.
    func add(_ pcm: AVAudioPCMBuffer) {
        guard !abandoned else { return }
        if input == nil {
            pending.append(pcm)
            if pending.count > 1_000 { pending.removeFirst(pending.count - 1_000) }
        } else {
            feed(pcm)
        }
    }

    /// It never started: nothing more is kept for it.
    func abandon() {
        abandoned = true
        pending = []
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
    private var failures = 0
    /// Three slices in a row failed: the server is away, and the rest of this recording is
    /// left to the transcription after the stop.
    private var paused = false

    init(localeID: String) { self.localeID = localeID }

    func add(_ data: Data, packets: [AudioStreamPacketDescription], format: AudioStreamBasicDescription) {
        guard !paused, !cancelled else { return }
        for p in packets {
            buffer.append(data.subdata(in: Int(p.mStartOffset)..<Int(p.mStartOffset) + Int(p.mDataByteSize)))
        }
        let frames = Double(max(format.mFramesPerPacket, 1)) * Double(packets.count)
        bufferedSeconds += frames / max(format.mSampleRate, 1)
        if bufferedSeconds >= Self.chunkSeconds { flush() }
    }

    /// The last slice usually takes a second or two. A server gone quiet is not waited on for
    /// more than twenty, and what was heard is kept; the transcription after the stop has the rest.
    func finish() async -> String {
        flush()
        let deadline = Date().addingTimeInterval(20)
        while worker != nil || !queue.isEmpty {
            if Date() > deadline || cancelled || paused {
                cancel()
                break
            }
            if worker == nil { work() }
            try? await Task.sleep(for: .milliseconds(200))
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
                // A fifteen-second slice that takes a minute is not coming.
                let t = try await RemoteSTT.transcribe(chunk.data, filename: "live.mp3", type: "audio/mpeg", localeID: localeID, timeout: 60)
                guard let self else { return }
                self.failures = 0
                if !t.text.isEmpty { self.text += self.text.isEmpty ? t.text : " " + t.text }
                self.words += t.words.map { TimedWord(word: $0.word, start: $0.start + chunk.offset, end: $0.end + chunk.offset) }
                self.onText?(self.text)
            } catch {
                guard let self else { return }
                self.failures += 1
                if self.failures >= 3 {
                    self.paused = true
                    self.queue = []
                    self.buffer = Data()
                    self.onError?("your server didn't answer, so the whole recording is transcribed after it stops")
                } else {
                    self.onError?(error.localizedDescription)
                }
            }
            guard let self else { return }
            self.worker = nil
            self.work()
        }
    }
}

/// MP3 frames to float PCM at the stream's own rate.
final class MP3Decoder {
    private var converter: AVAudioConverter?
    private var pcmFormat: AVAudioFormat?

    func decode(_ data: Data, packets: [AudioStreamPacketDescription],
                        format: AudioStreamBasicDescription) -> AVAudioPCMBuffer? {
        var asbd = format
        guard let mp3 = AVAudioFormat(streamDescription: &asbd) else { return nil }
        if converter == nil {
            pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: asbd.mSampleRate,
                                      channels: asbd.mChannelsPerFrame, interleaved: false)
            if let pcmFormat { converter = AVAudioConverter(from: mp3, to: pcmFormat) }
        }
        guard let converter, let pcmFormat else { return nil }
        let maxPacket = packets.map { Int($0.mDataByteSize) }.max() ?? 0
        let comp = AVAudioCompressedBuffer(format: mp3, packetCapacity: AVAudioPacketCount(packets.count),
                                           maximumPacketSize: maxPacket)
        data.withUnsafeBytes { comp.data.copyMemory(from: $0.baseAddress!, byteCount: data.count) }
        for (i, d) in packets.enumerated() { comp.packetDescriptions?[i] = d }
        comp.packetCount = AVAudioPacketCount(packets.count)
        comp.byteLength = UInt32(data.count)

        let framesPerPacket = asbd.mFramesPerPacket > 0 ? Int(asbd.mFramesPerPacket) : 1152   // 576 for the Pocket's MPEG-2 frames
        guard let out = AVAudioPCMBuffer(pcmFormat: pcmFormat,
                                         frameCapacity: AVAudioFrameCount(packets.count * framesPerPacket))
        else { return nil }
        var given = false
        _ = converter.convert(to: out, error: nil) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return comp
        }
        return out.frameLength > 0 ? out : nil
    }
}

/// How loud the stream is, ten times a second: the root mean square of each tenth of a
/// second of decoded audio, on a scale from silence (−50 dB) to full (−12 dB). Published
/// on its own so that only the waveforms redraw at that rate. `stalled` is set when
/// nothing has arrived for a second and a half, so a waveform can go flat rather than
/// show a gap as silence.
@MainActor
final class LiveLevels: ObservableObject {
    static let capacity = 200   // twenty seconds
    @Published private(set) var values: [Float] = []
    @Published private(set) var stalled = false
    private var sum = 0.0
    private var count = 0
    private var lastAt = Date.distantPast
    private var watch: Task<Void, Never>?

    func start() {
        stop()
        values = []
        stalled = false
        lastAt = Date()
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                let quiet = Date().timeIntervalSince(self.lastAt) > 1.5
                if quiet != self.stalled { self.stalled = quiet }
            }
        }
    }

    func stop() {
        watch?.cancel()
        watch = nil
        sum = 0
        count = 0
    }

    func add(_ pcm: AVAudioPCMBuffer) {
        guard let samples = pcm.floatChannelData?[0] else { return }
        let window = max(400, Int(pcm.format.sampleRate / 10))
        var fresh: [Float] = []
        for i in 0..<Int(pcm.frameLength) {
            let x = Double(samples[i])
            sum += x * x
            count += 1
            if count >= window {
                fresh.append(Self.level(rms: (sum / Double(count)).squareRoot()))
                sum = 0
                count = 0
            }
        }
        lastAt = Date()
        if stalled { stalled = false }
        guard !fresh.isEmpty else { return }
        var v = values
        v.append(contentsOf: fresh)
        if v.count > Self.capacity { v.removeFirst(v.count - Self.capacity) }
        values = v
    }

    static func level(rms: Double) -> Float {
        let db = 20 * log10(max(rms, 1e-7))
        return Float(min(1, max(0, (db + 50) / 38)))
    }

    /// The last `seconds` as `count` bars, the loudest level in each, 0–15: small enough to
    /// send to the Dynamic Island every two seconds.
    func bars(_ count: Int, seconds: Double) -> [UInt8] {
        let per = max(1, Int((seconds * 10 / Double(count)).rounded()))
        let tail = Array(values.suffix(per * count))
        var out: [UInt8] = []
        var i = 0
        while i < tail.count {
            let top = tail[i..<min(i + per, tail.count)].max() ?? 0
            out.append(UInt8((max(0, top) * 15).rounded()))
            i += per
        }
        return out
    }
}

