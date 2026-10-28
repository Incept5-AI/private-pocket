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

**Reading the app's log from the Mac:** the protocol log is also written to `Documents/pocket-log.txt` (`DiskLog`, shareable from the device screen's Protocol log). Pull it with `xcrun devicectl device copy from --device <udid> --domain-type appDataContainer --domain-identifier com.incept5.private-pocket --source Documents/pocket-log.txt --destination pocket-log.txt`.

**Measuring STT:** `report/eval/` (gitignored) has the harness used on 2026-10-28: `stt.py` (whole vs chunked Whisper), `wer2.py` (WER against several transcripts of a phone recording of the same meeting, fillers and stutters normalised away, since each model family scores best against its own family), `analyse.py`, `trsim.py` (the Translate gate and server path on a clip) and `report/STT-EVAL.md` with the numbers. FluidAudio's CLI (`swift run fluidaudiocli transcribe|process`) runs the same Core ML models on the Mac. The simulator gets no microphone audio here; `axe` (Homebrew) drives the simulator UI and `xcrun devicectl device capture screenshot` shows the phone.

There are no tests and no linter. To exercise app logic without the phone, copy the relevant `App/*.swift` files into a scratch directory with a `main.swift` and run it with `swiftc`, feeding it a TTS MP3 at 16 kHz/32 kbps mono (`ffmpeg … -ar 16000 -ac 1 -b:a 32k`). Background noise transcribes as nothing, so it is useless as test input.

- **Adding a Swift file:** run `xcodegen generate` first. The `.xcodeproj` is generated from `project.yml` and gitignored.
- **Bundle id** is `com.incept5.private-pocket`; the Keychain service name is read from the bundle id.
- **App icon:** `App/Assets.xcassets/AppIcon.appiconset` (1024 px, opaque). The README logo is `assets/logo.png`.
- **Signing:** Xcode on this Mac has no Apple ID, so automatic signing fails. `sign-install.sh` signs by hand with the profile, identity, app-id prefix, team and phone from the gitignored `signing.env` (template: `signing.env.example`). Don't switch the project to manual signing: that fails with "profile is Xcode managed".

## Secrets

`ble/.env` (mode 600, template `ble/.env.example`) holds `POCKET_SK`, the device session key, plus device and server defaults and `SERVER_KEY`. Server values stay blank by default (examples only in `.env.example`). Never print the keys.

- The pre-build `gen-defaults.sh` bakes them into the gitignored `Generated/DefaultDevice.swift` (`DefaultDevice`, `DefaultServer`).
- On first launch `AppModel.init` copies `SERVER_KEY` into the Keychain, once, guarded by the `seededServerKey` flag.
- At runtime all secrets live in the Keychain: `llm.key`, `stt.key` (which falls back to `llm.key`), and per-device session keys.

## Protocol essentials (details in `ble/PROTOCOL.md`)

- **Service `001120a0-…`:**
  - `…a2`: commands, ASCII `APP&…`
  - `…a3`: replies and events, `MCU&…`
  - `…a1`: raw MP3 (MPEG-2 L3, 16 kHz mono, 32 kbps, about 4,000 B/s)
- **Session key:** `APP&SK&<key>` must be sent first, or the device silently ignores every command. In pairing mode (side button held 5 s, light blinking blue) the device accepts any 16-character key and adds it to the ones it holds. Outside pairing mode a wrong key drops the connection at once. Without a key the link still delivers `MCU&STA`/`MCU&STO` and the live stream, which is how an unpaired device works in the app (`AppModel.canCommand` gates record and sync). Only a real refusal (the drop, or a reply that is not `MCU&SK&OK`) sets `keyRejected`; a timeout does not. Keyless or refused, `tryPairing` runs once per connection after a drop the device made by itself (`pairAttemptPending`), and from `AppModel.keepPairing` every 15 s for two minutes in the foreground, then every minute, never while recording or streaming. It tries the stored key (unless refused in the last 45 s), then a key that may have been taken as the link dropped (`sk.tried.<id>` in the Keychain), then a fresh one. `pair` (the Pair button) goes straight to a fresh key.
- **Live streaming needs no command.** While recording, live MP3 arrives on `…a1` unprompted, whether started by `APP&STA` or the button. Downloads (`APP&U&…`) arrive on the same characteristic, so `PocketLink` routes `…a1` bytes to the download in progress if there is one, otherwise to `onLiveAudio`.
- **Deleting:** there is no delete over BLE. Deletion is only via USB mass storage: `APP&USB&1`, re-plug, delete under `RECORD/<date>/`, unplug. While the cable is in, the device reports 0 space and ignores `LIST`.
- File names are UTC timestamps (`yyyyMMddHHmmss`). With the side switch on call (contact mic) they are `PH` + `yyMMddHHmmss`, and `LIST` does not list them, so only the live stream captures them. `PocketTime.parse` handles both; `DeviceStatus.recordingName` carries the name from `MCU&STA&` to the stop. `APP&REC&SECEN` reads the switch (`DeviceStatus.mode`, saved as `RecordingMeta.mode`).

