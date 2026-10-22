# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A private, cloud-free companion app for the **Pocket (PKT01)** voice recorder, open source as `incept5-ai/private-pocket`. Layout:

- **`ble/`** — the BLE protocol (`PROTOCOL.md`, the source of truth) and Python/bleak tools used to verify it from the Mac. `captures/` (gitignored) holds PacketLogger captures of the official app plus captured live-stream MP3s.
- **`ios/PrivatePocket/`** — the SwiftUI iPhone app, which is where nearly all the work happens. Its `README.md` lists the features.
- **`docs/`, `plugins/`** (gitignored, local only) — clones of Pocket's own upstream repos (a Mintlify docs starter and their AI/MCP plugins). Use them for reference only; nothing here builds or uses them.
- `recordings/` (gitignored, mode 700) — real recordings. Personal data: never share.
- `report/` (gitignored) — private notes about Pocket, not for the repo.

## Commands

```bash
# iOS: regenerate project, build unsigned, sign, install and launch on the iPhone
cd ios/PrivatePocket && ./sign-install.sh          # reads signing.env; DEVICE=<udid> overrides

# Compile-check only (no phone needed)
cd ios/PrivatePocket && xcodegen generate -q && \
  xcodebuild -project PrivatePocket.xcodeproj -scheme PrivatePocket \
  -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build -quiet

# BLE from the Mac (the phone app must be disconnected: the Pocket talks to one central at a time)
cd ble && set -a && . ./.env && set +a && uv run pocket.py BAT FW SPACE 'LIST_DIRS'
uv run pocket.py --wait 10 --out x.mp3 STA STO      # --out saves audio received on …a1
```

There are no tests and no linter. To exercise app logic without the phone, copy the relevant `App/*.swift` files into a scratch directory with a `main.swift` and run it with `swiftc`, feeding it a TTS MP3 at 16 kHz/32 kbps mono (`ffmpeg … -ar 16000 -ac 1 -b:a 32k`). Background noise transcribes as nothing, so it is useless as test input.

- **Adding a Swift file:** run `xcodegen generate` first. The `.xcodeproj` is generated from `project.yml` and gitignored.
- **Bundle id** is `com.incept5.private-pocket`; the Keychain service name is read from the bundle id.
- **App icon:** `App/Assets.xcassets/AppIcon.appiconset` (1024 px, opaque). The README logo is `assets/logo.png`.
- **Signing:** Xcode on this Mac has no Apple ID, so automatic signing fails. `sign-install.sh` signs by hand with the profile, identity, app-id prefix, team and phone from the gitignored `signing.env` (template: `signing.env.example`). Don't switch the project to manual signing: that fails with "profile is Xcode managed".

## Secrets

`ble/.env` (mode 600, template `ble/.env.example`) optionally holds `POCKET_SK`, a device session key (the app pairs on its own; the Mac tools need one), plus device and server defaults and `SERVER_KEY`. Server values stay blank by default (examples only in `.env.example`). Never print the keys.

- The pre-build `gen-defaults.sh` bakes them into the gitignored `Generated/DefaultDevice.swift` (`DefaultDevice`, `DefaultServer`).
- On first launch `AppModel.init` copies `SERVER_KEY` into the Keychain, once, guarded by the `seededServerKey` flag.
- At runtime all secrets live in the Keychain: `llm.key`, `stt.key` (which falls back to `llm.key`), and per-device session keys.

## Protocol essentials (details in `ble/PROTOCOL.md`)

- **Service `001120a0-…`:**
  - `…a2`: commands, ASCII `APP&…`
  - `…a3`: replies and events, `MCU&…`
  - `…a1`: raw MP3 (MPEG-2 L3, 16 kHz mono, 32 kbps, about 4,000 B/s)
