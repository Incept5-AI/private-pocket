import Foundation
import SwiftUI

/// Is the user's own server (a DGX Spark over Tailscale, say) answering right now?
/// Checked when the app comes to the foreground and before each job. With "use it
/// when reachable" on, a server that does not answer means everything runs on the phone.
@MainActor
final class ServerStatus: ObservableObject {
    static let shared = ServerStatus()

    @Published private(set) var reachable: Bool?
    @Published private(set) var latencyMs: Int?
    @Published private(set) var checkedAt: Date?
    @Published private(set) var checking = false
    /// The models the server listed when it last answered (GET /models).
    @Published private(set) var models: [String] = []

    /// Remote work is allowed: the gate is off, or the server answered last time.
    var allowsRemote: Bool { !Prefs.serverWhenReachable || reachable != false }

    var label: String {
        if checking { return "Checking…" }
        switch reachable {
        case .some(true): return latencyMs.map { "Reachable · \($0) ms" } ?? "Reachable"
        case .some(false): return "Not reachable"
        case nil: return Prefs.llmURL.trimmingCharacters(in: .whitespaces).isEmpty ? "No address" : "Not checked yet"
        }
    }

    /// The check under way, which a second caller waits for rather than going on without an
    /// answer (that read a moment on the server, or the phone, before the server had said).
    private var inFlight: Task<Void, Never>?

    /// Asks the server for its model list. Any HTTP answer below 500 counts, since a key may
    /// be missing; no answer at all does not. Ten seconds: Tailscale on the phone takes a
    /// few to wake, and four called a server away that was only waking it.
    func check(force: Bool = false) async {
        if let t = inFlight { await t.value; return }
        let url = Prefs.llmURL.trimmingCharacters(in: .whitespaces)
        guard let base = URL(string: url), base.host() != nil else {
            reachable = nil
            latencyMs = nil
            return
        }
        if !force, let t = checkedAt, Date().timeIntervalSince(t) < 30 { return }
        let t = Task { await ask(base) }
        inFlight = t
        await t.value
        inFlight = nil
    }

    private func ask(_ base: URL) async {
        checking = true
        defer { checking = false }
        var req = URLRequest(url: base.appending(path: "models"), timeoutInterval: 10)
        let key = LLM.key
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let t0 = Date()
        let before = reachable
        var why = ""
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            reachable = status > 0 && status < 500
            latencyMs = Int(Date().timeIntervalSince(t0) * 1000)
            if (200..<300).contains(status) { models = ModelList.parse(data) }
        } catch {
            reachable = false
            latencyMs = nil
            why = " (\(error.localizedDescription))"
        }
        checkedAt = Date()
        if reachable != before { DiskLog.append("server: " + (reachable == true ? "answering" : "not answering" + why)) }
    }
}

/// Settings → Your own server: one address and key for speech to text, the language
/// model and speakers, used when it answers and left alone when it does not.
struct ServerView: View {
    @AppStorage("llmURL") private var url = LLMConfig.defaultURL
    @AppStorage("llmModel") private var llmModel = LLMConfig.defaultModel
    @AppStorage("sttModel") private var sttModel = RemoteSTT.defaultModel
    @AppStorage("sttRemote") private var sttRemote = LLMConfig.hasDefault
    @AppStorage("llmRemote") private var llmRemote = LLMConfig.hasDefault
    @AppStorage("diarize") private var diarize = !Diarizer.defaultURLs.isEmpty
    @AppStorage("serverWhenReachable") private var whenReachable = false
    @ObservedObject private var status = ServerStatus.shared
    @State private var key = LLM.key
    @State private var showKey = false