## iOS architecture

Every source file is in `App/`.

- **`PocketLink`** is the CoreBluetooth central. It handles scan, connect, the command/reply exchange, downloads and status, and exposes the hooks `onLiveAudio`, `onRecordingStarted`, `onRecordingStopped` and `onLinkLost`. Rules it keeps, each learned from a failure:
  - **One command at a time.** `send` waits its turn (`takeTurn`), then `exchange` does the work; two commands in flight took each other's replies and both timed out. `download` holds the channel for the whole file; a recording starting (`startRecording` or `MCU&STA&`) stops it with `PocketError.interrupted`. It returns a `FetchedFile` whose `whole` is false when fewer bytes came than `MCU&U&` announced.
  - **Cancels are not losses.** iOS answers every `cancelPeripheralConnection` with a `didDisconnect`. `cancelConnection` marks what it cancels (`cancelling`) and `didDisconnect` ignores those; a real loss tears down with `teardown(cancel: false)`. Cancelling inside the disconnect handler made a reconnect loop.
  - **Attempts are numbered.** `teardown` bumps `attempt`; `connect` waits with its number (`waitUntil(attempt:)`), stops with `superseded` once it changes, and never tears down what replaced it.
- **`AppModel`** is the orchestrator:
  - A keep-alive loop (`setActive`) reconnects every 15 s while the app is in the foreground. In the background it instead arms `PocketLink.standby`: a pending `connect` on the known peripheral that iOS completes whenever the Pocket advertises (phase `.waiting`), with the handshake run from the delegate (`checkStandbyReady`). The central has a restore identifier, so iOS relaunches the app for Bluetooth events; `willRestoreState` hands the peripheral back and `attach` treats an already-connected one as connected. Both are skipped when the user disconnected or during Add-device discovery. An unpaired device is still connected, so button-started recordings stream.
  - Sync, plus transcription and diarisation, which run concurrently. `autoSync` runs a quiet sync after every connection (foreground, standby `onConnected`, pairing) when the device is paired, `syncsAutomatically` is on (per-device `autoSync`, optional, default true) and nothing is recording.
  - Summary and Ask.
  - At a stop, `wrapUp` detaches the stream at once (into `stoppedStreams`), so a new recording can start meanwhile, and `saveStopped` saves each name once (`saving`). A new `MCU&STA&` while a stream is still open saves the old one first. `toggleRecording` is guarded by `toggling`.
  - `completeRecording` decides whether to keep the streamed copy: kept only if the stream had no gap and its duration is within ±2 s of the device's `LIST` seconds; otherwise the file is downloaded. The listing is tried three times (a call recording never appears in it); when it or the download fails, the stream is kept and marked `RecordingMeta.partial`, as is a short download. A sync downloads the Pocket's file for a partial copy once a session (`recheckedPartial`) and replaces it via `Library.replaceAudio` when that holds more.
  - Sync runs one at a time (`syncing`), stops at a recording, skips what was deleted here, and never saves an empty file.
