import AVFoundation
import Foundation

/// Whisper on a server, a recording at a time, but sent as pieces of at most 28 s cut at
/// the quietest moment. Sent whole, whisper.cpp carries its own output from one 30 s
/// window into the next, and once it repeats itself it never recovers: a 45-minute
/// meeting came back as 94% "A brief summary about that, it was..." and "*crickets*"
/// over the pauses. In pieces nothing carries over, silent pieces are not sent at all,
/// and a piece that still loops is tried again warmer.
enum ChunkedSTT {
    static let sampleRate = 16_000.0
    static let minSeconds = 12.0
    static let maxSeconds = 28.0
    /// Pieces in flight at once: the server's Whisper runs one at a time, so this only
    /// overlaps the uploads.
    static let parallel = 3

    struct Piece { var start: Double; var end: Double; var speech: Double }

    static func transcribe(_ url: URL, localeID: String, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> TimedTranscript {
        let samples = try pcm(url)
        let pieces = cut(samples)
        var language = localeID
        var results: [Int: TimedTranscript] = [:]
        var done = 0

        // With auto-detect, the first piece with speech decides the language for the rest,
        // so one stray piece cannot come back in another language.
        var order = Array(pieces.indices.filter { pieces[$0].speech >= 0.03 })
        if localeID == Languages.auto, let first = order.first {
            let (t, lang) = try await one(samples, pieces[first], localeID: localeID)
            results[first] = t
            if let lang { language = lang }
            order.removeFirst()
            done += 1
            progress(done, pieces.count)
        }
        let lang = language
        try await withThrowingTaskGroup(of: (Int, TimedTranscript).self) { group in
            var next = order.makeIterator()
            func add() {
                guard let i = next.next() else { return }
                let p = pieces[i]
                group.addTask { (i, try await one(samples, p, localeID: lang).0) }
            }
            for _ in 0..<parallel { add() }
            while let (i, t) = try await group.next() {
                results[i] = t
                done += 1
                progress(done, pieces.count)
                add()
            }
        }
        let words = pieces.indices.flatMap { results[$0]?.words ?? [] }
        return TimedTranscript(text: words.map(\.word).joined(separator: " "), words: words)
    }

    /// One piece, offset to its place in the recording, cleaned; retried at a higher
    /// temperature if it loops. Returns the language Whisper detected, if asked to.
    private static func one(_ x: [Float], _ p: Piece, localeID: String) async throws -> (TimedTranscript, String?) {
        let a = Int(p.start * sampleRate), b = min(x.count, Int(p.end * sampleRate))
        let wav = wav(x[a..<b])
        var r = try await RemoteSTT.request(wav, filename: "piece.wav", type: "audio/wav", localeID: localeID, timeout: 300)
        if r.transcript.text.count > 80, compression(r.transcript.text) > 2.4 {
            let warmer = try await RemoteSTT.request(wav, filename: "piece.wav", type: "audio/wav", localeID: localeID,
                                                        timeout: 300, temperature: 0.4)
            if compression(warmer.transcript.text) < compression(r.transcript.text) { r = warmer }
        }
        let words = Cleanup.words(r.transcript.words.map {
            TimedWord(word: $0.word, start: $0.start + p.start, end: $0.end + p.start)
        })
        return (TimedTranscript(text: words.map(\.word).joined(separator: " "), words: words), r.language)
    }

    /// The recording as 16 kHz mono floats.
    static func pcm(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else { throw ChunkError.decode }
        var out: [Float] = []
        out.reserveCapacity(Int(Double(file.length) * sampleRate / file.processingFormat.sampleRate) + 1)
        let inCap: AVAudioFrameCount = 32_768
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inCap),
              let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: inCap * 2) else { throw ChunkError.decode }
        var finished = false
        while true {
            var error: NSError?
            let status = converter.convert(to: outBuf, error: &error) { _, outStatus in
                if finished { outStatus.pointee = .endOfStream; return nil }
                do { try file.read(into: inBuf, frameCount: inCap) } catch { finished = true }
                if inBuf.frameLength == 0 { finished = true; outStatus.pointee = .endOfStream; return nil }
                outStatus.pointee = .haveData
                return inBuf
            }
            if let error { throw error }
            if let d = outBuf.floatChannelData, outBuf.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: d[0], count: Int(outBuf.frameLength)))
            }
            if status == .endOfStream || status == .error { break }
        }
        return out
    }

    /// Cuts at the quietest 0.2 s between `minSeconds` and `maxSeconds`. `speech` is the
    /// share of 20 ms frames 12 dB above the recording's quiet floor; under 3% is silence.
    static func cut(_ x: [Float]) -> [Piece] {
        let hop = 320, frames = x.count / hop
        guard frames > 0 else { return [] }
        var db = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            var e: Float = 0
            for j in i * hop..<(i + 1) * hop { e += x[j] * x[j] }
            db[i] = 10 * log10(e / Float(hop) + 1e-10)
        }
        let floor = db.sorted()[frames / 10]
        var smooth = db
        for i in 0..<frames {
            let lo = max(0, i - 5), hi = min(frames, i + 5)
            smooth[i] = db[lo..<hi].reduce(0, +) / Float(hi - lo)
        }
        let step = Double(hop) / sampleRate
        let minF = Int(minSeconds / step), maxF = Int(maxSeconds / step)
        var out: [Piece] = []
        var a = 0
        while a < frames {
            var b = frames
            if a + maxF < frames {
                let range = (a + minF)..<(a + maxF)
                b = range.min { smooth[$0] < smooth[$1] } ?? a + maxF
            }
            let loud = db[a..<b].filter { $0 > floor + 12 }.count
            out.append(Piece(start: Double(a) * step, end: Double(b) * step, speech: Double(loud) / Double(b - a)))
            a = b
        }
        return out
    }

    static func wav(_ x: ArraySlice<Float>) -> Data {
        var d = Data("RIFF".utf8)
        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let n = x.count
        le(UInt32(36 + n * 2)); d.append(Data("WAVEfmt ".utf8))
        le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(16_000)); le(UInt32(32_000)); le(UInt16(2)); le(UInt16(16))
        d.append(Data("data".utf8)); le(UInt32(n * 2))
        d.reserveCapacity(d.count + n * 2)
        for s in x { le(Int16(max(-1, min(1, s)) * 32_767)) }
        return d
    }

    /// Bytes over zlib-compressed bytes. Normal speech is about 2.3; a loop is far above.
    static func compression(_ s: String) -> Double {
        let d = Data(s.utf8)
        guard !d.isEmpty, let z = try? (d as NSData).compressed(using: .zlib) else { return 1 }
        return Double(d.count) / Double(max(1, z.length))
    }
}

