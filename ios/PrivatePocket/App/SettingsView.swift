import CoreLocation
import EventKit
import Speech
import SwiftUI

struct SettingsView: View {
    @State private var exportURL: URL?
    @State private var exporting = false
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var devices: DeviceStore
    /// Shown as a sheet from the Pocket tab: a Done button that closes it.
    var onDone: (() -> Void)? = nil
    @State private var showWalkthrough = false
    @State var confirmClear = false
    @State var confirmReset = false
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
    @State private var islandPresence = Prefs.islandPresence
    @State private var autoReminders = Prefs.autoReminders
    @State private var autoCalendar = Prefs.autoCalendar
    @State private var calendarsLine = ""
    @State private var yourName = Prefs.yourName
    @AppStorage("sttModel") private var sttModel = RemoteSTT.defaultModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(privacyText).font(.footnote).foregroundStyle(Brand.textSecondary)
                } header: { Text("Where things run") }

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
                    Toggle("Show in the Dynamic Island", isOn: $islandPresence)
                        .onChange(of: islandPresence) { Prefs.islandPresence = islandPresence }
                    NavigationLink { USBView() } label: {
                        Label("USB drive: free up space", systemImage: "externaldrive")
                    }
                    Button { showWalkthrough = true } label: { Label("How the Pocket works", systemImage: "hand.tap") }
                } header: { Text("Pockets") } footer: {
                    Text("Each Pocket gets its own key when paired, and its own folder of moments. Stay connected keeps the link up, also in the background, so every moment streams in as it is made. The Dynamic Island shows the Pocket's light and battery while connected and turns amber when it records; iOS only lets that start while the app is open, so without it a moment recorded with the phone locked shows up only once the app is opened. Deleting recordings from a Pocket needs the USB cable.")
                }

                Section {
                    NavigationLink { ServerView() } label: {
                        LabeledContent("Your own server", value: Prefs.serverWhenReachable ? ServerStatus.shared.label : "Off")
                    }
                    NavigationLink { STTSettingsView() } label: {
                        LabeledContent("Speech to text", value: sttRemote ? sttModel : "On this iPhone")
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
                        ForEach(((sttRemote ? [Languages.auto] : []) + [locale] + favourites).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } },
                                id: \.self) { Text(Languages.name($0)).tag($0) }
                    }
                    .onChange(of: locale) { Prefs.transcriptionLocale = locale }
                    NavigationLink {
                        LanguagesView(favourites: $favourites)
                    } label: {
                        LabeledContent("Languages to offer", value: favourites.map(Languages.name).joined(separator: ", "))
                    }
                } header: { Text("Transcription language") } footer: {
                    Text(sttRemote
                         ? "Whisper on the server can detect the language, or you can name it. Each recording can be transcribed again in another language from its page."
                         : "Each recording can be transcribed in any of these; pick the language on the recording. On-device recognition cannot detect the language itself. Each language's model downloads once, then works offline.")
                }

                Section {
                    Toggle("Tag moments with location", isOn: $tagLocation)
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
                    Text("The Pocket has no GPS, so the phone's location is used: where it was when a moment started (if connected), or when it was downloaded within 15 minutes of finishing. Place names come from Apple's geocoder, which receives the coordinates; turn that off to keep coordinates only.")
                }

                Section {
                    TextEditor(text: $instructions)
                        .frame(minHeight: 140)
                        .onChange(of: instructions) { Prefs.summaryInstructions = instructions }
                    Button("Reset to default") { instructions = Prefs.defaultSummaryInstructions }
                } header: { Text("Summary instructions") } footer: {
                    Text(Summariser.availability ?? "Sent with each transcript to \(LLM.whereLabel)")
                }

                Section {
                    Toggle("Actions go to Reminders", isOn: $autoReminders)
                        .onChange(of: autoReminders) { Prefs.autoReminders = autoReminders }
                    Toggle("Dates go to Calendar", isOn: $autoCalendar)
                        .onChange(of: autoCalendar) { Prefs.autoCalendar = autoCalendar }
                } header: { Text("After each moment") } footer: {
                    Text("Each moment lists its to-dos and events with Add beside them. Turn these on and they go in by themselves as soon as a moment is read: to-dos into a Pocket list in Reminders with their due dates, events into Calendar. Tick one off in either place and the moment shows it done.")
                }

                Section {
                    NavigationLink { CalendarsView() } label: {
                        HStack {
                            Label("Calendars to read", systemImage: "calendar")
                            Spacer()
                            Text(calendarsLine).foregroundStyle(.secondary)
                        }
                    }
                    .onAppear { calendarsLine = CalendarsView.summary() }
                    LabeledContent("Your name") {
                        TextField(Prefs.calendarName.isEmpty ? "Your name" : Prefs.calendarName, text: $yourName)
                            .multilineTextAlignment(.trailing)
                            .textContentType(.name)
                            .onChange(of: yourName) { Prefs.yourName = yourName }
                    }
                } header: { Text("Calendar") } footer: {
                    Text("The brief before a meeting, and naming who spoke in a moment recorded during one, read only the calendars switched on here. Dates from moments still go to your default calendar. Your name comes from your invitations unless you type one; add what people call you after a comma. It tells your voice from the others', so yours is never given someone else's name.")
                }

                Section {
                    NavigationLink { SamplesView() } label: { Label("Sample moments", systemImage: "waveform.badge.plus") }
                } header: { Text("Try it") } footer: {
                    Text("Eight short spoken conversations, one of each kind, that go through speech to text, reading, the tape and You exactly as a moment from the Pocket would.")
                }


                Section {
                    if let url = exportURL {
                        ShareLink(item: url) { Label("Share the export", systemImage: "square.and.arrow.up") }
                    } else {
                        Button {
                            Task {
                                exporting = true
                                exportURL = try? await model.exportAll()
                                exporting = false
                                if exportURL == nil { model.aiError = "The export couldn't be made. Try again in a moment." }
                            }
                        } label: {
                            HStack { Label("Export everything", systemImage: "archivebox"); if exporting { Spacer(); ProgressView() } }
                        }
                        .disabled(exporting)
                    }
                } header: { Text("Your moments") } footer: {
                    Text("Every recording and what was read from it, as one zip, to keep somewhere else or move to another phone. Nothing is sent anywhere by itself.")
                }

                startOver
            }
                .scrollContentBackground(.hidden)
                .background(Brand.ground)
                .confirmationDialog("Clear all moments?", isPresented: $confirmClear, titleVisibility: .visible) {
                    Button("Clear all moments", role: .destructive) { model.clearMoments() }
                } message: {
                    Text("Every moment on this iPhone, what was read from it, and the reminders and events made from them. The Pocket keeps its own copies until you clear it over USB, but they won't be fetched again.")
                }
                .confirmationDialog("Reset everything?", isPresented: $confirmReset, titleVisibility: .visible) {
                    Button("Reset everything", role: .destructive) {
                        model.resetEverything()
                        showWalkthrough = true
                    }
                } message: {
                    Text("All moments, your Pockets and their keys, and every setting. The app will be as it was when installed.")
                }
            .navigationTitle("Settings")
            .sheet(isPresented: $adding) { AddDeviceSheet() }
            .toolbar { if let onDone { ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) } } }
            .fullScreenCover(isPresented: $showWalkthrough) { WalkthroughView() }
        }
    }
}

