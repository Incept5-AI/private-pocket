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

    /// Asks the server for its model list, with a short timeout. Any HTTP answer below
    /// 500 counts, since a key may be missing; no answer at all does not.
    func check(force: Bool = false) async {
        let url = Prefs.llmURL.trimmingCharacters(in: .whitespaces)
        guard let base = URL(string: url), base.host() != nil else {
            reachable = nil
            latencyMs = nil
            return
        }
        if !force, let t = checkedAt, Date().timeIntervalSince(t) < 30 { return }
        guard !checking else { return }
        checking = true
        defer { checking = false }
        var req = URLRequest(url: base.appending(path: "models"), timeoutInterval: 4)
        let key = LLM.key
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let t0 = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            reachable = status > 0 && status < 500
            latencyMs = Int(Date().timeIntervalSince(t0) * 1000)
        } catch {
            reachable = false
            latencyMs = nil
        }
        checkedAt = Date()
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
        .task { await status.check() }
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