- **`LiveSession` (`Live.swift`)** handles the live stream:
  - It writes the stream to `Caches/Live/` (a failed write marks a gap). `bytes` is not published; `seconds` is, once a second.
  - `detach(name:)` takes a stopped recording's stream out at once as an `Ending`, which `finish()` completes on its own. The server's transcriber gives a slice 60 s, pauses after three failures, and `finish` waits at most 20 s; a phone recogniser that cannot start is abandoned.
  - `MP3Packetizer` (AudioFileStream) splits it into packets, which feed one of two transcribers:
    - `LocalLiveTranscriber`: AVAudioConverter, then SpeechAnalyzer
    - `RemoteLiveTranscriber`: 15 s chunks sent to Whisper, with word times offset by chunk start
  - Every 45 s it re-diarises the whole file so far.
- **`Library`** handles storage: `Documents/Recordings/<device id>/<yyyy-MM-dd>/<UTC>.mp3` plus a `.json` sidecar (`RecordingMeta`).
  - **A job that awaits writes through `Library.mutate(id) { meta in … }`**: the recording as it is now, only the fields that job owns, nothing if it was deleted meanwhile. `update` is only for a copy taken just now; writing back a copy held across an await loses renames and speaker names.
  - Deleted recordings are remembered in `Recordings/deleted.json` (`wasDeleted`), so sync and USB import never download them again. A sidecar that no longer decodes is copied aside as `.bad` first.
  - **Every field added to `RecordingMeta` must be optional**, or existing sidecars stop decoding.
  - The same applies to `DeviceConfig` in `Devices.swift`, where a decode failure wipes the saved devices.
- **`Prefs` (`Devices.swift`)** wraps UserDefaults. Views use `@AppStorage` with the same key names so labels refresh.
- **Speech to text and the language model are each local or remote, chosen independently** (`Prefs.sttRemote`, `Prefs.llmRemote`):
  - Local STT (`Transcriber` in `OnDeviceAI.swift` dispatches): **Parakeet TDT v3** via FluidAudio (`OnDeviceSpeech` in `Parakeet.swift`, pinned `exactVersion: 0.17.7` in `project.yml`; model 470 MB from Hugging Face on first use) when `Prefs.localEngine == .parakeet` and the language is one of its 25; otherwise SpeechAnalyzer/SpeechTranscriber. Only a few locales can be reserved, so `reserve` evicts ones that aren't favourites (it is capped at 5 per app).
  - Remote STT: `RemoteSTT` in `LLM.swift`, OpenAI `/audio/transcriptions` with `verbose_json` and word timestamps. **A whole recording goes through `ChunkedSTT` (`Chunked.swift`), never as one request**: pieces of 12–28 s cut at the quietest 0.2 s, pieces under 3% speech skipped, `Cleanup.words` drops caption words (`*crickets*`, `[BLANK_AUDIO]`) and runs of 1–12 words repeated 3+ times, and a piece with zlib compression > 2.4 is retried at temperature 0.4. Sent whole, whisper.cpp carried a loop across its 30 s windows: a 45-min meeting came back 94% repetition. With auto-detect the first speech piece fixes the language for the rest. `RemoteSTT.request` also returns Whisper's detected `language`.
  - Local LLM: FoundationModels with `guardrails: .permissiveContentTransformations` (the default refuses ordinary business talk, e.g. a sentence about a payments app). Its window is 8,192 tokens on iOS 27; `chunkChars` is 10k locally.
  - Remote LLM: OpenAI `/chat/completions`, with `chat_template_kwargs.enable_thinking=false` and any `<think>` block stripped from the reply.
  - Summaries and Ask map-reduce long transcripts in chunks of `LLMConfig.chunkChars`. Part notes are capped at 10 bullets and shortened (twice at most, then cut) until they fit: uncapped, the on-device model's notes overflowed the final request.
  - `Languages.auto` works with remote STT and Parakeet (`Prefs.canDetectLanguage`); Apple's throws `autoNeedsServer`.