extension SettingsView {
    /// Clear all moments, and Reset everything.
    var startOver: some View {
        Section {
            Button("Clear all moments", role: .destructive) { confirmClear = true }
            Button("Reset everything", role: .destructive) { confirmReset = true }
        } header: { Text("Start over") } footer: {
            Text("Clear all moments deletes every moment on this iPhone and what was read from it, and the reminders and calendar events made from them; your Pockets and settings stay. Reset everything also forgets your Pockets and their keys and puts every setting back to how it was when the app was installed.")
        }
    }
}

/// URL, model and key for an OpenAI-compatible server. The model is picked from the
/// list the server gives (GET /models) once it answers, typed until then; and a reset
/// to the build's default server.
struct ServerFields: View {
    @Binding var url: String
    @Binding var model: String
    @Binding var key: String
    /// Build-time suggestions, offered until the server lists its own.
    var models: [String] = []
    var modelExample = "model name"
    var keyPrompt = "API key"
    /// The speech-to-text page: speech models first.
    var speech = false
    /// Lists models with this key when the page's own is blank (the language model's).
    var fallbackKey = ""
    let reset: () -> Void
    @State private var showKey = false
    @State private var listed: [String] = []
    @State private var listing = false

    private var options: [String] { ModelList.ordered(listed, speech: speech, keeping: model) }

