import Foundation
import FoundationModels

/// Which language model writes summaries and answers questions: Apple's on-device
/// model, or any OpenAI-compatible server (`DefaultServer`, from ble/.env, if set).
/// With a server, transcripts are sent to it.
struct LLMConfig: Sendable {
    var remote: Bool
    var url: String
    var model: String
    var key: String
    /// Ask reasoning models not to think first (`chat_template_kwargs.enable_thinking`).
    var noThinking: Bool
    /// Characters of transcript per request on the server.
    var contextChars: Int

    static let defaultURL = DefaultServer.url
    static let defaultModel = DefaultServer.llmModel
    static let defaultHost = URL(string: DefaultServer.url)?.host() ?? ""
    /// A server was configured at build time: use it by default, offer a reset to it.
    static let hasDefault = !DefaultServer.url.isEmpty

    /// The on-device model has a 4k-token window; a server is told its own size.
    var chunkChars: Int { remote ? max(contextChars, 4_000) : 6_000 }

    var host: String { URL(string: url)?.host() ?? url }
}

enum LLM {
    @MainActor static var config: LLMConfig {
        LLMConfig(remote: Prefs.llmRemote, url: Prefs.llmURL, model: Prefs.llmModel,
                  key: Keychain.get("llm.key") ?? "", noThinking: Prefs.llmNoThinking,
                  contextChars: Prefs.llmContextChars)
    }

    @MainActor static var key: String {
        get { Keychain.get("llm.key") ?? "" }
        set { newValue.isEmpty ? Keychain.delete("llm.key") : Keychain.set(newValue, for: "llm.key") }
    }