- **Analysis (`Analysis.swift`)** is the default summary (`Prefs.defaultSummaryInstructions`; a saved copy of the old default counts as the default). The prompt fixes two line forms the app reads back: `- **Speaker N — Name**` (`suggestedNames`) and `- Same person: Speaker A and Speaker B` (`samePerson` → `Speakers.merge`). `Analysis.talkLine` (each speaker's share) goes ahead of the transcript. `RecordingMeta.summaryModel` records the model; merges are offered only from a server model's analysis, because Apple's invents them. Runs after transcription when `Prefs.autoAnalyse`. Tried on real meetings: DeepSeek V4.1 Flash named speakers right and caught a split speaker, Qwen3.8 named them right, Qwen3.6 swapped two names; thinking added minutes and nothing visible.
- **`RecordingDetail.swift`**: Analysis / Transcript / Details tabs (`@AppStorage("recordingTab")`), `SpeakerBar`, `TranscriptTurn` (time → `Player.play(from:)`), `MarkdownView` renders the models' Markdown. `AppModel.progress[id]` carries the step shown under the spinner.
- **Translate (`Translator.swift`, `TranslateView.swift`)**: phrases from the mic (`MicTap`) or the Pocket's live stream (`AppModel.liveListener`, decoded by `MP3Decoder`; starts and stops a recording if none was running). Phrase gate: start 12 dB over a minimum-tracking floor; end below the floor/speaker midpoint for 0.7 / 0.35 / 0.17 s (phrase < 3 / < 6 / ≥ 6 s); at 8 s cut at the quietest frame of the last 3 s. A fixed gate ran every phrase to its cap on street audio. Device mode: Parakeet per phrase (Apple's streaming recognisers for other languages; Dutch is DictationTranscriber-only there and failed on street noise) then Apple Translation, whose session exists only inside `.translationTask` (fed through `appleQueue`; an empty item means `prepareTranslation`). Server mode: Whisper **without** a language (Whisper told "nl" translates spoken English into Dutch), retried with the source language if it detects a third one, then the LLM with the last 3 lines as context. A phrase already in the target language is shown as is; `Cleanup.isStockPhrase` drops "thanks for watching" / "ondertiteld door" phrases.
- **Speakers (`Speakers.swift`)**:
  - `Diarizer.diarize(url)` runs on the phone (`OnDeviceSpeech.diarize`: FluidAudio's offline pyannote + WeSpeaker + VBx, 20 MB) when `Prefs.diarizeOnDevice` (default), else posts the whole file to `/v1/audio/diarize`. Speaker ids hold only within one request, so the app never diarises chunks. On a phone call the server's Nemotron split the far end into two speakers after 10 minutes; the on-device one found two.
  - `Speakers.align` rules: midpoint rule, narrowest overlapping segment wins, nearest segment within 1.5 s, a gap of 2 s starts a new turn, speakers renumbered by first turn.
  - The output format is `[MM:SS] Speaker N: text`. Keep it stable.
  - `Recording.transcriptForModel` feeds that speaker text to the LLM whenever there are 2 or more speakers. Two speakers given the same name read as one.
- **Naming clash:** the app's transcript type is `TimedTranscript` because FoundationModels already exports `Transcript`.

## Server defaults and gotchas

- **No hard-coded servers.** Defaults come from `ble/.env` via `gen-defaults.sh`, into the generated `DefaultServer` enum: `SERVER_URL`, models, `DIARIZE_URLS` and the key. If `SERVER_URL` is empty, `LLMConfig.hasDefault` is false: STT, the LLM and speakers default to off/on-device and the "Reset to …" buttons are hidden. Never put a real URL, hostname or key in Swift.
- **Testing a key:** many gateways serve `/models` without auth, so the STT test sends a real 1 s silent WAV instead.
- **Whisper input:** whisper.cpp accepts mp3 and wav, but not m4a.
- **Diarisation contract:** `POST <base>/audio/diarize`, multipart `file` + `preset`, returning `{segments:[{start,end,speaker}]}`. Several base URLs are tried in order; 404/5xx/unreachable moves to the next.
- **Plain http:** `NSAllowsArbitraryLoads` is on so private-network `http://` servers work.

## Open-source hygiene

The repo root is a git repo published as `incept5-ai/private-pocket`. Before committing, check that nothing personal is staged: `.env`, `signing.env`, `ble/captures/` (the PacketLogger traces contain the session key), recordings and MP3s, and the `docs/`, `plugins/` and `report/` directories are all gitignored and must stay that way. Use example identifiers like `PKT01_GREY_2617abcd` in docs.