    var body: some View {
        TextField("URL, e.g. https://llm.example.com/v1", text: $url)
            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            .task(id: "\(url)|\(key)|\(fallbackKey)") {
                try? await Task.sleep(for: .seconds(0.7))
                guard !Task.isCancelled else { return }
                listing = true
                listed = (try? await ModelList.fetch(url: url, key: key.isEmpty ? fallbackKey : key)) ?? []
                listing = false
                if model.isEmpty, let first = options.first { model = first }
            }
        if listed.isEmpty {
            HStack {
                TextField("Model, e.g. \(modelExample)", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                if listing {
                    ProgressView().controlSize(.small)
                } else if !models.isEmpty {
                    Menu {
                        ForEach(models, id: \.self) { m in Button(m) { model = m } }
                    } label: { Image(systemName: "chevron.up.chevron.down") }
                }
            }
        } else {
            Picker("Model", selection: $model) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.navigationLink)
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
    @AppStorage("diarize") private var diarize = !Diarizer.defaultURLs.isEmpty
    @AppStorage("diarizeURLs") private var diarizeURLs = Diarizer.defaultURLs
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
                     ? "Recordings are uploaded to the server below (as MP3) and the text comes back. Whisper detects the language if you let it."
                     : "Apple's on-device speech recognition. The audio does not leave the phone. You choose the language; each language's model downloads once.")
            }
            if remote {
                Section {
                    ServerFields(url: $url, model: $model, key: $key,
                                 models: DefaultServer.sttModels, modelExample: "whisper-large-v3",
                                 keyPrompt: "API key (blank: language model's)", speech: true, fallbackKey: LLM.key) {
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
                    TextField("e.g. http://gpu1:8000/v1, http://gpu2:8000/v1", text: $diarizeURLs, axis: .vertical)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.callout.monospaced())
                    if !Diarizer.defaultURLs.isEmpty {
                        Button("Reset to \(DefaultServer.name)") { diarizeURLs = Diarizer.defaultURLs }
                    }
                }
            } header: { Text("Speakers") } footer: {
                Text("Sends the audio to a diarisation server (…/audio/diarize) to work out who spoke when, with either kind of speech to text. Several servers, comma-separated, are tried in order. During a recording, speakers are refreshed every \(Int(LiveSession.diarizeEvery)) s. Uses the speech-to-text key, or the language model's.")
            }
        }
            .scrollContentBackground(.hidden)
            .background(Brand.ground)
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
            .scrollContentBackground(.hidden)
            .background(Brand.ground)
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
            .scrollContentBackground(.hidden)
            .background(Brand.ground)
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
            } header: { Text("Advanced: session key") } footer: {
                Text("Set when the app pairs, or paste the key another app uses. Sent first on every connection (APP&SK&…); without it the Pocket answers no commands but still streams recordings. Clear it to pair afresh from the Pocket screen. Stored in the Keychain on this phone only.")
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
                Toggle("Fetch missed recordings when connected", isOn: $device.syncsAutomatically)
                Toggle("Set the Pocket's clock on connect", isOn: $device.setClockOnConnect)
                Toggle("Fetch the file after stopping a recording", isOn: $device.downloadAfterStop)
                Toggle("Transcribe fetched recordings automatically", isOn: $device.autoTranscribe)
            }
            Section {
                Button("Remove device", role: .destructive) { confirmRemove = true }
            } footer: {
                Text("Removes the settings and key. Moments already on the phone are kept.")
            }
        }
            .scrollContentBackground(.hidden)
            .background(Brand.ground)
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
                        HStack { ProgressView(); Text("Looking for your Pocket…").foregroundStyle(.secondary) }
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
                } header: { Text("Found") } footer: {
                    Text("Your Pocket shows up only while nothing else is connected to it: close the official app, or turn Bluetooth off on other phones.")
                }
                if chosen != nil {
                    Section("Name") { TextField("Name", text: $name) }
                    Section {
                        TextField("Session key (optional)", text: $key)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
                    } header: { Text("Advanced") } footer: {
                        Text("Leave this empty: once added, hold the Pocket's side button for 5 seconds until it blinks blue and the app pairs by itself. Or paste the 16-character key another app already uses.")
                    }
                }
            }
                .scrollContentBackground(.hidden)
                .background(Brand.ground)
            .navigationTitle("Add Pocket")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let c = chosen else { return }
                        let d = DeviceConfig(name: name, advertisedName: c.name, peripheralID: c.id)
                        d.sessionKey = key.trimmingCharacters(in: .whitespaces)
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