/// What speech recognisers say over silence and when they loop.
enum Cleanup {
    /// Whole "words" that are captions, not speech: *crickets*, [BLANK_AUDIO], (music), ♪.
    static func isNoise(_ w: String) -> Bool {
        let t = w.trimmingCharacters(in: .whitespaces)
        guard let f = t.first, let l = t.last else { return true }
        return (f == "*" && l == "*" && t.count > 1) || (f == "[" && l == "]") || (f == "(" && l == ")") || t.allSatisfy { $0 == "♪" }
    }

    /// Drops caption words and any run of 1 to 12 words repeated back to back more than twice.
    static func words(_ input: [TimedWord]) -> [TimedWord] {
        let w = input.filter { !isNoise($0.word) }
        let key = w.map { $0.word.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        var out: [TimedWord] = []
        var i = 0
        outer: while i < w.count {
            for n in stride(from: 12, through: 1, by: -1) where i + 3 * n <= w.count {
                let g = key[i..<i + n]
                var k = 1
                while i + (k + 1) * n <= w.count, key[i + k * n..<i + (k + 1) * n].elementsEqual(g) { k += 1 }
                if k >= 3 {
                    out.append(contentsOf: w[i..<i + n])
                    i += k * n
                    continue outer
                }
            }
            out.append(w[i])
            i += 1
        }
        return out
    }
}

enum ChunkError: LocalizedError {
    case decode
    var errorDescription: String? { "The recording could not be decoded." }
}
