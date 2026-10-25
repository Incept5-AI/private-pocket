import Accelerate
import AVFoundation
import Foundation

/// A transcript with word times, so it can be split by speaker.
struct TimedTranscript {
    var text: String
    var words: [TimedWord]
}

struct TimedWord: Codable, Hashable {
    var word: String
    var start: Double
    var end: Double
}

struct SpeakerSegment: Codable, Hashable {
    var start: Double
    var end: Double
    var speaker: Int
}

/// Consecutive words from one speaker.
struct Turn: Codable, Hashable, Identifiable {
    var speaker: Int
    var start: Double
    var end: Double
    var text: String
    var id: Double { start }
}

/// Who spoke when, from a diarisation server, matched to word times. Transcripts
/// read "[MM:SS] Speaker 1: …", speakers numbered by first turn.
enum Speakers {
    static let nearest = 1.5     // an uncovered word joins a segment this close
    static let turnGap = 2.0     // a longer pause starts a new turn

    static func align(_ words: [TimedWord], _ segments: [SpeakerSegment]) -> [Turn] {
        guard !words.isEmpty, !segments.isEmpty else { return [] }
        var turns: [Turn] = []
        var previous = segments[0].speaker
        for w in words {
            let mid = (w.start + w.end) / 2
            // Where segments overlap, the narrowest wins: a short interjection inside
            // a long turn usually belongs to the interjector.
            let active = segments.filter { $0.start <= mid && mid <= $0.end }
            var speaker = active.min { ($0.end - $0.start) < ($1.end - $1.start) }?.speaker
            if speaker == nil {
                let close = segments.min { distance(mid, $0) < distance(mid, $1) }
                if let c = close, distance(mid, c) <= nearest { speaker = c.speaker }
            }
            let s = speaker ?? previous
            previous = s
            if var last = turns.last, last.speaker == s, w.start - last.end < turnGap {
                last.text += " " + w.word
                last.end = w.end
                turns[turns.count - 1] = last
            } else {
                turns.append(Turn(speaker: s, start: w.start, end: w.end, text: w.word))
            }
        }
        return renumber(turns)
    }

    /// Speakers numbered 0, 1, 2… in order of first turn.
    static func renumber(_ turns: [Turn]) -> [Turn] {
        var map: [Int: Int] = [:]
        return turns.map { t in
            var t = t
            if map[t.speaker] == nil { map[t.speaker] = map.count }
            t.speaker = map[t.speaker]!
            return t
        }
    }

    static func count(_ turns: [Turn]) -> Int { Set(turns.map(\.speaker)).count }

    /// How loud each voice is on the recording: the median level, in dB, of the half seconds
    /// of its turns that hold sound, for voices heard for five seconds or more. The wearer's,
    /// nearest the microphone, is usually far the loudest.
    static func levels(url: URL, turns: [Turn]) -> [Int: Double] {
        guard !turns.isEmpty, let file = try? AVAudioFile(forReading: url) else { return [:] }
        let rate = file.processingFormat.sampleRate
        let per = AVAudioFrameCount(rate / 2)
        guard per > 0, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: per) else { return [:] }
        let sorted = turns.sorted { $0.start < $1.start }
        var heard: [Int: [Double]] = [:]
        var t = 0.0, i = 0
        while true {
            do { try file.read(into: buf, frameCount: per) } catch { break }
            let n = Int(buf.frameLength)
            guard n > 0, let ch = buf.floatChannelData?[0] else { break }
            let mid = t + Double(n) / rate / 2
            t += Double(n) / rate
            while i < sorted.count, sorted[i].end < mid { i += 1 }
            guard i < sorted.count, sorted[i].start <= mid else { continue }
            var power: Float = 0
            vDSP_measqv(ch, 1, &power, vDSP_Length(n))
            let db = 10 * log10(Double(power) + 1e-12)
            if db > -55 { heard[sorted[i].speaker, default: []].append(db) }
        }
        return heard.compactMapValues { v in v.count >= 10 ? v.sorted()[v.count / 2] : nil }
    }

    /// The voice louder than every other by `gap` dB, which is the wearer's, or nil: a
    /// recorder lying between people hears no one that much nearer.
    static func wearer(_ levels: [Int: Double], gap: Double = 6) -> Int? {
        let ranked = levels.sorted { $0.value > $1.value }
        guard ranked.count > 1, ranked[0].value - ranked[1].value >= gap else { return nil }
        return ranked[0].key
    }

    static func name(_ speaker: Int, _ names: [String: String]?) -> String {
        names?[String(speaker)].flatMap { $0.isEmpty ? nil : $0 } ?? "Speaker \(speaker + 1)"
    }

    static func stamp(_ t: Double) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// The plain-text form given to the language model and shared.
    static func text(_ turns: [Turn], names: [String: String]?) -> String {
        turns.map { "[\(stamp($0.start))] \(name($0.speaker, names)): \($0.text)" }.joined(separator: "\n")
    }

    private static func distance(_ t: Double, _ s: SpeakerSegment) -> Double {
        t < s.start ? s.start - t : t > s.end ? t - s.end : 0
    }
}