extension SettingsView {
    /// The privacy claim, kept true: where each step runs right now, in one paragraph.
    var privacyText: String {
        var parts = ["Your moments stay on this iPhone, in Files under On My iPhone, and reach it from the Pocket over Bluetooth. No account, no cloud."]
        parts.append(Prefs.sttRemoteNow ? "Speech to text runs on your own server, which receives the audio." : "Speech to text runs on this iPhone.")
        parts.append(Prefs.llmRemoteNow ? "Reading, summaries and questions run on your own server, which receives the transcripts." : "Reading, summaries and questions run on this iPhone.")
        parts.append("Backups of this iPhone leave the moments out; the Pocket keeps its own copies, and Export everything below makes a copy to keep.")
        parts.append("Apple's speech models download once. Place names are looked up only when that is switched on.")
        return parts.joined(separator: " ")
    }
}

/// Which calendars the app reads, one switch each, grouped by account. Off means the brief
/// before a meeting and naming speakers never look at it; a calendar added later is read
/// until it is switched off.
struct CalendarsView: View {
    @EnvironmentObject var model: AppModel
    @State private var off: Set<String> = Prefs.excludedCalendars
    @State private var calendars: [EKCalendar] = []
    @State private var allowed = Briefs.calendarAllowed

    /// "All", "5 of 7", "Not allowed": the line beside the row in Settings.
    static func summary() -> String {
        guard Briefs.calendarAllowed else { return "Not allowed" }
        let all = Planner.eventCalendars()
        let on = all.filter { !Prefs.excludedCalendars.contains($0.calendarIdentifier) }.count
        return on == all.count ? "All" : "\(on) of \(all.count)"
    }

    private var groups: [(account: String, calendars: [EKCalendar])] {
        let byAccount = Dictionary(grouping: calendars) { $0.source?.title ?? "Other" }
        return byAccount.keys.sorted().map { key in
            (key, (byAccount[key] ?? []).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending })
        }
    }

    var body: some View {
        Form {
            if !allowed {
                Section {
                    Button("Allow Calendar") {
                        Task {
                            if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
                                allowed = await Planner.allowEvents()
                            } else if let url = URL(string: UIApplication.openSettingsURLString) {
                                await UIApplication.shared.open(url)
                            }
                            load()
                        }
                    }
                } footer: {
                    Text("Private Pocket reads your calendar for the brief before a meeting and to name who spoke in a moment recorded during one. Allow it to choose which calendars.")
                }
            } else if calendars.isEmpty {
                Section { Text("No calendars on this iPhone.").foregroundStyle(.secondary) }
            } else {
                ForEach(Array(groups.enumerated()), id: \.element.account) { i, g in
                    Section {
                        ForEach(g.calendars, id: \.calendarIdentifier) { c in
                            Toggle(isOn: binding(c)) {
                                HStack(spacing: 10) {
                                    Circle().fill(Color(cgColor: c.cgColor)).frame(width: 10, height: 10)
                                    Text(c.title)
                                }
                            }
                        }
                    } header: {
                        Text(g.account)
                    } footer: {
                        if i == groups.count - 1 {
                            Text("Switched off, a calendar is never read: not for briefs, not for naming speakers. A calendar added later is read until you switch it off. Moments already named from a calendar keep their names.")
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Brand.ground)
        .navigationTitle("Calendars to read")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func load() {
        allowed = Briefs.calendarAllowed
        calendars = Planner.eventCalendars()
        off = Prefs.excludedCalendars
    }

    private func binding(_ c: EKCalendar) -> Binding<Bool> {
        Binding(get: { !off.contains(c.calendarIdentifier) }, set: { on in
            if on { off.remove(c.calendarIdentifier) } else { off.insert(c.calendarIdentifier) }
            Prefs.excludedCalendars = off
            if on { model.calendarSwitchedOn() }
        })
    }
}

