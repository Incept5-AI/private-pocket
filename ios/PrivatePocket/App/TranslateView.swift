import SwiftUI
import Translation

/// Listen and translate: what is said near the iPhone, phrase by phrase, in your language.
struct TranslateView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var t = LiveTranslator()
    @AppStorage("translateInput") private var audioIn = LiveTranslator.Input.mic
    @AppStorage("translateFrom") private var from = "nl"
    @AppStorage("translateTo") private var to = "en"
    @AppStorage("translateMode") private var mode = LiveTranslator.Mode.device
    @AppStorage("translateSpeak") private var speak = false
    @State private var config: TranslationSession.Configuration?

    private var serverReason: String? { RemoteSTT.availability ?? (LLM.config.remote ? LLM.availability : nil) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                Divider()
                ScrollViewReader { scroll in
                    List {
                        if t.lines.isEmpty, t.partial.isEmpty {
                            ContentUnavailableView("Listen and translate", systemImage: "character.bubble",
                                                   description: Text(audioIn == .pocket
                                                                    ? "Put the Pocket near whoever is speaking \(LiveTranslator.name(from)) and tap Listen. Each phrase appears in \(LiveTranslator.name(to)) after they pause."
                                                                    : "Tap Listen and hold the iPhone towards whoever is speaking \(LiveTranslator.name(from)). Each phrase appears in \(LiveTranslator.name(to)) after they pause."))
                                .listRowSeparator(.hidden)
                        }
                        ForEach(t.lines) { line in
                            LineRow(line: line).id(line.id)
                        }
                        if !t.partial.isEmpty {
                            Text(t.partial).foregroundStyle(.secondary).italic().id("partial")
                        }
                    }
                    .listStyle(.plain)
                    .onChange(of: t.lines.count) { withAnimation { scroll.scrollTo(t.lines.last?.id, anchor: .bottom) } }
                    .onChange(of: t.partial) { if !t.partial.isEmpty { scroll.scrollTo("partial", anchor: .bottom) } }
                }
                Divider()
                bottomBar
            }
            .navigationTitle("Translate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Read translations aloud", isOn: $speak)
                        Button {
                            apply()
                            Task { await t.prepareOffline() }
                        } label: {
                            Label("Get ready for offline use", systemImage: "arrow.down.circle")
                        }
                        if !t.lines.isEmpty {
                            ShareLink(item: t.transcript) { Label("Share conversation", systemImage: "square.and.arrow.up") }
                            Button("Clear", role: .destructive) { t.clear() }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            // Apple Translation hands out its session only here; it asks to download the
            // languages the first time.
            .translationTask(config) { session in
                for await (id, text) in t.appleQueue {
                    if text.isEmpty { try? await session.prepareTranslation(); continue }
                    do {
                        let r = try await session.translate(text)
                        t.translated(id, .success(r.targetText))
                    } catch {
                        t.translated(id, .failure(error))
                    }
                }
            }
            .onAppear { apply() }
            .onChange(of: from) { restart() }
            .onChange(of: to) { restart() }
            .onChange(of: mode) { restart() }
            .onChange(of: audioIn) { restart() }
            .onChange(of: speak) { t.speak = speak }
            .onDisappear { t.stop(); UIApplication.shared.isIdleTimerDisabled = false }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                languageMenu($from)
                Button {
                    (from, to) = (to, from)
                } label: { Image(systemName: "arrow.left.arrow.right") }
                .buttonStyle(.bordered)
                .accessibilityLabel("Swap languages")
                languageMenu($to)
            }
            Picker("Listen with", selection: $audioIn) {
                ForEach(LiveTranslator.Input.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Where", selection: $mode) {
                ForEach(LiveTranslator.Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if audioIn == .pocket {
                Text(model.pocketCanStream
                     ? (model.pocketRecording ? "The Pocket is recording: its stream is translated." : "Listen starts a recording on the Pocket; Stop ends it. The recording is saved like any other.")
                     : "Connect the Pocket on the Recorder tab first.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(mode == .device
                 ? "\(OnDeviceSpeech.supports(from) ? "Parakeet" : "Apple's speech recognition") and Apple Translation. Offline once downloaded (⋯ → Get ready for offline use); nothing leaves the phone."
                 : serverReason ?? "Each phrase goes to \(Prefs.sttModel) and \(LLM.config.remote ? LLM.config.model : "the on-device model") after a pause. More natural translations; needs a connection.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
    }

    private func languageMenu(_ code: Binding<String>) -> some View {
        Menu {
            Picker("Language", selection: code) {
                ForEach(LiveTranslator.languages, id: \.self) { Text(LiveTranslator.name($0)).tag($0) }
            }
        } label: {
            Text(LiveTranslator.name(code.wrappedValue)).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            if let e = t.error { Text(e).font(.footnote).foregroundStyle(.red) }
            if let s = t.status { Text(s).font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 16) {
                Gauge(value: Double(t.level)) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(t.listening ? .green : .gray)
                    .frame(maxWidth: 120)
                Button {
                    if t.listening {
                        t.stop()
                        UIApplication.shared.isIdleTimerDisabled = false
                    } else {
                        apply()
                        UIApplication.shared.isIdleTimerDisabled = true
                        Task { await t.start(model: model) }
                    }
                } label: {
                    Label(t.listening ? "Stop" : "Listen", systemImage: t.listening ? "stop.fill" : "mic.fill")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .tint(t.listening ? .red : .accentColor)
                .controlSize(.large)
                .disabled(!t.listening && ((mode == .server && serverReason != nil) || (audioIn == .pocket && !model.pocketCanStream)))
            }
        }
        .padding()
    }

    private func apply() {
        t.source = from
        t.target = to
        t.mode = mode
        t.audioIn = audioIn
        t.speak = speak
        let c = TranslationSession.Configuration(source: Locale.Language(identifier: from), target: Locale.Language(identifier: to))
        if config?.source != c.source || config?.target != c.target { config = c }
    }

    private func restart() {
        let was = t.listening
        t.stop()
        apply()
        if was { Task { await t.start(model: model) } }
    }
}

private struct LineRow: View {
    let line: LiveTranslator.Line

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let tr = line.translation {
                Text(tr).font(.title3.weight(.medium))
            } else if let f = line.failed {
                Label(f, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(line.original).font(.callout).foregroundStyle(.secondary)
            Text(line.time.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
        }
        .textSelection(.enabled)
        .padding(.vertical, 4)
    }
}
