import CoreLocation
import Speech
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var devices: DeviceStore
    @State private var exportURL: URL?
    @State private var exporting = false
    @State private var exportFailed = false
    @EnvironmentObject var locator: Locator
    @State private var adding = false
    @State private var locale = Prefs.transcriptionLocale
    @State private var favourites = Prefs.favouriteLocales
    @State private var instructions = Prefs.summaryInstructions
    @State private var tagLocation = Prefs.tagLocation
    @State private var lookUpNames = Prefs.lookUpPlaceNames
    @AppStorage("llmRemote") private var llmRemote = LLMConfig.hasDefault
    @AppStorage("llmModel") private var llmModel = LLMConfig.defaultModel
    @AppStorage("sttRemote") private var sttRemote = LLMConfig.hasDefault
    @State private var stayConnected = Prefs.stayConnected
    @AppStorage("sttModel") private var sttModel = RemoteSTT.defaultModel
    @AppStorage("localEngine") private var localEngine = LocalEngine.parakeet
    @AppStorage("autoAnalyse") private var autoAnalyse = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(devices.devices) { d in
                        NavigationLink { DeviceEditor(device: d) } label: {
                            VStack(alignment: .leading) {
                                Text(d.name)
                                Text(d.advertisedName).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button { adding = true } label: { Label("Add device", systemImage: "plus") }
                    Toggle("Stay connected", isOn: $stayConnected)
                        .onChange(of: stayConnected) { Prefs.stayConnected = stayConnected }
                    NavigationLink { USBView() } label: {
                        Label("USB drive: free up space", systemImage: "externaldrive")
                    }
                } header: { Text("Devices") } footer: {
                    Text("Each Pocket gets its own key when paired, and its own recordings folder. Stay connected keeps the link up, also in the background, so recordings stream in as they are made. Deleting recordings from a Pocket needs the USB cable.")
                }

                Section {
                    NavigationLink { STTSettingsView() } label: {
                        LabeledContent("Speech to text", value: sttRemote ? sttModel : localEngine == .parakeet ? "Parakeet on this iPhone" : "On this iPhone")
                    }
                    NavigationLink { LLMSettingsView() } label: {
                        LabeledContent("Language model", value: llmRemote ? llmModel : "On this iPhone")
                    }
                } header: { Text("Processing") } footer: {
                    Text(LLMConfig.hasDefault
                         ? "Each can run on this iPhone or on a server (\(DefaultServer.name) by default). Live transcripts and speakers are under Speech to text."
                         : "Each runs on this iPhone unless you set a server. Live transcripts and speakers are under Speech to text.")
                }

                Section {
                    Picker("Default", selection: $locale) {
                        ForEach(((Prefs.canDetectLanguage ? [Languages.auto] : []) + [locale] + favourites).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } },
                                id: \.self) { Text(Languages.name($0)).tag($0) }
                    }
                    .onChange(of: locale) { Prefs.transcriptionLocale = locale }
                    NavigationLink {
                        LanguagesView(favourites: $favourites)
                    } label: {
                        LabeledContent("Languages to offer", value: favourites.map(Languages.name).joined(separator: ", "))
                    }
                } header: { Text("Transcription language") } footer: {
                    Text(sttRemote || localEngine == .parakeet
                         ? "\(sttRemote ? "Whisper on the server" : "Parakeet") can detect the language, or you can name it. Each recording can be transcribed again in another language from its page."
                         : "Each recording can be transcribed in any of these; pick the language on the recording. On-device recognition cannot detect the language itself. Each language's model downloads once, then works offline.")
                }

                Section {
                    Toggle("Tag recordings with location", isOn: $tagLocation)
                        .onChange(of: tagLocation) {
                            Prefs.tagLocation = tagLocation
                            if tagLocation { locator.requestPermission() }
                        }
                    Toggle("Look up place names", isOn: $lookUpNames)
                        .onChange(of: lookUpNames) { Prefs.lookUpPlaceNames = lookUpNames }
                        .disabled(!tagLocation)
                    if tagLocation, locator.authorization == .denied || locator.authorization == .restricted {
                        Button("Allow location in iOS Settings") {
                            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                        }
                    }
                } header: { Text("Location") } footer: {
                    Text("The Pocket has no GPS, so the phone's location is used: where it was when a recording started (if connected), or when it was downloaded within 15 minutes of finishing. Place names come from Apple's geocoder, which receives the coordinates; turn that off to keep coordinates only.")
                }

                Section {
                    Toggle("Analyse after transcribing", isOn: $autoAnalyse)
                    TextEditor(text: $instructions)
                        .frame(minHeight: 140)
                        .font(.callout)
                        .onChange(of: instructions) { Prefs.summaryInstructions = instructions }
                    Button("Reset to default") { instructions = Prefs.defaultSummaryInstructions }
                } header: { Text("Analysis") } footer: {
                    Text((Summariser.availability ?? "Sent with each transcript to \(LLM.whereLabel)") +
                         " The default asks for an overview, who is who, key points with times, decisions, action items, open questions and the dynamics, and the app offers the speaker names it finds. Of the server models tried, DeepSeek V4.1 Flash did this best.")
                }

                Section {
                    if let url = exportURL {
                        ShareLink(item: url) { Label("Share the export", systemImage: "square.and.arrow.up") }
                    } else {
                        Button {
                            Task {
                                exporting = true
                                exportURL = try? await model.exportAll()
                                exportFailed = exportURL == nil
                                exporting = false
                            }
                        } label: {
                            HStack { Label("Export everything", systemImage: "archivebox"); if exporting { Spacer(); ProgressView() } }
                        }
                        .disabled(exporting)
                    }
                } header: { Text("Recordings") } footer: {
                    Text(exportFailed ? "The export couldn't be made. Try again in a moment."
                                      : "Every recording with its transcript and summary, as one zip, to keep somewhere else or move to another phone.")
                }

                Section("Privacy") {
                    Text("Recordings are kept on this iPhone (Files → On My iPhone → Private Pocket) and reach it over Bluetooth, never Pocket's cloud. " +
                         (sttRemote ? "Audio is uploaded to the speech-to-text server for transcription. " : "Transcription runs on this iPhone. ") +
                         (llmRemote ? "Transcripts are sent to the language-model server for summaries and questions. " : "Summaries and questions run on this iPhone. ") +
                         "Other network requests: Apple's one-off speech model downloads and, if on, place-name lookups.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $adding) { AddDeviceSheet() }
        }
    }
}