    var body: some View {
        Form {
            Section {
                TextField("Address, e.g. http://spark:8000/v1", text: $url)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                HStack {
                    Group {
                        if showKey { TextField("API key", text: $key) } else { SecureField("API key", text: $key) }
                    }
                    .textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
                    Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                }
                if LLMConfig.hasDefault {
                    Button("Reset to \(DefaultServer.name)") {
                        url = LLMConfig.defaultURL
                        llmModel = LLMConfig.defaultModel
                        sttModel = RemoteSTT.defaultModel
                    }
                }
            } header: { Text("Your own server") } footer: {
                Text("A DGX Spark or any OpenAI-compatible server, over Tailscale or your own network: bigger models, speakers, any language. Nothing goes to it until you turn it on below. The address ends in /v1.")
            }
            Section {
                HStack(spacing: 10) {
                    Circle()
                        .fill(status.reachable == true ? Brand.good : status.reachable == false ? Brand.bad : Brand.dim)
                        .frame(width: 10, height: 10)
                    Text(status.label)
                    Spacer()
                    Button("Check") { Task { await status.check(force: true) } }
                        .disabled(status.checking || url.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section {
                Toggle("Use it when reachable", isOn: $whenReachable)
                    .onChange(of: whenReachable) { apply() }
            } footer: {
                Text(whenReachable
                     ? "While the server answers, speech to text, the language model and speakers run there, and the screens say so. When it does not, everything runs on this iPhone."
                     : "Off: everything runs on this iPhone. Each part can still be pointed at a server by hand, under Advanced.")
            }
            Section {
                if status.models.isEmpty {
                    TextField("Language model, e.g. qwen3", text: $llmModel)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Speech to text, e.g. whisper-large-v3", text: $sttModel)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } else {
                    Picker("Language model", selection: $llmModel) {
                        ForEach(ModelList.ordered(status.models, speech: false, keeping: llmModel), id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.navigationLink)
                    Picker("Speech to text", selection: $sttModel) {
                        ForEach(ModelList.ordered(status.models, speech: true, keeping: sttModel), id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.navigationLink)
                }
            } header: { Text("Models") } footer: {
                Text(status.models.isEmpty
                     ? "Once the server answers, it lists its models here and these become pickers. Until then, type the names."
                     : "\(status.models.count) listed by the server. Speech models come first for speech to text, the rest first for the language model.")
            }
            Section("What it does") {
                LabeledContent("Speech to text", value: sttRemote ? sttModel : "On this iPhone")
                LabeledContent("Language model", value: llmRemote ? llmModel : "On this iPhone")
                LabeledContent("Speakers", value: diarize ? "On the server" : "Off")
            }
            Section("Advanced") {
                NavigationLink("Speech to text") { STTSettingsView() }
                NavigationLink("Language model") { LLMSettingsView() }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Brand.ground)
        .navigationTitle("Your own server")
        .onChange(of: url) {
            Prefs.sttURL = url
            if whenReachable { Prefs.diarizeURLs = url }
        }
        .onChange(of: key) { LLM.key = key.trimmingCharacters(in: .whitespacesAndNewlines) }
        .onChange(of: status.models, initial: true) { fillEmptyChoices() }
        .task { await status.check() }
    }

    /// A choice left empty takes the first fitting model the server lists.
    private func fillEmptyChoices() {
        guard !status.models.isEmpty else { return }
        if llmModel.isEmpty, let m = ModelList.ordered(status.models, speech: false, keeping: "").first { llmModel = m }
        if sttModel.isEmpty, let m = ModelList.ordered(status.models, speech: true, keeping: "").first { sttModel = m }
    }

    private func apply() {
        sttRemote = whenReachable
        llmRemote = whenReachable
        Prefs.sttURL = url
        if whenReachable {
            diarize = true
            Prefs.diarizeURLs = url
        }
        Task { await status.check(force: true) }
    }
}

/// The models an OpenAI-compatible server offers: `GET <base>/models`, answered as
/// `{"data":[{"id":…}]}`, or by some servers as a bare array. Speech-to-text models are
/// told apart by name, so each picker can lead with the likely ones.
enum ModelList {
    static func fetch(url: String, key: String) async throws -> [String] {
        guard let base = URL(string: url.trimmingCharacters(in: .whitespaces)), base.host() != nil else { return [] }
        var req = URLRequest(url: base.appending(path: "models"), timeoutInterval: 6)
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw LLMError.http(status, String(decoding: data.prefix(200), as: UTF8.self)) }
        return parse(data)
    }

    static func parse(_ data: Data) -> [String] {
        struct Entry: Decodable { let id: String }
        struct List: Decodable { let data: [Entry] }
        if let l = try? JSONDecoder().decode(List.self, from: data) { return l.data.map(\.id) }
        if let a = try? JSONDecoder().decode([Entry].self, from: data) { return a.map(\.id) }
        if let a = try? JSONDecoder().decode([String].self, from: data) { return a }
        return []
    }

    static func isSpeech(_ id: String) -> Bool {
        let s = id.lowercased()
        return ["whisper", "parakeet", "canary", "voxtral", "wav2vec", "speech", "stt", "transcri", "asr"].contains { s.contains($0) }
    }

    /// Speech models first (or last), and the current choice kept even if the server
    /// no longer lists it, so a picker never shows an empty selection.
    static func ordered(_ ids: [String], speech: Bool, keeping current: String) -> [String] {
        var out = ids.filter { isSpeech($0) == speech } + ids.filter { isSpeech($0) != speech }
        if !current.isEmpty, !out.contains(current) { out.insert(current, at: 0) }
        return out
    }
}