- **Session key:** `APP&SK&<key>` must be sent first, or the device silently ignores every command. In pairing mode (side button held 5 s, light blinking blue) the device accepts any 16-character key and adds it to the ones it holds (earlier keys stay valid). Outside pairing mode a wrong key drops the connection at once. Without any key the link still delivers `MCU&STA`/`MCU&STO` events and the live stream, which is how an unpaired device works in the app. `PocketLink.handshake` therefore tries a fresh key once per keyless connection (`pairAttemptPending`): accepted in pairing mode, otherwise one reconnect. A stored key the device drops sets `keyRejected`, after which the link carries on keyless and keeps trying; `pair` is the same try on demand.
- **Live streaming needs no command.** While recording, live MP3 arrives on `…a1` unprompted, whether started by `APP&STA` or the button. Downloads (`APP&U&…`) arrive on the same characteristic, so `PocketLink` routes `…a1` bytes to the download in progress if there is one, otherwise to `onLiveAudio`.
- **Deleting:** there is no delete over BLE. Deletion is only via USB mass storage: `APP&USB&1`, re-plug, delete under `RECORD/<date>/`, unplug. While the cable is in, the device reports 0 space and ignores `LIST`.
- File names are UTC timestamps (`yyyyMMddHHmmss`). In call mode (the card on the back of the phone, contact mic) they are `PH` + `yyMMddHHmmss`, the start event says `MCU&REC&CALL`, and `LIST_DIRS`/`LIST` do not list them, so only the live stream captures them. `PocketTime.parse` handles both; `DeviceStatus.recordingName` carries the name from `MCU&STA&` to the stop.

## iOS architecture

App sources are in `App/`. `Shared/` is compiled into both the app and the `PrivatePocketWidgets` extension (`Widgets/`), which hosts the Live Activity and the Control Center controls: `RecordingAttributes`, `StartRecordingIntent` and `StopRecordingIntent` (both `LiveActivityIntent`, performed in the app through a static `handler`; that kind is what makes Control Center run them in the app rather than the extension) plus `PocketLook`, `LightDot` and `PocketFacts`. The signing profile is a wildcard without App Groups, so anything the extension needs from the app must travel in the activity's state or the shared Keychain access group, never a shared container. Keep app-only types out of `Shared/`. `App/LiveActivity.swift` (`RecordingActivity`) runs the activity from `AppModel`: iOS only lets an app *start* one in the foreground, so `refreshPresence` starts it while connected (light and battery, `Prefs.islandPresence`), and recording, saved and waiting are updates, which work from the background; `App/Intents.swift` has `StartRecordingIntent` and the App Shortcuts. `sign-install.sh` signs the `.appex` with its own entitlements before the app.

- **`PocketLink`** is the CoreBluetooth central. It handles scan, connect, the command/reply exchange, downloads and status, and exposes the hooks `onLiveAudio`, `onRecordingStarted` and `onLinkLost`.
- **`AppModel`** is the orchestrator:
  - A keep-alive loop (`setActive`) reconnects every 15 s while the app is in the foreground. In the background it instead arms `PocketLink.standby`: a pending `connect` on the known peripheral that iOS completes whenever the Pocket advertises (phase `.waiting`), with the handshake run from the delegate (`checkStandbyReady`). The central has a restore identifier, so iOS relaunches the app for Bluetooth events; `willRestoreState` hands the peripheral back and `attach` treats an already-connected one as connected. Both are skipped when the user disconnected or during Add-device discovery. An unpaired device (no key, or `link.keyRejected`; see `AppModel.canCommand`) is still connected so button-started recordings stream; the record button and sync are hidden until it is paired.
  - Sync, plus transcription and diarisation, which run concurrently. `autoSync` runs a quiet sync after every connection (foreground loop, standby `onConnected`, pairing) when the device is paired, `syncsAutomatically` is on (per-device `autoSync`, optional, default true) and nothing is recording.
  - Summary and Ask.
  - `completeRecording`, which runs at stop and decides whether to keep the streamed copy: kept only if the stream had no gap and its duration is within ±2 s of the device's `LIST` seconds; otherwise the file is downloaded. Unpaired: whatever streamed is kept, since nothing can be listed or downloaded.
