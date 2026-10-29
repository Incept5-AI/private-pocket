import AVFoundation
import Foundation

/// A whole recording to the server, in pieces when it is long. Whisper reads thirty seconds
/// at a time with what it wrote before as context; once it loses its place it writes one
/// phrase over and over, and the context keeps it there: a two-and-a-half-hour call sent
/// whole came back as one sentence for hours. Pieces of five minutes, each cut at the
/// quietest moment before its end, start it afresh; a piece that loops anyway is read again
/// a minute at a time, and what still repeats is kept once (`Repeats`).
enum LongAudio {
    static let pieceSeconds: Double = 300
    static let retrySeconds: Double = 60

    static func transcribe(_ url: URL, localeID: String) async throws -> TimedTranscript {
        let data = try Data(contentsOf: url)
        let name = url.lastPathComponent
        guard let mp3 = MP3Frames(data), mp3.seconds > pieceSeconds * 1.5 else {
            return await cleaned(try await RemoteSTT.transcribe(data, filename: name, type: "audio/mpeg", localeID: localeID), name: name)
        }
        let cuts = [0] + quietCuts(url, every: pieceSeconds, total: mp3.seconds) + [mp3.seconds]
        var out = TimedTranscript(text: "", words: [])
        var again = 0
        for (from, to) in zip(cuts, cuts.dropFirst()) {
            var t = try await piece(mp3, from, to, name: name, localeID: localeID)
            if Repeats.loops(t) {
                again += 1
                t = TimedTranscript(text: "", words: [])
                var a = from
                while a < to {
                    let b = to - a < retrySeconds * 1.5 ? to : a + retrySeconds
                    append(try await piece(mp3, a, b, name: name, localeID: localeID), to: &t)
                    a = b
                }
            }
            append(t, to: &out)
        }
        await log("transcribed \(name) in \(cuts.count - 1) pieces" + (again > 0 ? ", \(again) read again a minute at a time" : ""))
        return await cleaned(out, name: name)
    }

    /// One stretch of the recording, its word times moved to where it starts.
    private static func piece(_ mp3: MP3Frames, _ from: Double, _ to: Double, name: String, localeID: String) async throws -> TimedTranscript {
        let slice = mp3.slice(from, to)
        guard !slice.data.isEmpty else { return TimedTranscript(text: "", words: []) }
        var t = try await RemoteSTT.transcribe(slice.data, filename: name, type: "audio/mpeg", localeID: localeID, timeout: 600)
        t.words = t.words.map { TimedWord(word: $0.word, start: $0.start + slice.start, end: $0.end + slice.start) }
        return t
    }

    private static func append(_ t: TimedTranscript, to out: inout TimedTranscript) {
        if !t.text.isEmpty { out.text += out.text.isEmpty ? t.text : " " + t.text }
        out.words += t.words
    }

    private static func cleaned(_ t: TimedTranscript, name: String) async -> TimedTranscript {
        let c = Repeats.cleaned(t)
        let words = t.words.count - c.words.count
        if words > 0 { await log("took out \(words) repeated words Whisper wrote in \(name)") }
        return c
    }

    private static func log(_ line: String) async { await MainActor.run { DiskLog.append(line) } }

    /// Cuts about every `every` seconds, each at the quietest tenth of a second in the twenty
    /// before it, so a word is not split between two pieces.
    static func quietCuts(_ url: URL, every: Double, total: Double) -> [Double] {
        let file = try? AVAudioFile(forReading: url)
        var cuts: [Double] = []
        var t = every
        while t < total - every / 2 {
            let at = file.flatMap { quietest($0, before: t, window: 20) } ?? t
            cuts.append(at)
            t = at + every
        }
        return cuts
    }

    private static func quietest(_ f: AVAudioFile, before t: Double, window: Double) -> Double? {
        let rate = f.processingFormat.sampleRate
        let from = max(0, t - window)
        f.framePosition = AVAudioFramePosition(from * rate)
        let n = AVAudioFrameCount((t - from) * rate)
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n),
              (try? f.read(into: buf, frameCount: n)) != nil, let ch = buf.floatChannelData?[0] else { return nil }
        let block = max(1, Int(rate / 10))
        var best: (energy: Float, at: Double)?
        var b = 0
        while b + block <= Int(buf.frameLength) {
            var e: Float = 0
            for i in b..<(b + block) { e += ch[i] * ch[i] }
            if e < (best?.energy ?? .infinity) { best = (e, from + Double(b + block / 2) / rate) }
            b += block
        }
        return best?.at
    }
}

/// The frames of an MP3, found by their headers: where each starts, and the seconds each
/// holds (the same throughout a recording). Enough to cut it on frame lines.
struct MP3Frames {
    let data: Data
    let starts: [Int]
    let frameSeconds: Double
    var seconds: Double { Double(starts.count) * frameSeconds }