/// URL, model and key for an OpenAI-compatible server, with a reset to the build's default server.
struct ServerFields: View {
    @Binding var url: String
    @Binding var model: String
    @Binding var key: String
    var models: [String] = []
    var modelExample = "model name"
    var keyPrompt = "API key"
    let reset: () -> Void
    @State private var showKey = false

    var body: some View {
        TextField("URL, e.g. https://llm.example.com/v1", text: $url)
            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        HStack {
            TextField("Model, e.g. \(modelExample)", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
            if !models.isEmpty {
                Menu {
                    ForEach(models, id: \.self) { m in Button(m) { model = m } }
                } label: { Image(systemName: "chevron.up.chevron.down") }
            }
        }
        HStack {
            Group {
                if showKey { TextField(keyPrompt, text: $key) } else { SecureField(keyPrompt, text: $key) }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
            Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }
                .buttonStyle(.borderless)
        }
        if LLMConfig.hasDefault { Button("Reset to \(DefaultServer.name)", action: reset) }
    }
}

/// Runs a check and shows the result under a Test button.
struct TestRow: View {
    let disabledReason: String?
    let run: () async throws -> String
    @State private var result: String?
    @State private var testing = false

    var body: some View {
        Section {
            Button {
                testing = true
                result = nil
                Task {
                    do { result = "✓ " + (try await run()) } catch { result = "✗ " + error.localizedDescription }
                    testing = false
                }
            } label: {
                HStack { Text("Test"); if testing { Spacer(); ProgressView() } }
            }
            .disabled(testing || disabledReason != nil)
            if let result { Text(result).font(.callout).textSelection(.enabled) }
        } footer: {
            if let disabledReason { Text(disabledReason) }
        }
    }
}

/// On-device speech recognition or a Whisper server.
struct STTSettingsView: View {
    @AppStorage("sttRemote") private var remote = LLMConfig.hasDefault
    @AppStorage("sttURL") private var url = LLMConfig.defaultURL
    @AppStorage("sttModel") private var model = RemoteSTT.defaultModel
    @AppStorage("liveTranscript") private var liveTranscript = true
    @AppStorage("diarize") private var diarize = true
    @AppStorage("diarizeOnDevice") private var diarizeOnDevice = true
    @AppStorage("diarizeURLs") private var diarizeURLs = Diarizer.defaultURLs
    @AppStorage("localEngine") private var engine = LocalEngine.parakeet
    @State private var key = RemoteSTT.key