- **`LiveSession` (`Live.swift`)** handles the live stream:
  - It writes the stream to `Caches/Live/`.
  - `MP3Packetizer` (AudioFileStream) splits it into packets, which feed one of two transcribers:
    - `LocalLiveTranscriber`: AVAudioConverter, then SpeechAnalyzer
    - `RemoteLiveTranscriber`: 15 s chunks sent to Whisper, with word times offset by chunk start
  - Every 45 s it re-diarises the whole file so far.
- **`Library`** handles storage: `Documents/Recordings/<device id>/<yyyy-MM-dd>/<UTC>.mp3` plus a `.json` sidecar (`RecordingMeta`).
  - **Every field added to `RecordingMeta` must be optional**, or existing sidecars stop decoding.
  - The same applies to `DeviceConfig` in `Devices.swift`, where a decode failure wipes the saved devices.
- **`Prefs` (`Devices.swift`)** wraps UserDefaults. Views use `@AppStorage` with the same key names so labels refresh.
- **Speech to text and the language model are each local or remote, chosen independently** (`Prefs.sttRemote`, `Prefs.llmRemote`):
  - Local STT: `Transcriber` in `OnDeviceAI.swift`, on SpeechAnalyzer/SpeechTranscriber (iOS 26+). Only a few locales can be reserved, so `reserve` evicts ones that aren't favourites.
  - Remote STT: `RemoteSTT` in `LLM.swift`, OpenAI `/audio/transcriptions` with `verbose_json` and word timestamps.
  - Local LLM: FoundationModels, with about 6k characters per chunk.
  - Remote LLM: OpenAI `/chat/completions`, with `chat_template_kwargs.enable_thinking=false` and any `<think>` block stripped from the reply.
  - Summaries and Ask map-reduce long transcripts in chunks of `LLMConfig.chunkChars`.
  - `Languages.auto` works only with remote STT: local transcription throws `autoNeedsServer`.
- **Speakers (`Speakers.swift`)**:
  - `Diarizer` posts the whole audio file to `/v1/audio/diarize`. Speaker ids hold only within one request, so the app never diarises chunks.
  - `Speakers.align` rules: midpoint rule, narrowest overlapping segment wins, nearest segment within 1.5 s, a gap of 2 s starts a new turn, speakers renumbered by first turn.
  - The output format is `[MM:SS] Speaker N: text`. Keep it stable.
  - `Recording.transcriptForModel` feeds that speaker text to the LLM whenever there are 2 or more speakers.
- **Naming clash:** the app's transcript type is `TimedTranscript` because FoundationModels already exports `Transcript`.

## Server defaults and gotchas

- **No hard-coded servers.** Defaults come from `ble/.env` via `gen-defaults.sh`, into the generated `DefaultServer` enum: `SERVER_URL`, models, `DIARIZE_URLS` and the key. If `SERVER_URL` is empty, `LLMConfig.hasDefault` is false: STT, the LLM and speakers default to off/on-device and the "Reset to …" buttons are hidden. Never put a real URL, hostname or key in Swift.
- **Testing a key:** many gateways serve `/models` without auth, so the STT test sends a real 1 s silent WAV instead.
- **Whisper input:** whisper.cpp accepts mp3 and wav, but not m4a.
- **Diarisation contract:** `POST <base>/audio/diarize`, multipart `file` + `preset`, returning `{segments:[{start,end,speaker}]}`. Several base URLs are tried in order; 404/5xx/unreachable moves to the next.
- **Plain http:** `NSAllowsArbitraryLoads` is on so private-network `http://` servers work.

## Open-source hygiene

The repo root is a git repo published as `incept5-ai/private-pocket`. Before committing, check that nothing personal is staged: `.env`, `signing.env`, `ble/captures/` (the PacketLogger traces contain the session key), recordings and MP3s, and the `docs/`, `plugins/` and `report/` directories are all gitignored and must stay that way. Use example identifiers like `PKT01_GREY_2617abcd` in docs.