    init?(_ data: Data) {
        var starts: [Int] = []
        var frameSeconds: Double?
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            var i = 0
            if p.count >= 10, p[0] == 0x49, p[1] == 0x44, p[2] == 0x33 {   // an ID3 tag first
                i = 10 + (Int(p[6] & 0x7F) << 21 | Int(p[7] & 0x7F) << 14 | Int(p[8] & 0x7F) << 7 | Int(p[9] & 0x7F))
            }
            while i + 4 <= p.count {
                guard p[i] == 0xFF, p[i + 1] & 0xE0 == 0xE0, let f = Self.header(p[i + 1], p[i + 2]) else { i += 1; continue }
                starts.append(i)
                if frameSeconds == nil { frameSeconds = f.seconds }
                i += f.length
            }
        }
        guard !starts.isEmpty, let frameSeconds else { return nil }
        self.data = data
        self.starts = starts
        self.frameSeconds = frameSeconds
    }

    /// Layer III only: the Pocket's MPEG-2 at 16 kHz, or anything else a phone might hold.
    private static func header(_ b1: UInt8, _ b2: UInt8) -> (length: Int, seconds: Double)? {
        let version = (b1 >> 3) & 3, layer = (b1 >> 1) & 3
        guard version != 1, layer == 1 else { return nil }
        let mpeg1 = version == 3
        let kbps = mpeg1 ? [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
                         : [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
        let r = Int(b2 >> 4), s = Int((b2 >> 2) & 3)
        guard r > 0, r < 15, s < 3 else { return nil }
        let base = [44_100, 48_000, 32_000][s]
        let rate = mpeg1 ? base : version == 2 ? base / 2 : base / 4
        let samples = mpeg1 ? 1152 : 576
        let length = samples / 8 * kbps[r] * 1000 / rate + Int((b2 >> 1) & 1)
        guard length > 4 else { return nil }
        return (length, Double(samples) / Double(rate))
    }

    /// The frames from `from` to `to` seconds, and where the first of them starts.
    func slice(_ from: Double, _ to: Double) -> (data: Data, start: Double) {
        let a = frame(at: from), b = frame(at: to)
        guard a < b else { return (Data(), Double(a) * frameSeconds) }
        let lo = data.startIndex + starts[a], hi = b < starts.count ? data.startIndex + starts[b] : data.endIndex
        return (data.subdata(in: lo..<hi), Double(a) * frameSeconds)
    }

    private func frame(at seconds: Double) -> Int { min(starts.count, max(0, Int((seconds / frameSeconds).rounded()))) }
}

/// Whisper's loop: a phrase of four words or more written three times running, or more.
/// Kept once, in the text and in the word times.
enum Repeats {
    /// Enough repeated to say the reading lost its place, not a phrase said again.
    static func loops(_ t: TimedTranscript) -> Bool {
        if !t.words.isEmpty { return drops(t.words.map { key($0.word) }, periods: 1...40).filter { $0 }.count >= 20 }
        return drops(sentences(t.text).map(key), periods: 1...6).filter { $0 }.count >= 3
    }

    static func cleaned(_ t: TimedTranscript) -> TimedTranscript {
        let s = sentences(t.text)
        let ds = drops(s.map(key), periods: 1...6)
        let dw = drops(t.words.map { key($0.word) }, periods: 1...40)
        guard ds.contains(true) || dw.contains(true) else { return t }
        return TimedTranscript(text: zip(s, ds).filter { !$0.1 }.map(\.0).joined(separator: " "),
                               words: zip(t.words, dw).filter { !$0.1 }.map(\.0))
    }

    /// For each key, whether it repeats what came before: of every unit of `periods` keys,
    /// four words or more, said three times running or more, all but the first.
    private static func drops(_ keys: [String], periods: ClosedRange<Int>) -> [Bool] {
        var sum = [0]
        for k in keys { sum.append(sum.last! + (k.isEmpty ? 0 : k.split(separator: " ").count)) }
        var drop = [Bool](repeating: false, count: keys.count)
        var i = 0
        next: while i < keys.count {
            for p in periods where i + 3 * p <= keys.count && sum[i + p] - sum[i] >= 4 {
                let unit = keys[i..<(i + p)]
                var n = 1
                while i + (n + 1) * p <= keys.count, keys[(i + n * p)..<(i + (n + 1) * p)].elementsEqual(unit) { n += 1 }
                if n >= 3 {
                    for j in (i + p)..<(i + n * p) { drop[j] = true }
                    i += n * p
                    continue next
                }
            }
            i += 1
        }
        return drop
    }

    /// Lower case, letters and digits, one space between words.
    private static func key(_ s: String) -> String {
        s.lowercased().split(separator: " ")
            .map { String($0.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init)) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current: [Substring] = []
        for w in text.split(separator: " ") {
            current.append(w)
            if let last = w.last, ".?!…".contains(last) { out.append(current.joined(separator: " ")); current = [] }
        }
        if !current.isEmpty { out.append(current.joined(separator: " ")) }
        return out
    }
}