    /// Why the model cannot be used now, or nil if it can.
    @MainActor static var availability: String? {
        let c = config
        if c.remote {
            if URL(string: c.url)?.host() == nil { return "Set the server URL in Settings → Language model." }
            if c.model.isEmpty { return "Set the model name in Settings → Language model." }
            if c.key.isEmpty, LLMConfig.hasDefault, c.host == LLMConfig.defaultHost {
                return "Add your \(DefaultServer.name) key in Settings → Language model, or switch it to On this iPhone."
            }
            return nil
        }
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "This iPhone does not support Apple Intelligence. Use a server in Settings → Language model."
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in Settings, or use a server in Settings → Language model."
        case .unavailable(.modelNotReady): return "The on-device model is still downloading. Try again later."
        case .unavailable: return "The on-device model is unavailable."
        }
    }

    /// For footers: where the text is processed.
    @MainActor static var whereLabel: String {
        let c = config
        return c.remote ? "\(c.model) on \(c.host). Transcripts are sent to that server."
                        : "Apple's on-device model. Nothing leaves this iPhone."
    }

    static func complete(_ c: LLMConfig, instructions: String, prompt: String) async throws -> String {
        guard c.remote else {
            let session = LanguageModelSession(model: .default, instructions: instructions)
            return try await session.respond(to: prompt).content
        }
        guard let base = URL(string: c.url.trimmingCharacters(in: .whitespaces)) else { throw LLMError.badURL }
        var req = URLRequest(url: base.appending(path: "chat/completions"), timeoutInterval: 600)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !c.key.isEmpty { req.setValue("Bearer \(c.key)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = [
            "model": c.model,
            "temperature": 0.2,
            "messages": [["role": "system", "content": instructions], ["role": "user", "content": prompt]],
        ]
        if c.noThinking { body["chat_template_kwargs"] = ["enable_thinking": false] }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LLMError.http(status, String(decoding: data.prefix(300), as: UTF8.self))
        }
        struct Reply: Decodable {
            struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message }
            let choices: [Choice]
        }
        guard let text = try JSONDecoder().decode(Reply.self, from: data).choices.first?.message.content else {
            throw LLMError.empty
        }
        return stripThinking(text)
    }

    /// Drops a `<think>…</think>` block if the server returns one inline.
    static func stripThinking(_ s: String) -> String {
        guard let end = s.range(of: "</think>") else { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(s[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum LLMError: LocalizedError {
    case badURL, http(Int, String), empty

    var errorDescription: String? {
        switch self {
        case .badURL: "The server URL is not valid."
        case .http(401, _), .http(403, _): "The server rejected the key (check Settings → Language model)."
        case .http(let code, let body): "The server returned \(code): \(body)"
        case .empty: "The server returned no text."
        }
    }
}

/// Speech to text on an OpenAI-compatible `/audio/transcriptions` endpoint, by
/// e.g. whisper.cpp or OpenAI. MP3 is sent as recorded (whisper.cpp decodes it;
/// it cannot decode m4a).
enum RemoteSTT {
    static let defaultModel = DefaultServer.sttModel

    @MainActor static var key: String {
        get { Keychain.get("stt.key") ?? "" }
        set { newValue.isEmpty ? Keychain.delete("stt.key") : Keychain.set(newValue, for: "stt.key") }
    }

    @MainActor static var availability: String? {
        guard let host = URL(string: Prefs.sttURL)?.host() else { return "Set the server URL in Settings → Speech to text." }
        if Prefs.sttModel.isEmpty { return "Set the model name in Settings → Speech to text." }
        if key.isEmpty, LLM.key.isEmpty, LLMConfig.hasDefault, host == LLMConfig.defaultHost {
            return "Add your \(DefaultServer.name) key in Settings → Speech to text, or switch it to On this iPhone."
        }
        return nil
    }

    static func transcribe(_ audio: URL, localeID: String) async throws -> TimedTranscript {
        try await transcribe(try Data(contentsOf: audio), filename: audio.lastPathComponent,
                             type: "audio/mpeg", localeID: localeID)
    }

    /// Sends one second of silence, to check the URL, key and model.
    static func test() async throws -> String {
        var wav = Data("RIFF".utf8)
        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        let samples = 16_000
        le(UInt32(36 + samples * 2)); wav.append(Data("WAVEfmt ".utf8))
        le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(16_000)); le(UInt32(32_000)); le(UInt16(2)); le(UInt16(16))
        wav.append(Data("data".utf8)); le(UInt32(samples * 2)); wav.append(Data(count: samples * 2))
        let text = try await transcribe(wav, filename: "test.wav", type: "audio/wav", localeID: "en").text
        return "Transcription works\(text.isEmpty ? "" : " (heard: \(text))")."
    }

    /// Text plus word times (`verbose_json` with word timestamps), for speakers.
    static func transcribe(_ audio: Data, filename: String, type: String, localeID: String,
                           timeout: TimeInterval = 1_800) async throws -> TimedTranscript {
        if let why = await RemoteSTT.availability { throw AIError.modelUnavailable(why) }
        let (base, model, key) = await MainActor.run {
            // An empty key falls back to the language model's key (same server by default).
            (Prefs.sttURL, Prefs.sttModel, RemoteSTT.key.isEmpty ? LLM.key : RemoteSTT.key)
        }
        guard let url = URL(string: base.trimmingCharacters(in: .whitespaces))?.appending(path: "audio/transcriptions")
        else { throw LLMError.badURL }

        let boundary = "pp-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("response_format", "verbose_json")
        field("timestamp_granularities[]", "word")
        if localeID != Languages.auto, let code = Locale(identifier: localeID).language.languageCode?.identifier {
            field("language", code)
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(type)\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }

        let (data, response) = try await URLSession.shared.upload(for: req, from: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LLMError.http(status, String(decoding: data.prefix(300), as: UTF8.self))
        }
        struct Reply: Decodable {
            struct Word: Decodable { let word: String; let start: Double; let end: Double }
            let text: String
            let words: [Word]?
        }
        let r = try JSONDecoder().decode(Reply.self, from: data)
        let text = r.text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        return TimedTranscript(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                          words: (r.words ?? []).map { TimedWord(word: $0.word.trimmingCharacters(in: .whitespaces), start: $0.start, end: $0.end) })
    }
}