/// `POST <base>/audio/diarize` (multipart `file` + `preset`) returning
/// `{segments: [{start, end, speaker}]}`. Speaker ids only hold within one request,
/// so the whole recording goes each time. Several base URLs can be given; they are
/// tried in order.
enum Diarizer {
    static let defaultURLs = DefaultServer.diarizeURLs

    @MainActor static var enabled: Bool { Prefs.diarize }

    static func diarize(_ audio: Data, filename: String = "audio.mp3") async throws -> [SpeakerSegment] {
        let (urls, key) = await MainActor.run {
            (Prefs.diarizeURLs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
             RemoteSTT.key.isEmpty ? LLM.key : RemoteSTT.key)
        }
        var lastError: Error = DiarizeError.noServer
        for base in urls where !base.isEmpty {
            guard let url = URL(string: base)?.appending(path: "audio/diarize") else { continue }
            let boundary = "pp-\(UUID().uuidString)"
            var body = Data()
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"preset\"\r\n\r\noffline\r\n".utf8))
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: audio/mpeg\r\n\r\n".utf8))
            body.append(audio)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            var req = URLRequest(url: url, timeoutInterval: 900)
            req.httpMethod = "POST"
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            do {
                let (data, response) = try await URLSession.shared.upload(for: req, from: body)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401 || status == 403 { throw LLMError.http(status, "") }
                guard (200..<300).contains(status) else {
                    lastError = LLMError.http(status, String(decoding: data.prefix(200), as: UTF8.self))
                    continue   // 404 / 5xx: this box has no diarizer, try the next
                }
                await MainActor.run { DiskLog.append("diarize reply: " + shape(data)) }
                struct Reply: Decodable { let segments: [SpeakerSegment] }
                return try JSONDecoder().decode(Reply.self, from: data).segments
            } catch let e as URLError {
                lastError = e   // not reachable (off a private network?): try the next
            }
        }
        throw lastError is URLError ? DiarizeError.unreachable : lastError
    }

    /// What a reply holds, for the log: its keys and how many of each, and the keys of a
    /// segment, never the values. Says whether the server sends anything beyond segments,
    /// such as a voice print per speaker.
    static func shape(_ data: Data) -> String {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "not an object" }
        return o.keys.sorted().map { k -> String in
            switch o[k] {
            case let a as [Any]:
                let inner = (a.first as? [String: Any]).map { " of {" + $0.keys.sorted().joined(separator: ",") + "}" }
                    ?? (a.first as? [Any]).map { " of [\($0.count)]" } ?? ""
                return "\(k)[\(a.count)]\(inner)"
            case let d as [String: Any]:
                return "\(k){" + d.keys.sorted().prefix(8).joined(separator: ",") + (d.count > 8 ? ",…" : "") + "}"
            default:
                return k
            }
        }.joined(separator: " ")
    }
}

enum DiarizeError: LocalizedError {
    case noServer, unreachable

    var errorDescription: String? {
        switch self {
        case .noServer: "No diarisation server set (Settings → Speech to text)."
        case .unreachable: "The diarisation server is not reachable. If it is on a private network (e.g. Tailscale), connect this iPhone to it."
        }
    }
}