    var body: some View {
        Form {
            Section {
                Picker("Use", selection: $remote) {
                    Text("On this iPhone").tag(false)
                    Text("Server").tag(true)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(remote
                     ? "Recordings are uploaded to the server below in pieces of up to 28 s, cut at pauses, and the text comes back. Sent whole, Whisper repeats itself on long recordings. It detects the language if you let it."
                     : "The audio does not leave the phone.")
            }
            if !remote {
                Section {
                    Picker("Engine", selection: $engine) {
                        ForEach(LocalEngine.allCases) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text(engine == .parakeet
                         ? "NVIDIA's Parakeet on the Neural Engine: 25 European languages, detected by itself, and as accurate as Whisper on the server on Pocket recordings. The model (470 MB) downloads the first time. Other languages use Apple's."
                         : "Apple's speech recognition. You choose the language; each language's model downloads once. Less accurate than Parakeet on meetings.")
                }
            }
            if remote {
                Section {
                    ServerFields(url: $url, model: $model, key: $key,
                                 models: DefaultServer.sttModels, modelExample: "whisper-large-v3",
                                 keyPrompt: "API key (blank: language model's)") {
                        url = LLMConfig.defaultURL
                        model = RemoteSTT.defaultModel
                    }
                } header: { Text("Server (OpenAI-compatible)") } footer: {
                    Text("The URL ends in /v1; requests go to …/audio/transcriptions with word timestamps (whisper.cpp, faster-whisper servers and OpenAI all work). Leave the key blank to use the language model's key. Keys are stored in the Keychain.")
                }
                TestRow(disabledReason: RemoteSTT.availability) { try await RemoteSTT.test() }
            }
            Section {
                Toggle("Live transcript while recording", isOn: $liveTranscript)
            } header: { Text("Live") } footer: {
                Text(remote
                     ? "While the phone is connected, the Pocket streams what it records. The server transcribes it in \(Int(RemoteLiveTranscriber.chunkSeconds))-second pieces."
                     : "While the phone is connected, the Pocket streams what it records and this iPhone transcribes it as you speak.")
            }
            Section {
                Toggle("Label speakers", isOn: $diarize)
                if diarize {
                    Picker("Find them", selection: $diarizeOnDevice) {
                        Text("On this iPhone").tag(true)
                        Text("Server").tag(false)
                    }
                }
                if diarize, !diarizeOnDevice {
                    TextField("e.g. http://gpu1:8000/v1, http://gpu2:8000/v1", text: $diarizeURLs, axis: .vertical)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.callout.monospaced())
                    if !Diarizer.defaultURLs.isEmpty {
                        Button("Reset to \(DefaultServer.name)") { diarizeURLs = Diarizer.defaultURLs }
                    }
                }
            } header: { Text("Speakers") } footer: {
                Text(diarizeOnDevice
                     ? "Works out who spoke when on this iPhone (pyannote and WeSpeaker on the Neural Engine; a 20 MB model downloads the first time), with either kind of speech to text. During a recording, speakers are refreshed every \(Int(LiveSession.diarizeEvery)) s."
                     : "Sends the audio to a diarisation server (…/audio/diarize) to work out who spoke when, with either kind of speech to text. Several servers, comma-separated, are tried in order. During a recording, speakers are refreshed every \(Int(LiveSession.diarizeEvery)) s. Uses the speech-to-text key, or the language model's.")
            }
        }
        .navigationTitle("Speech to text")
        .onChange(of: key) { RemoteSTT.key = key.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

/// On-device model or an OpenAI-compatible server for summaries and questions.
struct LLMSettingsView: View {
    @AppStorage("llmRemote") private var remote = LLMConfig.hasDefault
    @AppStorage("llmURL") private var url = LLMConfig.defaultURL
    @AppStorage("llmModel") private var model = LLMConfig.defaultModel
    @AppStorage("llmNoThinking") private var noThinking = true
    @AppStorage("llmContextChars") private var contextChars = 120_000
    @State private var key = LLM.key

    var body: some View {
        Form {
            Section {
                Picker("Use", selection: $remote) {
                    Text("On this iPhone").tag(false)
                    Text("Server").tag(true)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(remote
                     ? "Summaries and questions go to the server below. Transcripts are sent to it; audio is not."
                     : "Apple's on-device model (Apple Intelligence). Nothing leaves the phone. Its window is small, so long transcripts are handled in parts.")
            }
            if remote {
                Section {
                    ServerFields(url: $url, model: $model, key: $key,
                                 models: DefaultServer.llmModels, modelExample: "qwen3.6-35b") {
                        url = LLMConfig.defaultURL
                        model = LLMConfig.defaultModel
                        noThinking = true
                        contextChars = 120_000
                    }
                } header: { Text("Server (OpenAI-compatible)") } footer: {
                    Text("The URL ends in /v1; requests go to …/chat/completions. The key is stored in the Keychain on this phone.")
                }
                Section {
                    Toggle("Turn off thinking", isOn: $noThinking)
                    Stepper(value: $contextChars, in: 8_000...800_000, step: 8_000) {
                        LabeledContent("Characters per request", value: contextChars.formatted())
                    }
                } header: { Text("Options") } footer: {
                    Text("Turn off thinking sends enable_thinking=false, which Qwen models on vLLM understand; switch it off for servers that reject unknown fields. Transcripts longer than the character limit are handled in parts.")
                }
            }
            TestRow(disabledReason: LLM.availability) {
                try await LLM.complete(LLM.config, instructions: "Reply with one short sentence.",
                                       prompt: "Say hello and name the model you are.")
            }
        }
        .navigationTitle("Language model")
        .onChange(of: key) { LLM.key = key.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

/// All languages on-device transcription supports; ticked ones are offered on recordings.
struct LanguagesView: View {
    @Binding var favourites: [String]
    @State private var all: [String] = []
    @State private var search = ""

    var body: some View {
        List {
            if all.isEmpty { ProgressView() }
            ForEach(all.filter { search.isEmpty || Languages.name($0).localizedCaseInsensitiveContains(search) },
                    id: \.self) { id in
                Button {
                    if let i = favourites.firstIndex(of: id) {
                        if favourites.count > 1 { favourites.remove(at: i) }
                    } else {
                        favourites.append(id)
                    }
                    Prefs.favouriteLocales = favourites
                } label: {
                    HStack {
                        Text(Languages.name(id)).foregroundStyle(.primary)
                        Spacer()
                        if favourites.contains(id) { Image(systemName: "checkmark") }
                    }
                }
            }
        }
        .navigationTitle("Languages")
        .searchable(text: $search)
        .task { all = await Languages.supported() }
    }
}

struct DeviceEditor: View {
    @EnvironmentObject var devices: DeviceStore
    @EnvironmentObject var link: PocketLink
    @Environment(\.dismiss) private var dismiss
    @State var device: DeviceConfig
    @State private var key = ""
    @State private var showKey = false
    @State private var confirmRemove = false

    var body: some View {
        Form {
            Section("Name") { TextField("Name", text: $device.name) }
            Section {
                HStack {
                    Group {
                        if showKey { TextField("Session key", text: $key) } else { SecureField("Session key", text: $key) }
                    }
                    .textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
                    Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                }
            } header: { Text("Session key") } footer: {
                Text("Set when you pair, or paste the key another app uses. Sent first on every connection (APP&SK&…); without it the Pocket answers no commands but still streams recordings. Clear it to pair again from the Recorder tab. Stored in the Keychain on this phone only.")
            }
            Section("Bluetooth") {
                TextField("Advertised name", text: $device.advertisedName)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                LabeledContent("Peripheral ID", value: device.peripheralID?.uuidString ?? "learned on first connect")
                    .font(.caption)
                if device.peripheralID != nil {
                    Button("Forget peripheral ID") { device.peripheralID = nil }
                }
            }
            Section("Behaviour") {
                Toggle("Download missed recordings when connected", isOn: $device.syncsAutomatically)
                Toggle("Set the Pocket's clock on connect", isOn: $device.setClockOnConnect)
                Toggle("Download after stopping a recording", isOn: $device.downloadAfterStop)
                Toggle("Transcribe automatically after download", isOn: $device.autoTranscribe)
            }
            Section {
                Button("Remove device", role: .destructive) { confirmRemove = true }
            } footer: {
                Text("Removes the settings and key. Recordings already on the phone are kept.")
            }
        }
        .navigationTitle(device.name)
        .onAppear { key = device.sessionKey }
        .onDisappear {
            guard devices.devices.contains(where: { $0.id == device.id }) else { return }
            if key != device.sessionKey { device.sessionKey = key; link.disconnect() }
            devices.update(device)
        }
        .confirmationDialog("Remove \(device.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if link.connectedDeviceID == device.id { link.disconnect() }
                devices.remove(device)
                dismiss()
            }
        }
    }
}

struct AddDeviceSheet: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var devices: DeviceStore
    @EnvironmentObject var link: PocketLink
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Discovered?
    @State private var name = ""
    @State private var key = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if link.discovered.isEmpty {
                        HStack { ProgressView(); Text("Scanning for Pockets…").foregroundStyle(.secondary) }
                    }
                    ForEach(link.discovered.sorted { $0.rssi > $1.rssi }) { d in
                        let known = devices.devices.contains { $0.advertisedName == d.name }
                        Button {
                            chosen = d
                            if name.isEmpty { name = defaultName(d.name) }
                        } label: {
                            HStack {
                                Text(d.name)
                                Spacer()
                                if known { Text("added").foregroundStyle(.secondary) }
                                Text("\(d.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                                if chosen == d { Image(systemName: "checkmark") }
                            }
                        }
                        .disabled(known)
                    }
                } header: { Text("Nearby") } footer: {
                    Text("A Pocket only shows up while it is not connected to another phone or app. Turn Bluetooth off on other phones, or close the official app.")
                }
                if chosen != nil {
                    Section("Name") { TextField("Name", text: $name) }
                    Section {
                        TextField("Session key (optional)", text: $key)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
                    } header: { Text("Session key") } footer: {
                        Text("Leave this empty and pair from the Recorder tab: hold the Pocket's side button for 5 seconds until it blinks blue, then tap Pair. Or paste the 16-character key another app already uses.")
                    }
                }
            }
            .navigationTitle("Add device")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let c = chosen else { return }
                        let d = DeviceConfig(name: name, advertisedName: c.name, peripheralID: c.id)
                        let k = key.trimmingCharacters(in: .whitespaces)
                        if !k.isEmpty { d.sessionKey = k }
                        devices.add(d)
                        dismiss()
                        link.stopDiscovery()
                        Task { await model.userConnect() }   // now, not at the next tick
                    }
                    .disabled(chosen == nil || name.isEmpty)
                }
            }
            .onChange(of: link.discovered) {
                // One Pocket nearby and none chosen yet: pick it, so Add is one tap.
                guard chosen == nil, link.discovered.count == 1, let d = link.discovered.first,
                      !devices.devices.contains(where: { $0.advertisedName == d.name }) else { return }
                chosen = d
                if name.isEmpty { name = defaultName(d.name) }
            }
            .onAppear { link.disconnect(); link.startDiscovery() }
            .onDisappear { link.stopDiscovery() }
        }
    }

    /// "PKT01_GREY_2617abcd" → "Pocket-abcd".
    private func defaultName(_ advertised: String) -> String { DeviceStore.defaultName(advertised) }
}
